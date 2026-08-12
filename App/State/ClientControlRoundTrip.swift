import Foundation

/// Terminal outcome of one client-control round trip.
///
/// Three states on purpose: `unconfirmed` is NOT a flavour of failure. When no Done ack arrives
/// before the deadline the master may still have applied the command, so the UI must switch on all
/// three exhaustively and never collapse `unconfirmed` into either "activated" or "nothing happened".
enum RoundTripOutcome: Equatable {
    /// Master answered Done/Ok. `payload` is the raw ack payload JSON — a `BolusPreview` for any
    /// `..Prepare`, nil for commands that return nothing (Ping, SceneCommit, SceneStop).
    case applied(payload: String?)
    /// Definitively refused — by the master (Done/Failed, Done/Expired) or locally (not paired,
    /// another command in flight, the PUT failed, the ack did not verify). `reason` is the master's
    /// `FailureReason` case name when it came from the master, otherwise a `RoundTripReason` code.
    case rejected(reason: String?)
    /// No Done ack before the deadline. THERAPY STATE IS UNKNOWN.
    case unconfirmed
}

/// The result of a Hello.
///
/// Its own type, deliberately NOT a `RoundTripOutcome`: the master writes no ack for Hello — it
/// promotes the pairing entry Pending → Active instead — so a successful PUT proves only that
/// *Nightscout* accepted the document. Returning `.applied` made `ClientControlSignal
/// .provesMasterAlive` true, which set `lastVerifiedAckAt`, which made `masterControlAvailability`
/// report `.available` for the full nine-minute liveness window against a master that might be
/// switched off — the one "HTTP 200 rendered as success" the rest of this work exists to remove.
/// A separate type makes feeding it to the liveness clock a compile error rather than a judgement
/// call. `ping()` is the receipt.
enum HelloOutcome: Equatable {
    /// The signed envelope reached Nightscout. Says nothing whatsoever about the master.
    case sent
    /// The PUT itself failed. `reason` is a `RoundTripReason` code, optionally `Code — detail`.
    case failed(reason: String?)
}

/// Locally-minted rejection codes. Deliberately shaped like the master's `FailureReason` case names
/// (PascalCase) so one mapping at the call site covers both sources.
enum RoundTripReason {
    static let busy = "Busy"
    static let notPaired = "NotPaired"
    static let sendFailed = "SendFailed"
    static let badSignature = "BadSignature"
    /// No longer produced: a verified terminal ack we cannot date is `.unconfirmed`, not a refusal
    /// (see `readAck`). Kept because it is still a `locallyMintedReasons` member and still has a
    /// localized sentence — a master with a drifted clock that some future build wants to name
    /// explicitly should reuse this code rather than invent a second one.
    static let staleAck = "StaleAck"
    static let expired = "Expired"
    /// This client's command slot on NS was soft-deleted by some earlier build and is now a
    /// tombstone: every PUT to that identifier answers HTTP 410 forever. Unrecoverable for this
    /// clientId — only a re-pair (which mints a new clientId, hence a new identifier) fixes it.
    static let slotTombstoned = "SlotTombstoned"

    /// Separates a code from its free-text detail inside `RoundTripOutcome.rejected(reason:)`.
    static let detailSeparator = " — "
}

extension RoundTripOutcome {
    /// Decodes the ack payload of a `..Prepare` into the master's signed preview. nil when the
    /// outcome was not `.applied`, carried no payload, or the payload did not parse.
    ///
    /// `JSONSerialization`, never `JSONDecoder`: the master serializes Kotlin `Double`s at full
    /// precision (`"insulinFromCOB":0.30000000000000004`, `"sens":82.80000000000001`), which is
    /// exactly the shape the iOS 18+ swift-foundation `JSONDecoder` number parser rejects with
    /// `dataCorrupted` — see the header of `NsMapping`, which states the rule for the whole app. A
    /// `try?` around a decoder that throws on real master output turns a command that SUCCEEDED into
    /// "unreadable", and for a scene prepare that loses the parked `bolusId` for good.
    var preview: BolusPreview? {
        guard case .applied(let raw) = self,
              let payload = raw,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return BolusPreview(jsonObject: object)
    }
}

/// Single-command gate. The master's ack document is ONE per-client slot it overwrites in place, so
/// two overlapping round trips race on it and the loser spins to its deadline on a command that
/// actually applied. Mirrors `ClientControlRoundTrip.kt`'s `AtomicBoolean`, but held PROCESS-WIDE
/// (`shared`) rather than per-instance, because each screen still builds its own coordinator today.
final class RoundTripGate: @unchecked Sendable {
    static let shared = RoundTripGate()

    private let lock = NSLock()
    private var busy = false

    /// True when the gate was free and is now held by the caller, who must `release()` it.
    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }

    func release() {
        lock.lock()
        busy = false
        lock.unlock()
    }
}

/// Owns one client-control command end to end: mint + PUT the signed envelope, poll the master's
/// shared ack slot until the deadline, and reduce the result to a `RoundTripOutcome`.
///
/// The deadline is derived from the command's own signed `validUntil` (`now + ttl`) plus
/// `ClientControlTiming.propagationMarginMs`, so the client always stops listening AFTER the master
/// has stopped being allowed to apply the command. The previous fixed 5×1 s loop gave up three
/// seconds before the master's own 8 s deadline while having signed a five-minute window.
actor ClientControlRoundTrip {
    private let publisher: ClientControlPublisher
    private let gate: RoundTripGate
    private let now: () -> Date
    private let sleepNanos: (UInt64) async throws -> Void

    /// How often to re-read the shared ack slot. The master writes Executing then Done, both inside
    /// a second on a healthy link, so a 1 s cadence costs ~10 reads for a full round trip.
    private static let pollIntervalNanos: UInt64 = 1_000_000_000

    init(
        publisher: ClientControlPublisher,
        gate: RoundTripGate = .shared,
        now: @escaping () -> Date = { Date() },
        sleepNanos: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.publisher = publisher
        self.gate = gate
        self.now = now
        self.sleepNanos = sleepNanos
    }

    // MARK: - Commands

    /// The master writes NO ack for Hello — it promotes the pairing entry Pending → Active instead.
    ///
    /// Returns `HelloOutcome`, not `RoundTripOutcome`, so its success can never reach
    /// `AppStore.recordRoundTripOutcome`: see the type's own doc comment. Confirm the promotion with
    /// `ping()` and treat the verified pong as the receipt.
    func hello() async -> HelloOutcome {
        guard gate.acquire() else { return .failed(reason: RoundTripReason.busy) }
        defer { gate.release() }
        do {
            _ = try await publisher.sendHello()
            return .sent
        } catch {
            return .failed(reason: Self.sendFailureReason(error))
        }
    }

    func ping() async -> RoundTripOutcome {
        await perform(ttlMs: ClientControlTiming.pingMs) { ttl in
            try await self.publisher.sendPing(ttlMs: ttl)
        }
    }

    func scenePrepare(sceneId: String, durationMinutes: Int?) async -> RoundTripOutcome {
        await perform(ttlMs: ClientControlTiming.roundTripMs) { ttl in
            try await self.publisher.sendScenePrepare(sceneId: sceneId, durationMinutes: durationMinutes, ttlMs: ttl)
        }
    }

    func sceneCommit(bolusId: Int64) async -> RoundTripOutcome {
        await perform(ttlMs: ClientControlTiming.roundTripMs) { ttl in
            try await self.publisher.sendSceneCommit(bolusId: bolusId, ttlMs: ttl)
        }
    }

    func sceneStop(triggerChain: Bool) async -> RoundTripOutcome {
        await perform(ttlMs: ClientControlTiming.roundTripMs) { ttl in
            try await self.publisher.sendSceneStop(triggerChain: triggerChain, ttlMs: ttl)
        }
    }

    /// Read-only: displays the master's own computed dose. There is no matching commit in this app.
    func wizardPrepare(_ inputs: ClientControlMessage.WizardPrepare) async -> RoundTripOutcome {
        await perform(ttlMs: ClientControlTiming.roundTripMs) { ttl in
            try await self.publisher.sendWizardPrepare(inputs, ttlMs: ttl)
        }
    }

    // MARK: - Private

    private func perform(ttlMs: Int64, send: (Int64) async throws -> Int64) async -> RoundTripOutcome {
        guard gate.acquire() else { return .rejected(reason: RoundTripReason.busy) }
        defer { gate.release() }

        let deadline = now().addingTimeInterval(Double(ttlMs + ClientControlTiming.propagationMarginMs) / 1000)
        let counter: Int64
        do {
            counter = try await send(ttlMs)
        } catch {
            // The counter is minted before the PUT, so a failed PUT burns one. That is correct: the
            // master's replay gate is strictly-greater, so a gap is harmless and a reuse is not.
            return .rejected(reason: Self.sendFailureReason(error))
        }
        return await pollAck(counter: counter, until: deadline)
    }

    private func pollAck(counter: Int64, until deadline: Date) async -> RoundTripOutcome {
        while now() < deadline {
            do {
                try await sleepNanos(Self.pollIntervalNanos)
            } catch {
                // Cancelled mid-wait — we never saw a Done ack, so the state really is unknown.
                return .unconfirmed
            }
            if let outcome = await readAck(counter: counter) { return outcome }
        }
        // The ack may have landed inside the final interval — one last read before giving up.
        if let outcome = await readAck(counter: counter) { return outcome }
        return .unconfirmed
    }

    /// nil means "keep waiting".
    private func readAck(counter: Int64) async -> RoundTripOutcome? {
        let result: ClientControlPublisher.AckResult
        do {
            result = try await publisher.fetchAck(expectedCounter: counter)
        } catch ClientControlPublisher.PublishError.notPaired {
            return .rejected(reason: RoundTripReason.notPaired)
        } catch {
            // A transient read failure is not an answer — keep polling until the deadline.
            return nil
        }
        switch result {
        case .pending:
            return nil
        case .invalidSignature:
            return .rejected(reason: RoundTripReason.badSignature)
        case .staleTimestamp:
            // A verified terminal ack we cannot DATE is not a refusal — the master may well have
            // applied the command. Reporting "the master rejected it" invites the user to re-tap,
            // which for a scene activation means doing it twice. The skew check is an iOS-only
            // invention (the Kotlin client performs none on acks), so it must fail into the honest
            // "state unknown" bucket, never into a definitive verdict.
            return .unconfirmed
        case .terminal(let status, let reason, let payload):
            switch status {
            case .ok:
                return .applied(payload: payload)
            case .failed:
                // The master puts the FailureReason NAME in `reason` and the human detail in
                // `payload` — `AckOutcome(Failed, FailureReason.BolusComputeFailed.name,
                // result.message)`, e.g. "no BG value available" / "pump not available". The Kotlin
                // client forwards both; dropping `payload` collapsed every compute failure into one
                // generic sentence with no clue why. `ClientControlText.rejectionText` already
                // renders the `Code — detail` shape.
                guard let code = reason, let detail = payload, !detail.isEmpty else {
                    return .rejected(reason: reason)
                }
                return .rejected(reason: code + RoundTripReason.detailSeparator + detail)
            case .expired:
                // The master ALWAYS attaches free text here ("expired before master applied it"), so
                // its `reason` is never a FailureReason code and `reason ?? .expired` never fell
                // through — the localized `clientcontrol.fail.expired` was unreachable and the user
                // saw untranslated master-authored English. Use our own code, keep the text as detail.
                guard let detail = reason, !detail.isEmpty else {
                    return .rejected(reason: RoundTripReason.expired)
                }
                return .rejected(reason: RoundTripReason.expired + RoundTripReason.detailSeparator + detail)
            // Done/Pending is not a shape the master produces; treat it as still running.
            case .pending:
                return nil
            }
        }
    }

    private static func sendFailureReason(_ error: Error) -> String {
        if let publishError = error as? ClientControlPublisher.PublishError {
            switch publishError {
            case .notPaired:     return RoundTripReason.notPaired
            case .signingFailed: return RoundTripReason.sendFailed + RoundTripReason.detailSeparator + "signing failed"
            }
        }
        // HTTP 410 on a command slot is a tombstone, and it is permanent: NS never resurrects a
        // deleted settings identifier. Naming it is the difference between "your network hiccuped,
        // try again" (which will fail forever) and "re-pair" (which actually fixes it, because a new
        // clientId means a new slot identifier).
        if let http = error as? NsHttpStatusError, http.code == 410 {
            return RoundTripReason.slotTombstoned + RoundTripReason.detailSeparator + http.detail
        }
        return RoundTripReason.sendFailed + RoundTripReason.detailSeparator + error.localizedDescription
    }
}
