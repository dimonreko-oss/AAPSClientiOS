import Foundation

protocol NightscoutClient: Sendable {
    func authorize() async throws
    func fetchEntries(limit: Int) async throws -> [GlucoseReading]
    func fetchTreatments(since: Date?) async throws -> [Treatment]
    func fetchDeviceStatus() async throws -> LoopStatus?
    /// Newest devicestatus document date, regardless of whether it carries an APS result.
    ///
    /// The master keeps uploading every five minutes while the loop is stopped, so this is the only
    /// heartbeat that survives a long suspension — `fetchDeviceStatus()` correctly returns nil there
    /// rather than inventing IOB/COB of zero. Callers use it ONLY to answer "is the master alive",
    /// and only when `fetchDeviceStatus()` came back nil, so it costs nothing in steady state.
    /// A protocol requirement (not extension-only) so a call through the protocol type reaches the
    /// live override — see `fetchEntries(sinceDays:)` for the same trap.
    func fetchDeviceStatusHeartbeat() async throws -> Date?
    func fetchProfile() async throws -> NsProfile
    func fetchProfileStore() async throws -> NsProfileStore
    /// Returns nil for HTTP 404 — NS APIv3 answers 404 for a settings identifier that has never
    /// been written, which is the normal state of a per-client ack slot on a freshly paired client.
    func fetchSettings(identifier: String) async throws -> NsSettingsDocument?
    func putSettings(identifier: String, document: [String: Any]) async throws
    /// Best-effort delete. Used to recover a settings slot created with a bad immutable `date`
    /// field, and to clean up a consumed pairing offer. Swallows 404/410 — the caller's intent
    /// ("this identifier must not exist") is already satisfied when it is already gone.
    ///
    /// The default below is a no-op so read-only fakes stay compiling; the live client overrides it.
    /// It is a protocol REQUIREMENT (not extension-only) so a call through the protocol type
    /// dispatches to the override — see `fetchEntries(sinceDays:)` for the same trap.
    func deleteSettings(identifier: String) async throws
    func searchSettings(limit: Int) async throws -> [NsSettingsDocument]
    func fetchRunningConfigCold() async throws -> NsRunningConfigCold?
    func fetchRunningConfigHot() async throws -> NsRunningConfigHot?
    func postTreatment(_ payload: [String: Any]) async throws
    /// Latest care-portal events (site/sensor/insulin/battery) — these are infrequent and fall
    /// outside the general treatments window, so they need a dedicated eventType-filtered query.
    func fetchCareEvents() async throws -> [Treatment]
    /// Paginated entries covering `days` back (live client pages past the NS per-request cap).
    /// MUST be a protocol requirement so calls via the protocol type dispatch to the live override,
    /// not the extension default below.
    func fetchEntries(sinceDays days: Int) async throws -> [GlucoseReading]
    func fetchDeviceStatusHistory(since: Date) async throws -> [DeviceStatusEntry]
    /// Treatments covering `since` to now, paginated by the treatment `date` field (not
    /// `srvModified`). MUST be a protocol requirement — see `fetchEntries(sinceDays:)` above
    /// for why an extension-only default would silently shadow the live client's real paging.
    func fetchTreatmentsHistory(since: Date) async throws -> [Treatment]
}

extension NightscoutClient {
    func deleteSettings(identifier: String) async throws {}
    /// nil = "this client cannot tell you". Callers must treat that as no evidence either way, never
    /// as "the master is gone".
    func fetchDeviceStatusHeartbeat() async throws -> Date? { nil }
    func fetchCareEvents() async throws -> [Treatment] { try await fetchTreatments(since: nil) }
    func fetchEntries(sinceDays days: Int) async throws -> [GlucoseReading] { try await fetchEntries(limit: days * 320) }
    func fetchDeviceStatusHistory(since: Date) async throws -> [DeviceStatusEntry] { [] }
    func fetchTreatmentsHistory(since: Date) async throws -> [Treatment] {
        try await fetchTreatments(since: nil).filter { $0.date >= since }
    }
    func fetchRunningConfigCold() async throws -> NsRunningConfigCold? {
        guard let document = try await fetchSettings(identifier: NightscoutSettingsIdentifier.cold) else { return nil }
        return try NsMapping.runningConfigCold(from: document)
    }
    func fetchRunningConfigHot() async throws -> NsRunningConfigHot? {
        guard let document = try await fetchSettings(identifier: NightscoutSettingsIdentifier.state) else { return nil }
        return try NsMapping.runningConfigHot(from: document)
    }
}

enum NightscoutSettingsIdentifier {
    static let cold = "aaps"
    static let state = "aaps-state"
}
