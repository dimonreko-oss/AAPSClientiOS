import XCTest
@testable import AAPSClientiOS

final class CountingNightscoutClient: FreshEntriesFixtureClient {
    var entriesCalls = 0
    var deviceStatusCalls = 0
    var treatmentsCalls = 0
    var profileCalls = 0

    override func fetchEntries(limit: Int) async throws -> [GlucoseReading] {
        entriesCalls += 1
        return try await super.fetchEntries(limit: limit)
    }

    override func fetchDeviceStatus() async throws -> LoopStatus? {
        deviceStatusCalls += 1
        return try await super.fetchDeviceStatus()
    }

    override func fetchTreatments(since: Date?) async throws -> [Treatment] {
        treatmentsCalls += 1
        return try await super.fetchTreatments(since: since)
    }

    override func fetchProfile() async throws -> NsProfile {
        profileCalls += 1
        return try await super.fetchProfile()
    }
}

final class RefreshScopeTests: XCTestCase {
    // A light refresh proves the connection is alive, so it must count as a
    // successful update for alarm staleness. Otherwise the stale check in
    // AlarmEngineLive.evaluate short-circuits to .noData and returns before it
    // ever compares glucose against the thresholds — spurious "No Data" alarms
    // every few minutes, and real low/high alarms silently never fire in the
    // background.
    @MainActor
    func test_lightRefresh_doesNotFireStaleNoDataAlarm() async throws {
        let notifier = MockNotifier()
        let store = AppStore(
            client: FreshEntriesFixtureClient(),
            alarmEngine: makeAlarmEngine(notifier: notifier)
        )

        try await store.refresh(scope: .light)

        XCTAssertFalse(
            notifier.posted.contains { $0.identifier == "alarm.noData" },
            "light refresh just fetched fresh data; it must not report it as stale"
        )
    }

    @MainActor
    func test_lightRefresh_stillEvaluatesGlucoseThresholds() async throws {
        let notifier = MockNotifier()
        let store = AppStore(
            client: FreshEntriesFixtureClient(),
            alarmEngine: makeAlarmEngine(notifier: notifier)
        )
        // Assign directly rather than via updateThresholds(_:), which persists to
        // UserDefaults and would leak these thresholds into every later test.
        store.thresholds = AlarmThresholds(
            urgentLow: 55, low: 70, high: 80, urgentHigh: 250, staleMinutes: 15
        )

        try await store.refresh(scope: .light)

        XCTAssertTrue(
            notifier.posted.contains { $0.identifier.hasPrefix("alarm.") && $0.identifier != "alarm.noData" },
            "a glucose alarm must still be reachable from the light path"
        )
    }

    /// The light path stays cheap: entries + devicestatus, plus one bounded `srvModified`-filtered
    /// treatments page for the Announcement relay (bg-light-announcements — every background wake
    /// path is `.light`, so relaying only from `.full` meant a pocketed phone never saw one).
    /// It must NOT pull profile, profileStore, careEvents, deviceStatusHistory or the config docs.
    @MainActor
    func test_lightRefresh_fetchesEntriesDeviceStatusAndTheAnnouncementProbeOnly() async throws {
        let client = CountingNightscoutClient()
        let store = AppStore(client: client, alarmEngine: makeAlarmEngine())

        try await store.refresh(scope: .light)

        XCTAssertEqual(client.entriesCalls, 1)
        XCTAssertEqual(client.deviceStatusCalls, 1)
        XCTAssertEqual(client.treatmentsCalls, 1)
        XCTAssertEqual(client.profileCalls, 0)
    }

    /// bg-light-announcements: the relay used to be reachable only from the full path.
    @MainActor
    func test_lightRefresh_relaysAnnouncements() async throws {
        // The "already relayed" marker is persisted now (it has to survive a relaunch), so it also
        // survives between test cases.
        UserDefaults.standard.removeObject(forKey: "announce.lastNotifiedDate")
        let client = CountingNightscoutClient()
        client.treatmentsOverride = [
            Treatment(
                id: "ann-light", eventType: "Announcement", date: Date(),
                insulin: nil, carbs: nil, durationMin: nil, enteredBy: nil, notes: "Pump paused",
                targetBottom: nil, targetTop: nil, profileName: nil, percentage: nil,
                absolute: nil, tempBasalPercent: nil
            )
        ]
        let notifier = MockNotifier()
        let store = AppStore(client: client, alarmEngine: makeAlarmEngine(), notifier: notifier)

        try await store.refresh(scope: .light)

        XCTAssertEqual(notifier.posted.map(\.body), ["Pump paused"])
    }

    /// bg-snooze-durability: `refreshLight` had no `isSnoozed` guard and never appended to
    /// `activeAlarms`, so a snoozed Connection Lost re-posted a notification on every background
    /// tick while the in-app banner said nothing.
    @MainActor
    func test_lightRefresh_respectsConnectionLostSnooze_andTracksActiveAlarms() async throws {
        let client = FreshEntriesFixtureClient()
        let notifier = MockNotifier()
        let engine = makeAlarmEngine(notifier: notifier)
        let store = AppStore(client: client, alarmEngine: engine, notifier: MockNotifier())
        // Pinned so leaked thresholds from another test cannot add a glucose alarm to the array.
        store.thresholds = AlarmThresholds(urgentLow: 55, low: 70, high: 180, urgentHigh: 250, staleMinutes: 15)

        try await store.refresh(scope: .light)
        client.shouldThrow = NsError.noNetwork

        do {
            try await store.refresh(scope: .light)
            XCTFail("Expected error")
        } catch {}

        XCTAssertEqual(store.activeAlarms, [.connectionLost])

        store.snoozeAlarms([.connectionLost], minutes: 15)
        notifier.posted.removeAll()

        do {
            try await store.refresh(scope: .light)
            XCTFail("Expected error")
        } catch {}

        XCTAssertFalse(notifier.posted.contains { $0.identifier == "alarm.connectionLost" })
        XCTAssertTrue(store.activeAlarms.isEmpty)
    }

    /// bg-foreground-full-refresh: the 60 s foreground tick used to take the ~28-request full pass
    /// every single time, because `isStale` is keyed to `lastRefresh` which only the full path moves.
    @MainActor
    func test_foregroundTick_takesTheLightPathBetweenFullRefreshes() async throws {
        let client = CountingNightscoutClient()
        let store = AppStore(client: client, alarmEngine: makeAlarmEngine())

        // Cold: nothing has been fetched, so the first tick must be the full pass.
        await store.refreshForeground()
        XCTAssertEqual(client.profileCalls, 1)
        XCTAssertEqual(client.entriesCalls, 1)

        // 90 s later: light only.
        await store.refreshForeground(now: Date().addingTimeInterval(90))
        XCTAssertEqual(client.profileCalls, 1, "the heavy pass must not repeat inside the interval")
        XCTAssertEqual(client.entriesCalls, 2)

        // Past the five-minute cadence the heavy pass runs again.
        await store.refreshForeground(now: Date().addingTimeInterval(6 * 60))
        XCTAssertEqual(client.profileCalls, 2)
    }

    @MainActor
    func test_fullRefresh_stillFetchesEverything() async throws {
        let client = CountingNightscoutClient()
        let store = AppStore(client: client, alarmEngine: makeAlarmEngine())

        try await store.refresh(scope: .full)

        XCTAssertEqual(client.entriesCalls, 1)
        XCTAssertEqual(client.deviceStatusCalls, 1)
        XCTAssertEqual(client.treatmentsCalls, 2)
        XCTAssertEqual(client.profileCalls, 1)
    }

    @MainActor
    func test_lightRefresh_mergesIntoExistingReadings_withoutTruncating() async throws {
        let store = AppStore(client: FreshEntriesFixtureClient(), alarmEngine: makeAlarmEngine())
        let old = (1...200).map { i in
            GlucoseReading(
                date: Date(timeIntervalSince1970: 1_700_000_000 - Double(i) * 300),
                mgdl: 100,
                trend: .flat
            )
        }
        store.readings = old

        try await store.refresh(scope: .light)

        XCTAssertGreaterThanOrEqual(store.readings.count, old.count)
    }

    @MainActor
    func test_lightRefresh_deduplicatesByDate() async throws {
        let store = AppStore(client: FreshEntriesFixtureClient(), alarmEngine: makeAlarmEngine())

        try await store.refresh(scope: .light)
        let afterFirst = store.readings.count
        try await store.refresh(scope: .light)

        XCTAssertEqual(store.readings.count, afterFirst)
    }

    @MainActor
    func test_lightRefresh_capsReadingsAt288() async throws {
        let store = AppStore(client: FreshEntriesFixtureClient(), alarmEngine: makeAlarmEngine())
        let old = (1...400).map { i in
            GlucoseReading(
                date: Date(timeIntervalSince1970: 1_700_000_000 - Double(i) * 300),
                mgdl: 100,
                trend: .flat
            )
        }
        store.readings = old

        try await store.refresh(scope: .light)

        XCTAssertEqual(store.readings.count, 288)
    }

    @MainActor
    func test_lightRefresh_doesNotSuppressTheNextForegroundFullRefresh() async throws {
        let store = AppStore(client: FreshEntriesFixtureClient(), alarmEngine: makeAlarmEngine())

        try await store.refresh(scope: .light)

        XCTAssertTrue(store.isStale)
    }

    @MainActor
    func test_fullRefresh_clearsStaleness() async throws {
        let store = AppStore(client: FreshEntriesFixtureClient(), alarmEngine: makeAlarmEngine())

        try await store.refresh(scope: .full)

        XCTAssertFalse(store.isStale)
    }
}
