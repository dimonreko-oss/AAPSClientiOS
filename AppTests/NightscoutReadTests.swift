import XCTest
@testable import AAPSClientiOS

final class NightscoutReadTests: XCTestCase {

    func test_fetchEntriesReturnsParsedData() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"# .data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        let fixture = try loadFixture("entries")
        transport.responseData = fixture
        let entries = try await client.fetchEntries(limit: 10)

        XCTAssertEqual(transport.lastRequest?.url?.absoluteString.contains("api/v3/entries"), true)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].mgdl, 120)
        XCTAssertEqual(entries[0].trend, .flat)
    }

    func test_fetchTreatmentsReturnsParsedData() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"# .data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        let fixture = try loadFixture("treatments")
        transport.responseData = fixture
        let treatments = try await client.fetchTreatments()

        XCTAssertEqual(treatments.count, 4)
        XCTAssertEqual(treatments[0].eventType, "Meal Bolus")
    }

    func test_fetchTreatmentsWithSinceAddsSrvModifiedFilter() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"# .data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        transport.responseData = #"{"status":200,"result":[]}"# .data(using: .utf8)!
        let since = Date(timeIntervalSince1970: 1000)
        _ = try await client.fetchTreatments(since: since)

        let url = transport.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("srvModified$gte="))
    }

    func test_fetchDeviceStatusReturnsLoopStatus() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"# .data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        let fixture = try loadFixture("devicestatus")
        transport.responseData = fixture
        let status = try await client.fetchDeviceStatus()

        XCTAssertEqual(status?.iob, 1.85)
        XCTAssertEqual(status?.cob, 24.0)
    }

    func test_fetchProfileReturnsParsedProfile() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"# .data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        let fixture = try loadFixture("profile")
        transport.responseData = fixture
        let profile = try await client.fetchProfile()

        XCTAssertEqual(profile.units, .mgdl)
        XCTAssertEqual(profile.basal.count, 3)
    }

    func test_urlHasNoDoubleSlash() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"# .data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        transport.responseData = #"{"status":200,"result":[]}"# .data(using: .utf8)!
        _ = try await client.fetchEntries(limit: 10)

        let url = transport.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("test.nightscout.example.com/api/v3/entries"))
        XCTAssertFalse(url.contains("//api"))
    }

    func test_serverErrorThrowsServerCase() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"# .data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        transport.responseCode = 500
        transport.responseData = Data()

        do {
            _ = try await client.fetchEntries(limit: 10)
            XCTFail("Expected error")
        } catch {
        }
    }

    func test_fetchDeviceStatusHistoryURL() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"#.data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        transport.responseData = try loadFixture("devicestatus_history")
        let since = Date(timeIntervalSince1970: 1_718_571_600)
        let entries = try await client.fetchDeviceStatusHistory(since: since)

        let url = transport.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("api/v3/devicestatus"))
        XCTAssertTrue(url.contains("sort$desc=date"))
        XCTAssertTrue(url.contains("limit=288"))
        XCTAssertTrue(url.contains("date$gt=1718571600000"))
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries[0].iob, 1.20, accuracy: 0.001)
    }

    func test_fetchRunningConfigColdUsesAapsSettingsEndpoint() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"#.data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        transport.responseData = try loadFixture("settings_aaps")
        let cold = try await client.fetchRunningConfigCold()

        let url = transport.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("api/v3/settings/aaps"))
        XCTAssertEqual(cold?.pump, "Dana-i")
        XCTAssertTrue(cold?.remoteCapabilities.canRemoteProfileSwitch == true)
    }

    func test_fetchTreatmentsHistoryURL() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"#.data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        transport.responseData = try loadFixture("treatments")
        let since = Date(timeIntervalSince1970: 1_718_571_600)
        let treatments = try await client.fetchTreatmentsHistory(since: since)

        let url = transport.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("api/v3/treatments"))
        XCTAssertTrue(url.contains("sort$desc=date"))
        XCTAssertTrue(url.contains("date$gt=1718571600000"))
        XCTAssertEqual(treatments.count, 4)
    }

    func test_fetchRunningConfigHotUsesStateSettingsEndpoint() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"#.data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        transport.responseData = try loadFixture("settings_aaps_state")
        let hot = try await client.fetchRunningConfigHot()

        let url = transport.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("api/v3/settings/aaps-state"))
        XCTAssertEqual(hot?.activeScene?.sceneId, "school-sport")
        XCTAssertEqual(hot?.usedAutosensOnMainPhone, true)
    }

    func test_putSettingsUsesCorrectEndpointAndMethod() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"#.data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        transport.responseData = #"{"status":200}"#.data(using: .utf8)!
        try await client.putSettings(identifier: "aaps_clientcontrol_hello_abc", document: ["schemaVersion": 1])

        XCTAssertEqual(transport.lastRequest?.httpMethod, "PUT")
        XCTAssertTrue(transport.lastRequest?.url?.absoluteString.contains("api/v3/settings/aaps_clientcontrol_hello_abc") == true)
    }

    /// NS APIv3 answers 404 for a settings identifier that was never written — the normal state of
    /// the per-client ack slot right after pairing. Throwing here aborted the very first ack poll on
    /// iteration 1 against a perfectly healthy master.
    func test_fetchSettingsReturnsNilOn404() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"#.data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        transport.responseCode = 404
        transport.responseData = #"{"status":404,"message":"Not found"}"#.data(using: .utf8)!

        let document = try await client.fetchSettings(identifier: "aaps_clientcontrol_ack_c1")
        XCTAssertNil(document)
    }

    func test_fetchSettingsStillThrowsOnServerError() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"#.data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        transport.responseCode = 500
        transport.responseData = Data()

        do {
            _ = try await client.fetchSettings(identifier: "aaps")
            XCTFail("expected a 500 to propagate")
        } catch let error as NsHttpStatusError {
            XCTAssertEqual(error.code, 500)
        }
    }

    func test_deleteSettingsIssuesDeleteAndSwallows404() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"#.data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        transport.responseCode = 404
        transport.responseData = Data()
        try await client.deleteSettings(identifier: "aaps_clientcontrol_cmd_ping_c1")

        XCTAssertEqual(transport.lastRequest?.httpMethod, "DELETE")
        // `?permanent=true` is the whole point of this method. A plain DELETE only TOMBSTONES the
        // identifier on NS, and `ClientControlPublisher.putRecoveringPoisonedDate` re-PUTs the same
        // slot immediately afterwards — against a tombstone that answers HTTP 410 forever. The
        // master added `deleteSettingsPermanent` for exactly this, so pin the query string, not just
        // the path: dropping it converts a recoverable wedge into a permanently dead command slot.
        XCTAssertEqual(
            transport.lastRequest?.url?.absoluteString,
            "https://test.nightscout.example.com/api/v3/settings/aaps_clientcontrol_cmd_ping_c1?permanent=true"
        )
    }

    /// NS answers 410 for an identifier that is already a tombstone. The caller's intent — "this
    /// identifier must not exist" — is satisfied, so the delete must not throw.
    func test_deleteSettingsSwallows410() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"#.data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        transport.responseCode = 410
        transport.responseData = Data()

        try await client.deleteSettings(identifier: "aaps_clientcontrol_cmd_ping_c1")
    }

    /// The signature the doc-date recovery path in `ClientControlPublisher` keys off.
    func test_immutableDateRejectionIsRecognisable() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"#.data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        transport.responseCode = 400
        transport.responseData = #"{"status":400,"message":"Field date cannot be modified by the client"}"#.data(using: .utf8)!

        do {
            try await client.putSettings(identifier: "aaps_clientcontrol_cmd_ping_c1", document: ["date": 1])
            XCTFail("expected the 400 to propagate")
        } catch let error as NsHttpStatusError {
            XCTAssertEqual(error.code, 400)
            XCTAssertTrue(error.isImmutableDateRejection)
        }
    }

    func test_searchSettingsReturnsAllMatchingIdentifiers() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"#.data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "t", transport: transport)
        try await client.authorize()

        transport.responseData = #"""
        {"status":200,"result":[
            {"identifier":"aaps_clientcontrol_offer_c1","runningConfig":{},"date":1,"utcOffset":0,"app":"AAPS","schemaVersion":1},
            {"identifier":"aaps-state","runningConfig":{},"date":1,"utcOffset":0,"app":"AAPS","schemaVersion":1}
        ]}
        """#.data(using: .utf8)!
        let docs = try await client.searchSettings(limit: 500)

        XCTAssertEqual(transport.lastRequest?.url?.absoluteString.contains("api/v3/settings?"), true)
        XCTAssertEqual(docs.count, 2)
        XCTAssertEqual(docs.first?.identifier, "aaps_clientcontrol_offer_c1")
    }
}
