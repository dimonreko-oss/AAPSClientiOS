import XCTest
@testable import AAPSClientiOS

final class OrphanDetectorTests: XCTestCase {
    private let gracePeriodMs: Int64 = 60_000

    func test_noSignalWhenRosterIsNil() {
        let result = OrphanDetector.evaluate(
            ownClientId: "c1", roster: nil,
            docSrvModifiedMs: 2_000_000, pairedAtMs: 1_000_000, nowMs: 3_000_000, gracePeriodMs: gracePeriodMs
        )
        XCTAssertEqual(result, .noSignal)
    }

    func test_authorizedWhenOwnIdInRoster() {
        let result = OrphanDetector.evaluate(
            ownClientId: "c1", roster: ["c1", "c2"],
            docSrvModifiedMs: 2_000_000, pairedAtMs: 1_000_000, nowMs: 3_000_000, gracePeriodMs: gracePeriodMs
        )
        XCTAssertEqual(result, .authorized)
    }

    func test_deferredWhenDocPredatesPairingWithinGrace() {
        // Doc modified at pairedAt + 30s (grace is 60s) — still within the race window.
        let result = OrphanDetector.evaluate(
            ownClientId: "c1", roster: ["c2"],
            docSrvModifiedMs: 1_030_000, pairedAtMs: 1_000_000, nowMs: 3_000_000, gracePeriodMs: gracePeriodMs
        )
        XCTAssertEqual(result, .deferred)
    }

    func test_orphanedWhenDocPastGraceAndOwnIdMissing() {
        // Doc modified at pairedAt + 90s (past the 60s grace).
        let result = OrphanDetector.evaluate(
            ownClientId: "c1", roster: ["c2"],
            docSrvModifiedMs: 1_090_000, pairedAtMs: 1_000_000, nowMs: 3_000_000, gracePeriodMs: gracePeriodMs
        )
        XCTAssertEqual(result, .orphaned)
    }

    func test_orphanedWhenNoPairedAtRecorded() {
        // pairedAtMs == 0 (unknown) skips the race guard entirely, matching Kotlin's `pairedAt > 0L` check.
        let result = OrphanDetector.evaluate(
            ownClientId: "c1", roster: ["c2"],
            docSrvModifiedMs: 500_000, pairedAtMs: 0, nowMs: 3_000_000, gracePeriodMs: gracePeriodMs
        )
        XCTAssertEqual(result, .orphaned)
    }

    func test_orphanedWhenDocSrvModifiedUnknown() {
        // docSrvModifiedMs == 0 (unknown) skips the race guard entirely, matching Kotlin's `docSrvModified > 0L` check.
        let result = OrphanDetector.evaluate(
            ownClientId: "c1", roster: ["c2"],
            docSrvModifiedMs: 0, pairedAtMs: 1_000_000, nowMs: 3_000_000, gracePeriodMs: gracePeriodMs
        )
        XCTAssertEqual(result, .orphaned)
    }

    // MARK: - Durable verdict

    func test_resolveTurnsEvidenceIntoADurableFlag() {
        XCTAssertEqual(OrphanDetector.resolve(.authorized, previous: nil), true)
        XCTAssertEqual(OrphanDetector.resolve(.authorized, previous: false), true)
        XCTAssertEqual(OrphanDetector.resolve(.orphaned, previous: nil), false)
        XCTAssertEqual(OrphanDetector.resolve(.orphaned, previous: true), false)
    }

    /// The two non-verdicts must not reset anything. This is the bug that made a revoked client
    /// report itself authorized again after every relaunch: the flag was recomputed from scratch
    /// instead of being folded into what was already known.
    func test_resolveKeepsPriorStateWhenThereIsNoEvidence() {
        XCTAssertEqual(OrphanDetector.resolve(.noSignal, previous: false), false)
        XCTAssertEqual(OrphanDetector.resolve(.deferred, previous: false), false)
        XCTAssertEqual(OrphanDetector.resolve(.noSignal, previous: true), true)
        XCTAssertNil(OrphanDetector.resolve(.deferred, previous: nil))
    }
}
