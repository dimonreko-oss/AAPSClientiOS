import XCTest
@testable import AAPSClientiOS

final class NsTreatmentWriterTests: XCTestCase {

    func test_carbsPayloadMatchesContract() async throws {
        let mock = FixtureNightscoutClient()
        let writer = NsTreatmentWriterLive(client: mock)
        let date = Date(timeIntervalSince1970: 1525383.610088)

        try await writer.sendCarbs(grams: 30, at: date)

        let p = mock.postedPayloads.first!
        XCTAssertEqual(p["eventType"] as? String, "Carb Correction")
        XCTAssertEqual(p["carbs"] as? Double, 30)
        XCTAssertEqual(p["enteredBy"] as? String, "AAPSClient-iOS")
        XCTAssertNotNil(p["date"])
    }

    func test_tempTargetPayloadMatchesContract() async throws {
        let mock = FixtureNightscoutClient()
        let writer = NsTreatmentWriterLive(client: mock)

        try await writer.sendTempTarget(targetMgdl: 90, durationMin: 60, reason: .eatingSoon)

        let p = mock.postedPayloads.first!
        XCTAssertEqual(p["eventType"] as? String, "Temporary Target")
        XCTAssertEqual(p["duration"] as? Int, 60)
        XCTAssertEqual(p["targetBottom"] as? Int, 90)
        XCTAssertEqual(p["targetTop"] as? Int, 90)
        XCTAssertEqual(p["units"] as? String, "mg/dl")
        XCTAssertEqual(p["reason"] as? String, "Eating Soon")
    }

    func test_cancelTempTargetHasZeroDuration() async throws {
        let mock = FixtureNightscoutClient()
        let writer = NsTreatmentWriterLive(client: mock)

        try await writer.cancelTempTarget()

        let p = mock.postedPayloads.first!
        XCTAssertEqual(p["eventType"] as? String, "Temporary Target")
        XCTAssertEqual(p["duration"] as? Int, 0)
    }

    func test_sendCarbsPropagatesNetworkError() async {
        let mock = FixtureNightscoutClient()
        mock.shouldThrow = NsError.noNetwork
        let writer = NsTreatmentWriterLive(client: mock)

        do {
            try await writer.sendCarbs(grams: 10, at: Date())
            XCTFail("Expected error")
        } catch {
            guard case NsError.noNetwork = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func test_siteChangePayload() {
        let now = Date()
        let p = NsTreatmentWriterLive.buildEvent(eventType: "Site Change", at: now, notes: "right arm", glucoseMgdl: nil, durationMin: nil)
        XCTAssertEqual(p["eventType"] as? String, "Site Change")
        XCTAssertEqual(p["notes"] as? String, "right arm")
        XCTAssertNotNil(p["date"])
        XCTAssertEqual(p["app"] as? String, "AAPSClient-iOS")
        XCTAssertNil(p["glucose"])
    }

    func test_bgCheckPayloadHasGlucose() {
        let now = Date()
        let p = NsTreatmentWriterLive.buildEvent(eventType: "BG Check", at: now, notes: nil, glucoseMgdl: 120, durationMin: nil)
        XCTAssertEqual(p["eventType"] as? String, "BG Check")
        XCTAssertEqual(p["glucose"] as? Int, 120)
        XCTAssertEqual(p["units"] as? String, "mg/dl")
    }

    func test_loopModePayload() {
        let p = NsTreatmentWriterLive.buildLoopMode("OPEN_LOOP", durationMin: 60)
        XCTAssertEqual(p["eventType"] as? String, "OpenAPS Offline")
        XCTAssertEqual(p["mode"] as? String, "OPEN_LOOP")
        XCTAssertEqual(p["duration"] as? Int, 60)
        XCTAssertEqual(p["app"] as? String, "AAPSClient-iOS")
    }

    func test_announcementPayloadMatchesIapsContract() async throws {
        let mock = FixtureNightscoutClient()
        let writer = NsTreatmentWriterLive(client: mock)

        try await writer.sendAnnouncement(notes: "looping:true")

        let p = mock.postedPayloads.first!
        XCTAssertEqual(p["eventType"] as? String, "Announcement")
        XCTAssertEqual(p["notes"] as? String, "looping:true")
        // iAPS's Announcement.action parser only fires for enteredBy == "remote" senders in
        // practice (matches iAPS's own Shortcuts, which hard-code this) — NOT this app's usual
        // "AAPSClient-iOS", which is why this is asserted explicitly rather than reusing appName.
        XCTAssertEqual(p["enteredBy"] as? String, "remote")
        XCTAssertEqual(p["app"] as? String, "AAPSClient-iOS")
        XCTAssertNotNil(p["date"])
    }

    func test_disconnectPumpPayload() {
        let p = NsTreatmentWriterLive.buildLoopMode("DISCONNECTED_PUMP", durationMin: 30)
        XCTAssertEqual(p["eventType"] as? String, "OpenAPS Offline")
        XCTAssertEqual(p["mode"] as? String, "DISCONNECTED_PUMP")
        XCTAssertEqual(p["duration"] as? Int, 30)
        XCTAssertEqual(p["app"] as? String, "AAPSClient-iOS")
    }

    func test_profileSwitchPayloadWithEditedProfileJson() async throws {
        let data = try loadFixture("profile")
        let store = try NsMapping.profileStore(from: data)
        let rawJson = try XCTUnwrap(store.rawJson["Default"])

        let modifiedJson = try ProfileEdit.apply([ProfileEdit.Edit("basal", 0, 0.8)], to: rawJson)

        let mock = FixtureNightscoutClient()
        let writer = NsTreatmentWriterLive(client: mock)

        try await writer.switchProfile(name: "Default", percentage: 100, durationMin: 0, profileJson: modifiedJson)

        let p = try XCTUnwrap(mock.postedPayloads.first)
        XCTAssertEqual(p["app"] as? String, "AAPSClient-iOS")
        XCTAssertEqual(p["eventType"] as? String, "Profile Switch")
        XCTAssertEqual(p["profile"] as? String, "Default")
        XCTAssertEqual(p["percentage"] as? Int, 100)
        XCTAssertEqual(p["duration"] as? Int, 0)
        XCTAssertNotNil(p["date"])

        let jsonStr = try XCTUnwrap(p["profileJson"] as? String)
        let reParsed = try JSONSerialization.jsonObject(with: XCTUnwrap(jsonStr.data(using: .utf8))) as? [String: Any]
        let basal = try XCTUnwrap(reParsed?["basal"] as? [[String: Any]])
        XCTAssertEqual(basal[0]["value"] as? Double, 0.8)
    }

    func test_profileSwitchPayloadWithDuration() async throws {
        let data = try loadFixture("profile")
        let store = try NsMapping.profileStore(from: data)
        let rawJson = try XCTUnwrap(store.rawJson["Default"])

        let mock = FixtureNightscoutClient()
        let writer = NsTreatmentWriterLive(client: mock)

        try await writer.switchProfile(name: "Default", percentage: 100, durationMin: 60, profileJson: rawJson)

        let p = try XCTUnwrap(mock.postedPayloads.first)
        XCTAssertEqual(p["duration"] as? Int, 60)
        XCTAssertEqual(p["percentage"] as? Int, 100)
        XCTAssertNotNil(p["profileJson"])
    }

    /// `PS.timeshift` is milliseconds all the way through the master's mapper
    /// (`RemoteTreatment.timeshift` → `NSProfileSwitch.timeShift` → `PS.timeshift // [milliseconds]`),
    /// so hours on the wire arrived as milliseconds, rounded to 0 h, and the shift vanished silently.
    func test_profileSwitchTimeshiftIsSentInMilliseconds() async throws {
        let mock = FixtureNightscoutClient()
        let writer = NsTreatmentWriterLive(client: mock)

        try await writer.switchProfile(name: "Default", percentage: 120, durationMin: 60, timeshiftHours: 3, profileJson: nil)

        let p = try XCTUnwrap(mock.postedPayloads.first)
        XCTAssertEqual(p["timeshift"] as? Int64, 10_800_000)
    }

    func test_profileSwitchNegativeTimeshiftIsSentInMilliseconds() {
        let p = NsTreatmentWriterLive.buildProfileSwitch(
            name: "Default", percentage: 100, durationMin: 0, timeshiftHours: -2, profileJson: nil
        )
        XCTAssertEqual(p["timeshift"] as? Int64, -7_200_000)
    }

    func test_profileSwitchDefaultTimeshiftIsZero() async throws {
        let mock = FixtureNightscoutClient()
        let writer = NsTreatmentWriterLive(client: mock)

        try await writer.switchProfile(name: "Default", percentage: 100, durationMin: 0, profileJson: nil)

        let p = try XCTUnwrap(mock.postedPayloads.first)
        XCTAssertEqual(p["timeshift"] as? Int64, 0)
    }

    /// Round-trip: what we write must come back out of `NsMapping` unchanged in meaning.
    func test_profileSwitchPayloadRoundTripsThroughNsMapping() throws {
        let payload = NsTreatmentWriterLive.buildProfileSwitch(
            name: "Weekday", percentage: 80, durationMin: 120, timeshiftHours: 2, profileJson: nil
        )
        var doc = payload
        doc["identifier"] = "ps-1"
        doc["originalProfileName"] = "Weekday"
        doc["profile"] = "Weekday (80%,2h)"

        let envelope: [String: Any] = ["status": 200, "result": [doc]]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let treatments = try NsMapping.treatments(from: data)

        XCTAssertEqual(treatments.count, 1)
        XCTAssertEqual(treatments[0].profileName, "Weekday")
        XCTAssertEqual(treatments[0].percentage, 80)
        XCTAssertEqual(treatments[0].durationMin, 120)
        XCTAssertTrue(treatments[0].isValid)
    }

    func test_profileSwitchPayload_afterAddingBasalBlock() async throws {
        let data = try loadFixture("profile")
        let store = try NsMapping.profileStore(from: data)
        let rawJson = try XCTUnwrap(store.rawJson["Default"])

        // Simulate: basal block added at 18:00 (64800s), value 0.55; existing blocks untouched.
        let newBlocks: [(startSeconds: Int, value: Double)] = [
            (0, 0.5), (21600, 0.7), (43200, 0.6), (64800, 0.55)
        ]
        let modifiedJson = try ProfileEdit.replaceSchedule("basal", blocks: newBlocks, in: rawJson)

        let mock = FixtureNightscoutClient()
        let writer = NsTreatmentWriterLive(client: mock)
        try await writer.switchProfile(name: "Default", percentage: 100, durationMin: 0, profileJson: modifiedJson)

        let p = try XCTUnwrap(mock.postedPayloads.first)
        let jsonStr = try XCTUnwrap(p["profileJson"] as? String)
        let reParsed = try JSONSerialization.jsonObject(with: XCTUnwrap(jsonStr.data(using: .utf8))) as? [String: Any]
        let basal = try XCTUnwrap(reParsed?["basal"] as? [[String: Any]])
        XCTAssertEqual(basal.count, 4)
        XCTAssertEqual(basal[3]["time"] as? String, "18:00")
        XCTAssertEqual(basal[3]["timeAsSeconds"] as? Int, 64800)
        XCTAssertEqual(basal[3]["value"] as? Double, 0.55)
        // Untouched schedule preserved.
        XCTAssertEqual((reParsed?["sens"] as? [[String: Any]])?.first?["value"] as? Double, 49)
    }
}
