import XCTest
@testable import AAPSClientiOS

final class BackgroundPollScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    func test_alignsToCgmCadence_whenLastReadingIsRecent() {
        let lastReading = now.addingTimeInterval(-60)

        let next = BackgroundPollSchedule.nextPollDate(
            lastReadingDate: lastReading,
            consecutiveMisses: 0,
            now: now
        )

        XCTAssertEqual(next.timeIntervalSince(now), 4 * 60 + 20, accuracy: 0.001)
    }

    func test_pollsImmediately_whenScheduleIsAlreadyInThePast() {
        let lastReading = now.addingTimeInterval(-3600)

        let next = BackgroundPollSchedule.nextPollDate(
            lastReadingDate: lastReading,
            consecutiveMisses: 0,
            now: now
        )

        XCTAssertEqual(next, now)
    }

    func test_usesShortRetry_afterAMissedReading() {
        let next = BackgroundPollSchedule.nextPollDate(
            lastReadingDate: now.addingTimeInterval(-60),
            consecutiveMisses: 1,
            now: now
        )

        XCTAssertEqual(next.timeIntervalSince(now), 30, accuracy: 0.001)
    }

    func test_fallsBackToFixedInterval_afterMissCap() {
        let next = BackgroundPollSchedule.nextPollDate(
            lastReadingDate: now.addingTimeInterval(-60),
            consecutiveMisses: 4,
            now: now
        )

        XCTAssertEqual(next.timeIntervalSince(now), 5 * 60, accuracy: 0.001)
    }

    func test_fallsBackToFixedInterval_whenThereAreNoReadings() {
        let next = BackgroundPollSchedule.nextPollDate(
            lastReadingDate: nil,
            consecutiveMisses: 0,
            now: now
        )

        XCTAssertEqual(next.timeIntervalSince(now), 5 * 60, accuracy: 0.001)
    }

    func test_aggressiveModeUsesFixedShortInterval() {
        XCTAssertEqual(BackgroundPollSchedule.aggressiveInterval, 60)
    }
}

@MainActor
final class BackgroundTickCoordinatorTests: XCTestCase {
    /// Old enough that the CGM-aligned next poll always lands in the past, so
    /// `nextDelay` collapses to its 1 s floor.
    private var staleReading: Date { Date().addingTimeInterval(-3600) }

    func test_repeatedIdenticalReadingCountsAsAMiss() {
        let coordinator = BackgroundTickCoordinator()
        let reading = staleReading

        coordinator.recordOutcome(latestReadingDate: reading)
        coordinator.recordOutcome(latestReadingDate: reading)

        XCTAssertEqual(
            coordinator.nextDelay(mode: .normal, lastReadingDate: reading),
            BackgroundPollSchedule.retryInterval,
            accuracy: 0.001
        )
    }

    func test_resetClearsTheMissCounter() {
        let coordinator = BackgroundTickCoordinator()
        let reading = staleReading
        coordinator.recordOutcome(latestReadingDate: reading)
        coordinator.recordOutcome(latestReadingDate: reading)

        coordinator.reset()

        XCTAssertEqual(coordinator.nextDelay(mode: .normal, lastReadingDate: reading), 1, accuracy: 0.5)
    }

    // `resetMisses()` cleared the counter but kept `lastSeenReadingDate`, so a short
    // foreground visit during which no new reading arrived was scored as a miss on
    // the very next background tick — one wasted 30 s retry poll every time the user
    // glanced at the app.
    func test_resetAlsoForgetsTheLastSeenReading() {
        let coordinator = BackgroundTickCoordinator()
        let reading = staleReading
        coordinator.recordOutcome(latestReadingDate: reading)

        coordinator.reset()
        coordinator.recordOutcome(latestReadingDate: reading)

        XCTAssertEqual(
            coordinator.nextDelay(mode: .normal, lastReadingDate: reading),
            1,
            accuracy: 0.5,
            "the same reading seen after a reset is a first sighting, not a miss"
        )
    }

    func test_aggressiveModeIgnoresMisses() {
        let coordinator = BackgroundTickCoordinator()
        let reading = staleReading
        coordinator.recordOutcome(latestReadingDate: reading)
        coordinator.recordOutcome(latestReadingDate: reading)

        XCTAssertEqual(
            coordinator.nextDelay(mode: .aggressive, lastReadingDate: reading),
            BackgroundPollSchedule.aggressiveInterval,
            accuracy: 0.001
        )
    }
}
