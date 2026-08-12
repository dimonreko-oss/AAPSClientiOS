import SwiftUI

struct ClientControlPairingView: View {
    @ObservedObject var store: AppStore

    @State private var pin = ""
    @State private var matchedPayload: PairingPayload?
    @State private var isSearching = false
    @State private var statusText: String?
    @State private var isPaired = false

    /// The app's single pairing store — the counter, the hello receipt and the orphan verdict all
    /// live in one Keychain blob now, and a per-view instance would fork that state.
    private var pairingStore: ClientPairingStore { store.clientPairingStore }

    var body: some View {
        Form {
            if pairingStore.needsRepair, let stale = pairingStore.currentPairingIgnoringRepair() {
                // Without this the view silently falls back to the PIN form: `currentPairing()`
                // returns nil in this state, so the user sees no pairing and no explanation.
                Section {
                    Label("clientcontrol.repair_title", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(String(format: String(localized: "clientcontrol.repair_message"), stale.masterInstallId))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(String(localized: "clientcontrol.repair_action"), role: .destructive) {
                        pairingStore.unpair()
                        isPaired = false
                        statusText = String(localized: "clientcontrol.unpaired")
                    }
                }
            } else if let banner = ClientControlText.banner(store.clientControlState) {
                Section {
                    Text(banner)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // While `needsRepair` the only useful control is the one in the banner above: nothing
            // may be sent, and a PIN form next to a live-looking pairing would just be confusing.
            if !pairingStore.needsRepair {
                Section("clientcontrol.section_title") {
                    if let pairing = pairingStore.currentPairing(), matchedPayload == nil {
                        LabeledContent(String(localized: "clientcontrol.client_id"), value: pairing.clientId)
                        LabeledContent(String(localized: "clientcontrol.master"), value: pairing.masterInstallId)
                        Button(String(localized: "clientcontrol.send_ping")) { sendPing() }
                        if !pairingStore.helloAcked {
                            // The master's roster entry stays Pending until a Hello lands, and it is
                            // pruned after PAIR_TTL_MS — a swallowed Hello used to be unrecoverable.
                            Button(String(localized: "clientcontrol.resend_hello")) { sendHello() }
                        }
                        Button(String(localized: "clientcontrol.unpair"), role: .destructive) {
                            pairingStore.unpair()
                            isPaired = false
                            statusText = String(localized: "clientcontrol.unpaired")
                        }
                    } else {
                        TextField("clientcontrol.pin", text: $pin)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .onChange(of: pin) { value in
                                pin = String(value.filter(\.isNumber).prefix(8))
                            }

                        Button(isSearching
                               ? String(localized: "clientcontrol.searching")
                               : String(localized: "clientcontrol.find_offer")) {
                            findOffer()
                        }
                        .disabled(pin.count != 8 || isSearching)
                    }
                }
            }

            if let payload = matchedPayload {
                Section("clientcontrol.confirm_master") {
                    LabeledContent(String(localized: "clientcontrol.master"), value: payload.masterInstallId)
                    LabeledContent(String(localized: "clientcontrol.client_id"), value: payload.clientId)
                    if let left = PairingOfferFetcher.remainingLifetime(payload, now: Date()) {
                        // The window is two minutes; a user who sits on this screen has to see it
                        // closing, because past it the pairing can never be promoted.
                        LabeledContent(String(localized: "clientcontrol.offer_expires_in"),
                                       value: String(format: String(localized: "clientcontrol.offer_seconds"), Int(left)))
                    }
                    Button(String(localized: "clientcontrol.confirm_pairing")) { confirm(payload) }
                }
            }

            if let statusText {
                Section {
                    Text(statusText)
                        .foregroundColor(isPaired ? .green : .secondary)
                }
            }
        }
        .navigationTitle("clientcontrol.title")
    }

    // MARK: - Pairing

    private func findOffer() {
        isSearching = true
        statusText = nil
        matchedPayload = nil
        let enteredPin = pin

        Task {
            do {
                store.ensureConfigured()
                let docs = try await store.client.searchSettings(limit: 500)
                let offers = docs.compactMap(offer(from:))
                // PBKDF2-HMAC-SHA256 at 200 000 iterations *per candidate offer*. On the main actor
                // that is a visibly frozen screen; AAPS moved the same unwrap off Main for the same
                // reason. The UI writes below stay on Main.
                let result = await Task.detached(priority: .userInitiated) {
                    PairingOfferFetcher.match(offers: offers, pin: enteredPin, now: Date())
                }.value
                await MainActor.run {
                    switch result {
                    case .success(let payload):
                        matchedPayload = payload
                        statusText = String(localized: "clientcontrol.offer_found")
                    case .ambiguous:
                        statusText = String(localized: "clientcontrol.offer_ambiguous")
                    case .noMatch:
                        statusText = String(localized: "clientcontrol.offer_none")
                    }
                    isSearching = false
                }
            } catch {
                await MainActor.run {
                    statusText = String(format: String(localized: "clientcontrol.search_failed"), error.localizedDescription)
                    isSearching = false
                }
            }
        }
    }

    private func confirm(_ payload: PairingPayload) {
        // Re-check at confirm time: `match` filtered on expiry at scan time, but the master prunes
        // its Pending roster entry after PAIR_TTL_MS (2 min) and the user can sit here longer. Past
        // that, committing the secret produces a client that looks paired and can never be promoted.
        guard !PairingOfferFetcher.isExpired(payload, now: Date()) else {
            statusText = String(localized: "clientcontrol.offer_expired")
            matchedPayload = nil
            return
        }

        let pairing = MasterPairing(
            masterInstallId: payload.masterInstallId,
            clientId: payload.clientId,
            secretHex: payload.secretHex
        )
        pairingStore.pair(pairing)
        isPaired = true
        matchedPayload = nil
        pin = ""
        // A fresh pairing clears any desync suspicion inherited from the previous one.
        store.resetRoundTripSilence()
        statusText = String(localized: "clientcontrol.hello_sending")
        sendHello()
    }

    /// Hello has no ack of its own — the master promotes the roster entry instead. `.sent` means only
    /// "the signed envelope reached Nightscout"; the verified pong from `sendPing()` is the receipt.
    ///
    /// Deliberately NOT routed through `store.recordRoundTripOutcome`: that is why `hello()` returns
    /// its own `HelloOutcome`. Feeding a bare HTTP 200 to the liveness clock faked nine minutes of
    /// `masterReachable` against a master that might be switched off, and reset the counter-desync
    /// counter that "Resend hello" exists to diagnose.
    private func sendHello() {
        Task {
            let outcome = await store.clientControlRoundTrip.hello()
            await MainActor.run {
                switch outcome {
                case .sent:
                    statusText = String(localized: "clientcontrol.hello_sent")
                    // The master writes no ack for Hello, so the pong is the ONLY thing that calls
                    // `markHelloAcked()`. Without chaining it here every healthy pairing ages past
                    // `ClientControlStatusResolver.pairingWindow` and renders `.pairedPendingExpired`
                    // with a permanent "Pair again" banner that re-pairing cannot clear.
                    sendPing()
                case .failed(let reason):
                    statusText = String(
                        format: String(localized: "clientcontrol.hello_failed"),
                        ClientControlText.rejectionText(reason)
                    )
                }
            }
        }
    }

    private func sendPing() {
        guard !pairingStore.needsRepair else {
            statusText = ClientControlText.banner(.needsRepair)
            return
        }
        statusText = String(localized: "clientcontrol.ping_sending")
        Task {
            let outcome = await store.clientControlRoundTrip.ping()
            await MainActor.run {
                store.recordRoundTripOutcome(outcome)
                if case .applied = outcome {
                    // Ping is exempt from the master's policy gate, so a verified pong is the only
                    // proof the roster entry went Pending → Active.
                    pairingStore.markHelloAcked()
                }
                switch outcome {
                case .applied:
                    statusText = String(localized: "clientcontrol.ping_ok")
                case .rejected, .unconfirmed:
                    statusText = ClientControlText.failureText(for: outcome)
                }
            }
        }
    }

    private func offer(from document: NsSettingsDocument) -> PairingOffer? {
        guard document.identifier.hasPrefix(PairingOfferFetcher.offerIdentifierPrefix),
              let data = document.runningConfigJson.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(PairingOffer.self, from: data)
    }
}
