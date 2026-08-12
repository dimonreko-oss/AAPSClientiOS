import XCTest
@testable import AAPSClientiOS

/// `Fixtures/entries.v3.json` is dated 2018-05-03. Now that freshness is measured from the reading
/// timestamp rather than from the HTTP fetch (`bg-stale-from-reading`), a raw fixture feed is
/// permanently "No Data" and masks every threshold assertion underneath it. Shifting the whole
/// series so the newest reading lands on `newestDate` keeps those tests testing what they claim to.
///
/// `newestDate` is computed ONCE per instance because `RefreshScopeTests.test_lightRefresh_
/// deduplicatesByDate` requires two consecutive fetches to return identical dates.
class FreshEntriesFixtureClient: FixtureNightscoutClient {
    let newestDate = Date()

    private func rebased(_ readings: [GlucoseReading]) -> [GlucoseReading] {
        guard let newest = readings.map(\.date).max() else { return readings }
        let shift = newestDate.timeIntervalSince(newest)
        return readings.map {
            GlucoseReading(date: $0.date.addingTimeInterval(shift), mgdl: $0.mgdl, trend: $0.trend)
        }
    }

    override func fetchEntries(limit: Int) async throws -> [GlucoseReading] {
        rebased(try await super.fetchEntries(limit: limit))
    }

    override func fetchEntries(sinceDays days: Int) async throws -> [GlucoseReading] {
        rebased(try await super.fetchEntries(sinceDays: days))
    }
}

@MainActor
final class AppStoreTests: XCTestCase {
    func test_liveActivityPreference_migratesRunningActivity() {
        let suite = "AppStoreTests.liveActivityMigration"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        XCTAssertTrue(AppStore.resolveLiveActivityPreference(defaults: defaults, activityIsRunning: true))
        XCTAssertTrue(defaults.bool(forKey: AppStore.liveActivityEnabledKey))

        defaults.removePersistentDomain(forName: suite)
    }

    func test_liveActivityPreference_preservesExplicitOff() {
        let suite = "AppStoreTests.liveActivityExplicitOff"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: AppStore.liveActivityEnabledKey)

        XCTAssertFalse(AppStore.resolveLiveActivityPreference(defaults: defaults, activityIsRunning: true))

        defaults.removePersistentDomain(forName: suite)
    }

    func test_liveActivityStaleDate_isBasedOnReadingTimestamp() {
        let readingDate = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(liveActivityStaleDate(for: readingDate), readingDate.addingTimeInterval(15 * 60))
    }

    func test_liveActivityPush_skipsUnchangedReadingWhileRunning() {
        XCTAssertFalse(AppStore.shouldPushLiveActivity(
            readingChanged: false,
            activityIsRunning: true,
            lastPushAt: nil,
            now: Date()
        ))
    }

    func test_liveActivityPush_coalescesChangedReadingsForFiveMinutes() {
        let lastPush = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(AppStore.shouldPushLiveActivity(
            readingChanged: true,
            activityIsRunning: true,
            lastPushAt: lastPush,
            now: lastPush.addingTimeInterval(299)
        ))
        XCTAssertTrue(AppStore.shouldPushLiveActivity(
            readingChanged: true,
            activityIsRunning: true,
            lastPushAt: lastPush,
            now: lastPush.addingTimeInterval(300)
        ))
    }

    func test_liveActivityPush_sendsFirstReadingOrRestartsMissingActivity() {
        let now = Date()
        XCTAssertTrue(AppStore.shouldPushLiveActivity(
            readingChanged: true,
            activityIsRunning: true,
            lastPushAt: nil,
            now: now
        ))
        XCTAssertTrue(AppStore.shouldPushLiveActivity(
            readingChanged: false,
            activityIsRunning: false,
            lastPushAt: now,
            now: now
        ))
    }

    func test_refreshFillsStore() async throws {
        let mockClient = FixtureNightscoutClient()
        let engine = makeAlarmEngine()
        let store = AppStore(client: mockClient, alarmEngine: engine)

        try await store.refresh()

        XCTAssertEqual(store.readings.count, 2)
        XCTAssertEqual(store.loopStatus?.iob, 1.85)
        XCTAssertEqual(store.treatments.count, 4)
    }

    func test_fetchTreatmentHistoryDelegatesToClient() async throws {
        let mockClient = FixtureNightscoutClient()
        let store = AppStore(client: mockClient, alarmEngine: makeAlarmEngine())

        let treatments = try await store.fetchTreatmentHistory(days: 7)

        XCTAssertEqual(treatments.count, 4)
    }

    func test_connectionLostAlarmOnNetworkError() async throws {
        let mockClient = FreshEntriesFixtureClient()
        let notifier = MockNotifier()
        let engine = makeAlarmEngine(notifier: notifier)
        let store = AppStore(client: mockClient, alarmEngine: engine)

        try await store.refresh()

        mockClient.shouldThrow = NsError.noNetwork

        do {
            try await store.refresh()
            XCTFail("Expected error")
        } catch {
        }

        XCTAssertEqual(store.connectionLost, true)
        XCTAssertEqual(notifier.posted.map(\.identifier), ["alarm.connectionLost"])
    }

    func test_staleDataTriggersNoDataAlarm() async throws {
        let mockClient = FixtureNightscoutClient()
        let notifier = MockNotifier()
        let engine = makeAlarmEngine(notifier: notifier)
        let store = AppStore(client: mockClient, alarmEngine: engine)
        store.thresholds = AlarmThresholds(urgentLow: 55, low: 70, high: 180, urgentHigh: 250, staleMinutes: 0)

        try await store.refresh()
        try await Task.sleep(nanoseconds: 100_000_000)
        // No `await`: `evaluate` is synchronous and both `store` and its engine are already
        // main-actor-isolated here, so awaiting it is a "no async operations occur" warning — and a
        // hard error the day the test target builds with -warnings-as-errors.
        let result = store.alarmEngine.evaluate(
            latest: store.readings.first,
            lastUpdate: store.lastRefresh,
            now: Date(),
            thresholds: store.thresholds
        )
        XCTAssertEqual(result, .noData)
    }

    func test_activeAlarmsPopulatedOnThresholdBreach_andSnoozeClearsThem() async throws {
        let mockClient = FreshEntriesFixtureClient()
        let engine = makeAlarmEngine()
        let store = AppStore(client: mockClient, alarmEngine: engine)
        // Fixture entries are 120 mg/dl; set `high` below that so the refresh trips it.
        store.thresholds = AlarmThresholds(urgentLow: 55, low: 70, high: 100, urgentHigh: 250, staleMinutes: 15)

        try await store.refresh()

        XCTAssertEqual(store.activeAlarms, [.high])

        store.snoozeAlarms(store.activeAlarms, minutes: 30)

        XCTAssertTrue(store.activeAlarms.isEmpty)
        XCTAssertTrue(engine.isSnoozed(.high, now: Date()))
        XCTAssertFalse(engine.isSnoozed(.high, now: Date().addingTimeInterval(31 * 60)))
    }

    func test_connectionLostTracksActiveAlarms_andRespectsSnooze() async throws {
        let mockClient = FreshEntriesFixtureClient()
        let notifier = MockNotifier()
        let engine = makeAlarmEngine(notifier: notifier)
        let store = AppStore(client: mockClient, alarmEngine: engine)

        try await store.refresh()
        mockClient.shouldThrow = NsError.noNetwork

        do {
            try await store.refresh()
            XCTFail("Expected error")
        } catch {}

        XCTAssertEqual(store.activeAlarms, [.connectionLost])

        store.snoozeAlarms([.connectionLost], minutes: 15)
        XCTAssertTrue(store.activeAlarms.isEmpty)

        notifier.posted.removeAll()
        do {
            try await store.refresh()
            XCTFail("Expected error")
        } catch {}

        XCTAssertTrue(notifier.posted.isEmpty, "snoozed connectionLost should not repost a notification")
        XCTAssertTrue(store.activeAlarms.isEmpty, "snoozed connectionLost should not reappear in activeAlarms")
    }

    func test_thresholdsPersistInUserDefaults() async throws {
        let mockClient = FixtureNightscoutClient()
        let engine = makeAlarmEngine()
        let store = AppStore(client: mockClient, alarmEngine: engine)

        let newThresholds = AlarmThresholds(urgentLow: 60, low: 80, high: 200, urgentHigh: 300, staleMinutes: 20)
        store.updateThresholds(newThresholds)

        let d = UserDefaults.standard
        XCTAssertEqual(d.integer(forKey: "threshold.urgentLow"), 60)
        XCTAssertEqual(d.integer(forKey: "threshold.staleMinutes"), 20)
        XCTAssertEqual(store.thresholds, newThresholds)
    }

    func test_thresholdsLoadedFromUserDefaults() {
        let d = UserDefaults.standard
        d.set(65, forKey: "threshold.urgentLow")
        d.set(75, forKey: "threshold.low")
        d.set(185, forKey: "threshold.high")
        d.set(255, forKey: "threshold.urgentHigh")
        d.set(10, forKey: "threshold.staleMinutes")

        let store = AppStore(client: FixtureNightscoutClient(), alarmEngine: makeAlarmEngine())
        XCTAssertEqual(store.thresholds.urgentLow, 65)
        XCTAssertEqual(store.thresholds.staleMinutes, 10)

        d.removeObject(forKey: "threshold.urgentLow")
    }

    func test_reconnectUpdatesClientAndRefreshes() async throws {
        let engine = makeAlarmEngine()
        let store = AppStore(client: UnconfiguredTestClient(), alarmEngine: engine)

        do {
            try await store.refresh()
            XCTFail("Expected badURL")
        } catch { }

        let mockClient = FixtureNightscoutClient()
        store.client = mockClient

        try await store.refresh()
        XCTAssertEqual(store.readings.count, 2)
    }

    func test_displayUnitsDefaultToMgdl() {
        UserDefaults.standard.removeObject(forKey: "display.glucoseUnits")
        let store = AppStore(client: FixtureNightscoutClient(), alarmEngine: makeAlarmEngine())
        XCTAssertEqual(store.displayUnits, .mgdl)
    }

    func test_displayUnitsReadFromUserDefaults() {
        UserDefaults.standard.set("mmol/l", forKey: "display.glucoseUnits")
        let store = AppStore(client: FixtureNightscoutClient(), alarmEngine: makeAlarmEngine())
        XCTAssertEqual(store.displayUnits, .mmol)
        UserDefaults.standard.removeObject(forKey: "display.glucoseUnits")
    }

    // Regression: a Task cancelled after entries succeed (SwiftUI .task on view
    // disappear, overlapping foreground polls) must still mirror the fresh reading
    // to the App Group + Live Activity. Previously refresh() returned on the
    // CancellationError before updateSharedSnapshot(), freezing the widget/LA while
    // the in-app screen showed new glucose.
    func test_cancellationAfterEntries_stillMirrorsSnapshot() async throws {
        let suiteName = "AppStoreTests.snapshot"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let shared = SharedStore(defaults: defaults)

        let client = FixtureNightscoutClient()
        client.cancelAfterEntries = true
        let store = AppStore(client: client, alarmEngine: makeAlarmEngine(), sharedStore: shared)

        try await store.refresh()  // returns early on the cancelled treatments stage

        XCTAssertFalse(store.readings.isEmpty, "entries should have applied before cancellation")
        let snap = shared.loadSnapshot()
        XCTAssertNotNil(snap, "snapshot must be mirrored even when a later stage cancels")
        XCTAssertEqual(snap?.mgdl, store.readings.first?.mgdl)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func test_refreshPopulatesDeviceStatusHistory() async throws {
        let store = AppStore(client: FixtureNightscoutClient(), alarmEngine: makeAlarmEngine())
        try await store.refresh()
        XCTAssertEqual(store.deviceStatusHistory.count, 5)
        XCTAssertEqual(store.deviceStatusHistory[0].iob, 1.20, accuracy: 0.001)
        XCTAssertEqual(store.deviceStatusHistory[2].cob, 35.0, accuracy: 0.01)
    }

    func test_refreshLoadsRemoteRunningConfig() async throws {
        let client = FixtureNightscoutClient()
        let store = AppStore(client: client, alarmEngine: makeAlarmEngine())

        try await store.refresh()

        XCTAssertEqual(store.remoteConfigCold?.pump, "Dana-i")
        XCTAssertEqual(store.remoteConfigHot?.activeScene?.sceneId, "school-sport")
        XCTAssertTrue(store.remoteCapabilities?.canRemoteCarbs == true)
        XCTAssertNil(store.remoteConfigError)
    }

    func test_refreshKeepsMainDataWhenRemoteConfigIsInvalid() async throws {
        let client = FixtureNightscoutClient()
        client.settingsByIdentifier[NightscoutSettingsIdentifier.cold] = "settings_invalid"
        let store = AppStore(client: client, alarmEngine: makeAlarmEngine())

        try await store.refresh()

        XCTAssertEqual(store.readings.count, 2)
        XCTAssertNil(store.remoteConfigCold)
        XCTAssertEqual(store.remoteConfigHot?.activeScene?.sceneId, "school-sport")
        XCTAssertNotNil(store.remoteConfigError)
        XCTAssertFalse(store.connectionLost)
    }

    func test_refreshParsesRemoteSyncedPrefs() async throws {
        let store = AppStore(client: FixtureNightscoutClient(), alarmEngine: makeAlarmEngine())

        try await store.refresh()

        XCTAssertEqual(store.remoteTempTargetPresets.count, 1)
        XCTAssertEqual(store.remoteTempTargetPresets.first?.name, "Eating Soon")
        XCTAssertEqual(store.remoteTempTargetPresets.first?.targetMgdl, 90)
        XCTAssertEqual(store.remoteSceneDefinitions.first?.sceneId, "school-sport")
        XCTAssertEqual(store.remoteQuickWizardEntries.first?.name, "Breakfast")
        XCTAssertEqual(store.activeRemoteSceneDisplayName, "School Sport")
    }

    /// `lastNotifiedAnnouncementDate` is persisted now — an in-memory marker meant every cold launch
    /// inside the relay's 60-minute window re-posted the same announcement. Persisted also means it
    /// leaks between test cases, so the announcement tests clear it explicitly.
    private static let announcementMarkerKey = "announce.lastNotifiedDate"

    func test_refreshRelaysFreshAnnouncement() async throws {
        UserDefaults.standard.removeObject(forKey: Self.announcementMarkerKey)
        let mockClient = FixtureNightscoutClient()
        mockClient.treatmentsOverride = [
            Treatment(
                id: "ann1", eventType: "Announcement", date: Date(),
                insulin: nil, carbs: nil, durationMin: nil, enteredBy: nil, notes: "Check pump",
                targetBottom: nil, targetTop: nil, profileName: nil, percentage: nil,
                absolute: nil, tempBasalPercent: nil
            )
        ]
        let notifier = MockNotifier()
        let store = AppStore(client: mockClient, alarmEngine: makeAlarmEngine(), notifier: notifier)

        try await store.refresh()

        XCTAssertEqual(notifier.posted.map(\.body), ["Check pump"])
    }

    func test_refreshDoesNotReRelaySameAnnouncement() async throws {
        UserDefaults.standard.removeObject(forKey: Self.announcementMarkerKey)
        let mockClient = FixtureNightscoutClient()
        mockClient.treatmentsOverride = [
            Treatment(
                id: "ann1", eventType: "Announcement", date: Date(),
                insulin: nil, carbs: nil, durationMin: nil, enteredBy: nil, notes: "Check pump",
                targetBottom: nil, targetTop: nil, profileName: nil, percentage: nil,
                absolute: nil, tempBasalPercent: nil
            )
        ]
        let notifier = MockNotifier()
        let store = AppStore(client: mockClient, alarmEngine: makeAlarmEngine(), notifier: notifier)

        try await store.refresh()
        try await store.refresh()

        XCTAssertEqual(notifier.posted.count, 1)
    }

    /// The marker has to outlive the PROCESS, not just the store. The BGProcessing resurrect path
    /// and any OOM relaunch build a fresh `AppStore` while the announcement is still inside the
    /// relay's 60-minute validity window; with an in-memory marker that re-posted it every time.
    func test_aFreshStoreDoesNotReRelayAnAnnouncementTheLastOneAlreadyShowed() async throws {
        UserDefaults.standard.removeObject(forKey: Self.announcementMarkerKey)
        let announcement = Treatment(
            id: "ann1", eventType: "Announcement", date: Date(),
            insulin: nil, carbs: nil, durationMin: nil, enteredBy: nil, notes: "Check pump",
            targetBottom: nil, targetTop: nil, profileName: nil, percentage: nil,
            absolute: nil, tempBasalPercent: nil
        )

        let firstClient = FixtureNightscoutClient()
        firstClient.treatmentsOverride = [announcement]
        let firstNotifier = MockNotifier()
        try await AppStore(client: firstClient, alarmEngine: makeAlarmEngine(), notifier: firstNotifier).refresh()
        XCTAssertEqual(firstNotifier.posted.count, 1)

        // Relaunch.
        let secondClient = FixtureNightscoutClient()
        secondClient.treatmentsOverride = [announcement]
        let secondNotifier = MockNotifier()
        try await AppStore(client: secondClient, alarmEngine: makeAlarmEngine(), notifier: secondNotifier).refresh()

        XCTAssertTrue(
            secondNotifier.posted.isEmpty,
            "posted again after relaunch: \(secondNotifier.posted.map(\.identifier))"
        )
    }

    func test_consumableThresholdsPersistInUserDefaults() async throws {
        let mockClient = FixtureNightscoutClient()
        let store = AppStore(client: mockClient, alarmEngine: makeAlarmEngine())

        let custom = ConsumableThresholds(
            cageWarnHours: 40, cageCriticalHours: 60,
            iageWarnHours: 60, iageCriticalHours: 120,
            sageWarnHours: 200, sageCriticalHours: 220,
            bageWarnHours: 200, bageCriticalHours: 220,
            reservoirWarnUnits: 50, reservoirCriticalUnits: 5,
            pumpBattWarnPercent: 40, pumpBattCriticalPercent: 20
        )
        store.updateConsumableThresholds(custom)

        let d = UserDefaults.standard
        XCTAssertEqual(d.integer(forKey: "consumable.cageWarnHours"), 40)
        XCTAssertEqual(d.integer(forKey: "consumable.reservoirCriticalUnits"), 5)
        XCTAssertEqual(store.consumableThresholds, custom)
    }

    func test_consumableThresholdsDefaultWhenNotSet() {
        UserDefaults.standard.removeObject(forKey: "consumable.cageWarnHours")
        let mockClient = FixtureNightscoutClient()
        let store = AppStore(client: mockClient, alarmEngine: makeAlarmEngine())
        XCTAssertEqual(store.consumableThresholds, .defaults)
    }

    func test_refreshSchedulesPredictedLowAlarm() async throws {
        let mockClient = FixtureNightscoutClient()
        mockClient.loopStatusOverride = LoopStatus(
            iob: 1.0, cob: 5, eventualBgMgdl: 90, tempBasalRate: 0.5,
            suggestedReason: nil, timestamp: Date(), predictions: nil,
            pumpBattery: 80, pumpReservoir: 100,
            uploaderBattery: 90,
            reason: LoopReason(isfMgdl: nil, cr: nil, targetMgdl: nil, tdd: nil, deviation: nil, bgi: nil, minPredBg: 55, iobPredBg: nil, cobPredBg: nil)
        )
        let notifier = MockNotifier()
        let store = AppStore(client: mockClient, alarmEngine: makeAlarmEngine(notifier: notifier))

        try await store.refresh()

        XCTAssertTrue(notifier.posted.map(\.identifier).contains("alarm.predictedLow"))
    }

    func test_refreshDoesNotScheduleWhenPredictionAboveThreshold() async throws {
        let mockClient = FixtureNightscoutClient()
        mockClient.loopStatusOverride = LoopStatus(
            iob: 1.0, cob: 5, eventualBgMgdl: 120, tempBasalRate: 0.5,
            suggestedReason: nil, timestamp: Date(), predictions: nil,
            pumpBattery: 80, pumpReservoir: 100,
            uploaderBattery: 90,
            reason: LoopReason(isfMgdl: nil, cr: nil, targetMgdl: nil, tdd: nil, deviation: nil, bgi: nil, minPredBg: 130, iobPredBg: nil, cobPredBg: nil)
        )
        let notifier = MockNotifier()
        let store = AppStore(client: mockClient, alarmEngine: makeAlarmEngine(notifier: notifier))

        try await store.refresh()

        XCTAssertFalse(notifier.posted.map(\.identifier).contains("alarm.predictedLow"))
    }

    @MainActor
    func test_refreshDetectsOrphanedPairing() async throws {
        let client = FixtureNightscoutClient()
        let pairingStore = ClientPairingStore(service: "test.orphan.\(UUID().uuidString)")
        defer { pairingStore.unpair() }
        pairingStore.pair(MasterPairing(masterInstallId: "m1", clientId: "not-in-roster", secretHex: "aabbcc"))
        client.settingsByIdentifier[NightscoutSettingsIdentifier.cold] = "settings_aaps_authorized_clients_missing"
        let notifier = MockNotifier()
        let store = AppStore(
            client: client,
            alarmEngine: makeAlarmEngine(),
            clientPairingStore: pairingStore,
            notifier: notifier
        )

        try await store.refresh()

        XCTAssertEqual(store.clientControlAuthorized, false)
        // Durable: a relaunch must not spring back to authorized.
        XCTAssertFalse(pairingStore.isAuthorized)
        // AAPS posts a system notification on revocation; a red Label in Settings is not delivery.
        XCTAssertTrue(notifier.posted.contains { $0.identifier == "clientcontrol.revoked" })
    }

    @MainActor
    func test_refreshKeepsAuthorizedWhenOwnIdInRoster() async throws {
        let client = FixtureNightscoutClient()
        let pairingStore = ClientPairingStore(service: "test.orphan.\(UUID().uuidString)")
        defer { pairingStore.unpair() }
        pairingStore.pair(MasterPairing(masterInstallId: "m1", clientId: "abc", secretHex: "aabbcc"))
        let store = AppStore(client: client, alarmEngine: makeAlarmEngine(), clientPairingStore: pairingStore)

        try await store.refresh()

        XCTAssertEqual(store.clientControlAuthorized, true)
    }

    /// A master that publishes a cold doc with NO `authorizedClients` block is no evidence either
    /// way — `OrphanDetector.kt:92` returns early on a null roster. Before the mapper could tell
    /// "absent" from "empty", such a master durably revoked the client: persisted into the Keychain,
    /// a "removed on the master" notification, and a permanent "Pair again" banner that re-pairing
    /// could not clear, because re-pairing does not make the master start publishing a roster.
    @MainActor
    func test_masterThatPublishesNoRosterDoesNotRevokeTheClient() async throws {
        let client = FixtureNightscoutClient()
        client.settingsByIdentifier[NightscoutSettingsIdentifier.cold] = "settings_aaps_no_roster"
        let pairingStore = ClientPairingStore(service: "test.orphan.\(UUID().uuidString)")
        defer { pairingStore.unpair() }
        pairingStore.pair(MasterPairing(masterInstallId: "m1", clientId: "not-in-roster", secretHex: "aabbcc"))
        let notifier = MockNotifier()
        let store = AppStore(
            client: client,
            alarmEngine: makeAlarmEngine(),
            clientPairingStore: pairingStore,
            notifier: notifier
        )

        try await store.refresh()

        XCTAssertTrue(store.clientControlAuthorized)
        XCTAssertFalse(notifier.posted.contains { $0.identifier == "clientcontrol.revoked" })
    }

    // MARK: - Master liveness while the loop is stopped

    /// A master suspended longer than the devicestatus lookback yields `loopStatus == nil` — that is
    /// correct, because inventing IOB 0 / COB 0 for a stopped loop is the inverse of the truth. But
    /// it must NOT clear the liveness clock: the master's keep-alive keeps uploading a pump-only
    /// document every five minutes, so it is plainly alive. Keying liveness on the APS run made the
    /// app declare such a master unreachable after nine minutes and then refuse to send the one
    /// command that would resume the loop.
    @MainActor
    func test_deviceStatusHeartbeatKeepsTheMasterAliveWhenTheLoopIsStopped() async throws {
        let client = SuspendedMasterClient()
        let store = AppStore(client: client, alarmEngine: makeAlarmEngine())

        try await store.refresh()

        XCTAssertNil(store.loopStatus, "a pump-only window carries no APS result")
        XCTAssertEqual(store.lastDeviceStatusAt, client.heartbeat)
        XCTAssertEqual(store.lastMasterSignal, client.heartbeat)
    }

    /// And the heartbeat is only paid for when it is needed: a running loop answers from
    /// `fetchDeviceStatus()` alone.
    @MainActor
    func test_theExtraHeartbeatRequestIsNotMadeWhileTheLoopIsRunning() async throws {
        let client = HeartbeatCountingClient()
        let store = AppStore(client: client, alarmEngine: makeAlarmEngine())

        try await store.refresh()

        XCTAssertNotNil(store.loopStatus)
        XCTAssertEqual(client.heartbeatCalls, 0, "steady state must stay at one devicestatus request")
        XCTAssertNotNil(store.lastDeviceStatusAt)
    }

    // MARK: - bg-stale-from-reading (store half)

    /// The failure the whole item exists for: Nightscout answers HTTP 200 forever while the CGM or
    /// the uploader is dead, so measuring staleness from the fetch made `.noData` unreachable in the
    /// most common real-world failure — and left the engine alarming against a frozen value.
    func test_frozenCgmBehindHealthyNightscoutRaisesNoData() async throws {
        let store = AppStore(client: FreshEntriesFixtureClient(), alarmEngine: makeAlarmEngine())
        try await store.refresh()
        store.readings = [GlucoseReading(date: Date().addingTimeInterval(-40 * 60), mgdl: 45, trend: .flat)]

        let result = store.alarmEngine.evaluate(
            latest: store.readings.first,
            lastUpdate: store.lastRefresh,
            now: Date(),
            thresholds: store.thresholds
        )

        XCTAssertEqual(result, .noData)
    }

    /// Unreachable before the call-site fix: `evaluateAlarms` guarded on `if let readings.first`,
    /// so a follower holding nothing at all raised nothing at all.
    func test_emptyFeedRaisesNoDataThroughTheStore() async throws {
        let notifier = MockNotifier()
        let client = EmptyEntriesFixtureClient()
        let store = AppStore(client: client, alarmEngine: makeAlarmEngine(notifier: notifier))

        try await store.refresh(scope: .light)

        XCTAssertTrue(store.readings.isEmpty)
        XCTAssertTrue(notifier.posted.contains { $0.identifier == "alarm.noData" })
    }

    // MARK: - auth-unauthorized-classification

    func test_rejectedTokenSetsCredentialsInvalidAndSuppressesConnectionLost() async throws {
        let client = FreshEntriesFixtureClient()
        let notifier = MockNotifier()
        let store = AppStore(client: client, alarmEngine: makeAlarmEngine(notifier: notifier))

        client.shouldThrow = NsError.unauthorized
        do {
            try await store.refresh()
            XCTFail("Expected unauthorized")
        } catch {}

        XCTAssertTrue(store.credentialsInvalid)
        XCTAssertFalse(
            notifier.posted.contains { $0.identifier == "alarm.connectionLost" },
            "a revoked token is permanent and user-fixable; it must not render as a flaky network"
        )

        client.shouldThrow = nil
        try await store.refresh()
        XCTAssertFalse(store.credentialsInvalid)
    }

    // MARK: - auth-single-store-instance

    func test_oneSharedPublisherPerStore_invalidatedWhenTheClientChanges() async throws {
        let store = AppStore(client: FreshEntriesFixtureClient(), alarmEngine: makeAlarmEngine())

        let first = store.clientControlPublisher
        XCTAssertTrue(first === store.clientControlPublisher, "every screen must share one publisher")

        store.client = FreshEntriesFixtureClient()
        XCTAssertFalse(
            first === store.clientControlPublisher,
            "the publisher captures its client by value, so a swapped transport must rebuild it"
        )
    }

    // MARK: - auth-revocation-gates / cc-master-reachable

    func test_authorizationStateSeedsFromTheDurableVerdict() async throws {
        let pairingStore = ClientPairingStore(service: "test.state.\(UUID().uuidString)")
        defer { pairingStore.unpair() }
        pairingStore.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: "aabbcc"))
        pairingStore.recordAuthorization(false)

        let store = AppStore(
            client: FreshEntriesFixtureClient(),
            alarmEngine: makeAlarmEngine(),
            clientPairingStore: pairingStore
        )

        XCTAssertFalse(store.clientControlAuthorized, "a revoked client must not spring back on relaunch")
        XCTAssertEqual(store.clientControlState, .revoked)
        XCTAssertEqual(store.masterControlAvailability, .revoked)
    }

    func test_masterAvailability_separatesDisabledFromUnreachable() {
        let now = Date()
        XCTAssertEqual(
            ClientControlStatusResolver.availability(
                isPaired: true, needsRepair: false, authorized: true,
                publishedClientControlEnabled: false,
                lastMasterSignal: now, latestGlucoseMgdl: 120, now: now
            ),
            .controlDisabled
        )
        XCTAssertEqual(
            ClientControlStatusResolver.availability(
                isPaired: true, needsRepair: false, authorized: true,
                publishedClientControlEnabled: true,
                lastMasterSignal: now.addingTimeInterval(-10 * 60), latestGlucoseMgdl: 120, now: now
            ),
            .unreachable
        )
        // A master too old to declare the flag at all is not the same as one that switched it off.
        XCTAssertEqual(
            ClientControlStatusResolver.availability(
                isPaired: true, needsRepair: false, authorized: true,
                publishedClientControlEnabled: nil,
                lastMasterSignal: now, latestGlucoseMgdl: 120, now: now
            ),
            .notAdvertised
        )
        // Cold start: no signal yet is not a fresh one.
        XCTAssertEqual(
            ClientControlStatusResolver.availability(
                isPaired: true, needsRepair: false, authorized: true,
                publishedClientControlEnabled: true,
                lastMasterSignal: nil, latestGlucoseMgdl: 120, now: now
            ),
            .unreachable
        )
    }

    /// On an upstream master a devicestatus gap during a severe hypo is expected behaviour — sub-39
    /// readings are excluded from its read path, so the loop stops uploading.
    func test_masterAvailability_staysTolerantBelowThirtyNine() {
        let now = Date()
        XCTAssertEqual(
            ClientControlStatusResolver.availability(
                isPaired: true, needsRepair: false, authorized: true,
                publishedClientControlEnabled: true,
                lastMasterSignal: now.addingTimeInterval(-30 * 60), latestGlucoseMgdl: 35, now: now
            ),
            .available
        )
    }

    func test_repeatedSilenceWhileMasterIsAliveReadsAsCounterDesync() {
        let now = Date()
        let state = ClientControlStatusResolver.resolve(
            isConfigured: true, isPaired: true, needsRepair: false, helloAcked: true,
            pairedAt: now.addingTimeInterval(-3600), authorized: true,
            silentRoundTrips: ClientControlStatusResolver.desyncThreshold,
            masterReachable: true, now: now
        )
        XCTAssertEqual(state, .counterDesynced)

        // The same silence with no independent proof of life is just an offline master.
        let offline = ClientControlStatusResolver.resolve(
            isConfigured: true, isPaired: true, needsRepair: false, helloAcked: true,
            pairedAt: now.addingTimeInterval(-3600), authorized: true,
            silentRoundTrips: ClientControlStatusResolver.desyncThreshold,
            masterReachable: false, now: now
        )
        XCTAssertEqual(offline, .pairedActive)
    }

    func test_unpromotedPairingTerminatesRatherThanRetryingForever() {
        let now = Date()
        XCTAssertEqual(
            ClientControlStatusResolver.resolve(
                isConfigured: true, isPaired: true, needsRepair: false, helloAcked: false,
                pairedAt: now.addingTimeInterval(-30), authorized: true,
                silentRoundTrips: 0, masterReachable: true, now: now
            ),
            .pairedPending
        )
        // Past PAIR_TTL_MS the master has pruned the Pending entry and `markActive` is unreachable.
        XCTAssertEqual(
            ClientControlStatusResolver.resolve(
                isConfigured: true, isPaired: true, needsRepair: false, helloAcked: false,
                pairedAt: now.addingTimeInterval(-300), authorized: true,
                silentRoundTrips: 0, masterReachable: true, now: now
            ),
            .pairedPendingExpired
        )
    }

    func test_locallyMintedRejectionsDoNotCountAsProofOfLife() {
        XCTAssertFalse(ClientControlSignal.provesMasterAlive(.rejected(reason: RoundTripReason.busy)))
        XCTAssertFalse(ClientControlSignal.provesMasterAlive(
            .rejected(reason: RoundTripReason.sendFailed + RoundTripReason.detailSeparator + "offline")
        ))
        XCTAssertFalse(ClientControlSignal.provesMasterAlive(.unconfirmed))
        XCTAssertTrue(ClientControlSignal.provesMasterAlive(.applied(payload: nil)))
        // Expired is written BY the master, so it is proof the master read our envelope.
        XCTAssertTrue(ClientControlSignal.provesMasterAlive(.rejected(reason: RoundTripReason.expired)))
        XCTAssertTrue(ClientControlSignal.provesMasterAlive(.rejected(reason: "ControlDisabled")))
    }

    func test_recordRoundTripOutcomeBumpsTheLivenessClockOnAVerifiedAnswer() async throws {
        let store = AppStore(client: FreshEntriesFixtureClient(), alarmEngine: makeAlarmEngine())
        XCTAssertNil(store.lastVerifiedAckAt)

        store.recordRoundTripOutcome(.applied(payload: nil))

        XCTAssertNotNil(store.lastVerifiedAckAt)
        XCTAssertEqual(store.silentRoundTrips, 0)
    }

    // MARK: - Realtime wiring

    func test_applyRealtimeEntryMergesWithoutTouchingTheAlarmTransport() {
        let store = AppStore(client: FreshEntriesFixtureClient(), alarmEngine: makeAlarmEngine())
        store.readings = [GlucoseReading(date: Date().addingTimeInterval(-300), mgdl: 120, trend: .flat)]
        store.connectionLost = true

        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        store.applyRealtime(NightscoutRealtimeUpdate(
            operation: .create,
            collection: "entries",
            json: "{\"type\":\"sgv\",\"sgv\":133,\"date\":\(ms),\"direction\":\"Flat\",\"identifier\":\"rt1\"}",
            srvModified: Date()
        ))

        XCTAssertEqual(store.readings.count, 2)
        XCTAssertEqual(store.readings.first?.mgdl, 133)
        XCTAssertFalse(store.connectionLost, "a pushed reading proves the link is alive")
    }

    /// Deletions belong to the reconciliation poll: a push says nothing about what else went.
    func test_applyRealtimeIgnoresDeletes() {
        let store = AppStore(client: FreshEntriesFixtureClient(), alarmEngine: makeAlarmEngine())
        store.readings = [GlucoseReading(date: Date().addingTimeInterval(-300), mgdl: 120, trend: .flat)]

        store.applyRealtime(NightscoutRealtimeUpdate(
            operation: .delete,
            collection: "entries",
            json: "{\"colName\":\"entries\",\"identifier\":\"rt1\"}",
            srvModified: nil
        ))

        XCTAssertEqual(store.readings.count, 1)
    }

    // MARK: - Dead-man's switch

    func test_successfulSnapshotRearmsTheLadder() async throws {
        let spy = SpyDeadManSwitch()
        let store = AppStore(
            client: FreshEntriesFixtureClient(),
            alarmEngine: makeAlarmEngine(),
            deadManSwitch: spy
        )
        store.setKeepAliveMode(.normal)
        spy.rearmedWith.removeAll()

        try await store.refresh()

        XCTAssertEqual(spy.rearmedWith.last, store.readings.first?.date)
    }

    /// The ladder used to be disarmed whenever the audio keep-alive was switched off, which was
    /// exactly backwards: the pre-scheduled `UNTimeIntervalNotificationTrigger` rungs are the ONLY
    /// alarm path that survives the process being suspended and reaped, and a user who turns
    /// keep-alive off to save battery is the user iOS reaps soonest. Turning it off at bedtime
    /// cancelled the 02:20 rung that was the whole point of the feature.
    func test_turningKeepAliveOffDoesNotDisarmTheLadder() async throws {
        let spy = SpyDeadManSwitch()
        let store = AppStore(
            client: FreshEntriesFixtureClient(),
            alarmEngine: makeAlarmEngine(),
            deadManSwitch: spy
        )
        try await store.refresh()
        spy.rearmedWith.removeAll()

        store.setKeepAliveMode(.disabled)

        XCTAssertEqual(spy.disarmCount, 0, "the ladder is the fallback FOR a process that is not held alive")
        XCTAssertEqual(spy.rearmedWith.last, store.readings.first?.date, "and it is re-armed, not left stale")

        store.setKeepAliveMode(.normal) // the mode is persisted; restore it for later tests
    }

    // MARK: - Onboarding alarm storm (unconfigured app)

    /// A freshly installed app sits on the Settings screen with no Nightscout URL. Every stage of
    /// `refresh()` throws `badURL`, and `AlarmEngineLive.evaluate` calls both `latest == nil` and
    /// `lastUpdate == .distantPast` a `.noData` condition — so the foreground timer posted a
    /// Time-Sensitive "Glucose data is stale or missing" every 60 s while the user was still typing.
    /// That is how a user mutes a monitoring app before it has ever shown a reading.
    func test_unconfiguredAppNeverPostsAnAlarmHoweverManyTimesItRefreshes() async throws {
        let notifier = MockNotifier()
        let store = AppStore(client: UnconfiguredClient(), alarmEngine: makeAlarmEngine(notifier: notifier), notifier: notifier)

        for _ in 0..<5 {
            do {
                try await store.refresh()
                XCTFail("an unconfigured client must throw")
            } catch {}
        }

        XCTAssertTrue(
            notifier.posted.filter { $0.identifier.hasPrefix("alarm.") }.isEmpty,
            "posted: \(notifier.posted.map(\.identifier))"
        )
        XCTAssertTrue(store.activeAlarms.isEmpty)
    }

    /// The other half of the gate: configured, but no fetch has ever completed. Cached or seeded
    /// readings prove nothing about freshness, so `.noData` must wait for a real fetch — the error
    /// path is covered by `.connectionLost`, which is deliberately NOT gated.
    func test_noAlarmBeforeTheFirstSuccessfulFetch_thenNoDataOnce() async throws {
        let notifier = MockNotifier()
        let client = FreshEntriesFixtureClient()
        client.shouldThrow = NsError.noNetwork
        let store = AppStore(client: client, alarmEngine: makeAlarmEngine(notifier: notifier))

        do {
            try await store.refresh()
            XCTFail("expected the network error")
        } catch {}

        XCTAssertFalse(
            notifier.posted.contains { $0.identifier == "alarm.noData" },
            "nothing has ever been fetched — 'the CGM died' is not a claim this app can make yet"
        )
        XCTAssertTrue(
            notifier.posted.contains { $0.identifier == "alarm.connectionLost" },
            "a broken install must NOT go silent — connectionLost is the honest signal here"
        )
    }

    // MARK: - Alarm re-post throttle

    /// `evaluateAlarms()` now runs once per poll AND once per document pushed over `/storage`. A
    /// master uploading a devicestatus, three treatments and an entry in the same second is five
    /// socket events, so a real 52 mg/dL posted `alarm.urgentLow` five times in one second — and a
    /// post-reconnect backfill posts dozens. An alarm indistinguishable from a malfunction at the
    /// moment it matters is a safety failure.
    func test_anUnchangedActiveAlarmPostsOnceNotOncePerEvaluation() async throws {
        let notifier = MockNotifier()
        let client = FreshEntriesFixtureClient()
        let store = AppStore(client: client, alarmEngine: makeAlarmEngine(notifier: notifier))
        store.thresholds = AlarmThresholds(urgentLow: 55, low: 70, high: 100, urgentHigh: 250, staleMinutes: 15)

        try await store.refresh()
        try await store.refresh()
        try await store.refresh()

        XCTAssertEqual(store.activeAlarms, [.high], "the condition is still active on every pass")
        XCTAssertEqual(
            notifier.posted.filter { $0.identifier == "alarm.high" }.count,
            1,
            "posted: \(notifier.posted.map(\.identifier))"
        )
    }

    /// The throttle must never make a NEW event quiet: a condition that cleared and came back is a
    /// fresh event and alerts immediately, whatever the interval says.
    func test_anAlarmThatClearsAndReturnsAlertsAgainImmediately() async throws {
        let notifier = MockNotifier()
        let client = FreshEntriesFixtureClient()
        let store = AppStore(client: client, alarmEngine: makeAlarmEngine(notifier: notifier))
        store.thresholds = AlarmThresholds(urgentLow: 55, low: 70, high: 100, urgentHigh: 250, staleMinutes: 15)

        try await store.refresh()
        XCTAssertEqual(notifier.posted.filter { $0.identifier == "alarm.high" }.count, 1)

        // Back in range: the alarm clears, which forgets its post time.
        store.thresholds = AlarmThresholds(urgentLow: 55, low: 70, high: 180, urgentHigh: 250, staleMinutes: 15)
        try await store.refresh()
        XCTAssertTrue(store.activeAlarms.isEmpty)

        // And back out again, well inside `alarmRepostInterval`.
        store.thresholds = AlarmThresholds(urgentLow: 55, low: 70, high: 100, urgentHigh: 250, staleMinutes: 15)
        try await store.refresh()

        XCTAssertEqual(store.activeAlarms, [.high])
        XCTAssertEqual(notifier.posted.filter { $0.identifier == "alarm.high" }.count, 2)
    }

    /// Snoozing clears the post time, so the first evaluation after the snooze expires may alert
    /// straight away rather than serving out `alarmRepostInterval` on top of the snooze.
    func test_snoozeClearsThePostTimeSoTheAlarmIsNotDoubleThrottled() async throws {
        let notifier = MockNotifier()
        let client = FreshEntriesFixtureClient()
        let engine = makeAlarmEngine(notifier: notifier)
        let store = AppStore(client: client, alarmEngine: engine)
        store.thresholds = AlarmThresholds(urgentLow: 55, low: 70, high: 100, urgentHigh: 250, staleMinutes: 15)

        try await store.refresh()
        XCTAssertEqual(notifier.posted.filter { $0.identifier == "alarm.high" }.count, 1)

        store.snoozeAlarms([.high], minutes: 30)
        // Un-snooze by hand: the engine's table is what suppresses the alarm, and the store's
        // throttle entry must already be gone.
        engine.snooze(.high, until: Date().addingTimeInterval(-1))

        try await store.refresh()

        XCTAssertEqual(
            notifier.posted.filter { $0.identifier == "alarm.high" }.count,
            2,
            "an expired snooze must not be followed by five more silent minutes"
        )
    }

    /// The interval is the safety trade this fix makes, so pin it: five minutes is one CGM cycle.
    func test_repostIntervalIsOneCgmCycle() {
        XCTAssertEqual(AppStore.alarmRepostInterval, 5 * 60)
    }
}

/// A master whose loop has been stopped longer than the devicestatus lookback: no APS result
/// anywhere in the window, but the keep-alive is still uploading a pump-only document.
private final class SuspendedMasterClient: FreshEntriesFixtureClient {
    let heartbeat = Date().addingTimeInterval(-2 * 60)

    override func fetchDeviceStatus() async throws -> LoopStatus? { nil }
    override func fetchDeviceStatusHeartbeat() async throws -> Date? { heartbeat }
}

/// Counts the fallback so the "one request in steady state" claim can be pinned.
private final class HeartbeatCountingClient: FreshEntriesFixtureClient {
    private(set) var heartbeatCalls = 0

    override func fetchDeviceStatus() async throws -> LoopStatus? {
        LoopStatus(
            iob: 1.0, cob: 5, eventualBgMgdl: 120, tempBasalRate: 0.5,
            suggestedReason: nil, timestamp: Date(), predictions: nil,
            pumpBattery: 80, pumpReservoir: 100, uploaderBattery: 90, reason: nil,
            deviceDate: Date()
        )
    }

    override func fetchDeviceStatusHeartbeat() async throws -> Date? {
        heartbeatCalls += 1
        return Date()
    }
}

/// Nightscout answering successfully with an empty page — the "never fetched anything" state.
private final class EmptyEntriesFixtureClient: FixtureNightscoutClient {
    override func fetchEntries(limit: Int) async throws -> [GlucoseReading] { [] }
    override func fetchEntries(sinceDays days: Int) async throws -> [GlucoseReading] { [] }
}

private final class SpyDeadManSwitch: DeadManSwitching {
    var rearmedWith: [Date] = []
    var disarmCount = 0

    func rearm(reference: Date, now: Date) { rearmedWith.append(reference) }
    func disarm() { disarmCount += 1 }
}

private final class UnconfiguredTestClient: NightscoutClient {
    func authorize() async throws { throw NsError.badURL }
    func fetchEntries(limit: Int) async throws -> [GlucoseReading] { throw NsError.badURL }
    func fetchTreatments(since: Date?) async throws -> [Treatment] { throw NsError.badURL }
    func fetchDeviceStatus() async throws -> LoopStatus? { throw NsError.badURL }
    func fetchProfile() async throws -> NsProfile { throw NsError.badURL }
    func fetchProfileStore() async throws -> NsProfileStore { throw NsError.badURL }
    func fetchSettings(identifier: String) async throws -> NsSettingsDocument? { throw NsError.badURL }
    func putSettings(identifier: String, document: [String: Any]) async throws { throw NsError.badURL }
    func deleteSettings(identifier: String) async throws { throw NsError.badURL }
    func searchSettings(limit: Int) async throws -> [NsSettingsDocument] { throw NsError.badURL }
    func fetchRunningConfigCold() async throws -> NsRunningConfigCold? { throw NsError.badURL }
    func fetchRunningConfigHot() async throws -> NsRunningConfigHot? { throw NsError.badURL }
    func postTreatment(_ payload: [String: Any]) async throws { throw NsError.badURL }
    func fetchCareEvents() async throws -> [Treatment] { throw NsError.badURL }
    func fetchEntries(sinceDays days: Int) async throws -> [GlucoseReading] { throw NsError.badURL }
    func fetchDeviceStatusHistory(since: Date) async throws -> [DeviceStatusEntry] { throw NsError.badURL }
    func fetchTreatmentsHistory(since: Date) async throws -> [Treatment] { throw NsError.badURL }
}
