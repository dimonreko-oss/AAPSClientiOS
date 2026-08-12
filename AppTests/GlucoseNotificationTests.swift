import XCTest
@testable import AAPSClientiOS

final class GlucoseNotificationTests: XCTestCase {
    func test_contentUsesDisplayUnitsTrendAndDelta() {
        let latest = GlucoseReading(
            date: Date(timeIntervalSince1970: 1_000),
            mgdl: 120,
            trend: .fortyFiveUp
        )
        let previous = GlucoseReading(
            date: Date(timeIntervalSince1970: 700),
            mgdl: 111,
            trend: .flat
        )

        let content = GlucoseNotificationController.content(
            latest: latest,
            previous: previous,
            units: .mgdl,
            timeText: "12:34"
        )

        XCTAssertEqual(content.title, "120 ↗ +9 mg/dl")
        XCTAssertTrue(content.body.contains("12:34"))
    }

    func test_contentConvertsValueAndDeltaToMmol() {
        let latest = GlucoseReading(date: .now, mgdl: 90, trend: .singleDown)
        let previous = GlucoseReading(date: .now, mgdl: 108, trend: .flat)

        let content = GlucoseNotificationController.content(
            latest: latest,
            previous: previous,
            units: .mmol,
            timeText: "12:34"
        )

        XCTAssertEqual(content.title, "5.0 ↓ -1.0 mmol/l")
    }
}

@MainActor
final class GlucoseNotificationAppStoreTests: XCTestCase {
    func test_refreshReplacesNotificationOnlyForNewReading() async throws {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: AppStore.glucoseNotificationEnabledKey)
        defer { defaults.removeObject(forKey: AppStore.glucoseNotificationEnabledKey) }
        let publisher = RecordingGlucoseNotificationPublisher()
        let store = AppStore(
            client: FixtureNightscoutClient(),
            alarmEngine: makeAlarmEngine(),
            glucoseNotificationPublisher: publisher
        )

        try await store.refresh()
        try await store.refresh()

        XCTAssertEqual(publisher.contents.count, 1)
    }

    func test_disablingRemovesNotification() {
        let publisher = RecordingGlucoseNotificationPublisher()
        let store = AppStore(
            client: FixtureNightscoutClient(),
            alarmEngine: makeAlarmEngine(),
            glucoseNotificationPublisher: publisher
        )

        store.setGlucoseNotificationEnabled(false)

        XCTAssertEqual(publisher.removeCount, 1)
        UserDefaults.standard.removeObject(forKey: AppStore.glucoseNotificationEnabledKey)
    }

    func test_enablingImmediatelyPublishesLoadedReading() async throws {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: AppStore.glucoseNotificationEnabledKey)
        defer { defaults.removeObject(forKey: AppStore.glucoseNotificationEnabledKey) }
        let publisher = RecordingGlucoseNotificationPublisher()
        let store = AppStore(
            client: FixtureNightscoutClient(),
            alarmEngine: makeAlarmEngine(),
            glucoseNotificationPublisher: publisher
        )
        try await store.refresh()

        store.setGlucoseNotificationEnabled(true)

        XCTAssertEqual(publisher.contents.count, 1)
    }
}

private final class RecordingGlucoseNotificationPublisher: GlucoseNotificationPublishing {
    var contents: [GlucoseNotificationContent] = []
    var removeCount = 0

    func replace(with content: GlucoseNotificationContent) {
        contents.append(content)
    }

    func remove() {
        removeCount += 1
    }
}
