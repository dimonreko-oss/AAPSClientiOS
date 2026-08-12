import XCTest
@testable import AAPSClientiOS

final class AnnouncementRelayTests: XCTestCase {

    private func announcement(id: String, minutesAgo: Double, notes: String? = "Pump alert") -> Treatment {
        Treatment(
            id: id, eventType: "Announcement", date: Date().addingTimeInterval(-minutesAgo * 60),
            insulin: nil, carbs: nil, durationMin: nil, enteredBy: nil, notes: notes,
            targetBottom: nil, targetTop: nil, profileName: nil, percentage: nil,
            absolute: nil, tempBasalPercent: nil
        )
    }

    func test_returnsNil_whenNoAnnouncements() {
        let result = AnnouncementRelay.pendingAnnouncement(in: [], lastNotifiedDate: nil)
        XCTAssertNil(result)
    }

    func test_returnsLatest_whenFreshAndNotYetNotified() {
        let old = announcement(id: "a1", minutesAgo: 90)
        let fresh = announcement(id: "a2", minutesAgo: 5)
        let result = AnnouncementRelay.pendingAnnouncement(in: [old, fresh], lastNotifiedDate: nil)
        XCTAssertEqual(result?.id, "a2")
    }

    func test_returnsNil_whenOlderThanValidityWindow() {
        let stale = announcement(id: "a1", minutesAgo: 61)
        let result = AnnouncementRelay.pendingAnnouncement(in: [stale], lastNotifiedDate: nil)
        XCTAssertNil(result)
    }

    func test_returnsNil_whenAlreadyNotified() {
        let a = announcement(id: "a1", minutesAgo: 5)
        let result = AnnouncementRelay.pendingAnnouncement(in: [a], lastNotifiedDate: a.date)
        XCTAssertNil(result)
    }

    /// The marker is persisted as a `timeIntervalSince1970` Double while `Date` stores
    /// `timeIntervalSinceReferenceDate`, so it comes back shifted by the epoch difference and a few
    /// hundred nanoseconds off. Exact `!=` therefore re-posted the same announcement on roughly every
    /// other launch — nondeterministic, and it looked like a flaky test rather than a duplicate
    /// notification. This reproduces the round trip exactly as `AppStore` performs it.
    func test_returnsNil_whenTheMarkerHasRoundTrippedThroughUserDefaults() {
        let a = announcement(id: "a1", minutesAgo: 5)
        let persisted = Date(timeIntervalSince1970: a.date.timeIntervalSince1970)
        let result = AnnouncementRelay.pendingAnnouncement(in: [a], lastNotifiedDate: persisted)
        XCTAssertNil(result, "a round-tripped marker must still count as already notified")
    }

    /// The tolerance must not swallow a genuinely different announcement: Nightscout timestamps are
    /// millisecond resolution, so two announcements one millisecond apart are two events.
    func test_returnsLatest_whenOneMillisecondNewerThanTheMarker() {
        let a = announcement(id: "a1", minutesAgo: 5)
        let result = AnnouncementRelay.pendingAnnouncement(
            in: [a],
            lastNotifiedDate: a.date.addingTimeInterval(-0.002)
        )
        XCTAssertEqual(result?.id, "a1")
    }

    func test_ignoresNonAnnouncementEventTypes() {
        let carbs = Treatment(
            id: "c1", eventType: "Carb Correction", date: Date(),
            insulin: nil, carbs: 20, durationMin: nil, enteredBy: nil, notes: nil,
            targetBottom: nil, targetTop: nil, profileName: nil, percentage: nil,
            absolute: nil, tempBasalPercent: nil
        )
        let result = AnnouncementRelay.pendingAnnouncement(in: [carbs], lastNotifiedDate: nil)
        XCTAssertNil(result)
    }
}
