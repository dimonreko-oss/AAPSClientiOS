import ActivityKit
import Foundation
import os

/// Starts/stops/updates the glucose Live Activity. Best-effort: updates only
/// fire while the app process is alive (foreground or background refresh). No
/// push server, so the activity goes stale when the app is not running.
@available(iOS 16.1, *)
@MainActor final class LiveActivityController {
    static let shared = LiveActivityController()
    private var activity: Activity<GlucoseActivityAttributes>?
    private let log = Logger(subsystem: "com.nightaps.aapsclientios", category: "LiveActivity")

    private init() {
        reattach()
    }

    var isSupported: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Re-bind to an activity that survived a previous launch. `Activity.activities`
    /// can still be empty at the instant the singleton is first created — ActivityKit
    /// populates it asynchronously shortly after launch — so a one-shot re-attach in
    /// `init` can lose the race and leave the reference nil forever, silently dropping
    /// every `update()` while a stale activity stays frozen on screen. We therefore
    /// re-attempt on demand before each update until the binding succeeds.
    @discardableResult
    private func reattach() -> Bool {
        // Always look up the live activity — the stored reference can go stale
        // if ActivityKit dismissed it (system timeout, budget exhaustion, etc.).
        //
        // Skip activities that are already `.ended` or `.dismissed`. ActivityKit
        // keeps an ended activity in `activities` for its dismissal window, so
        // binding to the first entry unconditionally is how the 8-hour lifetime
        // expiry turned into a permanently frozen card: every later `update()`
        // went to a dead activity and `startOrUpdate` never took the restart
        // branch. Rejecting them here makes the restart happen from whichever
        // path pushes next — including a background tick, not just a foreground
        // visit.
        if let existing = Activity<GlucoseActivityAttributes>.activities.first(where: {
            $0.activityState != .dismissed && $0.activityState != .ended
        }) {
            activity = existing
            return true
        }
        if let activity,
           activity.activityState != .dismissed,
           activity.activityState != .ended {
            return true
        }
        activity = nil
        return false
    }

    @discardableResult
    func start(with state: GlucoseActivityAttributes.ContentState, staleMinutes: Int) -> Bool {
        guard isSupported else { return false }
        if reattach() { update(state, staleMinutes: staleMinutes); return true }
        do {
            let staleDate = liveActivityStaleDate(for: state.date, staleMinutes: staleMinutes)
            if #available(iOS 16.2, *) {
                activity = try Activity.request(
                    attributes: GlucoseActivityAttributes(),
                    content: ActivityContent(state: state, staleDate: staleDate)
                )
            } else {
                activity = try Activity.request(
                    attributes: GlucoseActivityAttributes(),
                    contentState: state
                )
            }
            log.info("started live activity")
            DebugLog.log("LA.start created id=\(String(describing: activity?.id.suffix(4))) mgdl=\(state.mgdl)")
            return true
        } catch {
            log.error("start failed: \(error.localizedDescription, privacy: .public)")
            DebugLog.log("LA.start FAILED \(error.localizedDescription)")
            return false
        }
    }

    /// `staleMinutes` is the user's own No-Data threshold, so the card greys out at exactly the
    /// moment the app would raise `.noData` rather than on a hardcoded 15 minutes.
    func update(_ state: GlucoseActivityAttributes.ContentState, staleMinutes: Int) {
        guard reattach() else {
            log.debug("update dropped — no live activity to bind")
            DebugLog.log("LA.update DROPPED (no activity)")
            return
        }
        let bound = activity
        Task {
            let staleDate = liveActivityStaleDate(for: state.date, staleMinutes: staleMinutes)
            if #available(iOS 16.2, *) {
                await bound?.update(ActivityContent(state: state, staleDate: staleDate))
            } else {
                await bound?.update(using: state)
            }
            if #available(iOS 16.2, *) {
                let held = bound?.content.state.mgdl
                DebugLog.log("LA.update pushed=\(state.mgdl) heldAfter=\(String(describing: held)) boundId=\(String(describing: bound?.id.suffix(4)))")
            }
        }
    }

    @discardableResult
    func startOrUpdate(with state: GlucoseActivityAttributes.ContentState, staleMinutes: Int) -> Bool {
        guard isSupported else { return false }
        if reattach() {
            update(state, staleMinutes: staleMinutes)
            return true
        }
        // Reached when ActivityKit ended the activity on its own — the 8-hour lifetime, a reboot, or
        // budget exhaustion. Re-`request()` from whichever path got here, foreground or background.
        DebugLog.log("LA.update missing activity; restarting mgdl=\(state.mgdl)")
        return start(with: state, staleMinutes: staleMinutes)
    }

    @discardableResult
    func stop() -> Bool {
        let activities = Activity<GlucoseActivityAttributes>.activities
        let wasRunning = !activities.isEmpty || activity != nil
        Task {
            for existing in activities {
                await existing.end(dismissalPolicy: .immediate)
            }
            await activity?.end(dismissalPolicy: .immediate)
            activity = nil
        }
        return wasRunning
    }

    var isRunning: Bool { reattach() }
}
