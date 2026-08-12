import XCTest
@testable import AAPSClientiOS

let testBaseURL = URL(string: "https://test.nightscout.example.com")!

/// Asserts that a piece of user-facing copy resolved to a real translation.
///
/// The trap this closes: `String(localized:)` returns the KEY when the entry is missing from
/// `Localizable.strings`, so `XCTAssertNotEqual(text, "ControlDisabled")` — and equally
/// `XCTAssertEqual(text, NSLocalizedString("clientcontrol.fail.control_disabled", comment: ""))`,
/// which resolves through the same missing key — both pass on a deleted entry. Pinning the English
/// sentence AND rejecting anything that still looks like a dotted key is what actually fails the
/// suite when a `.strings` file loses a line.
func assertLocalized(
    _ text: String?,
    equals expected: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let text else {
        XCTFail("expected localized copy, got nil", file: file, line: line)
        return
    }
    assertNotARawKey(text, file: file, line: line)
    XCTAssertEqual(text, expected, file: file, line: line)
}

/// The half of `assertLocalized` that survives a wording change: whatever the sentence says, it must
/// not be a `some.dotted.key` that leaked through because `Localizable.strings` has no entry for it.
func assertNotARawKey(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
    let looksLikeAKey = !text.contains(" ")
        && text.contains(".")
        && text.rangeOfCharacter(from: .uppercaseLetters) == nil
    XCTAssertFalse(
        looksLikeAKey,
        """
        "\(text)" is a localization key, not a translation. Either the entry is missing from \
        App/Resources/{en,ru}.lproj/Localizable.strings, or the test bundle has no TEST_HOST so \
        `String(localized:)` cannot see the app bundle.
        """,
        file: file,
        line: line
    )
}

/// `AlarmEngineLive` now PERSISTS its snooze table (`alarms.snoozedUntil`), reloading it in `init`.
/// Against `UserDefaults.standard` that means a snooze set by one test silences the alarm in every
/// test that runs after it — and, on a simulator, in the app itself. Every engine the suite builds
/// gets this isolated, freshly wiped domain instead.
private let alarmEngineTestSuite = "AAPSClientiOSTests.alarmEngine"

func makeAlarmDefaults() -> UserDefaults {
    guard let defaults = UserDefaults(suiteName: alarmEngineTestSuite) else { return .standard }
    defaults.removePersistentDomain(forName: alarmEngineTestSuite)
    return defaults
}

/// Use INSTEAD of `AlarmEngineLive(...)` everywhere in the suite. See `makeAlarmDefaults`.
func makeAlarmEngine(notifier: Notifier = MockNotifier()) -> AlarmEngineLive {
    AlarmEngineLive(notifier: notifier, defaults: makeAlarmDefaults())
}

final class MockAuthTransport: HttpTransport {
    var responseData: Data = Data()
    var responseCode: Int = 200
    var lastRequest: URLRequest?

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!, statusCode: responseCode, httpVersion: nil, headerFields: nil
        )!
        return (responseData, response)
    }
}

class FixtureNightscoutClient: NightscoutClient {
    var postedPayloads: [[String: Any]] = []
    var putSettingsCalls: [(identifier: String, document: [String: Any])] = []
    var deleteSettingsCalls: [String] = []
    /// Errors thrown from `putSettings`, consumed one per call — lets a test drive NS rejecting the
    /// first PUT with the immutable-date 400 and accepting the retry.
    var putSettingsErrors: [Error] = []
    var settingsSearchResults: [NsSettingsDocument] = []
    var shouldThrow: Error?
    /// Simulate a Task cancelled mid-refresh: entries succeed, later stages throw
    /// CancellationError (the real-world trigger for the frozen widget/LA bug).
    var cancelAfterEntries = false
    var treatmentsOverride: [Treatment]?
    var loopStatusOverride: LoopStatus?
    var settingsDocumentOverride: [String: NsSettingsDocument] = [:]
    var settingsByIdentifier: [String: String] = [
        NightscoutSettingsIdentifier.cold: "settings_aaps",
        NightscoutSettingsIdentifier.state: "settings_aaps_state",
    ]

    func authorize() async throws {
        if let error = shouldThrow { throw error }
    }

    func fetchEntries(limit: Int) async throws -> [GlucoseReading] {
        if let error = shouldThrow { throw error }
        let data = try loadFixture("entries")
        return try NsMapping.glucose(from: data)
    }

    func fetchTreatments(since: Date?) async throws -> [Treatment] {
        if cancelAfterEntries { throw CancellationError() }
        if let error = shouldThrow { throw error }
        if let treatmentsOverride { return treatmentsOverride }
        let data = try loadFixture("treatments")
        return try NsMapping.treatments(from: data)
    }

    func fetchDeviceStatus() async throws -> LoopStatus? {
        if cancelAfterEntries { throw CancellationError() }
        if let error = shouldThrow { throw error }
        if let loopStatusOverride { return loopStatusOverride }
        let data = try loadFixture("devicestatus")
        return try NsMapping.loopStatus(from: data)
    }

    /// Declared on the class rather than left to the protocol extension's `nil` default: a default
    /// implemented in a protocol extension is statically dispatched, so a SUBCLASS cannot override
    /// it. Tests that need the long-suspension liveness path (`fetchDeviceStatus()` nil, master
    /// still uploading) must be able to.
    var deviceStatusHeartbeat: Date?

    func fetchDeviceStatusHeartbeat() async throws -> Date? {
        if let error = shouldThrow { throw error }
        return deviceStatusHeartbeat
    }

    func fetchProfile() async throws -> NsProfile {
        if let error = shouldThrow { throw error }
        let data = try loadFixture("profile")
        return try NsMapping.profile(from: data)
    }

    func fetchProfileStore() async throws -> NsProfileStore {
        if let error = shouldThrow { throw error }
        let data = try loadFixture("profile")
        return try NsMapping.profileStore(from: data)
    }

    func fetchSettings(identifier: String) async throws -> NsSettingsDocument? {
        if let error = shouldThrow { throw error }
        if let override = settingsDocumentOverride[identifier] { return override }
        guard let fixture = settingsByIdentifier[identifier] else { return nil }
        let data = try loadFixture(fixture)
        return try NsMapping.settingsDocument(from: data, identifier: identifier)
    }

    func putSettings(identifier: String, document: [String: Any]) async throws {
        if let error = shouldThrow { throw error }
        if !putSettingsErrors.isEmpty {
            let error = putSettingsErrors.removeFirst()
            putSettingsCalls.append((identifier, document))
            throw error
        }
        putSettingsCalls.append((identifier, document))
        postedPayloads.append(document)
    }

    func deleteSettings(identifier: String) async throws {
        if let error = shouldThrow { throw error }
        deleteSettingsCalls.append(identifier)
    }

    func searchSettings(limit: Int) async throws -> [NsSettingsDocument] {
        if let error = shouldThrow { throw error }
        return settingsSearchResults
    }

    func fetchEntries(sinceDays days: Int) async throws -> [GlucoseReading] {
        if let error = shouldThrow { throw error }
        let data = try loadFixture("entries")
        return try NsMapping.glucose(from: data)
    }

    func fetchDeviceStatusHistory(since: Date) async throws -> [DeviceStatusEntry] {
        if let error = shouldThrow { throw error }
        let data = try loadFixture("devicestatus_history")
        return try NsMapping.deviceStatusHistory(from: data)
    }

    func fetchTreatmentsHistory(since: Date) async throws -> [Treatment] {
        if let error = shouldThrow { throw error }
        let data = try loadFixture("treatments")
        return try NsMapping.treatments(from: data)
    }

    func postTreatment(_ payload: [String: Any]) async throws {
        if let error = shouldThrow { throw error }
        postedPayloads.append(payload)
    }
}
