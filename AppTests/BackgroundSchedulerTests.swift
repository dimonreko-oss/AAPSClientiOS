import XCTest
import BackgroundTasks
@testable import AAPSClientiOS

/// Records calls instead of touching the real system BGTaskScheduler.
final class SpyTaskScheduler: BGTaskScheduling {
    var registeredIdentifiers: [String] = []
    var submittedRequests: [BGTaskRequest] = []

    @discardableResult
    func register(
        forTaskWithIdentifier identifier: String,
        using queue: DispatchQueue?,
        launchHandler: @escaping (BGTask) -> Void
    ) -> Bool {
        registeredIdentifiers.append(identifier)
        return true
    }

    func submit(_ taskRequest: BGTaskRequest) throws {
        submittedRequests.append(taskRequest)
    }
}

/// `BGAppRefreshTask` has no public initializer, so the launch-handler body was
/// previously untestable — which is exactly where the reschedule-ordering and
/// double-completion bugs lived.
final class FakeBackgroundTask: BackgroundTaskHandle {
    var expirationHandler: (() -> Void)?

    private let lock = NSLock()
    private var _completions: [Bool] = []
    var completions: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return _completions
    }

    func setTaskCompleted(success: Bool) {
        lock.lock()
        _completions.append(success)
        lock.unlock()
    }
}

/// Stands in for a Nightscout that has stopped answering (captive portal, LTE
/// handoff), which is what pushes a wake-up past its budget.
final class SlowNightscoutClient: FixtureNightscoutClient {
    override func fetchEntries(limit: Int) async throws -> [GlucoseReading] {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return try await super.fetchEntries(limit: limit)
    }
}

final class BackgroundSchedulerTests: XCTestCase {
    @MainActor
    private func makeStore() -> AppStore {
        AppStore(client: FixtureNightscoutClient(), alarmEngine: makeAlarmEngine())
    }

    // BGTaskScheduler is unsupported for "Designed for iPad" apps running on Mac;
    // calling register()/submit() there throws an uncaught NSException at launch.
    @MainActor
    func test_register_skipsBGTaskScheduler_whenRunningOnMac() {
        let spy = SpyTaskScheduler()
        let scheduler = BackgroundScheduler(store: makeStore(), scheduler: spy, isRunningOnMac: true)

        scheduler.register()

        XCTAssertTrue(spy.registeredIdentifiers.isEmpty)
    }

    @MainActor
    func test_schedule_skipsBGTaskScheduler_whenRunningOnMac() {
        let spy = SpyTaskScheduler()
        let scheduler = BackgroundScheduler(store: makeStore(), scheduler: spy, isRunningOnMac: true)

        scheduler.schedule()

        XCTAssertTrue(spy.submittedRequests.isEmpty)
    }

    // Registering an identifier that is absent from BGTaskSchedulerPermittedIdentifiers
    // raises at launch, so this list and project.yml have to agree exactly.
    @MainActor
    func test_register_registersBothTasks_whenRunningOniOS() {
        let spy = SpyTaskScheduler()
        let scheduler = BackgroundScheduler(store: makeStore(), scheduler: spy, isRunningOnMac: false)

        scheduler.register()

        XCTAssertEqual(
            spy.registeredIdentifiers,
            [BackgroundScheduler.refreshTaskId, BackgroundScheduler.resurrectTaskId]
        )
    }

    @MainActor
    func test_schedule_submitsBothRequests_whenRunningOniOS() {
        let spy = SpyTaskScheduler()
        let scheduler = BackgroundScheduler(store: makeStore(), scheduler: spy, isRunningOnMac: false)

        scheduler.schedule()

        XCTAssertEqual(
            spy.submittedRequests.map(\.identifier),
            [BackgroundScheduler.refreshTaskId, BackgroundScheduler.resurrectTaskId]
        )
    }

    @MainActor
    func test_schedule_isIdempotentAndResubmits() {
        let spy = SpyTaskScheduler()
        let scheduler = BackgroundScheduler(store: makeStore(), scheduler: spy, isRunningOnMac: false)

        scheduler.schedule()
        scheduler.schedule()

        XCTAssertEqual(spy.submittedRequests.count, 4)
        XCTAssertEqual(
            Set(spy.submittedRequests.map(\.identifier)),
            [BackgroundScheduler.refreshTaskId, BackgroundScheduler.resurrectTaskId]
        )
    }

    // The resurrection path must not require a charger: plenty of users never plug
    // the phone in overnight, and that is exactly the night it has to work.
    @MainActor
    func test_resurrectRequestWantsNetworkButNotExternalPower() throws {
        let spy = SpyTaskScheduler()
        let scheduler = BackgroundScheduler(store: makeStore(), scheduler: spy, isRunningOnMac: false)

        scheduler.schedule()

        let request = try XCTUnwrap(spy.submittedRequests.last as? BGProcessingTaskRequest)
        XCTAssertEqual(request.identifier, BackgroundScheduler.resurrectTaskId)
        XCTAssertTrue(request.requiresNetworkConnectivity)
        XCTAssertFalse(request.requiresExternalPower)
        let earliest = try XCTUnwrap(request.earliestBeginDate)
        XCTAssertGreaterThan(earliest.timeIntervalSinceNow, 14 * 60)
    }

    // A BGAppRefresh wake-up is the only thing that can reach the app after the
    // audio keep-alive died and the process was suspended. If it refreshes data
    // but leaves the keep-alive dead, the app just goes back to sleep and stays
    // dead until the user opens it by hand.
    @MainActor
    func test_backgroundRefresh_revivesTheKeepAlive() async {
        var revived = false
        let scheduler = BackgroundScheduler(
            store: makeStore(),
            scheduler: SpyTaskScheduler(),
            isRunningOnMac: false,
            onWake: { revived = true }
        )

        _ = await scheduler.performBackgroundRefresh()

        XCTAssertTrue(revived)
    }

    @MainActor
    func test_resurrection_runsTheResurrectHookAndTheWakeHook() async {
        var revived = false
        var resurrected = false
        let scheduler = BackgroundScheduler(
            store: makeStore(),
            scheduler: SpyTaskScheduler(),
            isRunningOnMac: false,
            onWake: { revived = true },
            onResurrect: { resurrected = true }
        )

        _ = await scheduler.performResurrection(within: BackgroundScheduler.resurrectBudget)

        XCTAssertTrue(resurrected)
        XCTAssertTrue(revived)
    }

    @MainActor
    func test_backgroundRefresh_reportsSuccess_whenRefreshSucceeds() async {
        let scheduler = BackgroundScheduler(
            store: makeStore(),
            scheduler: SpyTaskScheduler(),
            isRunningOnMac: false
        )

        let ok = await scheduler.performBackgroundRefresh()

        XCTAssertTrue(ok)
    }

    @MainActor
    func test_backgroundRefresh_reportsFailure_whenRefreshThrows() async {
        let client = FixtureNightscoutClient()
        client.shouldThrow = NsError.noNetwork
        let store = AppStore(client: client, alarmEngine: makeAlarmEngine())
        let scheduler = BackgroundScheduler(
            store: store,
            scheduler: SpyTaskScheduler(),
            isRunningOnMac: false
        )

        let ok = await scheduler.performBackgroundRefresh()

        XCTAssertFalse(ok)
    }

    @MainActor
    func test_scheduledRequestIsNotEarlierThanFiveMinutes() throws {
        let spy = SpyTaskScheduler()
        let scheduler = BackgroundScheduler(store: makeStore(), scheduler: spy, isRunningOnMac: false)

        scheduler.schedule()

        let request = try XCTUnwrap(spy.submittedRequests.first as? BGAppRefreshTaskRequest)
        let earliest = try XCTUnwrap(request.earliestBeginDate)
        XCTAssertGreaterThan(earliest.timeIntervalSinceNow, 4 * 60)
    }

    // iOS allows a BGAppRefreshTask ~30 s. `AppStore.refresh` has no timeout of its
    // own, so without a budget a hung Nightscout reliably reaches expiration — and
    // expiration is what costs the app its scheduling reputation.
    @MainActor
    func test_backgroundRefresh_givesUpWhenTheBudgetExpires() async {
        let store = AppStore(client: SlowNightscoutClient(), alarmEngine: makeAlarmEngine())
        let scheduler = BackgroundScheduler(
            store: store,
            scheduler: SpyTaskScheduler(),
            isRunningOnMac: false
        )

        let started = Date()
        let ok = await scheduler.performBackgroundRefresh(within: 0.25)

        XCTAssertFalse(ok)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // The pending BGAppRefreshTaskRequest is consumed the moment the task launches.
    // Rescheduling after the awaited work means an expiration silently opts the app
    // out of background refresh until the user next foregrounds it — permanently,
    // for a follower they never open at night.
    @MainActor
    func test_handleRefresh_reschedulesOnlyItsOwnRequestBeforeStartingTheWork() {
        let spy = SpyTaskScheduler()
        let scheduler = BackgroundScheduler(store: makeStore(), scheduler: spy, isRunningOnMac: false)

        scheduler.handleRefresh(FakeBackgroundTask())

        // ONLY the app-refresh request. Submitting a request whose identifier is already pending
        // REPLACES it, and `makeResurrectRequest` sets `earliestBeginDate = now + 15 min` — so
        // re-arming both here pushed the BGProcessing wake 15 minutes further out on every single
        // BGAppRefresh. With the audio keep-alive firing one every 10–15 min, the second,
        // charging/idle-biased budget — the overnight-nightstand path — never ran at all.
        XCTAssertEqual(
            spy.submittedRequests.map(\.identifier),
            [BackgroundScheduler.refreshTaskId],
            "the refresh chain must be re-armed synchronously, and nothing else touched"
        )
    }

    @MainActor
    func test_handleResurrect_reschedulesOnlyTheProcessingRequest() {
        let spy = SpyTaskScheduler()
        let scheduler = BackgroundScheduler(store: makeStore(), scheduler: spy, isRunningOnMac: false)

        scheduler.handleResurrect(FakeBackgroundTask())

        XCTAssertEqual(
            spy.submittedRequests.map(\.identifier),
            [BackgroundScheduler.resurrectTaskId]
        )
    }

    /// The starvation itself: repeated BGAppRefresh wakes must never move the resurrect task's
    /// earliest-begin date. `schedule()` (app launch / foreground) is the only thing that re-arms it
    /// alongside the refresh request.
    @MainActor
    func test_repeatedRefreshWakesNeverPushTheResurrectWindowOut() throws {
        let spy = SpyTaskScheduler()
        let scheduler = BackgroundScheduler(store: makeStore(), scheduler: spy, isRunningOnMac: false)

        scheduler.schedule()
        let armed = try XCTUnwrap((spy.submittedRequests.last as? BGProcessingTaskRequest)?.earliestBeginDate)

        for _ in 0..<5 {
            scheduler.handleRefresh(FakeBackgroundTask())
        }

        let processingRequests = spy.submittedRequests.compactMap { $0 as? BGProcessingTaskRequest }
        XCTAssertEqual(processingRequests.count, 1, "only schedule() may re-arm the resurrect task")
        XCTAssertEqual(processingRequests.last?.earliestBeginDate, armed)
    }

    @MainActor
    func test_handleRefresh_installsAnExpirationHandlerSynchronously() {
        let scheduler = BackgroundScheduler(
            store: makeStore(),
            scheduler: SpyTaskScheduler(),
            isRunningOnMac: false
        )
        let task = FakeBackgroundTask()

        scheduler.handleRefresh(task)

        XCTAssertNotNil(task.expirationHandler)
    }

    // Calling setTaskCompleted twice degrades scheduling reputation, and the
    // expiration handler races the success path by construction.
    @MainActor
    func test_expirationCompletesOnce_andTheLaterSuccessIsSuppressed() async throws {
        let store = AppStore(client: SlowNightscoutClient(), alarmEngine: makeAlarmEngine())
        let scheduler = BackgroundScheduler(
            store: store,
            scheduler: SpyTaskScheduler(),
            isRunningOnMac: false
        )
        let task = FakeBackgroundTask()

        scheduler.handleRefresh(task)
        let expire = try XCTUnwrap(task.expirationHandler)
        expire()
        expire()

        XCTAssertEqual(task.completions, [false])

        // Give the cancelled work every chance to complete the task a second time.
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(task.completions, [false], "the work path must not complete an expired task")
    }

    @MainActor
    func test_successCompletesExactlyOnce() async throws {
        let scheduler = BackgroundScheduler(
            store: makeStore(),
            scheduler: SpyTaskScheduler(),
            isRunningOnMac: false
        )
        let task = FakeBackgroundTask()

        scheduler.handleRefresh(task)
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(task.completions, [true])

        // A late expiration must be a no-op, not a second completion.
        task.expirationHandler?()
        XCTAssertEqual(task.completions, [true])
    }
}
