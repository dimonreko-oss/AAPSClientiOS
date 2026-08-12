import Foundation

protocol AlarmEngine {
    /// - Parameter latest: the newest reading, or nil when nothing has ever been
    ///   fetched. `nil` is a `.noData` condition, not a "skip evaluation" one — the
    ///   caller must pass it through rather than guarding on it.
    /// - Parameter lastUpdate: last successful HTTP fetch. Liveness of the *link*
    ///   only; freshness comes from `latest.date`. See `AlarmEngineLive.evaluate`.
    func evaluate(latest: GlucoseReading?, lastUpdate: Date, now: Date, thresholds: AlarmThresholds) -> AlarmType?
    func evaluatePredictedLow(minPredBgMgdl: Int?, thresholdMgdl: Int, now: Date) -> AlarmType?
    func schedule(_ type: AlarmType)
    func snooze(_ type: AlarmType, until: Date)
    func isSnoozed(_ type: AlarmType, now: Date) -> Bool
}

final class AlarmEngineLive: AlarmEngine {
    private var snoozed: [AlarmType: Date] = [:]
    private let lock = NSLock()
    private let notifier: Notifier
    private let defaults: UserDefaults

    /// `[AlarmType.rawValue: epoch seconds]`.
    private static let snoozeDefaultsKey = "alarms.snoozedUntil"

    init(notifier: Notifier = DummyNotifier(), defaults: UserDefaults = .standard) {
        self.notifier = notifier
        self.defaults = defaults
        // A snooze that does not survive the process is not a snooze. The BGProcessing resurrect
        // path and an OOM relaunch both build a fresh engine mid-snooze, and the next refresh then
        // re-raises the same Time-Sensitive alarm against the same still-low reading — minutes after
        // the user deliberately silenced it, and on every poll for the rest of the window.
        guard let raw = defaults.dictionary(forKey: Self.snoozeDefaultsKey) as? [String: Double] else { return }
        for (key, seconds) in raw {
            guard let type = AlarmType(rawValue: key) else { continue }
            let until = Date(timeIntervalSince1970: seconds)
            if until > Date() { snoozed[type] = until }
        }
    }

    /// Two independent clocks, deliberately:
    ///
    /// - `latest.date` is the only measure of *freshness*. A frozen CGM behind a
    ///   healthy Nightscout keeps answering HTTP 200 forever, so measuring
    ///   staleness from the fetch made "No Data" unreachable in exactly the most
    ///   common real CGM failure, and left the engine happily raising
    ///   urgentLow/low/high against a glucose value hours old.
    /// - `lastUpdate` only answers "have we ever reached the server at all". It
    ///   belongs to the `.connectionLost` path, which lives in `AppStore` because
    ///   only the caller knows whether the request threw.
    ///
    /// Never derive master liveness from treatment or profile recency: the fork
    /// defers those uploads by up to 300 min (`ns_client_sync_interval`), which is
    /// not published to followers. Anchor on the devicestatus heartbeat or the
    /// client-control Ping instead. Likewise, on an upstream master a devicestatus
    /// gap during a severe hypo is expected (sub-39 readings stop the loop), so a
    /// future "master unreachable" heuristic must stay silent below 39 mg/dL.
    func evaluate(latest: GlucoseReading?, lastUpdate: Date, now: Date, thresholds: AlarmThresholds) -> AlarmType? {
        guard let reading = latest else {
            return nonSnoozed(.noData, now: now)
        }

        // A follower that has never completed a fetch is holding cached or seeded
        // readings whose age proves nothing. Fail loud rather than silent.
        if lastUpdate == .distantPast {
            return nonSnoozed(.noData, now: now)
        }

        let readingAge = now.timeIntervalSince(reading.date)
        if readingAge > Double(thresholds.staleMinutes * 60) {
            return nonSnoozed(.noData, now: now)
        }

        let alarms: [AlarmType] = [
            reading.mgdl <= thresholds.urgentLow ? .urgentLow : nil,
            reading.mgdl > thresholds.urgentLow && reading.mgdl <= thresholds.low ? .low : nil,
            reading.mgdl >= thresholds.urgentHigh ? .urgentHigh : nil,
            reading.mgdl > thresholds.high && reading.mgdl < thresholds.urgentHigh ? .high : nil,
        ].compactMap { $0 }

        return alarms.first.map { nonSnoozed($0, now: now) } ?? nil
    }

    func schedule(_ type: AlarmType) {
        notifier.post(title: type.title, body: type.body, identifier: type.identifier)
    }

    func snooze(_ type: AlarmType, until: Date) {
        lock.lock()
        snoozed[type] = until
        let persisted = Dictionary(uniqueKeysWithValues: snoozed.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) })
        lock.unlock()
        defaults.set(persisted, forKey: Self.snoozeDefaultsKey)
        notifier.remove(identifier: type.identifier)
    }

    func evaluatePredictedLow(minPredBgMgdl: Int?, thresholdMgdl: Int, now: Date) -> AlarmType? {
        guard let minPredBgMgdl, minPredBgMgdl < thresholdMgdl else { return nil }
        return nonSnoozed(.predictedLow, now: now)
    }

    func isSnoozed(_ type: AlarmType, now: Date) -> Bool {
        lock.lock()
        let until = snoozed[type]
        lock.unlock()
        if let until, now < until {
            return true
        }
        return false
    }

    private func nonSnoozed(_ type: AlarmType, now: Date) -> AlarmType? {
        isSnoozed(type, now: now) ? nil : type
    }
}

extension AlarmType {
    var title: String {
        switch self {
        case .urgentLow: return "Urgent Low"
        case .low: return "Low Glucose"
        case .high: return "High Glucose"
        case .urgentHigh: return "Urgent High"
        case .noData: return "No Data"
        case .connectionLost: return "Connection Lost"
        case .predictedLow: return "Predicted Low"
        }
    }

    var body: String {
        switch self {
        case .urgentLow: return "Glucose is critically low"
        case .low: return "Glucose is below target"
        case .high: return "Glucose is above target"
        case .urgentHigh: return "Glucose is critically high"
        case .noData: return "Glucose data is stale or missing"
        case .connectionLost: return "Cannot reach Nightscout"
        case .predictedLow: return "Master predicts a low soon — consider carbs"
        }
    }

    var identifier: String {
        switch self {
        case .urgentLow: return "alarm.urgentLow"
        case .low: return "alarm.low"
        case .high: return "alarm.high"
        case .urgentHigh: return "alarm.urgentHigh"
        case .noData: return "alarm.noData"
        case .connectionLost: return "alarm.connectionLost"
        case .predictedLow: return "alarm.predictedLow"
        }
    }
}

private final class DummyNotifier: Notifier {
    func post(title: String, body: String, identifier: String) {}
    func remove(identifier: String) {}
}
