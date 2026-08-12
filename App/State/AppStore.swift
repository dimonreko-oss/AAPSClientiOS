import Foundation
import Combine
import WidgetKit

enum RefreshError: LocalizedError {
    case stage(String, Error)
    var errorDescription: String? {
        switch self {
        case .stage(let name, let err):
            return "[\(name)] \(err)"
        }
    }
}

/// How much of Nightscout to fetch.
enum RefreshScope {
    case full
    case light
}

@MainActor final class AppStore: ObservableObject {
    @Published var readings: [GlucoseReading] = []
    @Published var treatments: [Treatment] = []
    @Published var loopStatus: LoopStatus?
    @Published var profile: NsProfile?
    @Published var profileStore: NsProfileStore? = nil
    @Published var connectionLost = false
    @Published private(set) var activeAlarms: [AlarmType] = []
    @Published var thresholds: AlarmThresholds
    @Published var consumableThresholds: ConsumableThresholds
    @Published var displayUnits: GlucoseUnits = .mgdl
    @Published var keepAliveMode: KeepAliveMode = .normal
    @Published var careEvents: [Treatment] = []
    @Published var deviceStatusHistory: [DeviceStatusEntry] = []
    @Published var remoteConfigCold: NsRunningConfigCold?
    @Published var remoteConfigHot: NsRunningConfigHot?
    @Published var remoteCapabilities: NsRemoteCapabilities?
    @Published var remoteConfigError: String?
    @Published var clientControlAuthorized: Bool = true
    /// True when Nightscout rejected the ACCESS TOKEN itself (revoked, or its role changed) rather
    /// than the network failing. A permanent failure the user must fix in Settings — it must never
    /// render as "connection lost", and the poller must not keep raising `.connectionLost` for it.
    @Published var credentialsInvalid = false
    /// RunningMode rows parsed out of the treatment window already being fetched — no extra request.
    /// Without these the status card can only measure devicestatus *freshness*, and a master that is
    /// SUSPENDED_BY_USER keeps uploading every five minutes, so it renders green while therapy is off.
    @Published private(set) var runningModeRecords: [RunningModeRecord] = []
    /// Newest verified answer from the master's signed channel. Part of the liveness clock behind
    /// `masterControlAvailability`, alongside the devicestatus heartbeat and the config republishes.
    @Published private(set) var lastVerifiedAckAt: Date?
    /// Newest devicestatus UPLOAD time — the master's keep-alive heartbeat, which continues every
    /// five minutes while the loop is stopped. Monotonic: a fetch that finds nothing is no evidence
    /// the master died, so it never moves backwards. See `LoopStatus.deviceDate`.
    @Published private(set) var lastDeviceStatusAt: Date?
    /// Consecutive round trips that ended `.unconfirmed` while the master was otherwise alive.
    /// See `ClientControlAuthorizationState.counterDesynced`.
    @Published private(set) var silentRoundTrips = 0
    /// Mirrors `realtime.diagnosticSummary` so Settings can render it without taking the service as
    /// a second `@ObservedObject`.
    @Published private(set) var realtimeStatus = "off"
    @Published private(set) var realtimeEngaged = false

    var activeProfileSwitch: Treatment? {
        (careEvents + treatments)
            .filter { $0.eventType == "Profile Switch" }
            .max(by: { $0.date < $1.date })
    }

    var activeProfileName: String? {
        activeProfileSwitch?.profileName ?? profileStore?.defaultProfileName
    }

    let alarmEngine: AlarmEngine
    let clientPairingStore: ClientPairingStore
    /// Realtime accelerator over the same Nightscout instance. Owned here, not by `App.swift`, so
    /// every screen shares one socket and the UI can read its state without another injection point.
    /// It is *strictly* an optimisation: the HTTP reconciliation poll below stays authoritative and
    /// nothing on this path may raise an alarm or an error banner.
    let realtime: NightscoutRealtimeService
    private let notifier: Notifier
    private let deadManSwitch: DeadManSwitching
    private var cancellables = Set<AnyCancellable>()
    private var _client: NightscoutClient
    private let clientLock = NSLock()
    var client: NightscoutClient {
        get { clientLock.lock(); defer { clientLock.unlock() }; return _client }
        set {
            clientLock.lock()
            _client = newValue
            clientLock.unlock()
            // The publisher captures its client by value, so a swapped transport must invalidate it
            // or every later command would be signed and PUT against the old server.
            invalidateClientControlChannel()
        }
    }

    // MARK: - Client control channel

    /// ONE publisher and ONE coordinator for the whole app.
    ///
    /// Every view used to build its own `ClientPairingStore` + `ClientControlPublisher` pair. With
    /// the counter now a durable, lock-guarded Keychain blob that is a correctness bug and not just
    /// a smell: the master's ack document is a single per-client slot it overwrites in place, so two
    /// coordinators racing on it make the loser spin to its deadline on a command that actually
    /// applied. `RoundTripGate` is process-wide for the same reason; a single instance is what makes
    /// it meaningful rather than incidental.
    private var _clientControlPublisher: ClientControlPublisher?
    private var _clientControlRoundTrip: ClientControlRoundTrip?

    var clientControlPublisher: ClientControlPublisher {
        if let existing = _clientControlPublisher { return existing }
        let publisher = ClientControlPublisher(client: client, pairingStore: clientPairingStore)
        _clientControlPublisher = publisher
        return publisher
    }

    var clientControlRoundTrip: ClientControlRoundTrip {
        if let existing = _clientControlRoundTrip { return existing }
        let coordinator = ClientControlRoundTrip(publisher: clientControlPublisher)
        _clientControlRoundTrip = coordinator
        return coordinator
    }

    private func invalidateClientControlChannel() {
        _clientControlPublisher = nil
        _clientControlRoundTrip = nil
    }
    private(set) var lastRefresh = Date.distantPast
    /// Three hours of entries: enough for alarms, widget and Live Activity.
    static let lightEntriesLimit = 36
    private(set) var lastLightRefresh = Date.distantPast
    private let sharedStore: SharedStore
    private let glucoseNotificationPublisher: GlucoseNotificationPublishing
    private var lastPushedReadingDate: Date?
    private var lastNotifiedReadingDate: Date?
    private var lastLiveActivityReadingDate: Date?
    private var lastLiveActivityPushAt: Date?
    /// Persisted: in memory only, every cold launch and every BGProcessing-driven relaunch inside
    /// `AnnouncementRelay`'s 60-minute validity window re-posted the same announcement.
    private static let lastAnnouncementDefaultsKey = "announce.lastNotifiedDate"
    private var lastNotifiedAnnouncementDate: Date? {
        get {
            let raw = UserDefaults.standard.double(forKey: Self.lastAnnouncementDefaultsKey)
            return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.lastAnnouncementDefaultsKey)
        }
    }
    static let liveActivityEnabledKey = "liveActivity.enabled"
    static let liveActivityPushInterval: TimeInterval = 5 * 60
    static let glucoseNotificationEnabledKey = "notification.latestGlucose.enabled"
    static let announcementRelayEnabledKey = "announcementRelay.enabled"
    static let iapsMasterModeEnabledKey = "iapsMasterMode.enabled"
    static let keepAliveModeKey = "background.keepAliveMode"

    var isGlucoseNotificationEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.glucoseNotificationEnabledKey)
    }

    var isAnnouncementRelayEnabled: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: Self.announcementRelayEnabledKey) == nil { return true }
        return d.bool(forKey: Self.announcementRelayEnabledKey)
    }

    func setAnnouncementRelayEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.announcementRelayEnabledKey)
    }

    var isIapsMasterModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.iapsMasterModeEnabledKey)
    }

    func setIapsMasterModeEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.iapsMasterModeEnabledKey)
    }

    var isLiveActivityEnabled: Bool {
        let isRunning: Bool
        if #available(iOS 16.1, *) {
            isRunning = LiveActivityController.shared.isRunning
        } else {
            isRunning = false
        }
        return Self.resolveLiveActivityPreference(
            defaults: .standard,
            activityIsRunning: isRunning
        )
    }

    static func resolveLiveActivityPreference(
        defaults: UserDefaults,
        activityIsRunning: Bool
    ) -> Bool {
        if defaults.object(forKey: liveActivityEnabledKey) != nil {
            return defaults.bool(forKey: liveActivityEnabledKey)
        }
        if activityIsRunning {
            defaults.set(true, forKey: liveActivityEnabledKey)
        }
        return activityIsRunning
    }

    static func shouldPushLiveActivity(
        readingChanged: Bool,
        activityIsRunning: Bool,
        lastPushAt: Date?,
        now: Date
    ) -> Bool {
        guard activityIsRunning else { return true }
        guard readingChanged else { return false }
        guard let lastPushAt else { return true }
        return now.timeIntervalSince(lastPushAt) >= liveActivityPushInterval
    }

    var ttPresets: [TtReason: TtPreset] {
        get { Self.loadTtPresets() }
        set { Self.saveTtPresets(newValue) }
    }

    var remoteTempTargetPresets: [NsSyncedTempTargetPreset] {
        NsSyncedPrefsParser.tempTargetPresets(from: remoteConfigCold?.syncedPrefsSnapshot.tempTargetPresetsJson)
    }

    var remoteSceneDefinitions: [NsSceneDefinition] {
        NsSyncedPrefsParser.sceneDefinitions(from: remoteConfigCold?.syncedPrefsSnapshot.sceneDefinitionsJson)
    }

    var remoteQuickWizardEntries: [NsQuickWizardEntry] {
        NsSyncedPrefsParser.quickWizardEntries(from: remoteConfigCold?.syncedPrefsSnapshot.quickWizardJson)
    }

    var activeRemoteSceneDefinition: NsSceneDefinition? {
        guard let sceneId = remoteConfigHot?.activeScene?.sceneId else { return nil }
        return remoteSceneDefinitions.first(where: { $0.sceneId == sceneId })
    }

    var activeRemoteSceneDisplayName: String? {
        if let name = activeRemoteSceneDefinition?.name, !name.isEmpty {
            return name
        }
        return remoteConfigHot?.activeScene?.sceneId
    }

    var isStale: Bool { Date().timeIntervalSince(lastRefresh) > 60 }

    /// How often the *heavy* refresh may run. A full pass is entries + treatments + devicestatus +
    /// profile + profileStore + careEvents + deviceStatusHistory + two config docs — roughly 28 HTTP
    /// requests, and `isStale` is keyed to `lastRefresh` which only the full path advances, so the
    /// 60 s foreground tick always took it. That was ~28 requests a minute for as long as the app was
    /// open, which is the battery and cellular cost the user attributes to this app.
    static let fullRefreshInterval: TimeInterval = 5 * 60

    var isFullStale: Bool { Date().timeIntervalSince(lastRefresh) > Self.fullRefreshInterval }

    /// Newest successful fetch of *either* scope — the light path proves the link is alive too.
    var lastAnyRefresh: Date { max(lastRefresh, lastLightRefresh) }

    func refreshIfStale() async {
        guard isStale else { return }
        try? await refresh()
    }

    /// The 60 s foreground tick. Light by default; full only on the five-minute cadence (and on
    /// foreground entry, because `lastRefresh` is by then already older than the interval).
    ///
    /// `now` is injectable so the cadence is testable without sleeping through it.
    func refreshForeground(now: Date = Date()) async {
        if now.timeIntervalSince(lastRefresh) > Self.fullRefreshInterval {
            try? await refresh(scope: .full)
            return
        }
        guard now.timeIntervalSince(lastAnyRefresh) > 60 else { return }
        try? await refresh(scope: .light)
    }

    func fetchHistory(days: Int) async throws -> [GlucoseReading] {
        ensureConfigured()
        return try await client.fetchEntries(sinceDays: days)
    }

    func fetchTreatmentHistory(days: Int) async throws -> [Treatment] {
        ensureConfigured()
        return try await client.fetchTreatmentsHistory(since: Date().addingTimeInterval(-Double(days) * 86400))
    }

    init(
        client: NightscoutClient,
        alarmEngine: AlarmEngine,
        clientPairingStore: ClientPairingStore = ClientPairingStore(),
        sharedStore: SharedStore = SharedStore(),
        glucoseNotificationPublisher: GlucoseNotificationPublishing = DummyGlucoseNotificationPublisher(),
        notifier: Notifier = UNNotifier(),
        deadManSwitch: DeadManSwitching = DummyDeadManSwitch(),
        realtime: NightscoutRealtimeService? = nil
    ) {
        self._client = client
        self.alarmEngine = alarmEngine
        self.clientPairingStore = clientPairingStore
        self.sharedStore = sharedStore
        self.glucoseNotificationPublisher = glucoseNotificationPublisher
        self.notifier = notifier
        self.deadManSwitch = deadManSwitch
        self.realtime = realtime ?? NightscoutRealtimeService()
        self.thresholds = Self.loadThresholds()
        self.consumableThresholds = Self.loadConsumableThresholds()
        self.displayUnits = Self.loadDisplayUnits()
        self.keepAliveMode = Self.loadKeepAliveMode()
        // Seed from the durable verdict. In memory this defaulted to true, so a client the master had
        // revoked reported itself authorized again after every relaunch until some later full refresh
        // happened to re-derive it — and never at all if the master stopped publishing the cold doc.
        self.clientControlAuthorized = clientPairingStore.isAuthorized
        ensureConfigured()
        bindRealtime()
    }

    /// Realtime pushes land in exactly the same `@Published` state the poll writes, through the same
    /// `NsMapping` entry points. Binding here rather than in `App.swift` keeps the two paths from
    /// ever growing separate parsers.
    private func bindRealtime() {
        realtime.onDocument = { [weak self] update in self?.applyRealtime(update) }
        realtime.onAlarm = { [weak self] alarm in self?.applyRealtimeAlarm(alarm) }
        realtime.objectWillChange
            .sink { [weak self] _ in
                // `objectWillChange` fires *before* the property is written, so read on the next turn.
                Task { @MainActor in self?.syncRealtimeStatus() }
            }
            .store(in: &cancellables)
        syncRealtimeStatus()
    }

    private func syncRealtimeStatus() {
        realtimeStatus = realtime.diagnosticSummary
        realtimeEngaged = realtime.isEngaged
    }

    func reconnect(baseURL: URL, accessToken: String) {
        client = NightscoutClientLive(baseURL: baseURL, accessToken: accessToken, transport: URLSessionTransport())
        setCredentialsInvalid(false)
        // A changed URL or token leaves the old socket running against the old server.
        realtime.reconnect()
    }

    /// Normalize user-entered NS URL: trim, add https:// if scheme missing.
    static func normalizedURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        return URL(string: s)
    }

    /// Rebuild a live client from Keychain if the current one isn't configured.
    /// Makes refresh resilient to launch timing / Keychain re-population.
    func ensureConfigured() {
        guard !(client is NightscoutClientLive) else { return }
        let kc = SharedConstants.credentialKeychain()
        let urlStr = (try? kc.get(.nsUrl)) ?? nil
        let token = (try? kc.get(.nsAccessToken)) ?? nil
        guard let urlStr, let url = Self.normalizedURL(urlStr),
              let token, !token.isEmpty else { return }
        client = NightscoutClientLive(baseURL: url, accessToken: token, transport: URLSessionTransport())
    }

    func setDisplayUnits(_ units: GlucoseUnits) {
        displayUnits = units
        UserDefaults.standard.set(units.rawValue, forKey: "display.glucoseUnits")
        // Force a push: the reading is unchanged but the rendered units differ.
        updateSharedSnapshot(force: true)
    }

    func setKeepAliveMode(_ mode: KeepAliveMode) {
        keepAliveMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.keepAliveModeKey)
        // The ladder is the fallback FOR a process that is not being held alive, and it costs no
        // battery — so it is armed whatever this setting says. Disarming it here was exactly
        // backwards: a user who turns the audio keep-alive off (to save battery, which Settings
        // actively invites) is the user iOS suspends and reaps soonest, and the pre-scheduled
        // `UNTimeIntervalNotificationTrigger` rungs are the ONLY alarm path that survives that.
        // If a user-visible off switch is ever wanted, give it its own preference and call
        // `disarm()` from there — never from the audio setting.
        if let latest = readings.first {
            deadManSwitch.rearm(reference: latest.date)
        }
    }

    private static func loadKeepAliveMode() -> KeepAliveMode {
        let raw = UserDefaults.standard.string(forKey: Self.keepAliveModeKey) ?? ""
        return KeepAliveMode(rawValue: raw) ?? .normal
    }

    private static func loadDisplayUnits() -> GlucoseUnits {
        let raw = UserDefaults.standard.string(forKey: "display.glucoseUnits") ?? ""
        return GlucoseUnits(rawValue: raw) ?? .mgdl
    }

    func updateThresholds(_ t: AlarmThresholds) {
        thresholds = t
        let d = UserDefaults.standard
        d.set(t.urgentLow, forKey: "threshold.urgentLow")
        d.set(t.low, forKey: "threshold.low")
        d.set(t.high, forKey: "threshold.high")
        d.set(t.urgentHigh, forKey: "threshold.urgentHigh")
        d.set(t.staleMinutes, forKey: "threshold.staleMinutes")
    }

    private static func loadThresholds() -> AlarmThresholds {
        let d = UserDefaults.standard
        if d.object(forKey: "threshold.urgentLow") == nil { return .defaults }
        return AlarmThresholds(
            urgentLow: d.integer(forKey: "threshold.urgentLow"),
            low: d.integer(forKey: "threshold.low"),
            high: d.integer(forKey: "threshold.high"),
            urgentHigh: d.integer(forKey: "threshold.urgentHigh"),
            staleMinutes: d.integer(forKey: "threshold.staleMinutes")
        )
    }

    func updateConsumableThresholds(_ t: ConsumableThresholds) {
        consumableThresholds = t
        let d = UserDefaults.standard
        d.set(t.cageWarnHours, forKey: "consumable.cageWarnHours")
        d.set(t.cageCriticalHours, forKey: "consumable.cageCriticalHours")
        d.set(t.iageWarnHours, forKey: "consumable.iageWarnHours")
        d.set(t.iageCriticalHours, forKey: "consumable.iageCriticalHours")
        d.set(t.sageWarnHours, forKey: "consumable.sageWarnHours")
        d.set(t.sageCriticalHours, forKey: "consumable.sageCriticalHours")
        d.set(t.bageWarnHours, forKey: "consumable.bageWarnHours")
        d.set(t.bageCriticalHours, forKey: "consumable.bageCriticalHours")
        d.set(t.reservoirWarnUnits, forKey: "consumable.reservoirWarnUnits")
        d.set(t.reservoirCriticalUnits, forKey: "consumable.reservoirCriticalUnits")
        d.set(t.pumpBattWarnPercent, forKey: "consumable.pumpBattWarnPercent")
        d.set(t.pumpBattCriticalPercent, forKey: "consumable.pumpBattCriticalPercent")
    }

    private static func loadConsumableThresholds() -> ConsumableThresholds {
        let d = UserDefaults.standard
        if d.object(forKey: "consumable.cageWarnHours") == nil { return .defaults }
        return ConsumableThresholds(
            cageWarnHours: d.integer(forKey: "consumable.cageWarnHours"),
            cageCriticalHours: d.integer(forKey: "consumable.cageCriticalHours"),
            iageWarnHours: d.integer(forKey: "consumable.iageWarnHours"),
            iageCriticalHours: d.integer(forKey: "consumable.iageCriticalHours"),
            sageWarnHours: d.integer(forKey: "consumable.sageWarnHours"),
            sageCriticalHours: d.integer(forKey: "consumable.sageCriticalHours"),
            bageWarnHours: d.integer(forKey: "consumable.bageWarnHours"),
            bageCriticalHours: d.integer(forKey: "consumable.bageCriticalHours"),
            reservoirWarnUnits: d.integer(forKey: "consumable.reservoirWarnUnits"),
            reservoirCriticalUnits: d.integer(forKey: "consumable.reservoirCriticalUnits"),
            pumpBattWarnPercent: d.integer(forKey: "consumable.pumpBattWarnPercent"),
            pumpBattCriticalPercent: d.integer(forKey: "consumable.pumpBattCriticalPercent")
        )
    }

    private static func loadTtPresets() -> [TtReason: TtPreset] {
        let d = UserDefaults.standard
        var presets: [TtReason: TtPreset] = [:]
        for reason in [TtReason.eatingSoon, .activity, .hypo] {
            let key = "ttPreset.\(reason.rawValue)"
            if let data = d.data(forKey: key),
               let preset = try? JSONDecoder().decode(TtPreset.self, from: data) {
                presets[reason] = preset
            } else {
                presets[reason] = TtPreset(targetMgdl: reason.defaultTargetMgdl,
                                           durationMin: reason.defaultDurationMin)
            }
        }
        return presets
    }

    private static func saveTtPresets(_ presets: [TtReason: TtPreset]) {
        let d = UserDefaults.standard
        for (reason, preset) in presets {
            let key = "ttPreset.\(reason.rawValue)"
            if let data = try? JSONEncoder().encode(preset) {
                d.set(data, forKey: key)
            }
        }
    }

    func refresh(scope: RefreshScope = .full) async throws {
        ensureConfigured()
        switch scope {
        case .full: try await refreshFull()
        case .light: try await refreshLight()
        }
    }

    private func refreshLight() async throws {
        var firstError: Error?
        var entriesOk = false

        defer { if entriesOk { updateSharedSnapshot() } }

        do {
            let fresh = try await client.fetchEntries(limit: Self.lightEntriesLimit)
            mergeReadings(fresh)
            entriesOk = true
        } catch is CancellationError { return }
        catch { firstError = RefreshError.stage("entries", error) }

        do {
            try await applyDeviceStatus()
        } catch is CancellationError { return }
        catch { firstError = firstError ?? RefreshError.stage("devicestatus", error) }

        await sweepRecentTreatments()

        connectionLost = firstError != nil
        setCredentialsInvalid(firstError.map(Self.isUnauthorized) ?? false)
        if entriesOk {
            lastLightRefresh = Date()
        }

        evaluateAlarms()

        if let firstError {
            // Matches `refreshFull`: a snoozed Connection Lost used to re-post a notification on
            // every background tick, and `activeAlarms` was never appended here — so the in-app
            // banner and the notification disagreed for as long as the network stayed down.
            raiseConnectionLostIfAppropriate()
            throw firstError
        }
    }

    /// Fetches the devicestatus and keeps the master's upload heartbeat, which outlives it.
    ///
    /// `fetchDeviceStatus()` correctly returns nil once the fetched window holds no APS result at
    /// all — inventing IOB 0 / COB 0 for a stopped loop is the exact inverse of the truth. But the
    /// master's keep-alive keeps uploading a pump-only document every five minutes, so nil there
    /// says nothing about whether the master is alive, and letting it clear the liveness clock is
    /// what made the app refuse to send the very command that would resume a suspended loop.
    private func applyDeviceStatus() async throws {
        let status = try await client.fetchDeviceStatus()
        loopStatus = status
        notifyCarbsRequiredIfNeeded()
        if let heartbeat = status?.deviceDate ?? status?.timestamp {
            lastDeviceStatusAt = max(lastDeviceStatusAt ?? .distantPast, heartbeat)
        } else if let heartbeat = try? await client.fetchDeviceStatusHeartbeat() {
            // Only reached while the loop has been stopped longer than the widened lookback, so it
            // costs one extra (projected, tiny) request in exactly that case and none otherwise.
            lastDeviceStatusAt = max(lastDeviceStatusAt ?? .distantPast, heartbeat)
        }
    }

    /// The one recent-treatments page both the Announcement relay and `LoopHealth` need.
    ///
    /// Two things depend on it and both used to be wrong on the background path. The relay only ran
    /// from the full refresh, so an Announcement posted while the phone was in a pocket was never
    /// surfaced and had usually expired by the time the app was next opened. And `runningModeRecords`
    /// was only ever written by the full sweep, so a master that went `SUSPENDED_BY_USER` at 14:00
    /// kept rendering a green, healthy loop until the next foreground — the exact lie `LoopHealth`
    /// exists to prevent, because `LoopStateCalc` still sees the devicestatus heartbeat.
    ///
    /// Throttled because this is a paged `/treatments` query and the light path runs every 30–60 s.
    /// `try?` on purpose: entries and devicestatus define link health, and a flaky treatments
    /// endpoint must not raise Connection Lost while glucose is flowing normally.
    private func sweepRecentTreatments(now: Date = Date()) async {
        guard now.timeIntervalSince(lastRecentTreatmentSweep) > Self.recentTreatmentSweepInterval else { return }
        lastRecentTreatmentSweep = now
        guard let recent = try? await client.fetchTreatments(since: now.addingTimeInterval(-3600)) else { return }
        mergeTreatments(recent)
        if isAnnouncementRelayEnabled { relayAnnouncementIfNeeded(in: recent) }
    }

    /// Once per CGM cycle. See `sweepRecentTreatments`.
    static let recentTreatmentSweepInterval: TimeInterval = 5 * 60
    private var lastRecentTreatmentSweep = Date.distantPast

    private func mergeReadings(_ fresh: [GlucoseReading]) {
        var byDate: [Date: GlucoseReading] = [:]
        for reading in readings { byDate[reading.date] = reading }
        for reading in fresh { byDate[reading.date] = reading }
        readings = Array(byDate.values.sorted { $0.date > $1.date }.prefix(288))
    }

    private func refreshFull() async throws {
        var firstError: Error?
        var entriesOk = false

        defer { if entriesOk { updateSharedSnapshot() } }

        // Assign each piece independently — a partial failure keeps previously loaded data.
        do {
            let r = try await client.fetchEntries(limit: 288)
            readings = r
            entriesOk = true
        } catch is CancellationError { return }
        catch { firstError = firstError ?? RefreshError.stage("entries", error) }

        // A full sweep is 20 pages of 100 with `since: nil`. Once a window is held, read only what
        // changed and take a complete sweep again every `treatmentReconcileInterval`, so edits and
        // deletions still propagate but the steady-state cost is one page.
        let needsTreatmentSweep = treatments.isEmpty
            || Date().timeIntervalSince(lastTreatmentSweep) > Self.treatmentReconcileInterval
        // One minute of overlap absorbs clock skew between this device and the server's `srvModified`.
        let treatmentsSince: Date? = needsTreatmentSweep ? nil : lastTreatmentSync?.addingTimeInterval(-60)
        do {
            let t = try await client.fetchTreatments(since: treatmentsSince)
            if treatmentsSince == nil {
                replaceTreatments(t)
                lastTreatmentSweep = Date()
            } else {
                mergeTreatments(t)
            }
            lastTreatmentSync = Date()
            // The full sweep is a superset of what `sweepRecentTreatments` would fetch, so it also
            // satisfies the light path's throttle rather than having it re-page a minute later.
            lastRecentTreatmentSweep = Date()
            relayAnnouncementIfNeeded(in: t)
        } catch is CancellationError { return }
        catch { firstError = firstError ?? RefreshError.stage("treatments", error) }

        do {
            try await applyDeviceStatus()
        } catch is CancellationError { return }
        catch { firstError = firstError ?? RefreshError.stage("devicestatus", error) }

        // Held rather than assigned: v4 moved insulin duration out of the NS profile store into
        // `ICfg`, so `dia` is nil on every v4 profile and has to be filled from the master's
        // `insulin_configuration` cold pref — which is only fetched further down.
        let fetchedProfile = try? await client.fetchProfile()

        if let ps = try? await client.fetchProfileStore() {
            profileStore = ps
        }

        if let care = try? await client.fetchCareEvents() {
            careEvents = care
        }

        if let history = try? await client.fetchDeviceStatusHistory(since: Date().addingTimeInterval(-12 * 3600)) {
            deviceStatusHistory = history
        }

        remoteConfigError = nil
        do {
            let cold = try await client.fetchRunningConfigCold()
            remoteConfigCold = cold
            remoteCapabilities = cold?.remoteCapabilities
            evaluateOrphanVerdict(cold: cold)
        } catch is CancellationError { return }
        catch {
            rememberRemoteConfigError(error)
        }

        do {
            remoteConfigHot = try await client.fetchRunningConfigHot()
        } catch is CancellationError { return }
        catch {
            rememberRemoteConfigError(error)
        }

        // After the cold doc, so `masterInsulinConfig` reflects this refresh rather than the last one.
        if let fetchedProfile {
            profile = fetchedProfile.fillingInsulin(from: masterInsulinConfig)
        }

        connectionLost = firstError != nil
        setCredentialsInvalid(firstError.map(Self.isUnauthorized) ?? false)
        if entriesOk {
            lastRefresh = Date()
        }

        evaluateAlarms()

        // Snapshot mirroring runs via the `defer` above on every exit path.
        if let firstError {
            raiseConnectionLostIfAppropriate()
            throw firstError
        }
    }

    /// Folds the master's roster into the durable authorization verdict and notifies on the edge.
    ///
    /// Uses `currentPairingIgnoringRepair()`: the orphan question is still meaningful for a client
    /// that also needs re-pairing, and reading through the fail-closed accessor would silently stop
    /// re-evaluating exactly the installs most likely to be stale.
    private func evaluateOrphanVerdict(cold: NsRunningConfigCold?) {
        guard let pairing = clientPairingStore.currentPairingIgnoringRepair() else { return }
        let pairedAtMs = clientPairingStore.pairedAt().map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        let docSrvModifiedMs = cold?.srvModified.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        // nil roster = no evidence, exactly as `OrphanDetector.kt:92`
        // (`val roster = configuration.authorizedClients ?: return`). `.noSignal` used to be
        // unreachable from here because the mapper flattened an absent `authorizedClients` block to
        // `[]`, so any master that published a cold doc without one durably REVOKED the client:
        // persisted to the Keychain, a "removed on the master" notification, and a permanent
        // "Pair again" banner that could not fix it, because re-pairing does not make the master
        // start publishing a roster. A block that is present and empty is still a real revocation.
        let roster = (cold?.authorizedClientsPublished ?? false) ? cold?.authorizedClientIds : nil
        let verdict = OrphanDetector.evaluate(
            ownClientId: pairing.clientId,
            roster: roster,
            docSrvModifiedMs: docSrvModifiedMs,
            pairedAtMs: pairedAtMs,
            nowMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        // `.noSignal` / `.deferred` carry no evidence and must not reset what was established.
        let resolved = OrphanDetector.resolve(verdict, previous: clientPairingStore.isAuthorized)
        let wasAuthorized = clientControlAuthorized
        clientPairingStore.recordAuthorization(resolved)
        clientControlAuthorized = resolved ?? true
        guard wasAuthorized, !clientControlAuthorized else { return }
        // AAPS posts a system notification on revocation. A red Label two screens deep in Settings
        // is not a delivery mechanism for "your remote control just stopped working".
        notifier.post(
            title: String(localized: "clientcontrol.orphaned_title"),
            body: String(localized: "clientcontrol.orphaned_message"),
            identifier: "clientcontrol.revoked"
        )
    }

    /// Schedules `.connectionLost` unless it is snoozed or the real problem is the access token.
    private func raiseConnectionLostIfAppropriate() {
        // An app with no Nightscout configured has no connection to lose — every stage throws
        // `badURL` during onboarding, and alarming on that is the same "mute me before I have ever
        // shown a reading" trap `evaluateAlarms` guards against.
        guard !(client is UnconfiguredClient) else { return }
        // A rejected token is permanent and user-fixable. Telling the user their network is down,
        // forever, on every poll, is worse than saying nothing.
        guard !credentialsInvalid else { return }
        guard !alarmEngine.isSnoozed(.connectionLost, now: Date()) else { return }
        scheduleThrottled(.connectionLost)
        if !activeAlarms.contains(.connectionLost) {
            activeAlarms.append(.connectionLost)
        }
    }

    // MARK: - Alarm re-post suppression

    /// When each alarm type last actually POSTED a notification.
    private var lastAlarmPostAt: [AlarmType: Date] = [:]

    /// The most often an alarm that is already active and UNCHANGED may re-alert.
    ///
    /// `AlarmEngine.schedule` is `notifier.post` with a fixed per-type identifier: iOS replaces the
    /// pending request but re-alerts — sound, haptic, Time-Sensitive breakthrough — every single
    /// time. That was survivable while `evaluateAlarms()` ran once per poll. It now also runs once
    /// per document pushed over `/storage`, and a master uploading a devicestatus, three treatments
    /// and an entry in the same second is five socket events, so a real 52 mg/dL fired `alarm
    /// .urgentLow` five times in one second — and a post-reconnect backfill fires dozens. An alarm
    /// indistinguishable from a malfunction at the moment it matters is a safety failure: it is how
    /// a user learns to mute the app. One re-alert per CGM cycle.
    static let alarmRepostInterval: TimeInterval = 5 * 60

    private func scheduleThrottled(_ alarm: AlarmType, now: Date = Date()) {
        if let last = lastAlarmPostAt[alarm], now.timeIntervalSince(last) < Self.alarmRepostInterval {
            return
        }
        lastAlarmPostAt[alarm] = now
        alarmEngine.schedule(alarm)
    }

    private var didNotifyCredentialsInvalid = false

    /// Sets `credentialsInvalid`, and says so ONCE on the transition into it.
    ///
    /// A rejected token is permanent, user-fixable and otherwise completely invisible: the
    /// `.connectionLost` alarm is deliberately suppressed for it, and `.noData` cannot fire until
    /// the last reading ages past `staleMinutes` — after which it blames the CGM rather than the
    /// token. So a carer whose Nightscout token is revoked at 23:00 gets silence, then a misleading
    /// alarm. The follower has stopped following and nothing said so.
    ///
    /// The `alarm.` identifier prefix is load-bearing: `AlarmInterruption.apply` promotes it to
    /// `.timeSensitive`, which is right for a monitoring app that has silently stopped monitoring.
    private func setCredentialsInvalid(_ invalid: Bool) {
        defer { credentialsInvalid = invalid }
        guard invalid else {
            didNotifyCredentialsInvalid = false
            return
        }
        guard !didNotifyCredentialsInvalid else { return }
        didNotifyCredentialsInvalid = true
        notifier.post(
            title: String(localized: "home.credentials_invalid_title", defaultValue: "Nightscout rejected this token"),
            body: String(localized: "home.credentials_invalid"),
            identifier: "alarm.credentialsInvalid"
        )
    }

    /// `RefreshError.stage` wraps the transport error, so unwrap before classifying.
    private static func isUnauthorized(_ error: Error) -> Bool {
        if let stage = error as? RefreshError, case .stage(_, let inner) = stage {
            return isUnauthorized(inner)
        }
        if let ns = error as? NsError, case .unauthorized = ns { return true }
        return false
    }

    private func evaluateAlarms() {
        // An app with no Nightscout configured has nothing to be stale ABOUT, and one that has never
        // completed a single fetch cannot tell "the CGM died" from "we have not started yet". Both
        // satisfy `AlarmEngineLive`'s `.noData` conditions, so a freshly installed app posted a
        // Time-Sensitive "No Data — Glucose data is stale or missing" every 60 s foreground tick
        // while the user was still typing their Nightscout URL. That is how a user mutes an app
        // before it has ever shown a reading.
        //
        // This does not make a broken install silent: `raiseConnectionLostIfAppropriate()` runs on
        // the error path, outside this function, and is deliberately not gated here.
        guard !(client is UnconfiguredClient), lastAnyRefresh != .distantPast else {
            activeAlarms = []
            return
        }

        // `lastUpdate` now only answers "have we ever reached the server at all". Freshness is
        // measured from the reading timestamp inside the engine — see `AlarmEngineLive.evaluate`.
        // Either scope proves the link is alive, so both count here; `isStale` deliberately still
        // tracks only `lastRefresh`, because only a full refresh may satisfy `refreshIfStale()`.
        let lastSuccessfulUpdate = lastAnyRefresh
        var active: [AlarmType] = []

        // Do NOT guard on `readings.first`: an empty feed is a `.noData` condition, and guarding
        // here is exactly what made that branch unreachable for a follower that has never fetched.
        if let alarm = alarmEngine.evaluate(
            latest: readings.first,
            lastUpdate: lastSuccessfulUpdate,
            now: Date(),
            thresholds: thresholds
        ), alarm != .connectionLost {
            scheduleThrottled(alarm)
            active.append(alarm)
        }

        if let minPredBg = loopStatus?.reason?.minPredBg,
           let predictedAlarm = alarmEngine.evaluatePredictedLow(
               minPredBgMgdl: minPredBg,
               thresholdMgdl: thresholds.low,
               now: Date()
           ) {
            scheduleThrottled(predictedAlarm)
            active.append(predictedAlarm)
        }

        // A condition that CLEARED must alert again the instant it returns, so forget its post time.
        // `.connectionLost` is raised on the error path outside this function, so it is kept for as
        // long as the flag is set rather than because it appears in `active`.
        var stillRaised = Set(active)
        if connectionLost { stillRaised.insert(.connectionLost) }
        lastAlarmPostAt = lastAlarmPostAt.filter { stillRaised.contains($0.key) }

        activeAlarms = active
    }

    /// Silences the given alarms for `minutes`, both in the engine (so they stop
    /// re-firing notifications on the next refresh) and in `activeAlarms` (so the
    /// in-app banner clears immediately rather than waiting for the next refresh).
    func snoozeAlarms(_ types: [AlarmType], minutes: Int) {
        let until = Date().addingTimeInterval(Double(minutes) * 60)
        for type in types {
            alarmEngine.snooze(type, until: until)
            // Forget the last post time too, so the first evaluation after the snooze expires may
            // alert straight away rather than waiting out `alarmRepostInterval` on top of it.
            lastAlarmPostAt[type] = nil
        }
        activeAlarms.removeAll { types.contains($0) }
    }

    /// Mirror the latest reading + display config into the App Group for the widget.
    ///
    /// The snapshot is always persisted so the widget's timeline provider reads the
    /// freshest data whenever the system next asks for it.
    ///
    /// Widget reload fires only when the reading actually changed (or `force`) to
    /// stay under the timeline reload budget.
    ///
    /// Live Activity update fires only when the reading changed AND at most once every
    /// `liveActivityPushInterval` (5 min) — see `shouldPushLiveActivity`. The old comment here
    /// claimed a 60 s cadence backed by `NSSupportsLiveActivitiesFrequentUpdates`; that key governs
    /// the ActivityKit *push* budget and buys nothing without an APNs server, which this app does
    /// not have. Anyone raising the cadence is spending the local-update budget, not the push one.
    func updateSharedSnapshot(force: Bool = false) {
        sharedStore.saveConfig(DisplayConfig(units: displayUnits, thresholds: thresholds))
        var readingChanged = force
        if let latest = readings.first {
            let delta = readings.count >= 2 ? latest.mgdl - readings[1].mgdl : nil
            let snap = GlucoseSnapshot(
                mgdl: latest.mgdl, trend: latest.trend, delta: delta, date: latest.date,
                iob: loopStatus?.iob, cob: loopStatus?.cob,
                tempBasalRate: loopStatus?.tempBasalRate,
                activeProfileName: activeProfileName,
                activeProfilePercentage: activeProfileSwitch?.percentage
            )
            sharedStore.saveSnapshot(snap)

            // Push the ladder back out on every confirmed reading, whatever the keep-alive mode. If
            // the process dies before the next one, the system delivers the rungs on our behalf —
            // the only alarm path that survives a force-quit without APNs, and the one that matters
            // MOST when the audio keep-alive is off. See `setKeepAliveMode`.
            deadManSwitch.rearm(reference: latest.date)

            readingChanged = force || latest.date != lastPushedReadingDate
            if readingChanged {
                lastPushedReadingDate = latest.date
                WidgetCenter.shared.reloadAllTimelines()
            }

            updateGlucoseNotification(force: force)
        }

        if #available(iOS 16.1, *), !readings.isEmpty, isLiveActivityEnabled {
            let activityIsRunning = LiveActivityController.shared.isRunning
            let latestDate = readings[0].date
            let liveActivityReadingChanged = force || latestDate != lastLiveActivityReadingDate
            let now = Date()
            if Self.shouldPushLiveActivity(
                readingChanged: liveActivityReadingChanged,
                activityIsRunning: activityIsRunning,
                lastPushAt: lastLiveActivityPushAt,
                now: now
            ), LiveActivityController.shared.startOrUpdate(
                with: makeLAContentState(),
                staleMinutes: thresholds.staleMinutes
            ) {
                lastLiveActivityReadingDate = latestDate
                lastLiveActivityPushAt = now
            }
        }
    }

    func setGlucoseNotificationEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.glucoseNotificationEnabledKey)
        guard on else {
            glucoseNotificationPublisher.remove()
            lastNotifiedReadingDate = nil
            return
        }
        updateGlucoseNotification(force: true)
    }

    private func updateGlucoseNotification(force: Bool) {
        guard isGlucoseNotificationEnabled,
              let latest = readings.first,
              force || latest.date != lastNotifiedReadingDate else { return }
        let timeText = latest.date.formatted(date: .omitted, time: .shortened)
        glucoseNotificationPublisher.replace(with: GlucoseNotificationController.content(
            latest: latest,
            previous: readings.dropFirst().first,
            units: displayUnits,
            timeText: timeText
        ))
        lastNotifiedReadingDate = latest.date
    }

    @available(iOS 16.1, *)
    func setLiveActivityEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.liveActivityEnabledKey)
        guard on else { LiveActivityController.shared.stop(); return }
        guard let latest = readings.first else { return }
        if LiveActivityController.shared.startOrUpdate(
            with: makeLAContentState(),
            staleMinutes: thresholds.staleMinutes
        ) {
            lastLiveActivityReadingDate = latest.date
            lastLiveActivityPushAt = Date()
        }
    }

    @available(iOS 16.1, *)
    private func makeLAContentState() -> GlucoseActivityAttributes.ContentState {
        let latest = readings[0]
        let delta = readings.count >= 2 ? latest.mgdl - readings[1].mgdl : nil
        return GlucoseActivityAttributes.ContentState(
            mgdl: latest.mgdl, trendRaw: latest.trend.rawValue,
            delta: delta,
            date: latest.date, iob: loopStatus?.iob, unitsRaw: displayUnits.rawValue,
            cob: loopStatus?.cob,
            tempBasalRate: loopStatus?.tempBasalRate,
            activeProfileName: activeProfileName,
            activeProfilePercentage: activeProfileSwitch?.percentage
        )
    }

    private func relayAnnouncementIfNeeded(in treatments: [Treatment]) {
        guard isAnnouncementRelayEnabled,
              let pending = AnnouncementRelay.pendingAnnouncement(in: treatments, lastNotifiedDate: lastNotifiedAnnouncementDate) else {
            return
        }
        notifier.post(
            title: String(localized: "announcement.title"),
            body: pending.notes ?? "",
            identifier: "ns.announcement.\(pending.id)"
        )
        lastNotifiedAnnouncementDate = pending.date
    }

    private func rememberRemoteConfigError(_ error: Error) {
        if remoteConfigError == nil {
            remoteConfigError = error.localizedDescription
        }
    }

    // MARK: - Treatments

    /// Interval between complete treatment sweeps. Between them the fetch is incremental, which is
    /// additive by construction — the sweep is what lets an edit or a deletion on the master land.
    static let treatmentReconcileInterval: TimeInterval = 30 * 60
    private var lastTreatmentSweep = Date.distantPast
    private var lastTreatmentSync: Date?

    private func replaceTreatments(_ fresh: [Treatment]) {
        treatments = fresh
        runningModeRecords = RunningModeParser.records(from: fresh)
    }

    /// Union by id, newest first. Deliberately additive: an incremental fetch or a realtime push
    /// says nothing about the records it did not mention, so only the periodic sweep may remove.
    private func mergeTreatments(_ incoming: [Treatment]) {
        guard !incoming.isEmpty else { return }
        var byID: [String: Treatment] = [:]
        for treatment in treatments { byID[treatment.id] = treatment }
        for treatment in incoming { byID[treatment.id] = treatment }
        replaceTreatments(byID.values.sorted { $0.date > $1.date })
    }

    /// Mode the master is actually in, or nil when the fetched window holds no RunningMode row.
    var currentRunningMode: RunningMode? {
        RunningModeCalc.current(in: runningModeRecords)?.mode
    }

    // MARK: - Master insulin config

    /// v4 moved insulin duration out of the NS profile store into `ICfg`. `insulin_configuration` is
    /// the master's own insulin list; the first entry is the configured default.
    var masterInsulinConfig: NsInsulinConfig? {
        NsSyncedPrefsParser.insulinConfigs(from: remoteConfigCold?.syncedPrefsSnapshot.insulinConfigurationJson).first
    }

    /// Display-only: the fork tags its version with `-cust`. Gate no functionality on this.
    var isForkMaster: Bool {
        remoteConfigCold?.version?.hasSuffix("-cust") ?? false
    }

    private var lastNotifiedCarbsReq: Int?
    private var lastCarbsReqNotifiedAt: Date?

    /// At most one carbs-needed alert per three CGM cycles.
    ///
    /// This path runs from `refreshLight`, `refreshFull` AND every realtime devicestatus push, has
    /// no snooze and no user setting, and `carbsReq` legitimately oscillates by a gram or two
    /// between loop runs. Keying only on "the value changed" meant a master drifting between 8 g and
    /// 12 g overnight re-posted `loop.carbsRequired` every five minutes for hours; iOS replaces the
    /// banner but re-alerts each time.
    static let carbsRequiredRepostInterval: TimeInterval = 15 * 60

    /// `carbsReq` is the one piece of new RT telemetry a carer can act on directly.
    private func notifyCarbsRequiredIfNeeded(now: Date = Date()) {
        guard let grams = loopStatus?.carbsReq, grams > 0 else {
            lastNotifiedCarbsReq = nil
            lastCarbsReqNotifiedAt = nil
            return
        }
        guard grams != lastNotifiedCarbsReq else { return }
        if let last = lastCarbsReqNotifiedAt, now.timeIntervalSince(last) < Self.carbsRequiredRepostInterval {
            // Remember the new figure so the next change is measured against it, but stay quiet.
            lastNotifiedCarbsReq = grams
            return
        }
        lastNotifiedCarbsReq = grams
        lastCarbsReqNotifiedAt = now
        let within = loopStatus?.carbsReqWithin ?? 0
        notifier.post(
            title: String(localized: "status.carbs_required_title", defaultValue: "Carbs needed"),
            body: String(
                format: String(localized: "status.carbs_required", defaultValue: "%1$d g carbs needed within %2$d min"),
                grams,
                within
            ),
            identifier: "loop.carbsRequired"
        )
    }

    // MARK: - Master liveness / client-control gating

    /// Newest authenticated proof the master is alive.
    ///
    /// Three sources, all of them things only the master can produce: the devicestatus heartbeat
    /// (uploaded every five minutes even while the loop is stopped), a republish of either running
    /// config document, and a verified ack from the signed command channel. Never treatment or
    /// profile recency — the fork defers those by up to 300 min and does not publish the setting.
    ///
    /// The heartbeat is `lastDeviceStatusAt` — the document's UPLOAD time — never
    /// `loopStatus?.timestamp`, which dates the APS run. A user who suspends the loop deliberately
    /// still has a master that is present and uploading; keying liveness on the APS run made the app
    /// declare that master unreachable after nine minutes and then refuse to send the resume command.
    var lastMasterSignal: Date? {
        [lastDeviceStatusAt, remoteConfigCold?.srvModified, remoteConfigHot?.srvModified, lastVerifiedAckAt]
            .compactMap { $0 }
            .max()
    }

    var masterControlAvailability: MasterControlAvailability {
        ClientControlStatusResolver.availability(
            isPaired: clientPairingStore.currentPairingIgnoringRepair() != nil,
            needsRepair: clientPairingStore.needsRepair,
            authorized: clientControlAuthorized,
            // The raw published value, not the fail-open boolean: for THIS key absence genuinely
            // means "master too old", because it is the one accept-style flag that carries a SyncSpec.
            publishedClientControlEnabled: remoteCapabilities?.publishedClientControlEnabled,
            lastMasterSignal: lastMasterSignal,
            latestGlucoseMgdl: readings.first?.mgdl,
            now: Date()
        )
    }

    /// Whether a signed command may be sent right now. Gate the Prepare/Commit/Stop buttons on this
    /// and return an immediate rejection rather than burning a counter into a void.
    var masterReachable: Bool { masterControlAvailability.canSend }

    var clientControlState: ClientControlAuthorizationState {
        ClientControlStatusResolver.resolve(
            isConfigured: !(client is UnconfiguredClient),
            isPaired: clientPairingStore.currentPairingIgnoringRepair() != nil,
            needsRepair: clientPairingStore.needsRepair,
            helloAcked: clientPairingStore.helloAcked,
            pairedAt: clientPairingStore.pairedAt(),
            authorized: clientControlAuthorized,
            silentRoundTrips: silentRoundTrips,
            masterReachable: masterReachable,
            now: Date()
        )
    }

    /// Call after every `ClientControlRoundTrip` command.
    ///
    /// Feeds two things: the liveness clock (a signed answer is the strongest proof the master is
    /// there) and the counter-desync detector. Silence is the *only* client-observable signature of
    /// the master's counter gate — expiry and ControlDisabled both produce real, signed acks — so it
    /// only counts while the master is otherwise demonstrably alive.
    func recordRoundTripOutcome(_ outcome: RoundTripOutcome) {
        if ClientControlSignal.provesMasterAlive(outcome) {
            lastVerifiedAckAt = Date()
        }
        switch outcome {
        case .applied, .rejected:
            silentRoundTrips = 0
        case .unconfirmed:
            if masterReachable { silentRoundTrips += 1 }
        }
    }

    /// Clears the desync suspicion. Call after a successful re-pair.
    func resetRoundTripSilence() {
        silentRoundTrips = 0
    }

    // MARK: - Realtime (socket.io `/storage` and `/alarm`)

    /// A document pushed over the realtime socket.
    ///
    /// Additive and defensive by design: the socket is a latency optimisation, so anything
    /// unparseable is dropped and the next reconciliation poll fixes it. Never sets `connectionLost`
    /// and never schedules `.connectionLost` — a socket failure must not look like a network failure.
    func applyRealtime(_ update: NightscoutRealtimeUpdate) {
        // Removal is the reconciliation poll's job — a push tells us nothing about what else went.
        guard update.operation != .delete else { return }

        switch update.collection {
        case "entries":
            guard let fresh = try? NsMapping.glucose(from: update.resultArrayEnvelope), !fresh.isEmpty else { return }
            mergeReadings(fresh)
            // A pushed reading proves the link is alive, exactly like a successful light refresh.
            lastLightRefresh = Date()
            connectionLost = false

        case "devicestatus":
            // A pushed document is one record, so a pump-only keep-alive still maps to nil here —
            // but it is proof the master uploaded just now, which is what the liveness clock wants.
            if let heartbeat = try? NsMapping.deviceStatusHeartbeat(from: update.resultArrayEnvelope) {
                lastDeviceStatusAt = max(lastDeviceStatusAt ?? .distantPast, heartbeat)
            }
            guard let status = try? NsMapping.loopStatus(from: update.resultArrayEnvelope) else { return }
            loopStatus = status
            notifyCarbsRequiredIfNeeded()

        case "treatments":
            guard let fresh = try? NsMapping.treatments(from: update.resultArrayEnvelope), !fresh.isEmpty else { return }
            mergeTreatments(fresh)
            relayAnnouncementIfNeeded(in: fresh)

        case "profile":
            if let p = try? NsMapping.profile(from: update.resultArrayEnvelope) {
                profile = p.fillingInsulin(from: masterInsulinConfig)
            }
            if let ps = try? NsMapping.profileStore(from: update.resultArrayEnvelope) { profileStore = ps }

        case "settings":
            applyRealtimeSettings(update)

        default:
            return
        }

        evaluateAlarms()
        updateSharedSnapshot()
    }

    private func applyRealtimeSettings(_ update: NightscoutRealtimeUpdate) {
        guard let identifier = update.identifier,
              let document = try? NsMapping.settingsDocument(from: update.resultObjectEnvelope, identifier: identifier)
        else { return }
        switch identifier {
        case NightscoutSettingsIdentifier.cold:
            if let cold = try? NsMapping.runningConfigCold(from: document) {
                remoteConfigCold = cold
                remoteCapabilities = cold.remoteCapabilities
                evaluateOrphanVerdict(cold: cold)
            }
        case NightscoutSettingsIdentifier.state:
            if let hot = try? NsMapping.runningConfigHot(from: document) {
                remoteConfigHot = hot
            }
        default:
            break
        }
    }

    /// An `/alarm` push. Relayed as a plain notification only — it must NOT enter `AlarmEngine`,
    /// whose thresholds and snooze state are computed from the local reading, and which would then
    /// double-fire against the server's own alarm logic.
    func applyRealtimeAlarm(_ alarm: NightscoutRealtimeAlarm) {
        guard alarm.isAnnouncement, isAnnouncementRelayEnabled else { return }
        let body = alarm.message ?? alarm.title ?? ""
        guard !body.isEmpty else { return }
        notifier.post(
            title: String(localized: "announcement.title"),
            body: body,
            identifier: "ns.realtime.announcement"
        )
    }
}
