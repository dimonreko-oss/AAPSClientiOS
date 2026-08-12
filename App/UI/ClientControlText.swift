import Foundation

/// The one place that turns client-control machine state into a sentence the user can act on.
///
/// Three sources feed in and all three arrive as bare English or as bare PascalCase codes:
/// `RoundTripOutcome.rejected(reason:)` carries the master's `FailureReason` **name** straight off
/// the wire, while `MasterControlAvailability` and `ClientControlAuthorizationState` live in
/// `App/State`, which has no business owning user copy. Mapping them here keeps every string in
/// `Localizable.strings` and keeps the three screens from inventing their own wording for the same
/// condition — which is how "the master is off" and "the master is unreachable" ended up sharing a
/// generic timeout message in the first place.
enum ClientControlText {

    // MARK: - Round-trip outcomes

    /// Text for the two non-success outcomes; nil for `.applied`.
    ///
    /// `.unconfirmed` deliberately never says the command applied *or* that it failed: the master
    /// may have executed it after we stopped listening, so the only honest answer is "check it".
    static func failureText(for outcome: RoundTripOutcome) -> String? {
        switch outcome {
        case .applied:
            return nil
        case .unconfirmed:
            return String(localized: "clientcontrol.outcome.unconfirmed")
        case .rejected(let reason):
            return rejectionText(reason)
        }
    }

    /// Renders a `rejected` reason. The wire format is `Code` or `Code — detail`.
    static func rejectionText(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return String(localized: "clientcontrol.fail.unknown") }
        let parts = raw.components(separatedBy: RoundTripReason.detailSeparator)
        let code = parts.first ?? raw
        let detail = parts.dropFirst().joined(separator: RoundTripReason.detailSeparator)
        // A newer master may add a FailureReason we have never heard of. Showing the raw code beats
        // swallowing it into a generic "failed" — it is the only clue the user can relay.
        guard let sentence = sentence(forCode: code) else { return raw }
        guard !detail.isEmpty else { return sentence }
        return sentence + RoundTripReason.detailSeparator + detail
    }

    /// `nil` for an unrecognised code. Codes are `ActionProgress.FailureReason` names on the master
    /// side (`core/interfaces/.../ActionProgress.kt`) and `RoundTripReason` values locally; the two
    /// sets are deliberately spelled the same way so one table covers both.
    private static func sentence(forCode code: String) -> String? {
        switch code {
        // Locally minted, and the master's transport-side names.
        case RoundTripReason.notPaired:    return String(localized: "clientcontrol.fail.not_paired")
        case RoundTripReason.busy:         return String(localized: "clientcontrol.fail.busy")
        case RoundTripReason.sendFailed:   return String(localized: "clientcontrol.fail.send_failed")
        case RoundTripReason.badSignature: return String(localized: "clientcontrol.fail.bad_signature")
        case RoundTripReason.staleAck:     return String(localized: "clientcontrol.fail.stale_ack")
        case RoundTripReason.expired:      return String(localized: "clientcontrol.fail.expired")
        // Unrecoverable for this clientId: NS never resurrects a soft-deleted settings identifier,
        // so the sentence must name re-pairing (a new clientId = a new slot) rather than "try again".
        case RoundTripReason.slotTombstoned: return String(localized: "clientcontrol.fail.slot_tombstoned")
        case "NotReachable":               return String(localized: "clientcontrol.fail.not_reachable")
        case "NoReply":                    return String(localized: "clientcontrol.fail.no_reply")
        // `ClientControlPublisher.PublishError` gains these two with auth-revocation-gates; the codes
        // are matched by name so this table does not have to land in the same commit.
        case "NeedsRepair":                return String(localized: "clientcontrol.fail.needs_repair")
        case "Revoked":                    return String(localized: "clientcontrol.fail.revoked")
        // Master-side execution.
        case "NoActiveProfile":            return String(localized: "clientcontrol.fail.no_active_profile")
        case "SceneNotFound":              return String(localized: "clientcontrol.fail.scene_not_found")
        case "SceneDisabled":              return String(localized: "clientcontrol.fail.scene_disabled")
        case "PartialFailure":             return String(localized: "clientcontrol.fail.partial")
        case "ExecutionFailed":            return String(localized: "clientcontrol.fail.execution")
        case "ControlDisabled":            return String(localized: "clientcontrol.fail.control_disabled")
        case "NoAction":                   return String(localized: "clientcontrol.fail.no_action")
        case "NoPendingBolus":             return String(localized: "clientcontrol.fail.no_pending_bolus")
        case "BolusComputeFailed":         return String(localized: "clientcontrol.fail.bolus_compute")
        case "Internal":                   return String(localized: "clientcontrol.fail.internal")
        case "Unknown":                    return String(localized: "clientcontrol.fail.unknown")
        default:                           return nil
        }
    }

    // MARK: - Gating

    /// Why a command cannot be sent right now; nil when it can.
    static func availability(_ availability: MasterControlAvailability) -> String? {
        switch availability {
        case .available:       return nil
        case .notPaired:       return String(localized: "clientcontrol.availability.not_paired")
        case .needsRepair:     return String(localized: "clientcontrol.availability.needs_repair")
        case .revoked:         return String(localized: "clientcontrol.availability.revoked")
        case .notAdvertised:   return String(localized: "clientcontrol.availability.not_advertised")
        case .controlDisabled: return String(localized: "clientcontrol.availability.control_disabled")
        case .unreachable:     return String(localized: "clientcontrol.availability.unreachable")
        }
    }

    /// Banner for a durable pairing condition; nil when there is nothing to say.
    static func banner(_ state: ClientControlAuthorizationState) -> String? {
        switch state {
        case .unconfigured, .nsOnly, .pairedActive:
            return nil
        case .pairedPending:
            return String(localized: "clientcontrol.state.paired_pending")
        case .pairedPendingExpired:
            return String(localized: "clientcontrol.state.paired_pending_expired")
        case .needsRepair:
            return String(localized: "clientcontrol.state.needs_repair")
        case .revoked:
            return String(localized: "clientcontrol.state.revoked")
        case .counterDesynced:
            return String(localized: "clientcontrol.state.counter_desynced")
        }
    }
}
