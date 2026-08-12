import Foundation
import Security
import XCTest
@testable import AAPSClientiOS

final class KeychainStoreTests: XCTestCase {

    func test_storesAndReadsSecret() throws {
        let s = KeychainStore(service: "test.aapsclient")
        try s.set("abc", for: .nsAccessToken)
        XCTAssertEqual(try s.get(.nsAccessToken), "abc")
    }

    func test_updatesExistingSecret() throws {
        let s = KeychainStore(service: "test.aapsclient")
        try s.set("first", for: .nsAccessToken)
        try s.set("second", for: .nsAccessToken)
        XCTAssertEqual(try s.get(.nsAccessToken), "second")
    }

    func test_deleteRemovesSecret() throws {
        let s = KeychainStore(service: "test.aapsclient")
        try s.set("xyz", for: .nsAccessToken)
        try s.delete(.nsAccessToken)
        XCTAssertNil(try s.get(.nsAccessToken))
    }

    func test_returnsNilForMissing() throws {
        let s = KeychainStore(service: "test.aapsclient.missing")
        XCTAssertNil(try s.get(.nsAccessToken))
    }

    /// Credentials must stay readable while the screen is locked — that is exactly when the audio
    /// keep-alive's background refresh needs them. The system default (WhenUnlocked) would make
    /// every background poll fail silently until the user next unlocks and opens the app.
    func test_defaultAccessibilityIsAfterFirstUnlock() throws {
        let s = KeychainStore(service: "test.aapsclient.accessibility.\(UUID().uuidString)")
        try s.set("abc", for: .nsAccessToken)
        defer { try? s.delete(.nsAccessToken) }

        let cls = try XCTUnwrap(s.accessibility(for: .nsAccessToken))
        XCTAssertEqual(cls, kSecAttrAccessibleAfterFirstUnlock as String)
    }

    /// An existing item written by an earlier build with a weaker class is upgraded in place on the
    /// next write, so installs self-heal without the user re-entering anything.
    func test_updateRewritesAccessibility() throws {
        let service = "test.aapsclient.accessibility.\(UUID().uuidString)"
        let weak = KeychainStore(service: service, accessibility: kSecAttrAccessibleWhenUnlocked)
        try weak.set("abc", for: .nsAccessToken)
        defer { try? weak.delete(.nsAccessToken) }
        XCTAssertEqual(try weak.accessibility(for: .nsAccessToken), kSecAttrAccessibleWhenUnlocked as String)

        let upgraded = KeychainStore(service: service)
        try upgraded.set("abc2", for: .nsAccessToken)
        XCTAssertEqual(try upgraded.accessibility(for: .nsAccessToken), kSecAttrAccessibleAfterFirstUnlock as String)
    }

    /// The pairing secret is `ThisDeviceOnly` so it can never ride an encrypted backup onto a second
    /// device: two devices signing as the same clientId with independent counters lock each other
    /// out of the master's strictly-greater replay gate.
    func test_pairingItemIsThisDeviceOnly() throws {
        let service = "test.aapsclient.pairing.\(UUID().uuidString)"
        let s = KeychainStore(service: service, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        try s.set("{}", for: .clientControlPairing)
        defer { try? s.delete(.clientControlPairing) }

        XCTAssertEqual(
            try s.accessibility(for: .clientControlPairing),
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }
}
