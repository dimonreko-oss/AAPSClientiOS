import UserNotifications

/// How loud an alarm is allowed to be.
///
/// `.timeSensitive` is the strongest level Apple hands out without review: it
/// breaks through Sleep Focus and Do Not Disturb, which is what silently ate the
/// overnight Urgent Low. It does **not** override the hardware ring/silent switch
/// — a phone flipped to silent still delivers an Urgent Low with no sound. So this
/// is an improvement, not a solution; only `.critical` closes that last hole.
///
/// It also requires the `com.apple.developer.usernotifications.time-sensitive`
/// entitlement (already in App/AAPSClientiOS.entitlements). Without it iOS quietly
/// downgrades the level back to `.active`.
enum AlarmInterruption {
    /// Flip to `true` on the day Apple grants
    /// `com.apple.developer.usernotifications.critical-alerts`, and uncomment the
    /// matching key in App/AAPSClientiOS.entitlements in the same commit. Those are
    /// the only two edits needed. Do not ship the key before approval: an
    /// unapproved critical-alerts entitlement breaks provisioning, and setting
    /// `.critical` without the key makes the notification centre reject the request
    /// outright — every alarm would vanish.
    static let criticalAlertsGranted = false

    /// Only the alarms that justify overriding the silent switch. Deliberately not
    /// `.low`/`.high`/`.predictedLow`: one nuisance critical alert and the user
    /// turns the whole category off, taking the hypo alarm with it.
    static let criticalIdentifiers: Set<String> = [
        AlarmType.urgentLow.identifier,
        AlarmType.urgentHigh.identifier,
        AlarmType.noData.identifier,
    ]

    /// Alarm identifiers are namespaced `alarm.*` by `AlarmType.identifier`.
    /// Announcements and other relays go out at the default level on purpose —
    /// they are informational, and burning Time Sensitive on them trains the user
    /// to dismiss the badge that the hypo alarm depends on.
    static func isAlarm(_ identifier: String) -> Bool {
        identifier.hasPrefix("alarm.")
    }

    static func apply(to content: UNMutableNotificationContent, identifier: String) {
        content.sound = .default
        guard isAlarm(identifier) else { return }
        content.interruptionLevel = .timeSensitive
        if criticalAlertsGranted, criticalIdentifiers.contains(identifier) {
            content.interruptionLevel = .critical
            content.sound = .defaultCriticalSound(withAudioVolume: 1.0)
        }
    }
}

final class UNNotifier: Notifier {
    func post(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        AlarmInterruption.apply(to: content, identifier: identifier)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func remove(identifier: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
