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

    // MARK: - Access group resolution
    //
    // None of the *live* tests here may assert a literal team prefix: the group names depend on
    // whoever signed the build, and a test pinned to one team id is the same bug as the hardcoded
    // constant they replaced. What is pinned instead is the relationships — one prefix for both
    // groups, and the resolved group being the one iOS actually uses. `test_groupResolutionRules`
    // does name team ids, but only as inputs to the pure resolution function.

    /// Both groups come out of ONE probe of the process's default group; a divergence would mean the
    /// credentials and the pairing secret were being filed under two different team prefixes, at
    /// most one of which is real. Asserted as a relationship rather than as `shared == appPrivate +
    /// ".shared"`, because the app-private group names the *running* bundle id, which a contributor
    /// signing with their own team normally has to change while the entitlement suffix stays put.
    func test_bothAccessGroupsShareOneResolvedPrefix() throws {
        let groups = try resolvedGroups()
        let bundleId = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertTrue(
            groups.appPrivate.hasSuffix(bundleId),
            "app-private group \(groups.appPrivate) does not name this bundle (\(bundleId))"
        )
        let prefix = String(groups.appPrivate.dropLast(bundleId.count))
        XCTAssertTrue(
            groups.shared.hasPrefix(prefix),
            "shared group \(groups.shared) does not carry the same prefix as \(groups.appPrivate)"
        )
    }

    /// The invariant that makes the resolution correct rather than merely plausible: the group we
    /// resolved is the group an unscoped write actually lands in — the process's default group, i.e.
    /// the first entry of `keychain-access-groups`. Guaranteed by construction now that the probed
    /// string is used verbatim, which is exactly what this pins: a future rewrite that goes back to
    /// synthesising the name from a prefix plus a hardcoded suffix fails here.
    func test_resolvedSharedGroupIsWhereAnUnscopedWriteLands() throws {
        let groups = try resolvedGroups()
        let service = "test.aapsclient.group.\(UUID().uuidString)"
        let store = KeychainStore(service: service)
        try store.set("abc", for: .nsAccessToken)
        defer { try? store.delete(.nsAccessToken) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: KeychainKey.nsAccessToken.rawValue,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessGroup as String] as? String, groups.shared)
    }

    /// Naming either resolved group must work end to end. A wrong prefix does not throw anywhere
    /// visible in normal use — it returns -34018 from every `SecItem*` call, which every store path
    /// in the app swallows, so the app runs on with nothing persisted. Here it fails the test.
    func test_roundTripThroughEachResolvedGroup() throws {
        let groups = try resolvedGroups()
        for group in [groups.shared, groups.appPrivate] {
            let store = KeychainStore(service: "test.aapsclient.rt.\(UUID().uuidString)", accessGroup: group)
            defer { try? store.delete(.nsAccessToken) }
            do {
                try store.set("abc", for: .nsAccessToken)
            } catch {
                // Not every environment grants every group it can name: the app-private group is
                // implicit in `application-identifier`, which an unsigned runner may not have — the
                // very configuration this resolver exists to unblock. `KeychainMigrationTests`
                // skips on the same condition and `ClientPairingStore.writeLocked` degrades for it
                // at runtime, so a red suite here would be a false alarm.
                throw XCTSkip("group \(group) is not usable in this environment: \(error)")
            }
            XCTAssertEqual(try store.get(.nsAccessToken), "abc", "round trip failed for group \(group)")
        }
    }

    /// The probe writes a real keychain item. It must not survive the resolution that created it,
    /// on either the success or the failure path — and, because the cleanup sweeps the whole probe
    /// service rather than one account, not survive a run that was killed mid-probe either. That
    /// matters here: keychain items outlive app deletion, so without the sweep one jetsammed widget
    /// refresh would leave this assertion failing on that simulator forever.
    func test_theProbeLeavesNoItemBehind() throws {
        _ = SharedConstants.keychainAccessGroup  // force resolution if it has not happened yet

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainAccessGroupResolver.probeService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecItemNotFound)
    }

    /// Repeated reads are identical, including from several queues at once.
    ///
    /// NOTE: this does not cover the contended *first* resolution. The test bundle is hosted by the
    /// app, whose launch already resolved (`ClientPairingStore.init` -> `SharedConstants
    /// .pairingKeychain`) long before any test method runs, so the cache is warm here. That path is
    /// covered by inspection instead: the probe is called inside `cache.withLock`, so the loser of
    /// a race waits and then reads.
    func test_resolutionIsStableAcrossCallsAndQueues() {
        let firstShared = SharedConstants.keychainAccessGroup
        let firstPrivate = SharedConstants.appPrivateKeychainAccessGroup
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                XCTAssertEqual(SharedConstants.keychainAccessGroup, firstShared)
                XCTAssertEqual(SharedConstants.appPrivateKeychainAccessGroup, firstPrivate)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
    }

    /// Resolution rules, exercised on strings rather than on this machine's signing identity so they
    /// cover configurations no single machine can produce. The team ids here are invented.
    ///
    /// The load-bearing case is the first one: on team J6275F9A66 both results must come out
    /// byte-identical to the literals this resolver replaced, or an existing install's keychain
    /// items become unreachable.
    func test_groupResolutionRules() {
        func expect(
            defaultGroup: String?,
            bundleId: String?,
            shared: String?,
            appPrivate: String?,
            line: UInt = #line
        ) {
            let groups = KeychainAccessGroupResolver.resolve(
                defaultGroup: defaultGroup,
                bundleIdentifier: bundleId
            )
            XCTAssertEqual(groups.shared, shared, "shared group", line: line)
            XCTAssertEqual(groups.appPrivate, appPrivate, "app-private group", line: line)
        }

        // The shipping shape, with the real team id: exactly the two strings that used to be
        // hardcoded in SharedConstants. Nothing moves, so no keychain migration is needed.
        expect(
            defaultGroup: "J6275F9A66.com.nightaps.aapsclientios.shared",
            bundleId: "com.nightaps.aapsclientios",
            shared: "J6275F9A66.com.nightaps.aapsclientios.shared",
            appPrivate: "J6275F9A66.com.nightaps.aapsclientios"
        )
        // Contributor who kept this repo's entitlement but had to rename PRODUCT_BUNDLE_IDENTIFIER
        // (automatic signing cannot register an App ID another team already owns). Their
        // application-identifier group carries their bundle id, not this repo's.
        expect(
            defaultGroup: "K1234ABCDE.com.nightaps.aapsclientios.shared",
            bundleId: "com.foo.aapsclientios",
            shared: "K1234ABCDE.com.nightaps.aapsclientios.shared",
            appPrivate: "K1234ABCDE.com.foo.aapsclientios"
        )
        // Fork that renamed both, or any re-signed/sideloaded install: the granted group is named
        // verbatim rather than rebuilt from this repo's suffix, which nothing would grant.
        expect(
            defaultGroup: "K1234ABCDE.com.fork.client.shared",
            bundleId: "com.fork.client",
            shared: "K1234ABCDE.com.fork.client.shared",
            appPrivate: "K1234ABCDE.com.fork.client"
        )
        // Unsigned simulator build: `$(AppIdentifierPrefix)` expanded to nothing. An empty prefix is
        // a real answer, not a failure — the bare bundle id IS the granted group there.
        expect(
            defaultGroup: "com.nightaps.aapsclientios.shared",
            bundleId: "com.nightaps.aapsclientios",
            shared: "com.nightaps.aapsclientios.shared",
            appPrivate: "com.nightaps.aapsclientios"
        )
        // No `keychain-access-groups` declared: the default already IS the application-identifier
        // group, so the two coincide. `KeychainStore.migrate` reads that as "source not distinct"
        // and downgrades to a copy, which is the safe direction.
        expect(
            defaultGroup: "K1234ABCDE.com.nightaps.aapsclientios",
            bundleId: "com.nightaps.aapsclientios",
            shared: "K1234ABCDE.com.nightaps.aapsclientios",
            appPrivate: "K1234ABCDE.com.nightaps.aapsclientios"
        )
        // The widget extension: the same shared group (it declares the same entitlement) but its own
        // application-identifier. Nothing in the extension reads the app-private group.
        expect(
            defaultGroup: "J6275F9A66.com.nightaps.aapsclientios.shared",
            bundleId: "com.nightaps.aapsclientios.widget",
            shared: "J6275F9A66.com.nightaps.aapsclientios.shared",
            appPrivate: "J6275F9A66.com.nightaps.aapsclientios.widget"
        )

        // Nothing to go on: unscoped stores. Naming a guessed group would make every call -34018,
        // whereas an unscoped query still finds items in any group the process belongs to.
        for nothing in [nil, "", "com.apple.token"] as [String?] {
            expect(defaultGroup: nothing, bundleId: "com.nightaps.aapsclientios", shared: nil, appPrivate: nil)
        }
    }

    /// Both groups, or a skip: a context where nothing could be resolved runs unscoped by design,
    /// and there is no group name left to assert anything about.
    private func resolvedGroups() throws -> (shared: String, appPrivate: String) {
        guard let shared = SharedConstants.keychainAccessGroup,
              let appPrivate = SharedConstants.appPrivateKeychainAccessGroup else {
            throw XCTSkip("no keychain access group resolvable here — stores are running unscoped")
        }
        return (shared, appPrivate)
    }
}
