import BackgroundTasks
import Foundation
import os

/// System BGTaskScheduler seam so the scheduler can be tested without the real
/// singleton (which is also unavailable for iOS apps running on Mac).
protocol BGTaskScheduling {
    @discardableResult
    func register(
        forTaskWithIdentifier identifier: String,
        using queue: DispatchQueue?,
        launchHandler: @escaping (BGTask) -> Void
    ) -> Bool
    func submit(_ taskRequest: BGTaskRequest) throws
}

extension BGTaskScheduler: BGTaskScheduling {}

/// Minimal seam over `BGTask`, which has no public initializer — without this the
/// whole launch-handler body is untestable and the reschedule/completion ordering
/// (the part that actually breaks) can only be verified by shipping it.
protocol BackgroundTaskHandle: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

extension BGTask: BackgroundTaskHandle {}

/// Per-invocation state for one background task.
///
/// `setTaskCompleted` must be called exactly once. The expiration handler and the
/// success path race by construction, and completing twice is a scheduling-
/// reputation penalty — iOS responds by handing out fewer wake-ups, which for this
/// app means fewer chances to notice a dead CGM.
private final class BackgroundTaskRun: @unchecked Sendable {
    private struct State: Sendable {
        var completed = false
        var work: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Returns `true` for exactly one caller, ever.
    func claimCompletion() -> Bool {
        state.withLock { (s: inout State) -> Bool in
            if s.completed { return false }
            s.completed = true
            return true
        }
    }

    func attach(_ task: Task<Void, Never>) {
        state.withLock { (s: inout State) -> Void in s.work = task }
    }

    func cancelWork() {
        let task = state.withLock { (s: inout State) -> Task<Void, Never>? in s.work }
        task?.cancel()
    }
}

final class BackgroundScheduler {
    static let refreshTaskId = "com.nightaps.aapsclientios.refresh"
    /// Second, independent budget. `BGAppRefreshTask` runs in usage-predictive
    /// windows and is the first thing iOS throttles for an app the user never
    /// foregrounds at night — this app's exact profile. `BGProcessingTask` is
    /// biased toward charging-and-idle windows, which is precisely where an
    /// overnight phone on a nightstand charger sits.
    static let resurrectTaskId = "com.nightaps.aapsclientios.resurrect"

    /// Hard bound on one refresh wake-up. iOS gives a `BGAppRefreshTask` roughly
    /// 30 s before it expires the task and counts it against the app; `AppStore`'s
    /// refresh has no timeout of its own, so a captive portal or a slow Nightscout
    /// will reliably sit there until iOS kills the process.
    static let refreshBudget: TimeInterval = 20
    /// Processing tasks get a far longer wall clock, and resurrection does more
    /// than one fetch, so it is bounded loosely rather than tightly.
    static let resurrectBudget: TimeInterval = 45

    private let store: AppStore
    private let scheduler: BGTaskScheduling
    /// BackgroundTasks is unsupported for "Designed for iPad" apps running on Mac;
    /// touching BGTaskScheduler there throws an uncaught NSException and crashes
    /// the app at launch. Skip all BG work in that environment.
    private let isRunningOnMac: Bool
    /// Runs at the start of every background wake-up, to revive the audio
    /// keep-alive if it died while the process was suspended.
    private let onWake: @MainActor () -> Void
    /// Runs only on the BGProcessing path. Resurrection, not polling: reconnect the
    /// realtime socket, re-arm the dead-man ladder, rebuild anything that dies with
    /// a suspended process.
    private let onResurrect: @MainActor () -> Void
    private let log = Logger(subsystem: "com.nightaps.aapsclientios", category: "BackgroundScheduler")

    init(
        store: AppStore,
        scheduler: BGTaskScheduling = BGTaskScheduler.shared,
        isRunningOnMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac,
        onWake: @escaping @MainActor () -> Void = {},
        onResurrect: @escaping @MainActor () -> Void = {}
    ) {
        self.store = store
        self.scheduler = scheduler
        self.isRunningOnMac = isRunningOnMac
        self.onWake = onWake
        self.onResurrect = onResurrect
    }

    func register() {
        guard !isRunningOnMac else { return }
        // Both identifiers must also appear in `BGTaskSchedulerPermittedIdentifiers`
        // (project.yml -> App/Info.plist): registering one that is missing there
        // raises at launch.
        scheduler.register(forTaskWithIdentifier: Self.refreshTaskId, using: nil) { [weak self] task in
            self?.handleRefresh(task)
        }
        scheduler.register(forTaskWithIdentifier: Self.resurrectTaskId, using: nil) { [weak self] task in
            self?.handleResurrect(task)
        }
    }

    func schedule() {
        guard !isRunningOnMac else { return }
        scheduleRefresh()
        scheduleResurrect()
    }

    /// Re-arms ONLY the app-refresh request.
    ///
    /// Each handler must re-arm its own request and nothing else. Submitting a request whose
    /// identifier is already pending REPLACES it, and `makeResurrectRequest` sets
    /// `earliestBeginDate = now + 15 min` — so calling the full `schedule()` from the refresh handler
    /// pushed the BGProcessing wake 15 minutes further out on every single `BGAppRefreshTask`. With
    /// the audio keep-alive firing one every 10–15 minutes, the second, charging/idle-biased budget
    /// this app added specifically for the overnight nightstand case never ran at all.
    private func scheduleRefresh() {
        guard !isRunningOnMac else { return }
        submit(makeRefreshRequest())
    }

    private func scheduleResurrect() {
        guard !isRunningOnMac else { return }
        submit(makeResurrectRequest())
    }

    private func makeRefreshRequest() -> BGAppRefreshTaskRequest {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        return request
    }

    private func makeResurrectRequest() -> BGProcessingTaskRequest {
        let request = BGProcessingTaskRequest(identifier: Self.resurrectTaskId)
        // Network is the whole point of the wake-up; external power is not, or the
        // task would never run for a user who does not charge overnight.
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        return request
    }

    private func submit(_ request: BGTaskRequest) {
        do {
            try scheduler.submit(request)
        } catch {
            // Never fatal, but never silent either: `BGTaskSchedulerErrorCode
            // .notPermitted` here is the signature of a missing Info.plist
            // background mode, and losing it to `print` in Release is how that ships.
            log.error(
                "failed to schedule \(request.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Internal rather than private so the reschedule/completion ordering is
    /// testable through `BackgroundTaskHandle`.
    func handleRefresh(_ task: BackgroundTaskHandle) {
        // Reschedule FIRST, before any awaited work. The pending request is consumed
        // the moment the task launches, so if the work overruns and iOS reclaims the
        // process, a `schedule()` at the end never runs and the app has silently
        // opted itself out of background refresh until the user next foregrounds it.
        scheduleRefresh()
        run(task, budget: Self.refreshBudget) { [weak self] budget in
            guard let self else { return false }
            return await self.performBackgroundRefresh(within: budget)
        }
    }

    func handleResurrect(_ task: BackgroundTaskHandle) {
        scheduleResurrect()
        run(task, budget: Self.resurrectBudget) { [weak self] budget in
            guard let self else { return false }
            return await self.performResurrection(within: budget)
        }
    }

    private func run(
        _ task: BackgroundTaskHandle,
        budget: TimeInterval,
        work: @escaping @Sendable (TimeInterval) async -> Bool
    ) {
        let invocation = BackgroundTaskRun()
        task.expirationHandler = {
            invocation.cancelWork()
            if invocation.claimCompletion() { task.setTaskCompleted(success: false) }
        }
        invocation.attach(Task {
            let ok = await work(budget)
            if invocation.claimCompletion() { task.setTaskCompleted(success: ok) }
        })
    }

    /// The work one background wake-up performs, split out of `handleRefresh`
    /// because `BGAppRefreshTask` has no public initializer and so cannot be
    /// constructed in tests.
    ///
    /// Reviving the keep-alive comes first: a wake-up is the only chance to
    /// restart audio that died while the process was suspended, and without it
    /// the app refreshes once and sleeps again for good.
    @discardableResult
    func performBackgroundRefresh() async -> Bool {
        await MainActor.run { onWake() }
        do {
            try await store.refresh(scope: .light)
            return true
        } catch {
            return false
        }
    }

    /// The BGProcessing job: rebuild everything that dies with a suspended process,
    /// then reconcile data. Deliberately not just another poll.
    @discardableResult
    func performResurrection(within budget: TimeInterval) async -> Bool {
        await MainActor.run { onResurrect() }
        return await performBackgroundRefresh(within: budget)
    }

    /// Races the refresh against a wall clock so an unresponsive Nightscout can
    /// never be the reason iOS expires the task.
    @discardableResult
    func performBackgroundRefresh(within budget: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool?.self) { group -> Bool in
            group.addTask { await self.performBackgroundRefresh() }
            group.addTask { () -> Bool? in
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                return nil
            }
            // First finisher wins. `.some(nil)` means the budget task got there
            // first, i.e. the refresh overran and is about to be cancelled.
            let firstFinished = await group.next()
            group.cancelAll()
            return firstFinished.flatMap { $0 } ?? false
        }
    }
}
