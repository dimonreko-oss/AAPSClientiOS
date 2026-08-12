import Foundation

/// Where this install stands with the master's signed command channel.
///
/// One enum rather than four loose booleans because the states are mutually exclusive and each one
/// needs a *different* sentence and a *different* recovery. The failure this replaces: every
/// permanent, user-fixable condition (revoked on the master, counter desynced by a reinstall, an
/// unpromoted pairing whose 2-minute window has closed) surfaced as the same generic timeout, so the
/// only recovery — unpair and pair again — was undiscoverable.
enum ClientControlAuthorizationState: Equatable {
    /// No Nightscout credentials at all; nothing above this can be evaluated.
    case unconfigured
    /// Nightscout works, but this client has never paired with a master.
    case nsOnly
    /// The Keychain secret survived a reinstall but the durable counter did not. Sending would put
    /// counter=1 envelopes into the master's strictly-greater gate, which drops them *before*
    /// writing any ack — indistinguishable from an offline master. Hard block.
    case needsRepair
    /// Paired and hello sent, but no verified pong yet. The master's roster entry is still Pending.
    case pairedPending
    /// Still Pending past the master's `PAIR_TTL_MS`. The entry has been pruned and `markActive` is
    /// unreachable, so retrying hello can never work — this must terminate in "re-pair", not a loop.
    case pairedPendingExpired
    /// Promoted: a verified ack proves the roster entry went Pending → Active.
    case pairedActive
    /// The master's roster no longer lists this clientId.
    case revoked
    /// Repeated `wantsAck` commands went unanswered while the master was demonstrably alive. That
    /// silence is the unique client-observable signature of the counter gate — expiry and
    /// ControlDisabled both produce real, signed acks.
    case counterDesynced

    /// True when no command may be sent in this state.
    var blocksSending: Bool {
        switch self {
        case .unconfigured, .nsOnly, .needsRepair, .revoked, .counterDesynced, .pairedPendingExpired:
            return true
        case .pairedPending, .pairedActive:
            return false
        }
    }

    /// Whether the only way out is to pair again from scratch.
    var requiresRepairing: Bool {
        switch self {
        case .needsRepair, .revoked, .counterDesynced, .pairedPendingExpired: return true
        case .unconfigured, .nsOnly, .pairedPending, .pairedActive: return false
        }
    }

    /// Banner text, or nil when there is nothing to say.
    ///
    /// English literals on purpose: this type lives in `App/State`, which has no business owning
    /// user copy. `App/UI/ClientControlText.banner(_:)` is the localized rendering every screen
    /// actually uses; these are the fallback wording and the specification of what each state means.
    var bannerText: String? {
        switch self {
        case .unconfigured, .nsOnly, .pairedActive:
            return nil
        case .pairedPending:
            return "Paired, waiting for the master to confirm. Send a ping from Settings › Client Control."
        case .pairedPendingExpired:
            return "The master never confirmed this pairing and its 2-minute window has closed. Pair again."
        case .needsRepair:
            return "Re-pair required — this install inherited a pairing but not its message counter."
        case .revoked:
            return "This client was removed on the master. Pair again to restore remote control."
        case .counterDesynced:
            return "The master is answering, but not this client's commands. Pair again to resync."
        }
    }
}

/// Whether a command may be sent to the master *right now*, and if not, which of the several very
/// different reasons applies.
///
/// "Control switched off on the master" and "master unreachable" must never share a sentence: the
/// first is a setting the user can go and change, the second is a wait-and-see. Both currently
/// render as a generic timeout after burning a counter.
enum MasterControlAvailability: Equatable {
    case notPaired
    case needsRepair
    case revoked
    /// The master published nothing for `ns_allow_client_control` — too old to serve client control
    /// at all. Fails closed: this is the one capability flag whose absence is meaningful, because it
    /// *is* declared `SyncSpec(Cold, MasterOnly)` and so is always published by a master that has it.
    case notAdvertised
    /// The master published `ns_allow_client_control = false`.
    case controlDisabled
    /// No authenticated signal from the master inside the liveness window.
    case unreachable
    case available

    var canSend: Bool { self == .available }

    // User-facing wording lives in `App/UI/ClientControlText.availability(_:)` — ONE localized
    // table. A second hardcoded-English copy used to sit here; nothing referenced it, both screens
    // already went through `ClientControlText`, and two tables for the same six conditions only
    // drift. (`RoundTripOutcome.failureText` was the same mistake and was deleted for the same
    // reason.) `App/State` has no business owning user copy.
}

/// Pure resolvers for the two states above. Kept free of `AppStore` so both are unit-testable
/// without standing up a store, a keychain or a network client.
enum ClientControlStatusResolver {
    /// `PairingOfferPublisher.PAIR_TTL_MS` on the master: a Pending roster entry is pruned after two
    /// minutes and `markActive` becomes unreachable.
    static let pairingWindow: TimeInterval = 120

    /// How many consecutive unanswered round trips count as a counter desync. Three, because a
    /// single silent command is ordinary (the master was mid-loop, the phone lost signal) and two is
    /// bad luck; three while the devicestatus heartbeat keeps arriving is a pattern.
    static let desyncThreshold = 3

    /// The master uploads a devicestatus every five minutes *even when the loop is not running*
    /// (`KeepAliveWorker` does this precisely in that case), so nine minutes tolerates exactly one
    /// missed heartbeat. Never anchor this on treatment or profile recency: the fork defers those by
    /// up to 300 min via `ns_client_sync_interval`, which is not published to followers.
    static let masterSignalWindow: TimeInterval = 9 * 60

    /// Below this the master legitimately stops uploading devicestatus on an upstream build
    /// (sub-39 readings are excluded from its read path, so the loop stops). A gap there is expected
    /// behaviour, not evidence of an unreachable master.
    static let hypoSuppressionMgdl = 39

    static func resolve(
        isConfigured: Bool,
        isPaired: Bool,
        needsRepair: Bool,
        helloAcked: Bool,
        pairedAt: Date?,
        authorized: Bool,
        silentRoundTrips: Int,
        masterReachable: Bool,
        now: Date
    ) -> ClientControlAuthorizationState {
        guard isConfigured else { return .unconfigured }
        // Ordered by how permanent the condition is. `needsRepair` outranks everything paired-shaped
        // because in that state the pairing on screen is a lie — it cannot produce a valid envelope.
        if needsRepair { return .needsRepair }
        guard isPaired else { return .nsOnly }
        if !authorized { return .revoked }
        if silentRoundTrips >= desyncThreshold && masterReachable { return .counterDesynced }
        if helloAcked { return .pairedActive }
        if let pairedAt, now.timeIntervalSince(pairedAt) > pairingWindow {
            return .pairedPendingExpired
        }
        return .pairedPending
    }

    static func availability(
        isPaired: Bool,
        needsRepair: Bool,
        authorized: Bool,
        publishedClientControlEnabled: Bool?,
        lastMasterSignal: Date?,
        latestGlucoseMgdl: Int?,
        now: Date,
        window: TimeInterval = ClientControlStatusResolver.masterSignalWindow
    ) -> MasterControlAvailability {
        if needsRepair { return .needsRepair }
        guard isPaired else { return .notPaired }
        if !authorized { return .revoked }
        switch publishedClientControlEnabled {
        case .none: return .notAdvertised
        case .some(false): return .controlDisabled
        case .some(true): break
        }
        // Fails closed on cold start: no signal yet is not the same as a fresh one.
        guard let lastMasterSignal else { return .unreachable }
        guard now.timeIntervalSince(lastMasterSignal) > window else { return .available }
        if let latestGlucoseMgdl, latestGlucoseMgdl < hypoSuppressionMgdl {
            // See `hypoSuppressionMgdl`. Be tolerant rather than aggressive here — the cost of a
            // false "unreachable" during a severe hypo is that we hide the one control the carer
            // might want.
            return .available
        }
        return .unreachable
    }
}

/// Classification of a finished round trip for liveness purposes.
enum ClientControlSignal {
    /// Rejection codes minted by *this* client. They say nothing about the master, so they must not
    /// refresh the liveness clock. `RoundTripReason.expired` is deliberately absent — the master is
    /// what writes an Expired ack, so receiving one proves it is alive and reading our envelopes.
    static let locallyMintedReasons: Set<String> = [
        RoundTripReason.busy,
        RoundTripReason.notPaired,
        RoundTripReason.sendFailed,
        RoundTripReason.badSignature,
        RoundTripReason.staleAck,
        // Nightscout's verdict on a tombstoned slot, not the master's.
        RoundTripReason.slotTombstoned,
    ]

    /// True when the outcome could only have been produced by the master itself.
    ///
    /// `.applied` qualifies because the only way to get one is a signed, counter-matched, in-skew
    /// Done/Ok ack. Hello is deliberately not expressible here at all — it returns `HelloOutcome`,
    /// precisely so a bare HTTP 200 cannot be mistaken for that.
    static func provesMasterAlive(_ outcome: RoundTripOutcome) -> Bool {
        switch outcome {
        case .applied:
            return true
        case .unconfirmed:
            return false
        case .rejected(let reason):
            guard let reason, !reason.isEmpty else { return false }
            let code = reason.components(separatedBy: RoundTripReason.detailSeparator).first ?? reason
            return !locallyMintedReasons.contains(code)
        }
    }
}
