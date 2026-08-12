import Foundation
import XCTest
@testable import AAPSClientiOS

final class KeychainMigrationTests: XCTestCase {
    private func uniqueService() -> String { "test.kc.\(UUID().uuidString)" }

    func test_migration_copiesValuesAndIsIdempotent() throws {
        let service = uniqueService()
        let source = KeychainStore(service: service)
        try source.set("https://ns.example/", for: .nsUrl)
        try source.set("token-123", for: .nsAccessToken)

        // Same access group on both sides: the source must NOT be removed, because a nil-group
        // SecItemDelete spans every group the app belongs to and would take the destination with it.
        try source.migrate(to: source)
        XCTAssertEqual(try source.get(.nsUrl), "https://ns.example/")
        XCTAssertEqual(try source.get(.nsAccessToken), "token-123")

        let empty = KeychainStore(service: uniqueService())
        XCTAssertNoThrow(try empty.migrate(to: empty))

        try source.delete(.nsUrl)
        try source.delete(.nsAccessToken)
    }

    /// The pairing secret must never be carried into the shared, widget-readable group by the
    /// credentials migration. The widget reads only the NS URL and token.
    func test_migration_leavesThePairingSecretBehind() throws {
        let source = KeychainStore(service: uniqueService())
        let destination = KeychainStore(service: uniqueService())
        try source.set("{\"secretHex\":\"deadbeef\"}", for: .clientControlPairing)
        try source.set("token-123", for: .nsAccessToken)
        defer {
            try? source.delete(.clientControlPairing)
            try? source.delete(.nsAccessToken)
            try? destination.delete(.nsAccessToken)
        }

        try source.migrate(to: destination)

        XCTAssertEqual(try destination.get(.nsAccessToken), "token-123")
        XCTAssertNil(try destination.get(.clientControlPairing))
        XCTAssertNotNil(try source.get(.clientControlPairing))
    }

    /// The migration seeds an EMPTY destination. That is its whole job: a pre-widget install has
    /// credentials only in the app-private group, and the widget extension can read only the shared
    /// one. The source is still removed, so the ambiguous unscoped lookup can never see two items.
    func test_migration_seedsAnEmptyDestinationAndRemovesTheSource() throws {
        let service = uniqueService()
        let (legacy, shared) = try partitionedStores(service: service)
        defer {
            try? legacy.delete(.nsAccessToken)
            try? shared.delete(.nsAccessToken)
        }

        try legacy.set("legacy-token", for: .nsAccessToken)

        try legacy.migrate(to: shared)

        XCTAssertEqual(try shared.get(.nsAccessToken), "legacy-token")
        XCTAssertNil(try legacy.get(.nsAccessToken), "source must be removed, not left to win again")
    }

    /// The regression the launch-time migration used to cause: the legacy app-private item is very
    /// often the STALER of the two — the old copy-only migration never deleted it — so a user who
    /// has since rotated their token in Settings has a live shared-group value and a dead
    /// app-private one. Overwriting produces a silent 401, and `credentialsInvalid` suppresses the
    /// Connection Lost alarm, so the only signal is a banner inside an app that has stopped
    /// following. The destination wins; the stale source is still deleted so it cannot come back.
    func test_migration_neverOverwritesAValueTheDestinationAlreadyHolds() throws {
        let service = uniqueService()
        let (legacy, shared) = try partitionedStores(service: service)
        defer {
            try? legacy.delete(.nsAccessToken)
            try? shared.delete(.nsAccessToken)
        }

        try legacy.set("stale-token", for: .nsAccessToken)
        try shared.set("user-typed-token", for: .nsAccessToken)

        try legacy.migrate(to: shared)

        XCTAssertEqual(try shared.get(.nsAccessToken), "user-typed-token")
        XCTAssertNil(try legacy.get(.nsAccessToken), "the stale source must not survive to try again")

        // And a second launch is a no-op rather than a second chance for the stale value.
        try legacy.migrate(to: shared)
        XCTAssertEqual(try shared.get(.nsAccessToken), "user-typed-token")
    }

    /// Two stores on the app's real access groups, or a skip when the environment cannot tell them
    /// apart (access groups are not enforced everywhere the tests run).
    private func partitionedStores(service: String) throws -> (KeychainStore, KeychainStore) {
        // The groups are resolved from the signing team at runtime, so "no group at all" is a
        // legitimate outcome (see KeychainAccessGroupResolver) — and with nil on both sides these
        // would be the same unscoped store, which is not what this helper promises.
        guard let appPrivateGroup = SharedConstants.appPrivateKeychainAccessGroup,
              let sharedGroup = SharedConstants.keychainAccessGroup else {
            throw XCTSkip("no keychain access group resolvable here: stores run unscoped")
        }
        let legacy = KeychainStore(service: service, accessGroup: appPrivateGroup)
        let shared = KeychainStore(service: service, accessGroup: sharedGroup)
        do {
            try legacy.set("probe-legacy", for: .nsUrl)
            try shared.set("probe-shared", for: .nsUrl)
        } catch {
            throw XCTSkip("keychain access groups unavailable here: \(error)")
        }
        let partitioned = (try? legacy.get(.nsUrl)) == "probe-legacy" && (try? shared.get(.nsUrl)) == "probe-shared"
        try? legacy.delete(.nsUrl)
        try? shared.delete(.nsUrl)
        if !partitioned {
            throw XCTSkip("keychain access groups are not partitioned in this environment")
        }
        return (legacy, shared)
    }
}
