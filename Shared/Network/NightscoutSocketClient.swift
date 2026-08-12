import Foundation
import os

// MARK: - Protocol reference
//
// Everything below is hand-rolled on top of `URLSessionWebSocketTask`; there is no socket.io
// dependency. The framing is small enough to own, and owning it is what lets us negotiate the
// Engine.IO version instead of hardcoding one.
//
// Engine.IO — https://github.com/socketio/engine.io-protocol
//   A websocket frame carries exactly one packet: "<type digit><payload>", where the digits are
//   0 open · 1 close · 2 ping · 3 pong · 4 message · 5 upgrade · 6 noop. (The `\x1e` record
//   separator and base64 payloads only exist on the HTTP long-polling transport, which we skip.)
//
//   v4 (socket.io 3.x/4.x): the handshake `open` payload is
//   {"sid":…,"upgrades":[…],"pingInterval":…,"pingTimeout":…,"maxPayload":…} and the heartbeat is
//   SERVER driven — the server sends "2" and the client must answer "3".
//
//   v3 (socket.io 2.x, which cgm-remote-monitor shipped before it moved to socket.io 4): identical
//   digits, no `maxPayload` in the handshake, and the heartbeat is CLIENT driven — we send "2"
//   every `pingInterval` and the server answers "3".
//
//   Why we cannot trust the `EIO=` query parameter we asked for: engine.io 3.x servers never
//   validated it, so an old server answers an `EIO=4` request perfectly happily and then keeps
//   speaking v3. Getting that wrong is silent — nobody pings, and the server drops us on
//   `pingTimeout`. `maxPayload` is the in-band discriminator (see `EngineIOHandshake`), and an
//   `EIO=3` retry covers the opposite direction, where a v4-only server rejects the upgrade.
//
// Socket.IO — https://github.com/socketio/socket.io-protocol
//   Rides inside an Engine.IO `message` (leading "4"):
//     "<type>[<attachments>-][<namespace>,][<ackId>]<json>"
//     0 CONNECT · 1 DISCONNECT · 2 EVENT · 3 ACK · 4 CONNECT_ERROR · 5 BINARY_EVENT · 6 BINARY_ACK
//   e.g. "40/storage,"                       connect to a namespace
//        "42/storage,0[\"subscribe\",{…}]"   event carrying ack id 0
//        "43/storage,0[{\"success\":true}]"  the server's ack for it
//   Revision 4 (socket.io 2.x) omits the trailing comma when a namespaced packet has no payload
//   and encodes errors as a bare JSON string; revision 5 (socket.io 3+) always sends an object and
//   allows an auth payload on CONNECT. The decoder here accepts both shapes.
//
// Nightscout surface — cgm-remote-monitor `lib/api3/storageSocket.js` and `lib/api3/alarmSocket.js`,
// both introduced with API v3 in NS 14.2. Older servers answer CONNECT_ERROR "Invalid namespace",
// which is the case this client must degrade out of silently.
//   /storage  emit "subscribe" {accessToken, collections:[…]}
//             → ack {success:true, collections:[…]} | {success:false, message:…}
//             then "create"/"update"/"delete" with {colName, doc}
//   /alarm    emit "subscribe" {accessToken}
//             → ack {success, message}
//             then "announcement"/"alarm"/"urgent_alarm"/"clear_alarm"/"notification"
//   The legacy root namespace (`lib/server/websocket.js`, the `authorize` → `dataUpdate` flow) is
//   deliberately NOT used: it authenticates with the api-secret hash rather than an access token,
//   and it pushes a whole recomputed dashboard payload rather than per-document deltas.
//
// This mirrors the AAPS reference client, `NSClientV3Service.kt`
// (`onConnectStorage` / `onConnectAlarms` / `onDataCreateUpdate`), which uses the same two
// namespaces, the same subscribe payload and the same collection list.

// MARK: - Connection state

/// Whether realtime actually engaged. Surfaced in Settings on purpose: a silent fallback to HTTP
/// polling with no diagnostic is exactly what lets this feature rot unnoticed.
enum NightscoutRealtimeState: Equatable, Sendable {
    case disconnected
    case connecting
    /// - Parameter namespace: the live namespaces, comma-joined (`/storage`, `/storage,/alarm`).
    case connected(eio: Int, namespace: String)
}

// MARK: - Engine.IO codec

enum EngineIOPacket: Equatable, Sendable {
    case open(String)
    case close
    case ping(String)
    case pong(String)
    case message(String)
    case upgrade
    case noop
    case unknown(String)

    var encoded: String {
        switch self {
        case .open(let payload):    return "0" + payload
        case .close:                return "1"
        case .ping(let payload):    return "2" + payload
        case .pong(let payload):    return "3" + payload
        case .message(let payload): return "4" + payload
        case .upgrade:              return "5"
        case .noop:                 return "6"
        case .unknown(let raw):     return raw
        }
    }

    static func decode(_ frame: String) -> EngineIOPacket {
        guard let first = frame.first else { return .unknown(frame) }
        let payload = String(frame.dropFirst())
        switch first {
        case "0": return .open(payload)
        case "1": return .close
        case "2": return .ping(payload)
        case "3": return .pong(payload)
        case "4": return .message(payload)
        case "5": return .upgrade
        case "6": return .noop
        default:  return .unknown(frame)
        }
    }
}

/// The parsed Engine.IO `open` payload.
struct EngineIOHandshake: Equatable, Sendable {
    let sid: String
    /// Milliseconds.
    let pingInterval: Int
    /// Milliseconds.
    let pingTimeout: Int
    /// True when the server advertised `maxPayload`, which only Engine.IO 4 does. It is also the
    /// only in-band way to tell the two heartbeat directions apart — see the note at the top.
    let serverDrivenHeartbeat: Bool

    var engineIOVersion: Int { serverDrivenHeartbeat ? 4 : 3 }

    static func decode(_ payload: String) -> EngineIOHandshake? {
        guard let data = payload.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any],
              let sid = object["sid"] as? String else { return nil }
        return EngineIOHandshake(
            sid: sid,
            pingInterval: (object["pingInterval"] as? NSNumber)?.intValue ?? 25_000,
            pingTimeout: (object["pingTimeout"] as? NSNumber)?.intValue ?? 20_000,
            serverDrivenHeartbeat: object["maxPayload"] != nil
        )
    }
}

// MARK: - Socket.IO codec

enum SocketIOPacket: Equatable, Sendable {
    case connect(namespace: String, payload: String?)
    case disconnect(namespace: String)
    case event(namespace: String, ackId: Int?, payload: String)
    case ack(namespace: String, ackId: Int?, payload: String)
    case connectError(namespace: String, payload: String?)
    /// Binary attachments are never used by Nightscout; modelled only so the decoder is total.
    case binary(namespace: String)
    case unknown(String)

    var encoded: String {
        switch self {
        case .connect(let namespace, let payload):
            return "0" + Self.prefix(namespace, nil) + (payload ?? "")
        case .disconnect(let namespace):
            return "1" + Self.prefix(namespace, nil)
        case .event(let namespace, let ackId, let payload):
            return "2" + Self.prefix(namespace, ackId) + payload
        case .ack(let namespace, let ackId, let payload):
            return "3" + Self.prefix(namespace, ackId) + payload
        case .connectError(let namespace, let payload):
            return "4" + Self.prefix(namespace, nil) + (payload ?? "")
        case .binary(let namespace):
            return "5" + Self.prefix(namespace, nil)
        case .unknown(let raw):
            return raw
        }
    }

    private static func prefix(_ namespace: String, _ ackId: Int?) -> String {
        var out = ""
        if namespace != "/" { out += namespace + "," }
        if let ackId { out += String(ackId) }
        return out
    }

    static func decode(_ text: String) -> SocketIOPacket {
        var rest = text[...]
        guard let typeCharacter = rest.first,
              typeCharacter.isASCII, typeCharacter.isNumber,
              let type = Int(String(typeCharacter)) else { return .unknown(text) }
        rest = rest.dropFirst()

        // Optional "<n>-" binary attachment count, only ever present on BINARY_EVENT / BINARY_ACK.
        if type == 5 || type == 6, let dash = rest.firstIndex(of: "-") {
            rest = rest[rest.index(after: dash)...]
        }

        var namespace = "/"
        if rest.first == "/" {
            if let comma = rest.firstIndex(of: ",") {
                namespace = String(rest[rest.startIndex..<comma])
                rest = rest[rest.index(after: comma)...]
            } else {
                // socket.io 2.x drops the separator when nothing follows the namespace.
                namespace = String(rest)
                rest = rest[rest.endIndex...]
            }
        }

        var ackId: Int?
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty {
            ackId = Int(digits)
            rest = rest.dropFirst(digits.count)
        }

        let payload: String? = rest.isEmpty ? nil : String(rest)

        switch type {
        case 0: return .connect(namespace: namespace, payload: payload)
        case 1: return .disconnect(namespace: namespace)
        case 2: return .event(namespace: namespace, ackId: ackId, payload: payload ?? "[]")
        case 3: return .ack(namespace: namespace, ackId: ackId, payload: payload ?? "[]")
        case 4: return .connectError(namespace: namespace, payload: payload)
        case 5, 6: return .binary(namespace: namespace)
        default: return .unknown(text)
        }
    }
}

/// A Socket.IO EVENT/ACK argument array split into its event name and the remaining arguments.
struct SocketIOEventArguments {
    let name: String
    let arguments: [Any]

    /// `["create", {...}]` → name "create", one argument.
    static func parse(_ json: String) -> SocketIOEventArguments? {
        guard let array = parseArray(json), let name = array.first as? String else { return nil }
        return SocketIOEventArguments(name: name, arguments: Array(array.dropFirst()))
    }

    /// An ACK payload has no leading name — it is just the callback's arguments.
    static func parseArray(_ json: String) -> [Any]? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let array = parsed as? [Any] else { return nil }
        return array
    }
}

// MARK: - Events handed upwards

/// Everything the socket reports is `Sendable` (strings, not parsed dictionaries) so it can cross
/// from the actor to `@MainActor` without a data race. Parsing happens on the consuming side, which
/// already owns the domain mappers.
enum NightscoutSocketEvent: Equatable, Sendable {
    /// The namespace accepted our `subscribe`. `collections` is what the server actually authorized,
    /// which may be a subset of what we asked for.
    case subscribed(namespace: String, eio: Int, collections: [String])
    /// The namespace will never work on this server/token: pre-14.2 Nightscout, a token without the
    /// required read permission, or an explicit refusal. Terminal for that namespace — the caller
    /// stays on HTTP polling. This must never reach the alarm engine.
    case unavailable(namespace: String, reason: String)
    /// A `/storage` create/update/delete. `json` is the `doc` object for create/update, and the raw
    /// event object (`{colName, identifier}`) for delete, which carries no document.
    case document(operation: String, collection: String, json: String, srvModifiedMs: Int64?)
    /// An `/alarm` announcement/alarm/urgent_alarm/clear_alarm/notification, with its payload object.
    case alarm(event: String, json: String)
    /// The transport dropped. The owner reconnects with backoff.
    case closed(reason: String)
}

// MARK: - Client

/// Dependency-free Nightscout realtime client.
///
/// Deliberately a *latency optimisation and a liveness signal*, never a source of truth: every
/// failure path here ends in `.unavailable` or `.closed` and the app keeps its HTTP reconciliation
/// poll. Nothing in this file may raise an alarm or surface a user-visible error.
actor NightscoutSocketClient {
    static let storageNamespace = "/storage"
    static let alarmNamespace = "/alarm"
    /// Matches the AAPS reference client's list minus `foods`, which this app does not read.
    static let defaultCollections = ["entries", "treatments", "devicestatus", "profile", "settings"]
    /// A server that accepts the transport but never answers our namespace CONNECT would otherwise
    /// leave the client parked in `connecting` forever, with no reconnect and no diagnostic.
    static let subscribeTimeout: TimeInterval = 20

    private let baseURL: URL
    /// The Nightscout *access token*, not the JWT: `storageSocket.subscribe` calls
    /// `authorization.resolveAccessToken`. Never interpolated into a logged string.
    private let accessToken: String
    private let collections: [String]
    private let subscribeToAlarms: Bool
    private let session: URLSession
    private let emit: @Sendable (NightscoutSocketEvent) -> Void
    private let log = Logger(subsystem: "com.nightaps.aapsclientios", category: "Realtime")

    private var task: URLSessionWebSocketTask?
    private var pump: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var handshake: EngineIOHandshake?
    private var nextAckId = 0
    private var pendingSubscribes: [Int: String] = [:]
    private var subscribedNamespaces: Set<String> = []
    private var isRunning = false

    init(
        baseURL: URL,
        accessToken: String,
        collections: [String] = NightscoutSocketClient.defaultCollections,
        subscribeToAlarms: Bool = true,
        session: URLSession = .shared,
        emit: @escaping @Sendable (NightscoutSocketEvent) -> Void
    ) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.collections = collections
        self.subscribeToAlarms = subscribeToAlarms
        self.session = session
        self.emit = emit
    }

    /// `https://host/base/` → `wss://host/base/socket.io/?EIO=<v>&transport=websocket`.
    /// Keeps any sub-path the user's Nightscout is mounted under.
    static func socketURL(base: URL, eio: Int) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        switch (components.scheme ?? "").lowercased() {
        case "https", "wss": components.scheme = "wss"
        case "http", "ws":   components.scheme = "ws"
        default: return nil
        }
        var path = components.path
        if !path.hasSuffix("/") { path += "/" }
        components.path = path + "socket.io/"
        components.queryItems = [
            URLQueryItem(name: "EIO", value: String(eio)),
            URLQueryItem(name: "transport", value: "websocket")
        ]
        return components.url
    }

    /// Opens the transport, negotiating the Engine.IO version. Returns as soon as the handshake
    /// succeeds; namespace connect + subscribe complete asynchronously and report via `emit`.
    func connect() async {
        guard !isRunning else { return }
        isRunning = true
        // v4 first — it is what every current server wants, and a v3 server tolerates the query
        // parameter rather than rejecting it. The retry covers a v4-only server refusing `EIO=3`.
        for eio in [4, 3] {
            guard isRunning else { return }
            if await openTransport(eio: eio) { return }
        }
        isRunning = false
        log.info("realtime handshake failed on both Engine.IO 4 and 3; staying on HTTP polling")
        emit(.closed(reason: "handshake failed"))
    }

    /// Caller-initiated stop. Silent by design: no `.closed` is emitted, so the owner's backoff
    /// does not treat a deliberate suspend as a failure to retry.
    func disconnect() {
        isRunning = false
        pump?.cancel()
        pump = nil
        teardownTransport()
    }

    // MARK: - Transport

    private func openTransport(eio: Int) async -> Bool {
        guard let url = Self.socketURL(base: baseURL, eio: eio) else { return false }
        let socket = session.webSocketTask(with: url)
        socket.resume()
        do {
            let frame = try await Self.receiveText(socket)
            guard case .open(let payload) = EngineIOPacket.decode(frame),
                  let shake = EngineIOHandshake.decode(payload) else {
                socket.cancel(with: .goingAway, reason: nil)
                return false
            }
            task = socket
            handshake = shake
            log.info("realtime handshake ok, Engine.IO \(shake.engineIOVersion, privacy: .public)")
            startHeartbeat(shake)
            startSubscribeWatchdog()
            startPump()
            await transmit(.message(SocketIOPacket.connect(namespace: Self.storageNamespace, payload: nil).encoded))
            if subscribeToAlarms {
                await transmit(.message(SocketIOPacket.connect(namespace: Self.alarmNamespace, payload: nil).encoded))
            }
            return true
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            return false
        }
    }

    private func teardownTransport() {
        heartbeat?.cancel()
        heartbeat = nil
        watchdog?.cancel()
        watchdog = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        handshake = nil
        pendingSubscribes.removeAll()
        subscribedNamespaces.removeAll()
        nextAckId = 0
    }

    private func startSubscribeWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.subscribeTimeout * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self else { return }
            await self.dropIfNeverSubscribed()
        }
    }

    /// The transport came up but `/storage` never acknowledged. Treat it as a drop so the owner's
    /// backoff takes over rather than leaving the app pinned in `connecting`.
    ///
    /// Tests the DOCUMENT namespace specifically, not "any namespace": `/alarm` is subscribed in
    /// parallel and normally acks first, so `subscribedNamespaces.isEmpty` gave a free pass to a
    /// server that accepts `/alarm` and silently never answers `/storage` — which is precisely the
    /// case this watchdog exists for, and which nothing else covers (it is not a CONNECT_ERROR).
    private func dropIfNeverSubscribed() {
        guard isRunning, !subscribedNamespaces.contains(Self.storageNamespace) else { return }
        isRunning = false
        teardownTransport()
        emit(.closed(reason: "subscribe timed out"))
    }

    private static func receiveText(_ socket: URLSessionWebSocketTask) async throws -> String {
        switch try await socket.receive() {
        case .string(let text): return text
        case .data(let data): return String(data: data, encoding: .utf8) ?? ""
        @unknown default: return ""
        }
    }

    private func transmit(_ packet: EngineIOPacket) async {
        guard let socket = task else { return }
        // Never log the encoded frame: the subscribe event carries the access token.
        try? await socket.send(.string(packet.encoded))
    }

    private func startPump() {
        pump?.cancel()
        pump = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let keepGoing = await self.pumpOnce()
                if !keepGoing { return }
            }
        }
    }

    /// Returns false once the loop should stop.
    private func pumpOnce() async -> Bool {
        guard let socket = task else { return false }
        do {
            let frame = try await Self.receiveText(socket)
            await handle(frame: frame)
            return isRunning
        } catch {
            // A caller-initiated `disconnect()` also lands here (the receive is cancelled), so a
            // cleared `isRunning` means "expected" and must not trigger the owner's backoff.
            guard isRunning else { return false }
            isRunning = false
            teardownTransport()
            emit(.closed(reason: (error as NSError).localizedDescription))
            return false
        }
    }

    private func startHeartbeat(_ shake: EngineIOHandshake) {
        heartbeat?.cancel()
        guard !shake.serverDrivenHeartbeat else {
            // Engine.IO 4: the server pings and `handle(frame:)` answers. Nothing to schedule.
            heartbeat = nil
            return
        }
        let interval = max(1.0, Double(shake.pingInterval) / 1000.0)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.transmit(.ping(""))
            }
        }
    }

    // MARK: - Inbound

    private func handle(frame: String) async {
        switch EngineIOPacket.decode(frame) {
        case .open:
            break // only ever expected once, and `openTransport` consumed it
        case .close:
            guard isRunning else { return }
            isRunning = false
            teardownTransport()
            emit(.closed(reason: "server closed the transport"))
        case .ping(let payload):
            // Engine.IO 4 heartbeat. Echo the payload back verbatim.
            await transmit(.pong(payload))
        case .pong:
            break // Engine.IO 3: our own ping was answered
        case .message(let text):
            await handle(socketIO: SocketIOPacket.decode(text))
        case .upgrade, .noop, .unknown:
            break
        }
    }

    private func handle(socketIO packet: SocketIOPacket) async {
        switch packet {
        case .connect(let namespace, _):
            switch namespace {
            case Self.storageNamespace:
                await sendSubscribe(namespace: namespace, includeCollections: true)
            case Self.alarmNamespace:
                await sendSubscribe(namespace: namespace, includeCollections: false)
            default:
                break // the root namespace, which socket.io 2.x connects on its own
            }

        case .connectError(let namespace, let payload):
            // Pre-14.2 Nightscout answers "Invalid namespace" here. Terminal, and deliberately
            // invisible: HTTP polling remains correct on its own.
            emit(.unavailable(namespace: namespace, reason: Self.reason(from: payload)))

        case .disconnect(let namespace):
            // A server-initiated namespace DISCONNECT is a DROP, not a capability verdict. Only
            // CONNECT_ERROR means "this server/token will never serve this namespace". Emitting
            // `.unavailable` here made an ordinary Nightscout restart or dyno cycle park realtime for
            // `unsupportedRetryInterval` (six hours) with no reconnect. Losing the optional `/alarm`
            // still must not cost us the document stream, so only `/storage` closes the transport.
            subscribedNamespaces.remove(namespace)
            guard namespace == Self.storageNamespace, isRunning else {
                emit(.unavailable(namespace: namespace, reason: "namespace disconnected"))
                return
            }
            isRunning = false
            teardownTransport()
            emit(.closed(reason: "storage namespace disconnected"))

        case .ack(_, let ackId, let payload):
            guard let ackId, let namespace = pendingSubscribes.removeValue(forKey: ackId) else { return }
            handleSubscribeAck(namespace: namespace, payload: payload)

        case .event(let namespace, _, let payload):
            handleEvent(namespace: namespace, payload: payload)

        case .binary, .unknown:
            break
        }
    }

    private func sendSubscribe(namespace: String, includeCollections: Bool) async {
        var message: [String: Any] = ["accessToken": accessToken]
        if includeCollections { message["collections"] = collections }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        let ackId = nextAckId
        nextAckId += 1
        pendingSubscribes[ackId] = namespace
        let arguments = "[\"subscribe\",\(json)]"
        await transmit(.message(
            SocketIOPacket.event(namespace: namespace, ackId: ackId, payload: arguments).encoded
        ))
    }

    private func handleSubscribeAck(namespace: String, payload: String) {
        guard let arguments = SocketIOEventArguments.parseArray(payload),
              let response = arguments.first as? [String: Any] else {
            emit(.unavailable(namespace: namespace, reason: "malformed subscribe ack"))
            return
        }
        guard (response["success"] as? Bool) == true else {
            emit(.unavailable(
                namespace: namespace,
                reason: (response["message"] as? String) ?? "subscribe refused"
            ))
            return
        }
        subscribedNamespaces.insert(namespace)
        // Only the document stream counts as liveness. Cancelling on the optional `/alarm` ack would
        // disarm the watchdog before `/storage` has answered, and a `/storage` subscribe that is
        // never acked would then park the client as "connected" forever with no documents.
        if namespace == Self.storageNamespace {
            watchdog?.cancel()
            watchdog = nil
        }
        let granted = (response["collections"] as? [Any])?.compactMap { $0 as? String } ?? []
        emit(.subscribed(
            namespace: namespace,
            eio: handshake?.engineIOVersion ?? 4,
            collections: granted
        ))
    }

    private func handleEvent(namespace: String, payload: String) {
        guard let parsed = SocketIOEventArguments.parse(payload) else { return }
        switch namespace {
        case Self.storageNamespace:
            guard ["create", "update", "delete"].contains(parsed.name),
                  let event = parsed.arguments.first as? [String: Any],
                  let collection = event["colName"] as? String else { return }
            // `delete` carries no `doc`, only `{colName, identifier}` — pass the event itself so the
            // consumer can still act on the identifier.
            let body = (event["doc"] as? [String: Any]) ?? event
            guard let data = try? JSONSerialization.data(withJSONObject: body),
                  let json = String(data: data, encoding: .utf8) else { return }
            emit(.document(
                operation: parsed.name,
                collection: collection,
                json: json,
                srvModifiedMs: (body["srvModified"] as? NSNumber)?.int64Value
            ))

        case Self.alarmNamespace:
            guard let first = parsed.arguments.first,
                  JSONSerialization.isValidJSONObject(first),
                  let data = try? JSONSerialization.data(withJSONObject: first),
                  let json = String(data: data, encoding: .utf8) else {
                emit(.alarm(event: parsed.name, json: "{}"))
                return
            }
            emit(.alarm(event: parsed.name, json: json))

        default:
            break
        }
    }

    /// CONNECT_ERROR is an object in socket.io 3+ (`{"message":…}`) and a bare string in 2.x.
    static func reason(from payload: String?) -> String {
        guard let payload, let data = payload.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return "namespace unavailable"
        }
        if let object = parsed as? [String: Any], let message = object["message"] as? String {
            return message
        }
        if let text = parsed as? String {
            return text
        }
        return "namespace unavailable"
    }
}
