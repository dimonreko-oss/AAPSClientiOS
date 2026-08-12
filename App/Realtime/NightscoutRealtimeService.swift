import Combine
import Foundation
import os

/// A single Nightscout document pushed over the `/storage` namespace.
///
/// Carries raw JSON rather than a parsed dictionary so it can cross from the socket actor to the
/// main actor without a data race, and so the existing `NsMapping` entry points can be reused
/// verbatim via the two envelope helpers below — realtime and polling must never grow two
/// divergent parsers for the same document.
struct NightscoutRealtimeUpdate {
    enum Operation: String {
        case create
        case update
        case delete
    }

    let operation: Operation
    /// `entries` | `treatments` | `devicestatus` | `profile` | `settings`
    let collection: String
    /// The document object. For `delete` Nightscout sends no document, so this is the raw event
    /// (`{"colName":…,"identifier":…}`) and only `identifier` is meaningful.
    let json: String
    let srvModified: Date?

    var document: [String: Any] {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else { return [:] }
        return object
    }

    var identifier: String? { document["identifier"] as? String }

    /// `{"result":[doc]}` — the NS v3 response envelope every array-shaped `NsMapping` mapper
    /// expects (`glucose`, `treatments`, `loopStatus`, `profile`, …).
    var resultArrayEnvelope: Data { Data(("{\"result\":[" + json + "]}").utf8) }

    /// `{"result":doc}` — the single-object envelope `NsMapping.settingsDocument(from:identifier:)`
    /// expects.
    var resultObjectEnvelope: Data { Data(("{\"result\":" + json + "}").utf8) }
}

/// A notification pushed over the `/alarm` namespace.
struct NightscoutRealtimeAlarm {
    /// `announcement` | `alarm` | `urgent_alarm` | `clear_alarm` | `notification`
    let event: String
    let json: String

    var payload: [String: Any] {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else { return [:] }
        return object
    }

    var title: String? { payload["title"] as? String }
    var message: String? { payload["message"] as? String }
    var isAnnouncement: Bool { event == "announcement" }
    var isUrgent: Bool { event == "urgent_alarm" }
    var isClear: Bool { event == "clear_alarm" }
}

/// Owns the lifecycle of `NightscoutSocketClient`: connect, backoff, suspend, resume.
///
/// Three rules this type exists to enforce, and which any caller must preserve:
///
/// 1. **The socket is an optimisation, never the source of truth.** HTTP reconciliation polling
///    stays exactly as it is. Everything here can fail — old server, no `/storage` namespace, a
///    token without read permission, a captive portal — and the app must be indistinguishable from
///    a build without realtime, minus the latency win.
/// 2. **A socket failure is never an alarm.** Nothing in this file touches `AlarmEngine` or
///    `connectionLost`. `/alarm` *contents* are forwarded to the caller; `/alarm` *transport*
///    problems are not.
/// 3. **State is visible.** A silent fallback with no diagnostic is what makes a feature like this
///    rot; `state` and `diagnosticSummary` are for Settings.
@MainActor final class NightscoutRealtimeService: ObservableObject {

    @Published private(set) var state: NightscoutRealtimeState = .disconnected
    /// Last inbound document or alarm. A liveness signal for the UI, independent of poll success.
    @Published private(set) var lastEventAt: Date?
    @Published private(set) var lastFailureReason: String?
    /// What `/storage` actually authorized us for, which may be less than we asked for.
    @Published private(set) var grantedCollections: [String] = []

    /// Bound by the app to `AppStore.applyRealtime(_:)`. Invoked on the main actor.
    var onDocument: (@MainActor (NightscoutRealtimeUpdate) -> Void)?
    /// Bound by the app to the alarm/announcement relay. Invoked on the main actor.
    var onAlarm: (@MainActor (NightscoutRealtimeAlarm) -> Void)?

    static let baseBackoff: TimeInterval = 2
    static let maxBackoff: TimeInterval = 120
    /// A server that has no `/storage` namespace will not grow one this hour. Park rather than
    /// reconnect-loop, but do re-probe eventually so a Nightscout upgrade is picked up.
    static let unsupportedRetryInterval: TimeInterval = 6 * 3600
    /// How long a connection must SURVIVE before it counts as healthy enough to reset the backoff.
    ///
    /// Resetting `attempt` on the subscribe ack alone made the backoff dead code against the one
    /// failure mode that actually persists: a reverse proxy, Heroku-style router or carrier NAT with
    /// a ~55 s idle timeout. Each cycle acked, reset the counter, dropped, and reconnected at the
    /// 1–2 s floor — a TLS handshake, an Engine.IO handshake and two authenticated subscribes every
    /// minute, all night, while the audio keep-alive holds the process.
    static let stableConnectionThreshold: TimeInterval = 120

    private let credentialsProvider: @MainActor () -> (url: URL, token: String)?
    private let subscribeToAlarms: Bool
    private let log = Logger(subsystem: "com.nightaps.aapsclientios", category: "Realtime")

    private var client: NightscoutSocketClient?
    private var retry: Task<Void, Never>?
    private var isActive = false
    private var attempt = 0
    private var liveNamespaces: Set<String> = []
    /// When the current connection first subscribed. See `stableConnectionThreshold`.
    private var connectedSince: Date?
    private var unsupportedSince: Date?
    private var highWaterMarks: [String: Int64] = [:]

    init(
        subscribeToAlarms: Bool = true,
        credentialsProvider: @escaping @MainActor () -> (url: URL, token: String)?
            = NightscoutRealtimeService.keychainCredentials
    ) {
        self.subscribeToAlarms = subscribeToAlarms
        self.credentialsProvider = credentialsProvider
    }

    /// Same source of truth as `AppStore.ensureConfigured()`.
    static func keychainCredentials() -> (url: URL, token: String)? {
        let keychain = SharedConstants.credentialKeychain()
        guard let raw = (try? keychain.get(.nsUrl)) ?? nil,
              let url = AppStore.normalizedURL(raw),
              let token = (try? keychain.get(.nsAccessToken)) ?? nil,
              !token.isEmpty else { return nil }
        return (url, token)
    }

    // MARK: - Diagnostics

    var isEngaged: Bool {
        if case .connected = state { return true }
        return false
    }

    /// One-line technical diagnostic for Settings. Deliberately unlocalized: it names protocol
    /// versions and namespaces, and its whole purpose is to be pasted into a bug report.
    var diagnosticSummary: String {
        switch state {
        case .disconnected:
            if let reason = lastFailureReason { return "off — \(reason)" }
            return "off"
        case .connecting:
            return "connecting…"
        case .connected(let eio, let namespace):
            return "on — Engine.IO \(eio), \(namespace)"
        }
    }

    /// Newest `srvModified` seen live for a collection. The reconciliation poll should resume from
    /// here so the window missed while disconnected is backfilled exactly once.
    func highWaterMark(for collection: String) -> Date? {
        guard let millis = highWaterMarks[collection] else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isActive else { return }
        if let since = unsupportedSince {
            guard Date().timeIntervalSince(since) >= Self.unsupportedRetryInterval else { return }
            unsupportedSince = nil
        }
        guard credentialsProvider() != nil else { return }
        isActive = true
        attempt = 0
        connectNow()
    }

    /// Hard stop. Emits nothing and arms no retry — a socket left half-open across a process
    /// suspension is worse than no socket, because the server keeps pushing into a dead pipe and we
    /// only find out at the next `pingTimeout`.
    func stop() {
        isActive = false
        retry?.cancel()
        retry = nil
        connectedSince = nil
        liveNamespaces.removeAll()
        grantedCollections = []
        state = .disconnected
        discardClient()
    }

    private func discardClient() {
        guard let previous = client else { return }
        client = nil
        Task { @MainActor in await previous.disconnect() }
    }

    /// Foreground or wake.
    func applicationWillEnterForeground() {
        start()
    }

    /// Backgrounding. The socket may only survive while the audio keep-alive holds the process.
    func applicationDidEnterBackground(keepAliveActive: Bool) {
        if keepAliveActive {
            start()
        } else {
            stop()
        }
    }

    /// Credentials or server changed: drop everything and re-probe from scratch.
    func reconnect() {
        unsupportedSince = nil
        lastFailureReason = nil
        stop()
        start()
    }

    // MARK: - Connection

    private func connectNow() {
        guard isActive, let credentials = credentialsProvider() else { return }
        // Never leave a previous socket half-open behind a new one.
        discardClient()
        state = .connecting
        let socket = NightscoutSocketClient(
            baseURL: credentials.url,
            accessToken: credentials.token,
            subscribeToAlarms: subscribeToAlarms,
            emit: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
        )
        client = socket
        Task { @MainActor in await socket.connect() }
    }

    /// Exponential backoff with jitter. Jitter matters here because every follower of the same
    /// Nightscout reconnects on the same restart; the floor is half the window so a slow server
    /// still gets steadily rarer retries rather than a stampede.
    static func backoffDelay(
        attempt: Int,
        random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 6)
        let window = min(baseBackoff * pow(2.0, Double(exponent)), maxBackoff)
        return random((window / 2)...window)
    }

    private func scheduleReconnect(reason: String) {
        guard isActive else { return }
        lastFailureReason = reason
        state = .disconnected
        attempt += 1
        let delay = Self.backoffDelay(attempt: attempt)
        retry?.cancel()
        retry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connectNow()
        }
    }

    // MARK: - Inbound

    private func handle(_ event: NightscoutSocketEvent) {
        switch event {
        case .subscribed(let namespace, let eio, let collections):
            // Start the clock, do NOT reset the backoff yet — the connection has to stay up first.
            if connectedSince == nil { connectedSince = Date() }
            lastFailureReason = nil
            liveNamespaces.insert(namespace)
            if namespace == NightscoutSocketClient.storageNamespace {
                grantedCollections = collections
            }
            state = .connected(eio: eio, namespace: Self.describe(liveNamespaces))
            log.info("realtime engaged: Engine.IO \(eio, privacy: .public)")

        case .unavailable(let namespace, let reason):
            liveNamespaces.remove(namespace)
            guard namespace == NightscoutSocketClient.storageNamespace else {
                // `/alarm` is optional — losing it must not cost us the document stream.
                if case .connected(let eio, _) = state {
                    state = .connected(eio: eio, namespace: Self.describe(liveNamespaces))
                }
                return
            }
            // No document stream on this server (pre-14.2, or a token without read permission).
            // Reconnecting would only reopen a socket that cannot work.
            stop()
            unsupportedSince = Date()
            lastFailureReason = reason

        case .closed(let reason):
            // Only a connection that lasted counts as proof the server is healthy; a 55 s flap must
            // let the backoff grow instead of resetting it every cycle.
            if let since = connectedSince, Date().timeIntervalSince(since) >= Self.stableConnectionThreshold {
                attempt = 0
            }
            connectedSince = nil
            liveNamespaces.removeAll()
            grantedCollections = []
            scheduleReconnect(reason: reason)

        case .document(let operation, let collection, let json, let srvModifiedMs):
            lastEventAt = Date()
            if let srvModifiedMs {
                highWaterMarks[collection] = max(highWaterMarks[collection] ?? 0, srvModifiedMs)
            }
            guard let parsedOperation = NightscoutRealtimeUpdate.Operation(rawValue: operation) else { return }
            onDocument?(NightscoutRealtimeUpdate(
                operation: parsedOperation,
                collection: collection,
                json: json,
                srvModified: srvModifiedMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            ))

        case .alarm(let name, let json):
            lastEventAt = Date()
            onAlarm?(NightscoutRealtimeAlarm(event: name, json: json))
        }
    }

    private static func describe(_ namespaces: Set<String>) -> String {
        namespaces.sorted().joined(separator: ",")
    }
}
