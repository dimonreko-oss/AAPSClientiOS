import XCTest
@testable import AAPSClientiOS

final class ClientControlCryptoTests: XCTestCase {
    func test_wrapThenUnwrapRoundTrips() throws {
        let plaintext = Data("hello world".utf8)
        let salt = ClientControlPairingCrypto.newSalt()
        let iv = ClientControlPairingCrypto.newIV()
        let wrapped = try ClientControlPairingCrypto.wrap(plaintext: plaintext, pin: "12345678", salt: salt, iv: iv)
        let unwrapped = ClientControlPairingCrypto.unwrap(ciphertext: wrapped, pin: "12345678", salt: salt, iv: iv)
        XCTAssertEqual(unwrapped, plaintext)
    }

    func test_unwrapReturnsNilOnWrongPin() throws {
        let plaintext = Data("hello world".utf8)
        let salt = ClientControlPairingCrypto.newSalt()
        let iv = ClientControlPairingCrypto.newIV()
        let wrapped = try ClientControlPairingCrypto.wrap(plaintext: plaintext, pin: "12345678", salt: salt, iv: iv)
        let unwrapped = ClientControlPairingCrypto.unwrap(ciphertext: wrapped, pin: "00000000", salt: salt, iv: iv)
        XCTAssertNil(unwrapped)
    }

    func test_newPinIsEightDigits() {
        let pin = ClientControlPairingCrypto.newPin()
        XCTAssertEqual(pin.count, 8)
        XCTAssertNotNil(Int(pin))
    }

    func test_signIsDeterministicAndVerifiable() {
        let secret = ClientControlCrypto.newSecretBytes()
        let sig1 = ClientControlCrypto.sign(secret: secret, canonical: "a|b|c")
        let sig2 = ClientControlCrypto.sign(secret: secret, canonical: "a|b|c")
        XCTAssertEqual(sig1, sig2)
        XCTAssertEqual(sig1.count, 64)
    }

    func test_signDiffersForDifferentSecrets() {
        let sigA = ClientControlCrypto.sign(secret: ClientControlCrypto.newSecretBytes(), canonical: "same")
        let sigB = ClientControlCrypto.sign(secret: ClientControlCrypto.newSecretBytes(), canonical: "same")
        XCTAssertNotEqual(sigA, sigB)
    }

    func test_verifyAcceptsOwnSignature() {
        let secret = ClientControlCrypto.newSecretBytes()
        let signature = ClientControlCrypto.sign(secret: secret, canonical: "c1|1|Done|Ok|||1000")
        XCTAssertTrue(ClientControlCrypto.verify(secret: secret, canonical: "c1|1|Done|Ok|||1000", signature: signature))
    }

    func test_verifyRejectsOneCharacterOffSignature() {
        let secret = ClientControlCrypto.newSecretBytes()
        let signature = ClientControlCrypto.sign(secret: secret, canonical: "a|b|c")
        // Flip the last hex digit — still 64 valid hex characters, so it survives decoding and has
        // to be rejected by the constant-time MAC comparison itself.
        let flipped = String(signature.dropLast()) + (signature.hasSuffix("0") ? "1" : "0")
        XCTAssertNotEqual(flipped, signature)
        XCTAssertEqual(flipped.count, 64)
        XCTAssertFalse(ClientControlCrypto.verify(secret: secret, canonical: "a|b|c", signature: flipped))
    }

    func test_verifyRejectsMalformedSignatures() {
        let secret = ClientControlCrypto.newSecretBytes()
        XCTAssertFalse(ClientControlCrypto.verify(secret: secret, canonical: "a", signature: ""))
        XCTAssertFalse(ClientControlCrypto.verify(secret: secret, canonical: "a", signature: "not-hex"))
        XCTAssertFalse(ClientControlCrypto.verify(secret: secret, canonical: "a", signature: "abcd"))
    }

    func test_verifyIsCaseInsensitiveOnHexInput() {
        let secret = ClientControlCrypto.newSecretBytes()
        let signature = ClientControlCrypto.sign(secret: secret, canonical: "x")
        XCTAssertTrue(ClientControlCrypto.verify(secret: secret, canonical: "x", signature: signature.uppercased()))
    }

    func test_hexRoundTrips() {
        let bytes = ClientControlCrypto.newSecretBytes()
        let hex = ClientControlCrypto.bytesToHex(bytes)
        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(ClientControlCrypto.hexToBytes(hex), bytes)
    }
}
