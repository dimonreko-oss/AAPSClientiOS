import Foundation

/// Mirrors AndroidAPS's `NsClientNotificationsFromAnnouncements` relay
/// (`NsIncomingDataProcessor.kt`): a Nightscout "Announcement" therapy event is only
/// worth surfacing locally for 60 minutes after it was created, and only once.
enum AnnouncementRelay {
    static let validityWindow: TimeInterval = 60 * 60

    /// Nightscout timestamps are millisecond resolution, and so is the comparison below.
    ///
    /// It cannot be exact equality. `lastNotifiedDate` round-trips through UserDefaults as a
    /// `timeIntervalSince1970` Double while `Date` stores `timeIntervalSinceReferenceDate`, so the
    /// value is shifted by 978307200 on the way out and back on the way in — an addition and
    /// subtraction that drops low-order mantissa bits. Whether a given instant survives depends on
    /// its fractional bits, so `!=` re-posted the same announcement on roughly every other launch:
    /// nondeterministic, and it presented as a duplicate notification rather than as a bug.
    private static let sameInstantTolerance: TimeInterval = 0.001

    static func pendingAnnouncement(
        in treatments: [Treatment],
        lastNotifiedDate: Date?,
        now: Date = Date()
    ) -> Treatment? {
        guard let latest = treatments
            .filter({ $0.eventType == "Announcement" })
            .max(by: { $0.date < $1.date }),
              latest.date.addingTimeInterval(validityWindow) > now,
              !isSameInstant(latest.date, lastNotifiedDate) else {
            return nil
        }
        return latest
    }

    private static func isSameInstant(_ date: Date, _ other: Date?) -> Bool {
        guard let other else { return false }
        return abs(date.timeIntervalSince(other)) < sameInstantTolerance
    }
}
