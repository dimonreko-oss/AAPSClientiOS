import Foundation
import XCTest
@testable import AAPSClientiOS

final class ClientPairingStoreTests: XCTestCase {
    private func uniqueService() -> String { "test.clientcontrol.\(UUID().uuidString)" }

    private func pairing(_ clientId: String = "c1") -> MasterPairing {
        MasterPairing(masterInstallId: "m1", clientId: clientId, secretHex: "aabbcc")
    }

    func test_pairThenLoadRoundTrips() throws {
        let store = ClientPairingStore(service: uniqueService())
        defer { store.unpair() }

        XCTAssertNil(store.currentPairing())

        let p = pairing()
        store.pair(p)

        XCTAssertEqual(store.currentPairing(), p)
    }

    func test_unpairClearsStoredPairing() throws {
        let store = ClientPairingStore(service: uniqueService())
        store.pair(pairing())
        store.unpair()
        XCTAssertNil(store.currentPairing())
        XCTAssertNil(store.currentPairingIgnoringRepair())
        XCTAssertFalse(store.needsRepair)
    }

    func test_counterIncrementsMonotonically() throws {
        let store = ClientPairingStore(service: uniqueService())
        defer { store.unpair() }
        store.pair(pairing())

        XCTAssertEqual(store.nextCounter(), 1)
        XCTAssertEqual(store.nextCounter(), 2)
    }

    /// The whole point of the blob: the counter must be as durable as the secret it is signed with.
    func test_counterSurvivesANewStoreInstance() throws {
        let service = uniqueService()
        let first = ClientPairingStore(service: service)
        defer { first.unpair() }
        first.pair(pairing())
        _ = first.nextCounter()
        _ = first.nextCounter()

        let second = ClientPairingStore(service: service)
        XCTAssertEqual(second.nextCounter(), 3)
    }

    func test_pairRecordsPairedAtTimestamp() throws {
        let store = ClientPairingStore(service: uniqueService())
        defer { store.unpair() }

        XCTAssertNil(store.pairedAt())

        let before = Date()
        store.pair(pairing())
        let after = Date()

        let pairedAt = try XCTUnwrap(store.pairedAt())
        XCTAssertTrue(pairedAt >= before.addingTimeInterval(-1) && pairedAt <= after.addingTimeInterval(1))
    }

    func test_unpairClearsPairedAt() throws {
        let store = ClientPairingStore(service: uniqueService())
        store.pair(pairing())
        store.unpair()
        XCTAssertNil(store.pairedAt())
    }

    // MARK: - Reinstall detection

    /// Delete-and-reinstall: the Keychain item survives, `UserDefaults` does not. Removing the
    /// install marker is the only faithful way to simulate that in-process.
    func test_reinstallIsDetectedAndBlocksSending() throws {
        let service = uniqueService()
        let store = ClientPairingStore(service: service)
        defer { store.unpair() }
        store.pair(pairing())
        XCTAssertFalse(store.needsRepair)

        UserDefaults.standard.removeObject(forKey: ClientPairingStore.installMarkerDefaultsKey(service: service))

        let reinstalled = ClientPairingStore(service: service)
        XCTAssertTrue(reinstalled.needsRepair)
        // Refusing to hand out the pairing is what stops a counter=1 envelope the master drops
        // without writing any ack at all.
        XCTAssertNil(reinstalled.currentPairing())
        XCTAssertEqual(reinstalled.currentPairingIgnoringRepair(), pairing())
    }

    func test_rePairingClearsNeedsRepair() throws {
        let service = uniqueService()
        let store = ClientPairingStore(service: service)
        defer { store.unpair() }
        store.pair(pairing())
        UserDefaults.standard.removeObject(forKey: ClientPairingStore.installMarkerDefaultsKey(service: service))

        let reinstalled = ClientPairingStore(service: service)
        XCTAssertTrue(reinstalled.needsRepair)

        reinstalled.pair(pairing("c2"))
        XCTAssertFalse(reinstalled.needsRepair)
        XCTAssertEqual(reinstalled.currentPairing()?.clientId, "c2")
        XCTAssertEqual(reinstalled.nextCounter(), 1)
    }

    /// An in-place app upgrade must NOT look like a reinstall: `UserDefaults` survived, so the
    /// counter it holds is real and has to be carried into the blob.
    func test_inPlaceUpgradeFromLegacyLayoutAdoptsTheCounter() throws {
        let service = uniqueService()
        let legacyKeychain = KeychainStore(service: service, accessGroup: SharedConstants.keychainAccessGroup)
        let blob = try XCTUnwrap(String(data: try JSONEncoder().encode(pairing()), encoding: .utf8))
        try legacyKeychain.set(blob, for: .clientControlPairing)
        UserDefaults.standard.set(Int64(7), forKey: "\(service).counterSent")
        UserDefaults.standard.set(Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSince1970,
                                  forKey: "\(service).pairedAt")

        let store = ClientPairingStore(service: service)
        defer { store.unpair() }

        XCTAssertFalse(store.needsRepair)
        XCTAssertEqual(store.currentPairing(), pairing())
        XCTAssertEqual(store.nextCounter(), 8)
        XCTAssertEqual(store.pairedAt(), Date(timeIntervalSince1970: 1_700_000_000))
        // The legacy UserDefaults copies are consumed, not left behind to be re-adopted.
        XCTAssertNil(UserDefaults.standard.object(forKey: "\(service).counterSent"))
    }

    /// Legacy Keychain blob with no `UserDefaults` beside it is the reinstall signature.
    func test_legacyBlobWithoutUserDefaultsIsTreatedAsReinstall() throws {
        let service = uniqueService()
        let legacyKeychain = KeychainStore(service: service, accessGroup: SharedConstants.keychainAccessGroup)
        let blob = try XCTUnwrap(String(data: try JSONEncoder().encode(pairing()), encoding: .utf8))
        try legacyKeychain.set(blob, for: .clientControlPairing)

        let store = ClientPairingStore(service: service)
        defer { store.unpair() }

        XCTAssertTrue(store.needsRepair)
        XCTAssertNil(store.currentPairing())
    }

    // MARK: - Hello promotion

    func test_helloAckedIsFalseUntilMarkedAndThenDurable() throws {
        let service = uniqueService()
        let store = ClientPairingStore(service: service)
        defer { store.unpair() }
        store.pair(pairing())

        XCTAssertFalse(store.helloAcked)
        store.markHelloAcked()
        XCTAssertTrue(store.helloAcked)
        XCTAssertTrue(ClientPairingStore(service: service).helloAcked)
    }

    func test_pairResetsHelloAcked() throws {
        let store = ClientPairingStore(service: uniqueService())
        defer { store.unpair() }
        store.pair(pairing())
        store.markHelloAcked()

        store.pair(pairing("c2"))
        XCTAssertFalse(store.helloAcked)
    }

    // MARK: - Durable authorization verdict

    func test_authorizationDefaultsToTrueAndPersistsRevocation() throws {
        let service = uniqueService()
        let store = ClientPairingStore(service: service)
        defer { store.unpair() }
        store.pair(pairing())

        XCTAssertTrue(store.isAuthorized)

        store.recordAuthorization(false)
        // A revoked client must still read as revoked after a relaunch — the old in-memory flag
        // sprang back to `true` on every launch.
        XCTAssertFalse(ClientPairingStore(service: service).isAuthorized)

        store.recordAuthorization(true)
        XCTAssertTrue(ClientPairingStore(service: service).isAuthorized)
    }

    // MARK: - Atomicity

    /// Two concurrent sends minting the same counter means the master silently drops the second one
    /// as a replay. `ClientControlPublisher.send` runs off the main actor, so this really happens.
    func test_concurrentNextCounterNeverRepeats() throws {
        let store = ClientPairingStore(service: uniqueService())
        defer { store.unpair() }
        store.pair(pairing())

        let iterations = 24
        let lock = NSLock()
        var minted: [Int64] = []
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let value = store.nextCounter()
            lock.lock()
            minted.append(value)
            lock.unlock()
        }

        XCTAssertEqual(minted.count, iterations)
        XCTAssertEqual(Set(minted).count, iterations, "counter was minted twice")
        XCTAssertEqual(minted.max() ?? 0, Int64(iterations))
    }

    /// Same, but across the four independent store instances that exist today (three views plus
    /// AppStore) — the lock has to be process-wide, not per-instance.
    func test_concurrentNextCounterAcrossInstancesNeverRepeats() throws {
        let service = uniqueService()
        let stores = (0..<4).map { _ in ClientPairingStore(service: service) }
        defer { stores[0].unpair() }
        stores[0].pair(pairing())

        let iterations = 24
        let lock = NSLock()
        var minted: [Int64] = []
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            let value = stores[index % stores.count].nextCounter()
            lock.lock()
            minted.append(value)
            lock.unlock()
        }

        XCTAssertEqual(Set(minted).count, iterations, "counter was minted twice across instances")
    }
}
