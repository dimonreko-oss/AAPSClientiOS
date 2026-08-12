import XCTest
@testable import AAPSClientiOS

/// Pure string fixtures — no network. Every frame below is a shape a real cgm-remote-monitor
/// emits: the v5 shapes come from socket.io 4.x (NS 14.2+), the v4/Engine.IO-3 shapes from the
/// socket.io 2.x builds that older Nightscout instances still run.
final class NightscoutSocketClientTests: XCTestCase {

    // MARK: - Engine.IO framing

    func test_engineIO_decodesEveryPacketType() {
        XCTAssertEqual(EngineIOPacket.decode("0{\"sid\":\"x\"}"), .open("{\"sid\":\"x\"}"))
        XCTAssertEqual(EngineIOPacket.decode("1"), .close)
        XCTAssertEqual(EngineIOPacket.decode("2"), .ping(""))
        XCTAssertEqual(EngineIOPacket.decode("2probe"), .ping("probe"))
        XCTAssertEqual(EngineIOPacket.decode("3"), .pong(""))
        XCTAssertEqual(EngineIOPacket.decode("40/storage,"), .message("0/storage,"))
        XCTAssertEqual(EngineIOPacket.decode("5"), .upgrade)
        XCTAssertEqual(EngineIOPacket.decode("6"), .noop)
        XCTAssertEqual(EngineIOPacket.decode(""), .unknown(""))
        XCTAssertEqual(EngineIOPacket.decode("x"), .unknown("x"))
    }

    func test_engineIO_encodesPacketsBackToTheWireForm() {
        XCTAssertEqual(EngineIOPacket.pong("").encoded, "3")
        XCTAssertEqual(EngineIOPacket.pong("probe").encoded, "3probe")
        XCTAssertEqual(EngineIOPacket.ping("").encoded, "2")
        XCTAssertEqual(EngineIOPacket.message("0/storage,").encoded, "40/storage,")
        XCTAssertEqual(EngineIOPacket.close.encoded, "1")
    }

    /// Engine.IO 4 advertises `maxPayload` and pings us; we answer.
    func test_engineIO_v4Handshake_isServerDriven() throws {
        let frame = #"0{"sid":"lv_VI97HAXpY6yYWAAAC","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}"#
        guard case .open(let payload) = EngineIOPacket.decode(frame) else {
            return XCTFail("expected an open packet")
        }
        let handshake = try XCTUnwrap(EngineIOHandshake.decode(payload))

        XCTAssertEqual(handshake.sid, "lv_VI97HAXpY6yYWAAAC")
        XCTAssertEqual(handshake.pingInterval, 25_000)
        XCTAssertEqual(handshake.pingTimeout, 20_000)
        XCTAssertTrue(handshake.serverDrivenHeartbeat)
        XCTAssertEqual(handshake.engineIOVersion, 4)
    }

    /// Engine.IO 3 omits `maxPayload` and expects the *client* to ping. Getting this wrong is the
    /// silent failure the negotiation exists for: an engine.io 3 server happily answers an `EIO=4`
    /// request and then drops us on `pingTimeout` because nobody sent a heartbeat.
    func test_engineIO_v3Handshake_isClientDriven() throws {
        let frame = #"0{"sid":"aBcDeF0123456789","upgrades":["websocket"],"pingInterval":25000,"pingTimeout":60000}"#
        guard case .open(let payload) = EngineIOPacket.decode(frame) else {
            return XCTFail("expected an open packet")
        }
        let handshake = try XCTUnwrap(EngineIOHandshake.decode(payload))

        XCTAssertFalse(handshake.serverDrivenHeartbeat)
        XCTAssertEqual(handshake.engineIOVersion, 3)
        XCTAssertEqual(handshake.pingTimeout, 60_000)
    }

    func test_engineIO_handshake_rejectsNonHandshakePayloads() {
        XCTAssertNil(EngineIOHandshake.decode("not json"))
        XCTAssertNil(EngineIOHandshake.decode(#"{"upgrades":[]}"#))
    }

    // MARK: - Socket.IO framing

    func test_socketIO_decodesNamespaceConnect_protocolV5() {
        XCTAssertEqual(
            SocketIOPacket.decode(#"0/storage,{"sid":"abc"}"#),
            .connect(namespace: "/storage", payload: #"{"sid":"abc"}"#)
        )
    }

    /// socket.io 2.x drops the separator when a namespaced packet has no payload.
    func test_socketIO_decodesNamespaceConnect_protocolV4_withoutTrailingComma() {
        XCTAssertEqual(SocketIOPacket.decode("0/storage"), .connect(namespace: "/storage", payload: nil))
        XCTAssertEqual(SocketIOPacket.decode("0/storage,"), .connect(namespace: "/storage", payload: nil))
    }

    func test_socketIO_decodesRootConnect() {
        XCTAssertEqual(SocketIOPacket.decode("0"), .connect(namespace: "/", payload: nil))
    }

    func test_socketIO_decodesDisconnect() {
        XCTAssertEqual(SocketIOPacket.decode("1/alarm"), .disconnect(namespace: "/alarm"))
    }

    func test_socketIO_decodesServerEventWithoutAckId() {
        XCTAssertEqual(
            SocketIOPacket.decode(#"2/storage,["create",{"colName":"entries"}]"#),
            .event(namespace: "/storage", ackId: nil, payload: #"["create",{"colName":"entries"}]"#)
        )
    }

    func test_socketIO_decodesAckWithAckId() {
        XCTAssertEqual(
            SocketIOPacket.decode(#"3/storage,12[{"success":true}]"#),
            .ack(namespace: "/storage", ackId: 12, payload: #"[{"success":true}]"#)
        )
    }

    func test_socketIO_decodesConnectError_objectShape() {
        let packet = SocketIOPacket.decode(#"4/storage,{"message":"Invalid namespace"}"#)
        XCTAssertEqual(packet, .connectError(namespace: "/storage", payload: #"{"message":"Invalid namespace"}"#))
        guard case .connectError(_, let payload) = packet else { return XCTFail("expected a connect error") }
        XCTAssertEqual(NightscoutSocketClient.reason(from: payload), "Invalid namespace")
    }

    /// socket.io 2.x sends the ERROR payload as a bare JSON string. A pre-14.2 Nightscout answers
    /// exactly this when we ask for `/storage`, and it must degrade to "no realtime", not to noise.
    func test_socketIO_decodesConnectError_stringShape_protocolV4() {
        let packet = SocketIOPacket.decode("4/storage,\"Invalid namespace\"")
        guard case .connectError(let namespace, let payload) = packet else {
            return XCTFail("expected a connect error")
        }
        XCTAssertEqual(namespace, "/storage")
        XCTAssertEqual(NightscoutSocketClient.reason(from: payload), "Invalid namespace")
    }

    func test_socketIO_reason_fallsBackWhenUnparseable() {
        XCTAssertEqual(NightscoutSocketClient.reason(from: nil), "namespace unavailable")
        XCTAssertEqual(NightscoutSocketClient.reason(from: "{"), "namespace unavailable")
    }

    func test_socketIO_decodesBinaryEventAsIgnorable() {
        XCTAssertEqual(
            SocketIOPacket.decode(#"51-/storage,["x",{"_placeholder":true,"num":0}]"#),
            .binary(namespace: "/storage")
        )
    }

    func test_socketIO_encodesSubscribeEvent() {
        let payload = #"["subscribe",{"accessToken":"redacted"}]"#
        XCTAssertEqual(
            SocketIOPacket.event(namespace: "/storage", ackId: 0, payload: payload).encoded,
            #"2/storage,0["subscribe",{"accessToken":"redacted"}]"#
        )
    }

    func test_socketIO_encodesNamespaceConnect() {
        XCTAssertEqual(SocketIOPacket.connect(namespace: "/storage", payload: nil).encoded, "0/storage,")
        XCTAssertEqual(SocketIOPacket.connect(namespace: "/alarm", payload: nil).encoded, "0/alarm,")
        XCTAssertEqual(SocketIOPacket.connect(namespace: "/", payload: nil).encoded, "0")
    }

    /// The full outbound frame the client actually writes for a namespace subscribe.
    func test_fullOutboundSubscribeFrame() {
        let arguments = #"["subscribe",{"accessToken":"redacted","collections":["entries"]}]"#
        let frame = EngineIOPacket.message(
            SocketIOPacket.event(namespace: "/storage", ackId: 3, payload: arguments).encoded
        ).encoded
        XCTAssertEqual(frame, #"42/storage,3["subscribe",{"accessToken":"redacted","collections":["entries"]}]"#)
    }

    // MARK: - Nightscout payloads

    func test_storageCreateFrame_yieldsCollectionAndDocument() throws {
        let frame = #"42/storage,["create",{"colName":"entries","doc":{"identifier":"abc","type":"sgv","sgv":112,"date":1700000000000,"direction":"Flat","srvModified":1700000001000}}]"#
        guard case .message(let text) = EngineIOPacket.decode(frame) else {
            return XCTFail("expected an engine.io message")
        }
        guard case .event(let namespace, let ackId, let payload) = SocketIOPacket.decode(text) else {
            return XCTFail("expected a socket.io event")
        }
        XCTAssertEqual(namespace, "/storage")
        XCTAssertNil(ackId)

        let parsed = try XCTUnwrap(SocketIOEventArguments.parse(payload))
        XCTAssertEqual(parsed.name, "create")
        let event = try XCTUnwrap(parsed.arguments.first as? [String: Any])
        XCTAssertEqual(event["colName"] as? String, "entries")
        let document = try XCTUnwrap(event["doc"] as? [String: Any])
        XCTAssertEqual((document["srvModified"] as? NSNumber)?.int64Value, 1_700_000_001_000)
        XCTAssertEqual(document["identifier"] as? String, "abc")
    }

    /// `delete` carries no `doc`, only the identifier.
    func test_storageDeleteFrame_hasNoDocument() throws {
        let payload = #"["delete",{"colName":"treatments","identifier":"gone"}]"#
        let parsed = try XCTUnwrap(SocketIOEventArguments.parse(payload))
        let event = try XCTUnwrap(parsed.arguments.first as? [String: Any])
        XCTAssertEqual(parsed.name, "delete")
        XCTAssertNil(event["doc"])
        XCTAssertEqual(event["identifier"] as? String, "gone")
    }

    func test_subscribeAck_successAndFailureShapes() throws {
        let success = try XCTUnwrap(
            SocketIOEventArguments.parseArray(#"[{"success":true,"collections":["entries","settings"]}]"#)
        )
        let successBody = try XCTUnwrap(success.first as? [String: Any])
        XCTAssertEqual(successBody["success"] as? Bool, true)
        let granted = (successBody["collections"] as? [Any])?.compactMap { $0 as? String }
        XCTAssertEqual(granted ?? [], ["entries", "settings"])

        let failure = try XCTUnwrap(
            SocketIOEventArguments.parseArray(#"[{"success":false,"message":"Missing or bad access token"}]"#)
        )
        let failureBody = try XCTUnwrap(failure.first as? [String: Any])
        XCTAssertEqual(failureBody["success"] as? Bool, false)
        XCTAssertEqual(failureBody["message"] as? String, "Missing or bad access token")
    }

    func test_alarmFrame_yieldsEventAndPayload() throws {
        let frame = #"42/alarm,["urgent_alarm",{"level":2,"title":"Urgent LOW","message":"BG Now: 45","group":"default"}]"#
        guard case .message(let text) = EngineIOPacket.decode(frame),
              case .event(let namespace, _, let payload) = SocketIOPacket.decode(text) else {
            return XCTFail("expected an /alarm event")
        }
        XCTAssertEqual(namespace, "/alarm")
        let parsed = try XCTUnwrap(SocketIOEventArguments.parse(payload))
        XCTAssertEqual(parsed.name, "urgent_alarm")

        let body = try XCTUnwrap(parsed.arguments.first as? [String: Any])
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let json = try XCTUnwrap(String(data: bodyData, encoding: .utf8))
        let alarm = NightscoutRealtimeAlarm(event: parsed.name, json: json)
        XCTAssertTrue(alarm.isUrgent)
        XCTAssertFalse(alarm.isAnnouncement)
        XCTAssertEqual(alarm.title, "Urgent LOW")
        XCTAssertEqual(alarm.message, "BG Now: 45")
    }

    func test_eventArguments_rejectMalformedPayloads() {
        XCTAssertNil(SocketIOEventArguments.parse("not json"))
        XCTAssertNil(SocketIOEventArguments.parse(#"{"colName":"entries"}"#))
        XCTAssertNil(SocketIOEventArguments.parse("[]"))
    }

    // MARK: - URL construction

    func test_socketURL_upgradesSchemeAndAppendsEngineIOQuery() throws {
        let url = try XCTUnwrap(
            NightscoutSocketClient.socketURL(base: URL(string: "https://ns.example.com")!, eio: 4)
        )
        XCTAssertEqual(url.absoluteString, "wss://ns.example.com/socket.io/?EIO=4&transport=websocket")
    }

    func test_socketURL_toleratesTrailingSlashAndKeepsSubPath() throws {
        let slashed = try XCTUnwrap(
            NightscoutSocketClient.socketURL(base: URL(string: "https://ns.example.com/")!, eio: 4)
        )
        XCTAssertEqual(slashed.absoluteString, "wss://ns.example.com/socket.io/?EIO=4&transport=websocket")

        let subPath = try XCTUnwrap(
            NightscoutSocketClient.socketURL(base: URL(string: "http://ns.example.com/nightscout/")!, eio: 3)
        )
        XCTAssertEqual(subPath.absoluteString, "ws://ns.example.com/nightscout/socket.io/?EIO=3&transport=websocket")
    }

    func test_socketURL_rejectsNonHttpSchemes() {
        XCTAssertNil(NightscoutSocketClient.socketURL(base: URL(string: "ftp://ns.example.com")!, eio: 4))
    }

    // MARK: - Reconnect backoff

    @MainActor
    func test_backoffDelay_growsExponentiallyAndIsCapped() {
        let low: (ClosedRange<Double>) -> Double = { $0.lowerBound }
        let high: (ClosedRange<Double>) -> Double = { $0.upperBound }

        XCTAssertEqual(NightscoutRealtimeService.backoffDelay(attempt: 1, random: high), 2, accuracy: 0.001)
        XCTAssertEqual(NightscoutRealtimeService.backoffDelay(attempt: 2, random: high), 4, accuracy: 0.001)
        XCTAssertEqual(NightscoutRealtimeService.backoffDelay(attempt: 3, random: high), 8, accuracy: 0.001)
        XCTAssertEqual(NightscoutRealtimeService.backoffDelay(attempt: 50, random: high),
                       NightscoutRealtimeService.maxBackoff, accuracy: 0.001)
        // Jitter never collapses to zero, so a reconnect storm can't become a hot loop.
        XCTAssertEqual(NightscoutRealtimeService.backoffDelay(attempt: 1, random: low), 1, accuracy: 0.001)
        XCTAssertEqual(NightscoutRealtimeService.backoffDelay(attempt: 0, random: low), 1, accuracy: 0.001)
    }

    /// The failure the threshold exists for: a Nightscout behind a reverse proxy or a carrier NAT
    /// with a ~55 s idle websocket timeout. Resetting `attempt` on the subscribe ack alone meant
    /// every cycle was connect → handshake → subscribe → ack (attempt := 0) → 55 s idle → drop →
    /// reconnect at the 1–2 s floor, all night — a TLS handshake, an Engine.IO handshake and two
    /// authenticated subscribes a minute, with the backoff, the jitter and the ceiling all dead
    /// code on the only failure mode that actually persists. A connection has to STAY up to count.
    @MainActor
    func test_stableConnectionThresholdIsLongerThanAProxyIdleTimeout() {
        XCTAssertEqual(NightscoutRealtimeService.stableConnectionThreshold, 120, accuracy: 0.001)
        XCTAssertGreaterThan(
            NightscoutRealtimeService.stableConnectionThreshold,
            60,
            "a 55-second flap must NOT be counted as a healthy connection, or the backoff never grows"
        )
    }

    // MARK: - Namespace liveness contract

    /// `/alarm` is optional and normally acks first; `/storage` is the document stream and the only
    /// thing that counts as liveness. The subscribe watchdog and `dropIfNeverSubscribed` therefore
    /// both key on `/storage` specifically — keying on "any namespace" left a server that accepts
    /// `/alarm` and silently never acks `/storage` parked as "connected" forever, with Settings
    /// reporting a healthy socket over a dead document stream.
    func test_theTwoNamespacesAreDistinctAndStorageIsTheDocumentStream() {
        XCTAssertEqual(NightscoutSocketClient.storageNamespace, "/storage")
        XCTAssertEqual(NightscoutSocketClient.alarmNamespace, "/alarm")
        XCTAssertNotEqual(NightscoutSocketClient.storageNamespace, NightscoutSocketClient.alarmNamespace)
        XCTAssertGreaterThan(NightscoutSocketClient.subscribeTimeout, 0)
    }

    // MARK: - Reuse of the existing mappers

    /// Realtime must not grow a second parser: the pushed document is re-wrapped in the NS v3
    /// response envelope and handed to the very same `NsMapping` entry point polling uses.
    func test_update_resultArrayEnvelope_feedsNsMapping() throws {
        let update = NightscoutRealtimeUpdate(
            operation: .create,
            collection: "entries",
            json: #"{"identifier":"abc","type":"sgv","sgv":112,"date":1700000000000,"direction":"Flat"}"#,
            srvModified: Date(timeIntervalSince1970: 1_700_000_001)
        )

        let readings = try NsMapping.glucose(from: update.resultArrayEnvelope)

        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings.first?.mgdl, 112)
        XCTAssertEqual(readings.first?.trend, .flat)
        XCTAssertEqual(update.identifier, "abc")
    }

    func test_update_resultObjectEnvelope_feedsSettingsMapping() throws {
        let update = NightscoutRealtimeUpdate(
            operation: .update,
            collection: "settings",
            json: #"{"identifier":"aaps","app":"AAPS","schemaVersion":1,"date":946684800001,"srvModified":1700000000000,"runningConfig":{"version":"3.3.0"}}"#,
            srvModified: nil
        )

        let document = try XCTUnwrap(
            NsMapping.settingsDocument(from: update.resultObjectEnvelope, identifier: "aaps")
        )

        XCTAssertEqual(document.identifier, "aaps")
        XCTAssertEqual(document.app, "AAPS")
        XCTAssertTrue(document.runningConfigJson.contains("3.3.0"))
    }

    func test_updateOperation_mapsWireStrings() {
        XCTAssertEqual(NightscoutRealtimeUpdate.Operation(rawValue: "create"), .create)
        XCTAssertEqual(NightscoutRealtimeUpdate.Operation(rawValue: "update"), .update)
        XCTAssertEqual(NightscoutRealtimeUpdate.Operation(rawValue: "delete"), .delete)
        XCTAssertNil(NightscoutRealtimeUpdate.Operation(rawValue: "patch"))
    }
}
