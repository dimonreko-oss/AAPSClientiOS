import Foundation

/// How **fresh** the master's last APS run is — nothing more.
///
/// Deliberately orthogonal to `RunningMode`: a master that is `SUSPENDED_BY_USER` can still be
/// publishing devicestatus every 5 minutes, and a master in `CLOSED_LOOP` can have gone quiet. The
/// status card must show both, so never substitute one for the other.
enum LoopState {
    case looping, warning, stale, unknown
}

enum LoopStateCalc {
    /// `.unknown` when there is no timestamp. `NsMapping.loopStatus` leaves `LoopStatus.timestamp` nil
    /// for a devicestatus with no APS result rather than synthesizing `Date()`, so a stopped loop
    /// lands here instead of reporting `.looping`.
    static func from(statusTimestamp: Date?, now: Date) -> LoopState {
        guard let t = statusTimestamp else { return .unknown }
        let age = now.timeIntervalSince(t) / 60
        if age < 7 { return .looping }
        if age < 15 { return .warning }
        return .stale
    }
}

/// The two independent axes of "is the master OK", resolved together so the UI cannot show one
/// without the other.
struct LoopHealth: Equatable {
    let freshness: LoopState
    /// `nil` when no RunningMode row covers the instant — genuinely unknown, not `DISABLED_LOOP`.
    let mode: RunningMode?
    let autoForced: Bool

    static func resolve(
        statusTimestamp: Date?,
        runningModeRecords: [RunningModeRecord],
        now: Date = Date()
    ) -> LoopHealth {
        let record = RunningModeCalc.current(in: runningModeRecords, at: now)
        return LoopHealth(
            freshness: LoopStateCalc.from(statusTimestamp: statusTimestamp, now: now),
            mode: record?.mode,
            autoForced: record?.autoForced ?? false
        )
    }

    /// Green only when the loop is both fresh *and* actually running. A suspended master that keeps
    /// uploading must never render as healthy.
    var isHealthy: Bool {
        guard freshness == .looping else { return false }
        // No RunningMode row in the window: freshness is all we have, so do not invent a suspension.
        guard let resolved = mode else { return true }
        return resolved.isLoopRunning
    }
}
