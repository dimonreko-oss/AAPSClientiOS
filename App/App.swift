import SwiftUI
import BackgroundTasks
import UserNotifications
import AVFoundation

@main
struct AAPSClientApp: App {
    @StateObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    private let writer: NsTreatmentWriter
    private let bgScheduler: BackgroundScheduler
    private let keepAlive: AudioKeepAlive
    private let backgroundTick = BackgroundTickCoordinator()

    init() {
        // Credentials live on the shared keychain group so the widget can read them. Move them once
        // out of the legacy default-group location — `migrate` removes the source, so this is
        // self-terminating. The wrapper (rather than a bare `try?`) matters: it falls back to the
        // historical unscoped lookup if the app-private group turns out not to be usable under this
        // build's provisioning profile, instead of silently stranding a pre-widget install's token.
        let keychain = SharedConstants.credentialKeychain()
        SharedConstants.migrateLegacyCredentials(into: keychain)
        let rawUrl = (try? keychain.get(.nsUrl)) ?? nil
        let nsUrl = rawUrl.flatMap(AppStore.normalizedURL)
        let accessToken = (try? keychain.get(.nsAccessToken)) ?? ""

        // Self-heal accessibility for installs whose credentials were written by an
        // earlier build with the default WhenUnlocked class: re-set the values we just
        // read so they're rewritten as AfterFirstUnlock. Only runs when the device is
        // unlocked (otherwise the reads above already returned nil); harmless and
        // idempotent thereafter.
        if let rawUrl { try? keychain.set(rawUrl, for: .nsUrl) }
        if !accessToken.isEmpty { try? keychain.set(accessToken, for: .nsAccessToken) }

        let client: NightscoutClient
        if let url = nsUrl, !accessToken.isEmpty {
            client = NightscoutClientLive(baseURL: url, accessToken: accessToken, transport: URLSessionTransport())
        } else {
            client = UnconfiguredClient()
        }

        let alarmEngine = AlarmEngineLive(notifier: UNNotifier())
        let store = AppStore(
            client: client,
            alarmEngine: alarmEngine,
            glucoseNotificationPublisher: GlucoseNotificationController(),
            // The pre-scheduled ladder is the only alarm path that survives process death, so the
            // real implementation belongs here even though every test uses the dummy.
            deadManSwitch: DeadManSwitch()
        )
        _store = StateObject(wrappedValue: store)
        writer = NsTreatmentWriterLive(clientProvider: { [store] in store.client })
        // Built locally first so the scheduler's onWake closure can capture it
        // without touching `self`, which is not yet fully initialized here.
        let keepAlive = AudioKeepAlive()
        self.keepAlive = keepAlive
        // A BGAppRefresh wake-up is the only way back if the audio keep-alive
        // died while the process was suspended.
        bgScheduler = BackgroundScheduler(
            store: store,
            onWake: { keepAlive.ensurePlaying() },
            onResurrect: {
                // BGProcessing draws from a separate, charging/idle-biased budget and is the
                // resurrection path: audio, the socket and the dead-man ladder all die with a
                // suspended process. Re-drive the keep-alive and the socket from scratch.
                keepAlive.enterBackground(
                    mode: store.keepAliveMode,
                    nextDelay: { BackgroundPollSchedule.aggressiveInterval },
                    onTick: { Task { try? await store.refresh(scope: .light) } }
                )
                store.realtime.applicationDidEnterBackground(
                    keepAliveActive: keepAlive.isAudioKeepAliveEnabled && store.keepAliveMode.shouldKeepAlive
                )
            }
        )
        // BGTaskScheduler launch handlers MUST be registered before the app finishes
        // launching. Registering from a SwiftUI `.task` (post-launch) throws an
        // uncaught NSException ("All launch handlers must be registered before
        // application finishes launching") on iOS 16/18 and Mac alike.
        bgScheduler.register()
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    HomeView(store: store, writer: writer)
                }
                .tabItem { Label("tab.home", systemImage: "house") }

                NavigationStack {
                    HistoryView(store: store)
                }
                .tabItem { Label("tab.history", systemImage: "clock") }

                NavigationStack {
                    SettingsView(store: store, writer: writer)
                }
                .tabItem { Label("tab.settings", systemImage: "gear") }

                NavigationStack {
                    StatisticsView(store: store)
                }
                .tabItem { Label("Statistics", systemImage: "chart.bar") }
            }
            .task {
                bgScheduler.schedule()
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                // Initial data refresh is owned by HomeView (.task) so errors surface there.
                // Start foreground polling here too: `.onChange(of: scenePhase)` only fires on
                // a transition observed *after* this view mounts, and on a cold launch the
                // scene is already `.active` by the time it mounts — so that handler's
                // `.active` case never fires and the 60 s timer never starts until the user
                // backgrounds/foregrounds the app at least once.
                backgroundTick.reset()
                // Realtime is a pure latency optimisation layered over the existing poll: it never
                // becomes the only path to data, and a failure here is silent by construction.
                store.realtime.start()
                enterForeground()
            }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    // Foreground polling. The tick is light by default and takes the ~28-request
                    // full pass only on the five-minute cadence — see `AppStore.refreshForeground`.
                    backgroundTick.reset()
                    store.realtime.applicationWillEnterForeground()
                    enterForeground()
                case .background:
                    bgScheduler.schedule()
                    enterBackground(mode: store.keepAliveMode)
                default:
                    break
                }
            }
            .onChange(of: store.keepAliveMode) { mode in
                // The setting has to bite immediately: writing UserDefaults alone left a playing
                // AVAudioPlayer and a live watchdog running in a mode the user explicitly switched
                // off, and left the socket open on a process that is about to be suspended.
                if scenePhase == .background {
                    enterBackground(mode: mode)
                } else {
                    enterForeground()
                }
            }
        }
    }

    // `@MainActor` explicitly, even though the SDK's `@MainActor @preconcurrency App` conformance
    // already infers it for the whole type today: both of these synchronously touch main-actor state
    // (`backgroundTick`, `store`), and the isolation should not rest on an inference that a future
    // toolchain might narrow to just the `body`/`init` witnesses.
    @MainActor
    private func enterForeground() {
        keepAlive.enterForeground { Task { await store.refreshForeground() } }
    }

    @MainActor
    private func enterBackground(mode: KeepAliveMode) {
        keepAlive.enterBackground(
            mode: mode,
            nextDelay: {
                backgroundTick.nextDelay(
                    mode: mode,
                    lastReadingDate: store.readings.first?.date
                )
            },
            onTick: { Task { await backgroundTick.tick(store: store) } }
        )
        // Hard stop unless the audio keep-alive is actually going to hold the process: a socket that
        // survives into suspension wedges half-open and the server keeps pushing into a dead pipe
        // until `pingTimeout`.
        store.realtime.applicationDidEnterBackground(
            keepAliveActive: keepAlive.isAudioKeepAliveEnabled && mode.shouldKeepAlive
        )
    }
}

final class UnconfiguredClient: NightscoutClient, @unchecked Sendable {
    func authorize() async throws { throw NsError.badURL }
    func fetchEntries(limit: Int) async throws -> [GlucoseReading] { throw NsError.badURL }
    func fetchTreatments(since: Date?) async throws -> [Treatment] { throw NsError.badURL }
    func fetchDeviceStatus() async throws -> LoopStatus? { throw NsError.badURL }
    func fetchDeviceStatusHeartbeat() async throws -> Date? { throw NsError.badURL }
    func fetchProfile() async throws -> NsProfile { throw NsError.badURL }
    func fetchProfileStore() async throws -> NsProfileStore { throw NsError.badURL }
    func fetchSettings(identifier: String) async throws -> NsSettingsDocument? { throw NsError.badURL }
    func putSettings(identifier: String, document: [String: Any]) async throws { throw NsError.badURL }
    /// Explicit rather than inheriting the protocol's no-op default, so an unconfigured app reports
    /// "no Nightscout" for every operation instead of silently succeeding at one of them.
    func deleteSettings(identifier: String) async throws { throw NsError.badURL }
    func searchSettings(limit: Int) async throws -> [NsSettingsDocument] { throw NsError.badURL }
    func fetchRunningConfigCold() async throws -> NsRunningConfigCold? { throw NsError.badURL }
    func fetchRunningConfigHot() async throws -> NsRunningConfigHot? { throw NsError.badURL }
    func postTreatment(_ payload: [String: Any]) async throws { throw NsError.badURL }
}
