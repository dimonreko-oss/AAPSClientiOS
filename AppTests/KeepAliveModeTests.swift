import XCTest
@testable import AAPSClientiOS

final class KeepAliveModeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: AppStore.keepAliveModeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppStore.keepAliveModeKey)
        super.tearDown()
    }

    @MainActor
    func test_defaultsToNormal_whenNothingPersisted() {
        let store = AppStore(client: FixtureNightscoutClient(), alarmEngine: makeAlarmEngine())

        XCTAssertEqual(store.keepAliveMode, .normal)
    }

    @MainActor
    func test_persistsSelectedMode() {
        let store = AppStore(client: FixtureNightscoutClient(), alarmEngine: makeAlarmEngine())

        store.setKeepAliveMode(.aggressive)

        XCTAssertEqual(store.keepAliveMode, .aggressive)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: AppStore.keepAliveModeKey),
            KeepAliveMode.aggressive.rawValue
        )
    }

    @MainActor
    func test_fallsBackToNormal_whenPersistedValueIsUnknown() {
        UserDefaults.standard.set("nonsense", forKey: AppStore.keepAliveModeKey)

        let store = AppStore(client: FixtureNightscoutClient(), alarmEngine: makeAlarmEngine())

        XCTAssertEqual(store.keepAliveMode, .normal)
    }

    func test_disabledModeDoesNotKeepAlive() {
        XCTAssertFalse(KeepAliveMode.disabled.shouldKeepAlive)
        XCTAssertTrue(KeepAliveMode.normal.shouldKeepAlive)
        XCTAssertTrue(KeepAliveMode.aggressive.shouldKeepAlive)
    }
}
