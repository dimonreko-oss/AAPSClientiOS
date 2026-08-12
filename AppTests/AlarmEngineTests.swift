import XCTest
@testable import AAPSClientiOS

final class AlarmEngineTests: XCTestCase {

    private let thresholds = AlarmThresholds(
        urgentLow: 55, low: 70, high: 180, urgentHigh: 250, staleMinutes: 15
    )

    func test_urgentLowFires() {
        let engine = makeAlarmEngine()
        let reading = GlucoseReading(date: .now, mgdl: 50, trend: .singleDown)
        let result = engine.evaluate(latest: reading, lastUpdate: .now, now: .now, thresholds: thresholds)
        XCTAssertEqual(result, .urgentLow)
    }

    func test_lowFires() {
        let engine = makeAlarmEngine()
        let reading = GlucoseReading(date: .now, mgdl: 65, trend: .flat)
        let result = engine.evaluate(latest: reading, lastUpdate: .now, now: .now, thresholds: thresholds)
        XCTAssertEqual(result, .low)
    }

    func test_highFires() {
        let engine = makeAlarmEngine()
        let reading = GlucoseReading(date: .now, mgdl: 200, trend: .flat)
        let result = engine.evaluate(latest: reading, lastUpdate: .now, now: .now, thresholds: thresholds)
        XCTAssertEqual(result, .high)
    }

    func test_urgentHighFires() {
        let engine = makeAlarmEngine()
        let reading = GlucoseReading(date: .now, mgdl: 260, trend: .singleUp)
        let result = engine.evaluate(latest: reading, lastUpdate: .now, now: .now, thresholds: thresholds)
        XCTAssertEqual(result, .urgentHigh)
    }

    func test_inRangeReturnsNil() {
        let engine = makeAlarmEngine()
        let reading = GlucoseReading(date: .now, mgdl: 120, trend: .flat)
        let result = engine.evaluate(latest: reading, lastUpdate: .now, now: .now, thresholds: thresholds)
        XCTAssertNil(result)
    }

    func test_noDataWhenReadingIsStale() {
        let engine = makeAlarmEngine()
        let reading = GlucoseReading(date: Date().addingTimeInterval(-20 * 60), mgdl: 120, trend: .flat)
        let result = engine.evaluate(latest: reading, lastUpdate: .now, now: .now, thresholds: thresholds)
        XCTAssertEqual(result, .noData)
    }

    // The whole point of bg-stale-from-reading: a frozen CGM behind a perfectly
    // healthy Nightscout. Every fetch returns 200, so `lastUpdate` is now — and the
    // old engine happily alarmed on the 40-minute-old number as if it were current.
    func test_noDataWhenFetchIsHealthyButReadingIsFrozen() {
        let engine = makeAlarmEngine()
        let frozen = GlucoseReading(date: Date().addingTimeInterval(-40 * 60), mgdl: 45, trend: .flat)
        let result = engine.evaluate(latest: frozen, lastUpdate: .now, now: .now, thresholds: thresholds)
        XCTAssertEqual(result, .noData, "a stale reading must not be alarmed on as if it were current")
    }

    // Mirror image: the network has been down for an hour but the CGM value we hold
    // is 2 minutes old. That is a `.connectionLost` condition, which AppStore owns —
    // the engine must not call it No Data and mask the real glucose state.
    func test_staleFetchWithFreshReadingIsNotNoData() {
        let engine = makeAlarmEngine()
        let reading = GlucoseReading(date: Date().addingTimeInterval(-2 * 60), mgdl: 120, trend: .flat)
        let result = engine.evaluate(
            latest: reading,
            lastUpdate: Date().addingTimeInterval(-60 * 60),
            now: .now,
            thresholds: thresholds
        )
        XCTAssertNil(result)
    }

    func test_noDataWhenNilReading() {
        let engine = makeAlarmEngine()
        let result = engine.evaluate(latest: nil, lastUpdate: .now, now: .now, thresholds: thresholds)
        XCTAssertEqual(result, .noData)
    }

    // A follower that has never completed a fetch must raise, not sit silent.
    func test_noDataWhenNeverFetched() {
        let engine = makeAlarmEngine()
        let reading = GlucoseReading(date: .now, mgdl: 120, trend: .flat)
        let result = engine.evaluate(
            latest: reading,
            lastUpdate: .distantPast,
            now: .now,
            thresholds: thresholds
        )
        XCTAssertEqual(result, .noData)
    }

    func test_noDataWhenNeverFetchedAndNoReadings() {
        let engine = makeAlarmEngine()
        let result = engine.evaluate(
            latest: nil,
            lastUpdate: .distantPast,
            now: .now,
            thresholds: thresholds
        )
        XCTAssertEqual(result, .noData)
    }

    func test_urgentOverridesNormal() {
        let engine = makeAlarmEngine()
        let reading = GlucoseReading(date: .now, mgdl: 50, trend: .doubleDown)
        let result = engine.evaluate(latest: reading, lastUpdate: .now, now: .now, thresholds: thresholds)
        XCTAssertEqual(result, .urgentLow)
    }

    func test_snoozedTypeSuppressed() {
        let engine = makeAlarmEngine()
        let reading = GlucoseReading(date: .now, mgdl: 50, trend: .flat)
        let futureDate = Date().addingTimeInterval(600)
        engine.snooze(.urgentLow, until: futureDate)
        let result = engine.evaluate(latest: reading, lastUpdate: .now, now: .now, thresholds: thresholds)
        XCTAssertNil(result)
    }

    func test_snoozedExpiredFiresAgain() {
        let engine = makeAlarmEngine()
        let reading = GlucoseReading(date: .now, mgdl: 50, trend: .flat)
        let pastDate = Date().addingTimeInterval(-600)
        engine.snooze(.urgentLow, until: pastDate)
        let result = engine.evaluate(latest: reading, lastUpdate: .now, now: .now, thresholds: thresholds)
        XCTAssertEqual(result, .urgentLow)
    }

    func test_predictedLowFiresBelowThreshold() {
        let engine = makeAlarmEngine()
        let result = engine.evaluatePredictedLow(minPredBgMgdl: 60, thresholdMgdl: 70, now: .now)
        XCTAssertEqual(result, .predictedLow)
    }

    func test_predictedLowDoesNotFireAtOrAboveThreshold() {
        let engine = makeAlarmEngine()
        let result = engine.evaluatePredictedLow(minPredBgMgdl: 70, thresholdMgdl: 70, now: .now)
        XCTAssertNil(result)
    }

    func test_predictedLowNilWhenNoPrediction() {
        let engine = makeAlarmEngine()
        let result = engine.evaluatePredictedLow(minPredBgMgdl: nil, thresholdMgdl: 70, now: .now)
        XCTAssertNil(result)
    }

    func test_isSnoozedTrueBeforeExpiry() {
        let engine = makeAlarmEngine()
        engine.snooze(.low, until: Date().addingTimeInterval(900))
        XCTAssertTrue(engine.isSnoozed(.low, now: Date()))
    }

    func test_isSnoozedFalseAfterExpiry() {
        let engine = makeAlarmEngine()
        engine.snooze(.low, until: Date().addingTimeInterval(900))
        XCTAssertFalse(engine.isSnoozed(.low, now: Date().addingTimeInterval(901)))
    }

    func test_isSnoozedFalseWhenNeverSnoozed() {
        let engine = makeAlarmEngine()
        XCTAssertFalse(engine.isSnoozed(.urgentHigh, now: .now))
    }

    func test_predictedLowRespectsSnooze() {
        let engine = makeAlarmEngine()
        let futureDate = Date().addingTimeInterval(600)
        engine.snooze(.predictedLow, until: futureDate)
        let result = engine.evaluatePredictedLow(minPredBgMgdl: 50, thresholdMgdl: 70, now: .now)
        XCTAssertNil(result)
    }

    // MARK: - Snooze durability

    /// A snooze that does not survive the process is not a snooze. The BGProcessing resurrect path
    /// and an OOM relaunch both build a fresh engine mid-snooze; before this, the very next refresh
    /// re-raised the same Time-Sensitive Urgent Low against the same still-low reading, minutes
    /// after the user deliberately silenced it — and then on every poll for the rest of the window.
    func test_snoozeSurvivesANewEngineInTheSameDefaults() {
        let defaults = makeAlarmDefaults()
        let reading = GlucoseReading(date: .now, mgdl: 50, trend: .flat)

        let before = AlarmEngineLive(notifier: MockNotifier(), defaults: defaults)
        before.snooze(.urgentLow, until: Date().addingTimeInterval(30 * 60))

        let afterRelaunch = AlarmEngineLive(notifier: MockNotifier(), defaults: defaults)

        XCTAssertTrue(afterRelaunch.isSnoozed(.urgentLow, now: Date()))
        XCTAssertNil(afterRelaunch.evaluate(
            latest: reading, lastUpdate: .now, now: .now, thresholds: thresholds
        ))
    }

    /// The reload must not resurrect a snooze that has already run out — that would silence an alarm
    /// for a window the user never asked for.
    func test_anExpiredSnoozeIsNotReloaded() {
        let defaults = makeAlarmDefaults()
        let reading = GlucoseReading(date: .now, mgdl: 50, trend: .flat)

        let before = AlarmEngineLive(notifier: MockNotifier(), defaults: defaults)
        before.snooze(.urgentLow, until: Date().addingTimeInterval(-1))

        let afterRelaunch = AlarmEngineLive(notifier: MockNotifier(), defaults: defaults)

        XCTAssertFalse(afterRelaunch.isSnoozed(.urgentLow, now: Date()))
        XCTAssertEqual(
            afterRelaunch.evaluate(latest: reading, lastUpdate: .now, now: .now, thresholds: thresholds),
            .urgentLow
        )
    }

    /// The persisted table is keyed by `AlarmType.rawValue`, so those raw values are a storage
    /// contract: renaming a case silently drops every live snooze on upgrade.
    func test_alarmTypeRawValuesAreTheStorageContract() {
        XCTAssertEqual(
            AlarmType.allCases.map(\.rawValue).sorted(),
            ["connectionLost", "high", "low", "noData", "predictedLow", "urgentHigh", "urgentLow"]
        )
    }
}
