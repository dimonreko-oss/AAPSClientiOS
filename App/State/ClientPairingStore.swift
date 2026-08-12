import Foundation

/// Everything the command channel needs in order to stay valid, persisted as one Keychain blob.
///
/// The failure this shape exists to kill: the HMAC secret used to live in the Keychain (which
/// survives app deletion) while the replay counter and `pairedAt` lived in `UserDefaults` (which
/// does not). After delete-and-reinstall the app looked fully paired with no user input and started
/// minting counter 1 again. Nightscout accepts those PUTs with HTTP 200, but the master's counter
/// gate is strictly-greater and runs *before* it writes any ack at all, so every envelope was
/// dropped in silence and the UI could only report a timeout — a permanently dead command channel
/// presented as a flaky master. Secret and counter are one atom; they live and die together.
struct PairingState: Codable, Equatable {
    let masterInstallId: String
    let clientId: String
    let secretHex: String
    /// Highest counter ever handed out by `nextCounter()`. Must never go backwards.
    var counterSent: Int64
    /// nil only for a blob recovered from a pre-blob install whose `UserDefaults` copy was lost.
    /// `OrphanDetector` reads nil as "unknown" and skips its post-pairing race guard, matching the
    /// master's own `pairedAt > 0` check.
    var pairedAt: Date?
    /// The master writes no ack for `hello` itself, so this flips on a verified Ping pong — the only
    /// client-observable proof that the roster entry was promoted from Pending to Active.
    var helloAcked: Bool
    /// Random per-install id, mirrored into a plain `UserDefaults` marker at pair time. The Keychain
    /// survives app deletion, `UserDefaults` does not, so a missing or mismatched marker is the only
    /// client-observable signature of "this secret was inherited by a fresh install".
    var deviceBindingId: String
    /// Last durable orphan verdict; nil until the master's roster has been seen at least once.
    /// Persisted so a revoked client stays revoked across relaunches instead of springing back to
    /// authorized until the next full refresh happens to run.
    var authorized: Bool?

    var pairing: MasterPairing {
        MasterPairing(masterInstallId: masterInstallId, clientId: clientId, secretHex: secretHex)
    }

    init(
        pairing: MasterPairing,
        counterSent: Int64 = 0,
        pairedAt: Date?,
        helloAcked: Bool = false,
        deviceBindingId: String,
        authorized: Bool? = nil
    ) {
        self.masterInstallId = pairing.masterInstallId
        self.clientId = pairing.clientId
        self.secretHex = pairing.secretHex
        self.counterSent = counterSent
        self.pairedAt = pairedAt
        self.helloAcked = helloAcked
        self.deviceBindingId = deviceBindingId
        self.authorized = authorized
    }
}

final class ClientPairingStore {
    /// Process-wide on purpose. Until `auth-single-store-instance` lands there are four live
    /// `ClientPairingStore` instances (three views plus `AppStore`) minting from the same Keychain
    /// item, and `ClientControlPublisher.send` runs off the main actor — a per-instance lock would
    /// not serialise them against each other. The critical section spans the whole
    /// decode → increment → encode → write, so two concurrent sends can never mint the same counter
    /// (which the master silently drops as a replay, with no ack).
    private static let stateLock = NSLock()

    /// Last counter handed out per service, in memory. Guards the one case the Keychain cannot:
    /// if the write-back of an incremented counter fails, the next call would otherwise re-issue
    /// the same value. Cleared on pair/unpair.
    private static var counterFloor: [String: Int64] = [:]

    private let service: String
    private let defaults: UserDefaults
    /// App-private access group + `ThisDeviceOnly` — see `SharedConstants.pairingKeychain`.
    private let keychain: KeychainStore
    /// Where builds before this change put the blob: `accessGroup: nil`, which on a build declaring
    /// `keychain-access-groups` resolves to the *first* declared group — the shared, widget-readable
    /// one. Read/migration source, and the write fallback if the app-private group turns out not to
    /// be usable under this build's provisioning profile.
    private let sharedGroupKeychain: KeychainStore

    /// Key of the plain `UserDefaults` install marker. Exposed so tests can simulate the one thing
    /// that cannot be simulated any other way: app deletion wiping `UserDefaults` while the Keychain
    /// item survives.
    static func installMarkerDefaultsKey(service: String) -> String { "\(service).installMarker" }

    private var installMarkerKey: String { Self.installMarkerDefaultsKey(service: service) }
    /// Pre-blob storage locations, read once during the in-place upgrade and then removed.
    private var legacyCounterKey: String { "\(service).counterSent" }
    private var legacyPairedAtKey: String { "\(service).pairedAt" }

    init(service: String = "clientcontrol.pairing") {
        self.service = service
        self.defaults = .standard
        self.keychain = SharedConstants.pairingKeychain(service: service)
        self.sharedGroupKeychain = KeychainStore(service: service, accessGroup: SharedConstants.keychainAccessGroup)
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        migrateLocked()
    }

    // MARK: - Pairing

    /// The pairing to sign with, or nil when there is nothing safe to send.
    ///
    /// Returns nil while `needsRepair` is true, deliberately. Every send path in the app already
    /// guards on this call, so a pairing whose durable counter state did not survive reads as
    /// "not paired" — which is what stops a reinstalled app from PUTting counter=1 envelopes that
    /// the master drops without ever writing an ack. Use `currentPairingIgnoringRepair()` for UI
    /// that needs to name the master while telling the user to re-pair.
    func currentPairing() -> MasterPairing? {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        guard let state = loadLocked(), !needsRepairLocked(state) else { return nil }
        return state.pairing
    }

    /// The stored pairing regardless of `needsRepair`. Display only — never build an envelope from it.
    func currentPairingIgnoringRepair() -> MasterPairing? {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        return loadLocked()?.pairing
    }

    func pair(_ pairing: MasterPairing) {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        let binding = UUID().uuidString
        let state = PairingState(
            pairing: pairing,
            counterSent: 0,
            pairedAt: Date(),
            helloAcked: false,
            deviceBindingId: binding,
            authorized: nil
        )
        Self.counterFloor[service] = 0
        writeLocked(state)
        // Marker last: a marker with no blob is inert, whereas a blob with no marker reads as a
        // reinstall and blocks sending.
        defaults.set(binding, forKey: installMarkerKey)
        defaults.removeObject(forKey: legacyCounterKey)
        defaults.removeObject(forKey: legacyPairedAtKey)
    }

    func unpair() {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        try? keychain.delete(.clientControlPairing)
        try? sharedGroupKeychain.delete(.clientControlPairing)
        Self.counterFloor.removeValue(forKey: service)
        defaults.removeObject(forKey: installMarkerKey)
        defaults.removeObject(forKey: legacyCounterKey)
        defaults.removeObject(forKey: legacyPairedAtKey)
    }

    /// True when the Keychain still holds a pairing secret but the durable counter state is gone
    /// (app deleted + reinstalled, or the blob restored onto a different install — the Keychain
    /// survives, `UserDefaults` does not). While true the client MUST NOT send: the master's
    /// strictly-greater counter gate would drop every envelope with no ack at all. The user has to
    /// re-pair.
    var needsRepair: Bool {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        guard let state = loadLocked() else { return false }
        return needsRepairLocked(state)
    }

    // MARK: - Counter

    /// Atomically mints the next envelope counter. Returns 0 when there is nothing safe to sign —
    /// unpaired, or `needsRepair`. Callers all guard on `currentPairing()` first (which is nil in
    /// both cases), and 0 can never satisfy the master's strictly-greater gate, so a stray envelope
    /// built from it is rejected outright rather than consuming a real counter.
    func nextCounter() -> Int64 {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        guard var state = loadLocked(), !needsRepairLocked(state) else { return 0 }
        let next = max(state.counterSent, Self.counterFloor[service] ?? 0) + 1
        Self.counterFloor[service] = next
        state.counterSent = next
        writeLocked(state)
        return next
    }

    /// When the current pairing was created. Used by `OrphanDetector`'s race-window guard —
    /// mirrors AndroidAPS's `NsClientControlPairedAt` preference.
    func pairedAt() -> Date? {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        return loadLocked()?.pairedAt
    }

    // MARK: - Hello promotion

    /// Records that the master answered a `wantsAck` command — proof it promoted our roster entry
    /// from Pending to Active. Only a verified pong counts; the master writes no ack for `hello`.
    func markHelloAcked() {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        guard var state = loadLocked(), !state.helloAcked else { return }
        state.helloAcked = true
        writeLocked(state)
    }

    var helloAcked: Bool {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        return loadLocked()?.helloAcked ?? false
    }

    // MARK: - Durable authorization verdict

    /// Last persisted orphan verdict, defaulting to true while unknown.
    ///
    /// Fails open on purpose: a client must not lock itself out of the command channel merely
    /// because it has not yet seen a roster. The change from the old in-memory
    /// `AppStore.clientControlAuthorized` is that a `false` now survives relaunch instead of
    /// reverting to true until some later full refresh happens to re-derive it.
    var isAuthorized: Bool {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        return loadLocked()?.authorized ?? true
    }

    /// Persists the *folded* verdict from `OrphanDetector.resolve` — pass the resolved value, not
    /// the raw verdict, because `.noSignal` / `.deferred` must leave the stored value untouched.
    func recordAuthorization(_ authorized: Bool?) {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        guard var state = loadLocked(), state.authorized != authorized else { return }
        state.authorized = authorized
        writeLocked(state)
    }

    // MARK: - Storage

    /// Reads the raw blob, preferring the app-private group and falling back to the shared group
    /// where pre-scoping builds left it.
    private func readRawLocked() -> Data? {
        for store in [keychain, sharedGroupKeychain] {
            if let json = try? store.get(.clientControlPairing), let data = json.data(using: .utf8) {
                return data
            }
        }
        return nil
    }

    private func loadLocked() -> PairingState? {
        guard let raw = readRawLocked() else { return nil }
        return try? JSONDecoder().decode(PairingState.self, from: raw)
    }

    private func writeLocked(_ state: PairingState) {
        guard let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else { return }
        do {
            try keychain.set(json, for: .clientControlPairing)
        } catch {
            // The app-private group is unusable under this build's provisioning profile. Degrade to
            // the previous (shared-group) location rather than losing the pairing outright.
            try? sharedGroupKeychain.set(json, for: .clientControlPairing)
        }
    }

    private func needsRepairLocked(_ state: PairingState) -> Bool {
        guard let marker = defaults.string(forKey: installMarkerKey) else { return true }
        return marker != state.deviceBindingId
    }

    /// One-time upgrade from the pre-blob layout: a bare `MasterPairing` in the Keychain plus a
    /// counter and `pairedAt` in `UserDefaults`.
    private func migrateLocked() {
        guard let raw = readRawLocked() else { return }
        // Already the blob format — the install marker (or its absence) is authoritative from here.
        if (try? JSONDecoder().decode(PairingState.self, from: raw)) != nil { return }
        guard let legacy = try? JSONDecoder().decode(MasterPairing.self, from: raw) else { return }

        // `UserDefaults` surviving alongside the Keychain item proves the app was upgraded in place
        // rather than deleted and reinstalled, so the counter it holds is the real one and must be
        // carried over. Restarting from 0 here would be the exact desync this whole change exists
        // to prevent, and it would hit every existing paired install on first launch of this build.
        let legacyCounter = defaults.object(forKey: legacyCounterKey) as? NSNumber
        let legacyPairedAt = defaults.object(forKey: legacyPairedAtKey) as? NSNumber
        let isInPlaceUpgrade = legacyCounter != nil || legacyPairedAt != nil

        let binding = UUID().uuidString
        let state = PairingState(
            pairing: legacy,
            counterSent: legacyCounter?.int64Value ?? 0,
            pairedAt: legacyPairedAt.map { Date(timeIntervalSince1970: $0.doubleValue) },
            helloAcked: false,
            deviceBindingId: binding,
            authorized: nil
        )
        writeLocked(state)

        guard isInPlaceUpgrade else {
            // No `UserDefaults` at all next to a live Keychain secret: this install inherited the
            // secret from a deleted one. Leave the marker unwritten so `needsRepair` stays true and
            // the client refuses to send until the user re-pairs.
            return
        }
        defaults.set(binding, forKey: installMarkerKey)
        defaults.removeObject(forKey: legacyCounterKey)
        defaults.removeObject(forKey: legacyPairedAtKey)
        purgeSharedGroupCopyLocked(restoring: state)
    }

    /// Removes a blob left behind in the shared, widget-readable group once it has been copied into
    /// the app-private group. Verifies the app-private copy survived: keychain access groups are not
    /// partitioned on the Simulator, where both queries can resolve to the same physical item and
    /// the delete would take the copy we just wrote with it.
    private func purgeSharedGroupCopyLocked(restoring state: PairingState) {
        guard (try? sharedGroupKeychain.get(.clientControlPairing)) != nil else { return }
        try? sharedGroupKeychain.delete(.clientControlPairing)
        if (try? keychain.get(.clientControlPairing)) == nil {
            writeLocked(state)
        }
    }
}
