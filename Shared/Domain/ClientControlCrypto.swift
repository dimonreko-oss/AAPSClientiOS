import Foundation
import CryptoKit
import CommonCrypto

enum ClientControlPairingCrypto {
    private static let kdfIterations: UInt32 = 200_000
    private static let keyBytes = 32
    private static let saltBytes = 16
    private static let ivBytes = 12
    private static let pinDigits = 8

    static func newPin() -> String {
        let n = UInt32.random(in: 0..<100_000_000)
        return String(format: "%0\(pinDigits)d", n)
    }

    static func newSalt() -> Data { randomBytes(saltBytes) }
    static func newIV() -> Data { randomBytes(ivBytes) }

    static func wrap(plaintext: Data, pin: String, salt: Data, iv: Data) throws -> Data {
        let key = deriveKey(pin: pin, salt: salt)
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        return sealed.ciphertext + sealed.tag
    }

    static func unwrap(ciphertext: Data, pin: String, salt: Data, iv: Data) -> Data? {
        guard ciphertext.count > 16 else { return nil }
        let key = deriveKey(pin: pin, salt: salt)
        let body = ciphertext.prefix(ciphertext.count - 16)
        let tag = ciphertext.suffix(16)
        guard let nonce = try? AES.GCM.Nonce(data: iv),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: body, tag: tag) else {
            return nil
        }
        return try? AES.GCM.open(box, using: key)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func deriveKey(pin: String, salt: Data) -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: keyBytes)
        pin.withCString { pinPtr in
            salt.withUnsafeBytes { saltPtr in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pinPtr,
                    strlen(pinPtr),
                    saltPtr.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    kdfIterations,
                    &derived,
                    keyBytes
                )
            }
        }
        return SymmetricKey(data: derived)
    }
}

enum ClientControlCrypto {
    static func newSecretBytes() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    static func newClientId() -> String { UUID().uuidString }

    static func bytesToHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func hexToBytes(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    static func sign(secret: Data, canonical: String) -> String {
        let key = SymmetricKey(data: secret)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)
        return bytesToHex(Data(mac))
    }

    /// HMAC length in bytes for SHA-256 — a signature of any other length is rejected outright.
    private static let macByteCount = 32

    /// Constant-time, matching the master's `MessageDigest.isEqual`. Comparing the hex with `==`
    /// short-circuits on the first differing scalar, and this same helper verifies documents an
    /// attacker can write if Nightscout is ever compromised (the ack slot, and the progress mirror
    /// when it lands), so the timing side-channel is worth closing even at a 1 Hz poll.
    static func verify(secret: Data, canonical: String, signature: String) -> Bool {
        guard let mac = hexToBytes(signature), mac.count == macByteCount else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            mac,
            authenticating: Data(canonical.utf8),
            using: SymmetricKey(data: secret)
        )
    }

    static func timestampWithinSkew(_ timestamp: Date, now: Date, skewSeconds: TimeInterval = ClientControlTiming.maxSkewSeconds) -> Bool {
        abs(now.timeIntervalSince(timestamp)) <= skewSeconds
    }
}
