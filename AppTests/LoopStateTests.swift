import XCTest
@testable import AAPSClientiOS

final class LoopStateTests: XCTestCase {

    func test_loopingUnder7min() {
        let now = Date()
        let t = now.addingTimeInterval(-6.9 * 60)
        XCTAssertEqual(LoopStateCalc.from(statusTimestamp: t, now: now), .looping)
    }

    func test_warning7to14min() {
        let now = Date()
        let t = now.addingTimeInterval(-10 * 60)
        XCTAssertEqual(LoopStateCalc.from(statusTimestamp: t, now: now), .warning)
    }

    func test_stale15minPlus() {
        let now = Date()
        let t = now.addingTimeInterval(-16 * 60)
        XCTAssertEqual(LoopStateCalc.from(statusTimestamp: t, now: now), .stale)
    }

    func test_boundary7min() {
        let now = Date()
        let t = now.addingTimeInterval(-7 * 60)
        XCTAssertEqual(LoopStateCalc.from(statusTimestamp: t, now: now), .warning)
    }

    func test_boundary15min() {
        let now = Date()
        let t = now.addingTimeInterval(-15 * 60)
        XCTAssertEqual(LoopStateCalc.from(statusTimestamp: t, now: now), .stale)
    }

    func test_nilTimestamp() {
        XCTAssertEqual(LoopStateCalc.from(statusTimestamp: nil, now: Date()), .unknown)
    }
}

// MARK: - RunningMode

final class RunningModeTests: XCTestCase {

    /// The instant the `treatments_runningmode` fixture is designed around: 1 h after the permanent
    /// CLOSED_LOOP row, 30 min into the 1 h DISCONNECTED_PUMP row.
    private let now = Date(timeIntervalSince1970: 1_760_003_600)

    private func fixtureRecords() throws -> [RunningModeRecord] {
        let treatments = try NsMapping.treatments(from: try loadFixture("treatments_runningmode"))
        return RunningModeParser.records(from: treatments)
    }

    func test_wireNamesMapToEveryMode() {
        XCTAssertEqual(RunningMode.from(wire: "OPEN_LOOP"), .openLoop)
        XCTAssertEqual(RunningMode.from(wire: "CLOSED_LOOP"), .closedLoop)
        XCTAssertEqual(RunningMode.from(wire: "CLOSED_LOOP_LGS"), .closedLoopLgs)
        XCTAssertEqual(RunningMode.from(wire: "DISABLED_LOOP"), .disabledLoop)
        XCTAssertEqual(RunningMode.from(wire: "SUPER_BOLUS"), .superBolus)
        XCTAssertEqual(RunningMode.from(wire: "DISCONNECTED_PUMP"), .disconnectedPump)
        XCTAssertEqual(RunningMode.from(wire: "SUSPENDED_BY_PUMP"), .suspendedByPump)
        XCTAssertEqual(RunningMode.from(wire: "SUSPENDED_BY_USER"), .suspendedByUser)
        XCTAssertEqual(RunningMode.from(wire: "SUSPENDED_BY_DST"), .suspendedByDst)
        XCTAssertEqual(RunningMode.from(wire: "RESUME"), .resume)
        XCTAssertEqual(RunningMode.from(wire: "SOMETHING_NEW"), .unknown)
        XCTAssertEqual(RunningMode.from(wire: nil), .unknown)
    }

    /// Every mode must have a human name — the shipped mapper covered 4 of 10 and rendered the rest
    /// as raw SCREAMING_SNAKE in history.
    func test_everyModeHasANonWireDisplayName() {
        for mode in RunningMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, "\(mode) has no display name")
            XCTAssertFalse(mode.displayName.contains("_"), "\(mode) renders as its wire name")
        }
    }

    func test_predicatesMatchTheMasterMatrix() {
        XCTAssertTrue(RunningMode.closedLoop.isLoopRunning)
        XCTAssertTrue(RunningMode.closedLoopLgs.isClosedLoopOrLgs)
        XCTAssertFalse(RunningMode.openLoop.isClosedLoopOrLgs)
        XCTAssertFalse(RunningMode.disabledLoop.isLoopRunning)
        XCTAssertFalse(RunningMode.disabledLoop.pausesLoopExecution)
        XCTAssertTrue(RunningMode.superBolus.pausesLoopExecution)
        XCTAssertFalse(RunningMode.superBolus.isPumpSuspended)
        XCTAssertTrue(RunningMode.disconnectedPump.isPumpSuspended)
        XCTAssertTrue(RunningMode.suspendedByPump.isPumpSuspended)
        XCTAssertFalse(RunningMode.suspendedByUser.isPumpSuspended)
        XCTAssertTrue(RunningMode.suspendedByDst.mustBeTemporary)
        XCTAssertFalse(RunningMode.disabledLoop.mustBeTemporary)
    }

    func test_effectiveDurationResolvesOriginalDurationFirst() throws {
        let records = try fixtureRecords()
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })

        // Working mode: wire duration 0, real span in originalDuration.
        XCTAssertEqual(try XCTUnwrap(byID["rm-open-2h"]).durationMs, 7_200_000)
        XCTAssertFalse(try XCTUnwrap(byID["rm-open-2h"]).isPermanent)
        // Permanent DISABLED_LOOP: a decade on the wire, 0 in originalDuration.
        XCTAssertEqual(try XCTUnwrap(byID["rm-disabled-old"]).durationMs, 0)
        XCTAssertTrue(try XCTUnwrap(byID["rm-disabled-old"]).isPermanent)
        XCTAssertTrue(try XCTUnwrap(byID["rm-disabled-old"]).autoForced)
    }

    /// Mirrors `AppRepository.getRunningModeActiveAt`: the newest temporary row still covering the
    /// instant beats an older permanent row.
    func test_currentPrefersNewerTemporaryOverOlderPermanent() throws {
        let record = try XCTUnwrap(RunningModeCalc.current(in: try fixtureRecords(), at: now))
        XCTAssertEqual(record.id, "rm-disconnect")
        XCTAssertEqual(record.mode, .disconnectedPump)
        XCTAssertFalse(record.mode.isLoopRunning)
    }

    func test_currentFallsBackToPermanentOnceTemporaryExpires() throws {
        let after = Date(timeIntervalSince1970: 1_760_006_000)
        let record = try XCTUnwrap(RunningModeCalc.current(in: try fixtureRecords(), at: after))
        XCTAssertEqual(record.id, "rm-closed-permanent")
        XCTAssertEqual(record.mode, .closedLoop)
    }

    /// The master's queries all carry `AND (isValid = 1)`. The fixture's newest temporary row is
    /// invalid and must not win.
    func test_invalidRowsAreIgnored() throws {
        let record = try XCTUnwrap(RunningModeCalc.current(in: try fixtureRecords(), at: now))
        XCTAssertNotEqual(record.mode, .suspendedByDst)
    }

    func test_permanentRowWinsWhenItIsTheNewer() throws {
        let records = [
            RunningModeRecord(
                id: "temp", mode: .disconnectedPump, date: Date(timeIntervalSince1970: 1_000),
                durationMs: 3_600_000, autoForced: false, reasons: nil, isValid: true
            ),
            RunningModeRecord(
                id: "perm", mode: .closedLoop, date: Date(timeIntervalSince1970: 2_000),
                durationMs: 0, autoForced: false, reasons: nil, isValid: true
            ),
        ]
        let record = try XCTUnwrap(RunningModeCalc.current(in: records, at: Date(timeIntervalSince1970: 3_000)))
        XCTAssertEqual(record.id, "perm")
    }

    /// "We have no rows" must stay distinguishable from "the loop is disabled" for the UI, while the
    /// convenience accessor still mirrors the master's `RM.DEFAULT_MODE`.
    func test_emptyWindowIsUnknownButDefaultsToDisabledLoop() {
        XCTAssertNil(RunningModeCalc.current(in: [], at: now))
        XCTAssertEqual(RunningModeCalc.mode(in: [], at: now), .disabledLoop)
    }

    func test_parserIgnoresNonRunningModeTreatments() throws {
        let treatments = try NsMapping.treatments(from: try loadFixture("treatments"))
        XCTAssertTrue(RunningModeParser.records(from: treatments).isEmpty)
    }

    // MARK: - LoopHealth

    /// The headline bug: a suspended master that keeps uploading devicestatus must never read green.
    func test_freshLoopWithSuspendedModeIsNotHealthy() throws {
        let health = LoopHealth.resolve(
            statusTimestamp: now.addingTimeInterval(-60),
            runningModeRecords: try fixtureRecords(),
            now: now
        )
        XCTAssertEqual(health.freshness, .looping)
        XCTAssertEqual(health.mode, .disconnectedPump)
        XCTAssertFalse(health.isHealthy)
    }

    func test_freshLoopWithRunningModeIsHealthy() throws {
        let after = Date(timeIntervalSince1970: 1_760_006_000)
        let health = LoopHealth.resolve(
            statusTimestamp: after.addingTimeInterval(-60),
            runningModeRecords: try fixtureRecords(),
            now: after
        )
        XCTAssertEqual(health.mode, .closedLoop)
        XCTAssertTrue(health.isHealthy)
    }

    func test_missingTimestampIsNeverHealthy() {
        let health = LoopHealth.resolve(statusTimestamp: nil, runningModeRecords: [], now: now)
        XCTAssertEqual(health.freshness, .unknown)
        XCTAssertNil(health.mode)
        XCTAssertFalse(health.isHealthy)
    }
}
