import Foundation

/// AAPS v4 `RM.Mode` — the master's durable "what is the loop actually doing" state.
///
/// In v4 this stopped being a transient "OpenAPS Offline" marker and became a first-class temporal
/// row: every mode change writes a `RM` record with a duration, and the mode in force at any instant
/// is resolved from those rows (see `RunningModeCalc`). The follower has to model the same thing,
/// because otherwise a master that is `SUSPENDED_BY_USER`, `DISCONNECTED_PUMP` or `SUSPENDED_BY_DST`
/// is indistinguishable from a healthy one — freshness alone says nothing about intent.
///
/// Raw values are the wire strings (`NSOfflineEvent.Mode.name`, written to the treatment's `mode`
/// field). They are the frozen contract and must not be renamed.
enum RunningMode: String, CaseIterable, Equatable, Sendable {
    case openLoop = "OPEN_LOOP"
    case closedLoop = "CLOSED_LOOP"
    case closedLoopLgs = "CLOSED_LOOP_LGS"
    case disabledLoop = "DISABLED_LOOP"
    case superBolus = "SUPER_BOLUS"
    case disconnectedPump = "DISCONNECTED_PUMP"
    case suspendedByPump = "SUSPENDED_BY_PUMP"
    case suspendedByUser = "SUSPENDED_BY_USER"
    case suspendedByDst = "SUSPENDED_BY_DST"
    /// Synthetic on the master — `handleRunningModeChange` cancels the current temporary row instead of
    /// persisting this, and `RM.toNSOfflineEvent()` errors on it, so it never reaches the wire. Present
    /// only so the enum mirrors `RM.Mode` one-for-one.
    case resume = "RESUME"
    case unknown = "UNKNOWN"

    /// The master's own fallback (`RM.DEFAULT_MODE`) when no row covers the instant being asked about.
    static let `default`: RunningMode = .disabledLoop

    /// Unknown strings map to `.unknown` rather than throwing — a newer master may add a mode.
    static func from(wire: String?) -> RunningMode {
        guard let wire, let mode = RunningMode(rawValue: wire.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .unknown
        }
        return mode
    }

    // MARK: - Predicates (mirroring `RM.Mode`)

    var isLoopRunning: Bool {
        switch self {
        case .openLoop, .closedLoop, .closedLoopLgs: return true
        default: return false
        }
    }

    var isClosedLoopOrLgs: Bool {
        self == .closedLoop || self == .closedLoopLgs
    }

    /// The loop algorithm is not dispatching. Note this is *not* "manual bolus blocked" —
    /// `SUPER_BOLUS` pauses the algorithm while the wizard delivers.
    var pausesLoopExecution: Bool {
        switch self {
        case .disconnectedPump, .suspendedByPump, .suspendedByUser, .suspendedByDst, .superBolus: return true
        default: return false
        }
    }

    var isPumpSuspended: Bool {
        self == .disconnectedPump || self == .suspendedByPump
    }

    /// Modes the master refuses to store without a duration.
    var mustBeTemporary: Bool {
        switch self {
        case .disconnectedPump, .suspendedByPump, .suspendedByUser, .suspendedByDst, .superBolus: return true
        default: return false
        }
    }

    /// True when the master is neither looping nor merely disabled — something is actively holding
    /// delivery back and the user should see it, whatever the loop's freshness says.
    var isTherapyInterrupted: Bool {
        pausesLoopExecution
    }

    // MARK: - Presentation

    /// Localized name. The `defaultValue:` fallbacks keep this readable before the matching
    /// `runningmode.*` keys land in `Localizable.strings` (see the integration notes).
    var displayName: String {
        switch self {
        case .openLoop:         return String(localized: "runningmode.open_loop", defaultValue: "Open Loop")
        case .closedLoop:       return String(localized: "runningmode.closed_loop", defaultValue: "Closed Loop")
        case .closedLoopLgs:    return String(localized: "runningmode.closed_loop_lgs", defaultValue: "Closed Loop (LGS)")
        case .disabledLoop:     return String(localized: "runningmode.disabled_loop", defaultValue: "Loop Disabled")
        case .superBolus:       return String(localized: "runningmode.super_bolus", defaultValue: "Super Bolus")
        case .disconnectedPump: return String(localized: "runningmode.disconnected_pump", defaultValue: "Pump Disconnected")
        case .suspendedByPump:  return String(localized: "runningmode.suspended_by_pump", defaultValue: "Suspended by Pump")
        case .suspendedByUser:  return String(localized: "runningmode.suspended_by_user", defaultValue: "Suspended")
        case .suspendedByDst:   return String(localized: "runningmode.suspended_by_dst", defaultValue: "Suspended (DST)")
        case .resume:           return String(localized: "runningmode.resume", defaultValue: "Resume")
        case .unknown:          return String(localized: "runningmode.unknown", defaultValue: "Unknown")
        }
    }
}

/// One `OpenAPS Offline` treatment, read as the RunningMode row it really is.
struct RunningModeRecord: Equatable, Identifiable, Sendable {
    let id: String
    let mode: RunningMode
    let date: Date
    /// Effective duration in milliseconds, resolved exactly as `NSOfflineEvent.toRunningMode()` does:
    /// `originalDuration ?: duration`. 0 means permanent.
    let durationMs: Int64
    /// The master forced this from a constraint rather than the user choosing it.
    let autoForced: Bool
    let reasons: String?
    let isValid: Bool

    /// A row with `duration == 0` is the master's "permanent" row — the one
    /// `getPermanentRunningModeActiveAt` looks for.
    var isPermanent: Bool { durationMs == 0 }

    var endDate: Date? {
        isPermanent ? nil : date.addingTimeInterval(Double(durationMs) / 1000)
    }

    /// Mirrors `getTemporaryRunningModeActiveAt`: `timestamp <= t AND (timestamp + duration) > t`.
    func coversTemporarily(_ instant: Date) -> Bool {
        guard let end = endDate else { return false }
        return date <= instant && end > instant
    }
}

enum RunningModeParser {
    /// AAPS writes RunningMode rows as `OpenAPS Offline` treatments (`EventType.APS_OFFLINE`).
    static let eventType = "OpenAPS Offline"

    /// Converts the RunningMode rows out of a treatment window, newest first.
    ///
    /// Invalid rows are kept — `RunningModeCalc` filters them, matching the master's `isValid = 1`
    /// clause, but a history view may still want to show them.
    static func records(from treatments: [Treatment]) -> [RunningModeRecord] {
        treatments
            .filter { $0.eventType == eventType }
            .map { treatment in
                RunningModeRecord(
                    id: treatment.id,
                    mode: RunningMode.from(wire: treatment.mode),
                    date: treatment.date,
                    // `Treatment.effectiveDurationMs` is `originalDurationMs ?? durationMin * 60_000`.
                    // Reading `durationMin` alone would show a 2 h CLOSED_LOOP as a cancel (v4 writes
                    // duration 0 for working modes) and a permanent DISABLED_LOOP as a decade.
                    durationMs: treatment.effectiveDurationMs,
                    autoForced: treatment.autoForced ?? false,
                    reasons: treatment.reasons,
                    isValid: treatment.isValid
                )
            }
            .sorted { $0.date > $1.date }
    }
}

/// Resolves "which mode is in force at instant X" the same way
/// `AppRepository.getRunningModeActiveAt` does on the master.
enum RunningModeCalc {
    /// Newest valid temporary row still covering `instant` vs. newest valid permanent row at or before
    /// it; when both exist the greater timestamp wins. `nil` when the window holds neither — a
    /// follower's 7-day treatment window can legitimately predate the last mode change, and claiming
    /// `DISABLED_LOOP` in that case would be a fabrication.
    static func current(in records: [RunningModeRecord], at instant: Date = Date()) -> RunningModeRecord? {
        let valid = records.filter { $0.isValid }
        let temporary = valid
            .filter { $0.coversTemporarily(instant) }
            .max { $0.date < $1.date }
        let permanent = valid
            .filter { $0.isPermanent && $0.date <= instant }
            .max { $0.date < $1.date }

        guard let temporary = temporary else { return permanent }
        guard let permanent = permanent else { return temporary }
        return permanent.date > temporary.date ? permanent : temporary
    }

    /// Same resolution, defaulting to the master's own `RM.DEFAULT_MODE` when nothing covers `instant`.
    /// Use `current(in:at:)` when "we do not know" has to stay distinguishable from "loop disabled".
    static func mode(in records: [RunningModeRecord], at instant: Date = Date()) -> RunningMode {
        current(in: records, at: instant)?.mode ?? RunningMode.default
    }
}
