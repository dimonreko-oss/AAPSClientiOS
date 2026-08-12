import UserNotifications
import XCTest
@testable import AAPSClientiOS

final class MockNotifier: Notifier {
    var posted: [(title: String, body: String, identifier: String)] = []
    var removed: [String] = []

    func post(title: String, body: String, identifier: String) {
        posted.append((title, body, identifier))
    }

    func remove(identifier: String) {
        removed.append(identifier)
    }
}

final class AlarmSchedulingTests: XCTestCase {

    func test_schedulePostsNotification() {
        let notifier = MockNotifier()
        let engine = makeAlarmEngine(notifier: notifier)

        engine.schedule(.low)

        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertEqual(notifier.posted[0].title, "Low Glucose")
        XCTAssertEqual(notifier.posted[0].identifier, "alarm.low")
    }

    func test_snoozeRemovesNotification() {
        let notifier = MockNotifier()
        let engine = makeAlarmEngine(notifier: notifier)

        engine.snooze(.high, until: Date().addingTimeInterval(600))

        XCTAssertEqual(notifier.removed, ["alarm.high"])
    }

    func test_scheduleDifferentTypes() {
        let notifier = MockNotifier()
        let engine = makeAlarmEngine(notifier: notifier)

        engine.schedule(.urgentLow)
        engine.schedule(.connectionLost)

        XCTAssertEqual(notifier.posted.count, 2)
        XCTAssertEqual(notifier.posted[0].identifier, "alarm.urgentLow")
        XCTAssertEqual(notifier.posted[1].identifier, "alarm.connectionLost")
    }
}

// Sleep Focus silences `.active`, which is the default. Without `.timeSensitive`
// an overnight Urgent Low lands silently in Notification Centre and none of the
// background-refresh work matters.
final class AlarmInterruptionTests: XCTestCase {
    private func level(for identifier: String) -> UNNotificationInterruptionLevel {
        let content = UNMutableNotificationContent()
        AlarmInterruption.apply(to: content, identifier: identifier)
        return content.interruptionLevel
    }

    func test_everyAlarmTypeIsTimeSensitive() {
        let all: [AlarmType] = [
            .urgentLow, .low, .high, .urgentHigh, .noData, .connectionLost, .predictedLow,
        ]
        for type in all {
            XCTAssertEqual(
                level(for: type.identifier),
                .timeSensitive,
                "\(type.identifier) must break through Sleep Focus"
            )
        }
    }

    func test_alarmsCarryASound() {
        let content = UNMutableNotificationContent()
        AlarmInterruption.apply(to: content, identifier: AlarmType.urgentLow.identifier)
        XCTAssertNotNil(content.sound)
    }

    // Announcements and other relays stay at the default level on purpose.
    func test_nonAlarmNotificationsAreNotPromoted() {
        XCTAssertEqual(level(for: "ns.announcement.abc123"), .active)
        XCTAssertEqual(level(for: GlucoseNotificationController.identifier), .active)
    }

    // Pins the promotion set so the day the entitlement lands, flipping one flag is
    // provably all it takes — and so `.low`/`.high` are never quietly added to it.
    func test_criticalPromotionSetIsUrgentAndNoDataOnly() {
        XCTAssertEqual(
            AlarmInterruption.criticalIdentifiers,
            ["alarm.urgentLow", "alarm.urgentHigh", "alarm.noData"]
        )
    }

    // Shipping `.critical` without the approved entitlement makes the notification
    // centre reject the request outright — every alarm would silently vanish.
    func test_criticalAlertsStayOffUntilTheEntitlementIsGranted() {
        XCTAssertFalse(AlarmInterruption.criticalAlertsGranted)
    }
}

final class SpyDeadManNotificationCenter: DeadManNotificationScheduling {
    var scheduled: [UNNotificationRequest] = []
    var cancelled: [[String]] = []
    /// Call order matters: a re-arm that schedules before cancelling would wipe the
    /// ladder it just created.
    var events: [String] = []

    func schedule(_ request: UNNotificationRequest) {
        scheduled.append(request)
        events.append("schedule:\(request.identifier)")
    }

    func cancel(identifiers: [String]) {
        cancelled.append(identifiers)
        events.append("cancel")
    }
}

final class DeadManSwitchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeSwitch() -> (DeadManSwitch, SpyDeadManNotificationCenter) {
        let center = SpyDeadManNotificationCenter()
        return (DeadManSwitch(center: center), center)
    }

    func test_armsTheFullLadderForAFreshReading() {
        let (deadMan, center) = makeSwitch()

        deadMan.rearm(reference: now, now: now)

        XCTAssertEqual(center.scheduled.map(\.identifier), ["deadman.20", "deadman.35", "deadman.60"])
    }

    func test_ladderIsMeasuredFromTheReadingTimestamp() throws {
        let (deadMan, center) = makeSwitch()

        // Reading is already 5 minutes old, so the +20 rung is only 15 min away.
        deadMan.rearm(reference: now.addingTimeInterval(-5 * 60), now: now)

        let first = try XCTUnwrap(center.scheduled.first?.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(first.timeInterval, 15 * 60, accuracy: 0.001)
    }

    // The bug that makes this feature unusable if missed: without a cancel, every
    // successful refresh stacks another ladder and the user drowns by morning.
    func test_rearmCancelsThePreviousLadderFirst() {
        let (deadMan, center) = makeSwitch()

        deadMan.rearm(reference: now, now: now)
        center.events.removeAll()
        deadMan.rearm(reference: now.addingTimeInterval(300), now: now.addingTimeInterval(300))

        XCTAssertEqual(center.events.first, "cancel")
        XCTAssertEqual(center.cancelled.last, ["deadman.20", "deadman.35", "deadman.60"])
        XCTAssertEqual(center.scheduled.count, 6, "3 per arm, not 3 then 6 stacked on top")
    }

    func test_dropsRungsThatAreAlreadyDue() {
        let (deadMan, center) = makeSwitch()

        // 40 minutes of silence: the live app is already raising a real .noData, so
        // repeating it 60 s later as a ladder rung is duplicate noise.
        deadMan.rearm(reference: now.addingTimeInterval(-40 * 60), now: now)

        XCTAssertEqual(center.scheduled.map(\.identifier), ["deadman.60"])
    }

    // UNTimeIntervalNotificationTrigger traps below 60 s.
    func test_neverSchedulesBelowTheSixtySecondFloor() {
        for minutesOld in 0...70 {
            let (deadMan, center) = makeSwitch()
            deadMan.rearm(reference: now.addingTimeInterval(-Double(minutesOld) * 60), now: now)
            for request in center.scheduled {
                let trigger = request.trigger as? UNTimeIntervalNotificationTrigger
                XCTAssertGreaterThanOrEqual(trigger?.timeInterval ?? 0, 60)
            }
        }
    }

    /// The ladder must never be left EMPTY. `AppStore.updateSharedSnapshot` re-arms on every
    /// successful refresh, and a refresh succeeds whenever Nightscout answers — even when the reading
    /// it returns is the same frozen one. So a CGM that died at 02:00 behind a healthy Nightscout had
    /// all three rungs in the past by 03:05, `rearm` cancelled them and armed nothing, and a
    /// force-quit or OOM kill after that left no pre-scheduled alarm at all — at exactly the point
    /// where the process is LEAST likely to survive to raise the live one.
    func test_armsAFloorRungOnceEveryEscalatingRungIsInThePast() throws {
        let (deadMan, center) = makeSwitch()

        deadMan.rearm(reference: now.addingTimeInterval(-90 * 60), now: now)

        XCTAssertEqual(center.scheduled.map(\.identifier), ["deadman.20"])
        let trigger = try XCTUnwrap(center.scheduled.first?.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, DeadManSwitch.floorInterval, accuracy: 0.001)
    }

    /// However long the feed has been dead, something is always pending.
    func test_theLadderIsNeverEmptyForAnyAgeOfReading() {
        for minutesOld in stride(from: 0, through: 240, by: 5) {
            let (deadMan, center) = makeSwitch()
            deadMan.rearm(reference: now.addingTimeInterval(-Double(minutesOld) * 60), now: now)
            XCTAssertFalse(center.scheduled.isEmpty, "nothing armed for a reading \(minutesOld) min old")
        }
    }

    func test_ladderStaysUnderThePendingRequestBudget() {
        XCTAssertLessThanOrEqual(DeadManSwitch.rungs.count, 5)
    }

    func test_rungsAreTimeSensitiveAndDoNotRepeat() throws {
        let (deadMan, center) = makeSwitch()

        deadMan.rearm(reference: now, now: now)

        let request = try XCTUnwrap(center.scheduled.first)
        XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
        let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertFalse(trigger.repeats)
    }

    func test_disarmRemovesEveryRungAndSchedulesNothing() {
        let (deadMan, center) = makeSwitch()

        deadMan.rearm(reference: now, now: now)
        center.scheduled.removeAll()
        deadMan.disarm()

        XCTAssertTrue(center.scheduled.isEmpty)
        XCTAssertEqual(center.cancelled.last, ["deadman.20", "deadman.35", "deadman.60"])
    }
}
