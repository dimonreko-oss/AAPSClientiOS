import XCTest
@testable import AAPSClientiOS

final class PairingOfferFetcherTests: XCTestCase {
    func test_findsMatchingOfferWithCorrectPin() throws {
        let offer = try makeOffer(pin: "12345678")
        let result = PairingOfferFetcher.match(offers: [offer], pin: "12345678", now: Date())
        guard case .success(let matched) = result else { return XCTFail("expected success") }
        XCTAssertEqual(matched.clientId, "c1")
    }

    func test_wrongPinReturnsNoMatch() throws {
        let offer = try makeOffer(pin: "12345678")
        let result = PairingOfferFetcher.match(offers: [offer], pin: "00000000", now: Date())
        guard case .noMatch = result else { return XCTFail("expected noMatch") }
    }

    func test_expiredOfferIsSkipped() throws {
        let offer = PairingOffer(schemaVersion: 1, clientId: "c1", expiresAt: 1, kdfSaltB64: "", ivB64: "", wrappedB64: "")
        let result = PairingOfferFetcher.match(offers: [offer], pin: "12345678", now: Date(timeIntervalSince1970: 1000))
        guard case .noMatch = result else { return XCTFail("expected noMatch for expired offer") }
    }

    /// The outer `expiresAt` is unauthenticated — anyone with a writable NS token can extend it.
    /// The wrapped payload's own copy is the one that matters, and it must be enforced too.
    func test_liveOfferWrappingAnExpiredPayloadIsSkipped() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let offer = try makeOffer(pin: "12345678", payloadExpiresAt: nowMs - 1, offerExpiresAt: nowMs + 600_000)

        let result = PairingOfferFetcher.match(offers: [offer], pin: "12345678", now: now)
        guard case .noMatch = result else { return XCTFail("expected noMatch for expired payload") }
    }

    func test_twoOffersMatchingTheSamePinAreRefused() throws {
        let a = try makeOffer(pin: "12345678")
        let b = try makeOffer(pin: "12345678")
        let result = PairingOfferFetcher.match(offers: [a, b], pin: "12345678", now: Date())
        guard case .ambiguous = result else { return XCTFail("expected ambiguous") }
    }

    // MARK: - Confirm-time expiry

    /// `match` filters at scan time, but the master's pairing window is only 2 minutes and the user
    /// can sit on the confirm screen for longer — past that the Pending roster entry is pruned and
    /// the pairing can never be promoted, so the secret must not be committed.
    func test_isExpiredRechecksThePairingWindow() {
        let now = Date(timeIntervalSince1970: 2_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let live = PairingPayload(v: 1, masterInstallId: "m1", clientId: "c1", secretHex: "aabb", expiresAt: nowMs + 1_000)
        let dead = PairingPayload(v: 1, masterInstallId: "m1", clientId: "c1", secretHex: "aabb", expiresAt: nowMs - 1)
        let undated = PairingPayload(v: 1, masterInstallId: "m1", clientId: "c1", secretHex: "aabb", expiresAt: 0)

        XCTAssertFalse(PairingOfferFetcher.isExpired(live, now: now))
        XCTAssertTrue(PairingOfferFetcher.isExpired(dead, now: now))
        XCTAssertFalse(PairingOfferFetcher.isExpired(undated, now: now))
    }

    func test_remainingLifetimeIsClampedAndNilWithoutExpiry() {
        let now = Date(timeIntervalSince1970: 2_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let live = PairingPayload(v: 1, masterInstallId: "m1", clientId: "c1", secretHex: "aabb", expiresAt: nowMs + 90_000)
        let dead = PairingPayload(v: 1, masterInstallId: "m1", clientId: "c1", secretHex: "aabb", expiresAt: nowMs - 5_000)
        let undated = PairingPayload(v: 1, masterInstallId: "m1", clientId: "c1", secretHex: "aabb", expiresAt: 0)

        XCTAssertEqual(PairingOfferFetcher.remainingLifetime(live, now: now) ?? -1, 90, accuracy: 0.001)
        XCTAssertEqual(PairingOfferFetcher.remainingLifetime(dead, now: now) ?? -1, 0, accuracy: 0.001)
        XCTAssertNil(PairingOfferFetcher.remainingLifetime(undated, now: now))
    }

    private func makeOffer(pin: String, payloadExpiresAt: Int64 = 0, offerExpiresAt: Int64 = 0) throws -> PairingOffer {
        let salt = ClientControlPairingCrypto.newSalt()
        let iv = ClientControlPairingCrypto.newIV()
        let payload = PairingPayload(v: 1, masterInstallId: "m1", clientId: "c1", secretHex: "aabb", expiresAt: payloadExpiresAt)
        let payloadJson = try JSONEncoder().encode(payload)
        let wrapped = try ClientControlPairingCrypto.wrap(plaintext: payloadJson, pin: pin, salt: salt, iv: iv)
        return PairingOffer(
            schemaVersion: 1,
            clientId: "c1",
            expiresAt: offerExpiresAt,
            kdfSaltB64: salt.base64EncodedString(),
            ivB64: iv.base64EncodedString(),
            wrappedB64: wrapped.base64EncodedString()
        )
    }
}
