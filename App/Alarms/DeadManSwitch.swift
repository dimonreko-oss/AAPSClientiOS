import Foundation
import UserNotifications

/// The honest ceiling, stated once so nobody re-litigates it:
///
/// **iOS cannot deliver data to a force-quit process without APNs or Core
/// Location.** Audio keep-alive, BGAppRefresh and BGProcessing all require the
/// process to still exist. So the architecture is layered — fresh while alive,
/// best-effort recovery when suspended, and this: a loud, unmissable failure
/// signal when the app is simply *dead*.
///
/// A pre-scheduled `UNTimeIntervalNotificationTrigger` is the one alarm path the
/// system delivers on the app's behalf. It survives suspension, termination, OOM
/// kill and force-quit. It is the only layer that fires for a phone sitting
/// motionless on a nightstand, which is exactly the scenario the whole feature
/// exists for.
///
/// The cost of the mechanism is that it is *pessimistic*: it fires unless the app
/// gets a chance to cancel it. Every successful refresh therefore re-arms the
/// ladder, pushing the rungs back out. A user who sees one of these has genuinely
/// had no data for that long, or the app is genuinely gone — both worth waking up
/// for.
protocol DeadManSwitching: AnyObject {
    /// Cancels the previous ladder and arms a new one measured from `reference`
    /// (the timestamp of the newest reading, never the fetch time — see
    /// `AlarmEngineLive.evaluate`).
    func rearm(reference: Date, now: Date)
    /// Cancels every pending rung. Called when the user turns keep-alive off, so a
    /// disabled feature cannot keep posting alarms.
    func disarm()
}

extension DeadManSwitching {
    func rearm(reference: Date) {
        rearm(reference: reference, now: Date())
    }
}

/// Narrow seam over `UNUserNotificationCenter`. Deliberately not named `add` /
/// `removePendingNotificationRequests`: same-name extension methods on
/// `UNUserNotificationCenter` would collide with its own defaulted-argument
/// overloads and make every existing call site ambiguous.
protocol DeadManNotificationScheduling: AnyObject {
    func schedule(_ request: UNNotificationRequest)
    func cancel(identifiers: [String])
}

extension UNUserNotificationCenter: DeadManNotificationScheduling {
    func schedule(_ request: UNNotificationRequest) {
        add(request, withCompletionHandler: nil)
    }

    /// PENDING only. Removing DELIVERED rungs meant the next successful poll silently erased the
    /// "no glucose data for 20 min" the user was supposed to find in Notification Centre in the
    /// morning — the app deleting its own evidence that it had failed.
    func cancel(identifiers: [String]) {
        removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

/// One rung of the ladder.
struct DeadManRung: Equatable {
    let identifier: String
    /// Minutes of silence after `reference` at which this rung fires.
    let afterMinutes: Int

    var title: String { "No glucose data for \(afterMinutes) min" }
    var body: String {
        "The app has stopped updating. Open it to restore monitoring."
    }
}

final class DeadManSwitch: DeadManSwitching {
    /// Three rungs. The pending-request cap is 64 and the alarm identifiers plus
    /// the glucose notification already occupy a handful, so the brief's "≤ 5"
    /// budget is respected with room to spare. Escalating rather than repeating:
    /// 20 min is "probably a hiccup", 60 min is "this is broken".
    static let rungs: [DeadManRung] = [
        DeadManRung(identifier: "deadman.20", afterMinutes: 20),
        DeadManRung(identifier: "deadman.35", afterMinutes: 35),
        DeadManRung(identifier: "deadman.60", afterMinutes: 60),
    ]

    /// `UNTimeIntervalNotificationTrigger` traps on anything below 60 s.
    static let minimumInterval: TimeInterval = 60

    private static var allIdentifiers: [String] { rungs.map(\.identifier) }

    private let center: DeadManNotificationScheduling

    init(center: DeadManNotificationScheduling = UNUserNotificationCenter.current()) {
        self.center = center
    }

    func rearm(reference: Date, now: Date) {
        // Cancel FIRST and unconditionally. Re-arming without cancelling would
        // stack a fresh ladder on every single refresh — one per poll, forever —
        // and the user would be buried in "no data" notifications by morning.
        center.cancel(identifiers: Self.allIdentifiers)

        for (rung, delay) in Self.pendingRungs(reference: reference, now: now) {
            let content = UNMutableNotificationContent()
            content.title = rung.title
            content.body = rung.body
            content.sound = .default
            // A dead app is precisely when Focus must be overridden, so this rung
            // is Time Sensitive even though it is not an `alarm.*` identifier and
            // so does not go through `AlarmInterruption.apply`.
            content.interruptionLevel = .timeSensitive

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            center.schedule(UNNotificationRequest(
                identifier: rung.identifier,
                content: content,
                trigger: trigger
            ))
        }
    }

    func disarm() {
        center.cancel(identifiers: Self.allIdentifiers)
    }

    /// Once every escalating rung is in the past, re-arm the first one this far out instead of
    /// leaving the ladder empty. That state means the feed has been dead for over an hour — which is
    /// exactly when the process is LEAST likely to survive to raise the live alarm, not most.
    static let floorInterval: TimeInterval = 20 * 60

    /// Rungs still in the future, with the delay each needs from `now`.
    ///
    /// Rungs already in the past are dropped rather than clamped to the 60 s floor:
    /// if the newest reading is already 25 minutes old the live app has raised a
    /// real `.noData` alarm this instant, and firing the +20 rung a minute later is
    /// pure duplicate noise.
    ///
    /// But the ladder is never left EMPTY. `AppStore.updateSharedSnapshot` re-arms on every
    /// successful refresh, and a refresh succeeds whenever Nightscout answers — even when the
    /// reading it returns is the same frozen one. So a CGM that died at 02:00 behind a healthy
    /// Nightscout used to have all three rungs cancelled and nothing armed by 03:05; a force-quit or
    /// OOM kill after that left no pre-scheduled alarm at all.
    static func pendingRungs(reference: Date, now: Date) -> [(rung: DeadManRung, delay: TimeInterval)] {
        let future = rungs.compactMap { rung -> (rung: DeadManRung, delay: TimeInterval)? in
            let fireAt = reference.addingTimeInterval(TimeInterval(rung.afterMinutes) * 60)
            let delay = fireAt.timeIntervalSince(now)
            guard delay >= minimumInterval else { return nil }
            return (rung: rung, delay: delay)
        }
        guard future.isEmpty else { return future }
        return [(rung: rungs[0], delay: floorInterval)]
    }
}

/// Used by tests and by any build that must not touch the notification centre.
final class DummyDeadManSwitch: DeadManSwitching {
    func rearm(reference: Date, now: Date) {}
    func disarm() {}
}
