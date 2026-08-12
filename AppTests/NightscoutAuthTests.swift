import XCTest
@testable import AAPSClientiOS

final class NightscoutAuthTests: XCTestCase {

    func test_authorizeRequestsJWT() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"test.jwt.token","iat":1525383610,"exp":4102444800}"# .data(using: .utf8)!

        let client = NightscoutClientLive(
            baseURL: testBaseURL, accessToken: "my-access-token", transport: transport
        )

        try await client.authorize()

        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/v2/authorization/request/my-access-token")
        XCTAssertEqual(transport.lastRequest?.httpMethod, "GET")
    }

    func test_authenticatedRequestCarriesBearer() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"test.jwt","iat":1525383610,"exp":4102444800}"# .data(using: .utf8)!

        let client = NightscoutClientLive(
            baseURL: testBaseURL, accessToken: "tok", transport: transport
        )
        try await client.authorize()

        transport.responseData = #"{"status":200,"result":[]}"# .data(using: .utf8)!
        _ = try await client.fetchEntries(limit: 10)

        let authHeader = transport.lastRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(authHeader, "Bearer test.jwt")
    }

    func test_unauthorizedTriggersRefresh() async throws {
        let transport = MockAuthTransport()

        transport.responseData = #"{"token":"first.jwt","iat":1,"exp":4102444800}"# .data(using: .utf8)!
        let client = NightscoutClientLive(
            baseURL: testBaseURL, accessToken: "tok", transport: transport
        )
        try await client.authorize()

        transport.responseData = Data()
        transport.responseCode = 401

        do {
            _ = try await client.fetchEntries(limit: 10)
            XCTFail("Expected unauthorized")
        } catch {
            guard case NsError.unauthorized = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func test_accessTokenIsPercentEncodedInTheAuthorizePath() async throws {
        let transport = MockAuthTransport()
        transport.responseData = #"{"token":"jwt","iat":1,"exp":4102444800}"# .data(using: .utf8)!

        // The token is the one secret that leaves the device as a PATH SEGMENT, so it must be
        // encoded rather than interpolated raw.
        let client = NightscoutClientLive(
            baseURL: testBaseURL, accessToken: "tok en#frag?q", transport: transport
        )
        try await client.authorize()

        let absolute = transport.lastRequest?.url?.absoluteString ?? ""
        XCTAssertTrue(absolute.hasSuffix("/api/v2/authorization/request/tok%20en%23frag%3Fq"), absolute)
        XCTAssertNil(transport.lastRequest?.url?.query)
        XCTAssertNil(transport.lastRequest?.url?.fragment)
    }

    /// A short-lived JWT must be renewed BEFORE it lapses; otherwise every poll burns a 401 + retry.
    func test_expiringJwtIsRenewedBeforeTheAuthenticatedCall() async throws {
        let transport = MockAuthTransport()
        let almostExpired = Int64(Date().addingTimeInterval(30).timeIntervalSince1970)
        transport.responseData = #"{"token":"first.jwt","iat":1,"exp":\#(almostExpired)}"# .data(using: .utf8)!
        let client = NightscoutClientLive(baseURL: testBaseURL, accessToken: "tok", transport: transport)
        try await client.authorize()

        // Within the 60 s renewal margin, so the next authenticated call re-authorizes first and
        // must carry the SECOND token, not the first.
        transport.responseData = #"{"token":"second.jwt","iat":1,"exp":4102444800}"# .data(using: .utf8)!
        _ = try? await client.fetchEntries(limit: 1)

        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer second.jwt")
    }

    func test_401onRefreshThrowsUnauthorized() async {
        let transport = MockAuthTransport()
        transport.responseCode = 401
        transport.responseData = Data()

        let client = NightscoutClientLive(
            baseURL: testBaseURL, accessToken: "bad-token", transport: transport
        )

        do {
            try await client.authorize()
            XCTFail("Expected unauthorized")
        } catch {
            guard case NsError.unauthorized = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }
}
