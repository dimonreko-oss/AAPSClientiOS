import XCTest
@testable import AAPSClientiOS

final class ClientControlPublisherTests: XCTestCase {
    func test_sendHelloPostsSignedEnvelopeToCorrectIdentifier() async throws {
        let mock = FixtureNightscoutClient()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        defer { store.unpair() }
        store.pair(MasterPairing(
            masterInstallId: "m1",
            clientId: "c1",
            secretHex: ClientControlCrypto.bytesToHex(ClientControlCrypto.newSecretBytes())
        ))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        try await publisher.sendHello()

        XCTAssertEqual(mock.putSettingsCalls.first?.identifier, "aaps_clientcontrol_hello_c1")
    }

    func test_sendHelloFailsGracefullyWhenUnpaired() async throws {
        let mock = FixtureNightscoutClient()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        do {
            try await publisher.sendHello()
            XCTFail("expected notPaired error")
        } catch ClientControlPublisher.PublishError.notPaired {
        }
    }

    func test_sendPingSetsWantsAckTrue() async throws {
        let mock = FixtureNightscoutClient()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        defer { store.unpair() }
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(ClientControlCrypto.newSecretBytes())))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        try await publisher.sendPing()

        let doc = try XCTUnwrap(mock.putSettingsCalls.first?.document)
        let envelope = try XCTUnwrap(doc["envelope"] as? [String: Any])
        XCTAssertEqual(envelope["wantsAck"] as? Bool, true)
    }

    func test_fetchAckReturnsVerifiedEnvelopeOnMatchingCounter() async throws {
        let mock = FixtureNightscoutClient()
        let secret = ClientControlCrypto.newSecretBytes()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        defer { store.unpair() }
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(secret)))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        var ack = AckEnvelope(clientId: "c1", commandCounter: 1, phase: .done, status: .ok, reason: nil, payload: nil, timestamp: Int64(Date().timeIntervalSince1970 * 1000), signature: "")
        ack.signature = ClientControlCrypto.sign(secret: secret, canonical: ack.canonicalString())
        let ackData = try JSONEncoder().encode(ack)
        let ackJson = try JSONSerialization.jsonObject(with: ackData) as! [String: Any]
        mock.settingsDocumentOverride["aaps_clientcontrol_ack_c1"] = try NsMapping.settingsDocument(
            from: JSONSerialization.data(withJSONObject: ["status": 200, "result": ["identifier": "aaps_clientcontrol_ack_c1", "date": 1, "utcOffset": 0, "app": "AAPS", "schemaVersion": 1, "ack": ackJson]]),
            identifier: "aaps_clientcontrol_ack_c1"
        )

        let result = try await publisher.fetchAck(expectedCounter: 1)
        XCTAssertEqual(result, .terminal(.ok, reason: nil, payload: nil))
    }

    func test_sendScenePrepareUsesCorrectIdentifierAndType() async throws {
        let mock = FixtureNightscoutClient()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        defer { store.unpair() }
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(ClientControlCrypto.newSecretBytes())))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        try await publisher.sendScenePrepare(sceneId: "sleep", durationMinutes: nil)

        let call = try XCTUnwrap(mock.putSettingsCalls.first)
        XCTAssertEqual(call.identifier, "aaps_clientcontrol_cmd_scene_prepare_c1")
        let envelope = try XCTUnwrap(call.document["envelope"] as? [String: Any])
        XCTAssertEqual(envelope["type"] as? String, "scene_prepare")
        XCTAssertEqual(envelope["wantsAck"] as? Bool, true)
    }

    func test_sendSceneCommitUsesCorrectIdentifierAndType() async throws {
        let mock = FixtureNightscoutClient()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        defer { store.unpair() }
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(ClientControlCrypto.newSecretBytes())))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        try await publisher.sendSceneCommit(bolusId: 42)

        let call = try XCTUnwrap(mock.putSettingsCalls.first)
        XCTAssertEqual(call.identifier, "aaps_clientcontrol_cmd_scene_commit_c1")
        let envelope = try XCTUnwrap(call.document["envelope"] as? [String: Any])
        XCTAssertEqual(envelope["type"] as? String, "scene_commit")
    }

    func test_sendSceneStopUsesCorrectIdentifierAndType() async throws {
        let mock = FixtureNightscoutClient()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        defer { store.unpair() }
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(ClientControlCrypto.newSecretBytes())))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        try await publisher.sendSceneStop(triggerChain: false)

        let call = try XCTUnwrap(mock.putSettingsCalls.first)
        XCTAssertEqual(call.identifier, "aaps_clientcontrol_cmd_scene_stop_c1")
        let envelope = try XCTUnwrap(call.document["envelope"] as? [String: Any])
        XCTAssertEqual(envelope["type"] as? String, "scene_stop")
    }

    func test_fetchAckRejectsBadSignature() async throws {
        let mock = FixtureNightscoutClient()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        defer { store.unpair() }
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(ClientControlCrypto.newSecretBytes())))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        let ack = AckEnvelope(clientId: "c1", commandCounter: 1, phase: .done, status: .ok, reason: nil, payload: nil, timestamp: Int64(Date().timeIntervalSince1970 * 1000), signature: "not-a-real-signature")
        let ackData = try JSONEncoder().encode(ack)
        let ackJson = try JSONSerialization.jsonObject(with: ackData) as! [String: Any]
        mock.settingsDocumentOverride["aaps_clientcontrol_ack_c1"] = try NsMapping.settingsDocument(
            from: JSONSerialization.data(withJSONObject: ["status": 200, "result": ["identifier": "aaps_clientcontrol_ack_c1", "date": 1, "utcOffset": 0, "app": "AAPS", "schemaVersion": 1, "ack": ackJson]]),
            identifier: "aaps_clientcontrol_ack_c1"
        )

        let result = try await publisher.fetchAck(expectedCounter: 1)
        XCTAssertEqual(result, .invalidSignature)
    }

    func test_fetchAckRejectsTimestampOutsideSkewWindow() async throws {
        let mock = FixtureNightscoutClient()
        let secret = ClientControlCrypto.newSecretBytes()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        defer { store.unpair() }
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(secret)))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        // Signature is otherwise valid, but the ack was (supposedly) written 20 minutes ago —
        // well outside the 5-minute default skew window `timestampWithinSkew` enforces.
        let staleTimestamp = Int64(Date().addingTimeInterval(-20 * 60).timeIntervalSince1970 * 1000)
        var ack = AckEnvelope(clientId: "c1", commandCounter: 1, phase: .done, status: .ok, reason: nil, payload: nil, timestamp: staleTimestamp, signature: "")
        ack.signature = ClientControlCrypto.sign(secret: secret, canonical: ack.canonicalString())
        let ackData = try JSONEncoder().encode(ack)
        let ackJson = try JSONSerialization.jsonObject(with: ackData) as! [String: Any]
        mock.settingsDocumentOverride["aaps_clientcontrol_ack_c1"] = try NsMapping.settingsDocument(
            from: JSONSerialization.data(withJSONObject: ["status": 200, "result": ["identifier": "aaps_clientcontrol_ack_c1", "date": 1, "utcOffset": 0, "app": "AAPS", "schemaVersion": 1, "ack": ackJson]]),
            identifier: "aaps_clientcontrol_ack_c1"
        )

        let result = try await publisher.fetchAck(expectedCounter: 1)
        XCTAssertEqual(result, .staleTimestamp)
    }

    func test_fetchAckIgnoresStaleCounter() async throws {
        let mock = FixtureNightscoutClient()
        let secret = ClientControlCrypto.newSecretBytes()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        defer { store.unpair() }
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(secret)))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        var ack = AckEnvelope(clientId: "c1", commandCounter: 1, phase: .done, status: .ok, reason: nil, payload: nil, timestamp: Int64(Date().timeIntervalSince1970 * 1000), signature: "")
        ack.signature = ClientControlCrypto.sign(secret: secret, canonical: ack.canonicalString())
        let ackData = try JSONEncoder().encode(ack)
        let ackJson = try JSONSerialization.jsonObject(with: ackData) as! [String: Any]
        mock.settingsDocumentOverride["aaps_clientcontrol_ack_c1"] = try NsMapping.settingsDocument(
            from: JSONSerialization.data(withJSONObject: ["status": 200, "result": ["identifier": "aaps_clientcontrol_ack_c1", "date": 1, "utcOffset": 0, "app": "AAPS", "schemaVersion": 1, "ack": ackJson]]),
            identifier: "aaps_clientcontrol_ack_c1"
        )

        let result = try await publisher.fetchAck(expectedCounter: 2)
        XCTAssertEqual(result, .pending)
    }

    func test_fetchAckExposesPreviewPayloadOnTerminalOk() async throws {
        let mock = FixtureNightscoutClient()
        let secret = ClientControlCrypto.newSecretBytes()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(secret)))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        let previewJson = #"{"bolusId":42,"lines":[{"role":"NORMAL","text":"Scene: Sleep"}],"advisorApplies":false,"advisorLines":[]}"#
        var ack = AckEnvelope(clientId: "c1", commandCounter: 1, phase: .done, status: .ok, reason: nil, payload: previewJson, timestamp: Int64(Date().timeIntervalSince1970 * 1000), signature: "")
        ack.signature = ClientControlCrypto.sign(secret: secret, canonical: ack.canonicalString())
        let ackData = try JSONEncoder().encode(ack)
        let ackJson = try JSONSerialization.jsonObject(with: ackData) as! [String: Any]
        mock.settingsDocumentOverride["aaps_clientcontrol_ack_c1"] = try NsMapping.settingsDocument(
            from: JSONSerialization.data(withJSONObject: ["status": 200, "result": ["identifier": "aaps_clientcontrol_ack_c1", "date": 1, "utcOffset": 0, "app": "AAPS", "schemaVersion": 1, "ack": ackJson]]),
            identifier: "aaps_clientcontrol_ack_c1"
        )

        let result = try await publisher.fetchAck(expectedCounter: 1)
        guard case .terminal(.ok, _, let payload) = result else { return XCTFail("expected terminal Ok with payload") }
        let preview = try JSONDecoder().decode(BolusPreview.self, from: Data(payload!.utf8))
        XCTAssertEqual(preview.bolusId, 42)
    }

    func test_sendWizardPrepareUsesCorrectIdentifierAndType() async throws {
        let mock = FixtureNightscoutClient()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(ClientControlCrypto.newSecretBytes())))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        let inputs = ClientControlMessage.WizardPrepare(
            bg: 120, carbs: 40, percentage: 100, directCorrection: 0, carbTime: 0,
            useBg: true, useCob: true, useIob: true, useTt: true, useTrend: true,
            alarm: false, notes: "", eCarbsGrams: 0, eCarbsDelayMinutes: 0, eCarbsDurationHours: 0,
            profileName: nil
        )
        try await publisher.sendWizardPrepare(inputs)

        let call = try XCTUnwrap(mock.putSettingsCalls.first)
        XCTAssertEqual(call.identifier, "aaps_clientcontrol_cmd_wizard_prepare_c1")
        let envelope = try XCTUnwrap(call.document["envelope"] as? [String: Any])
        XCTAssertEqual(envelope["type"] as? String, "wizard_prepare")
        XCTAssertEqual(envelope["wantsAck"] as? Bool, true)
    }

    // MARK: - Signed payload / signature integrity

    func test_signedPayloadCarriesTypeDiscriminatorAndMatchesTheSignature() async throws {
        let mock = FixtureNightscoutClient()
        let secret = ClientControlCrypto.newSecretBytes()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        defer { store.unpair() }
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(secret)))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        try await publisher.sendHello()

        let doc = try XCTUnwrap(mock.putSettingsCalls.first?.document)
        let envelopeObject = try XCTUnwrap(doc["envelope"] as? [String: Any])
        let payload = try XCTUnwrap(envelopeObject["payload"] as? String)
        XCTAssertEqual(payload, #"{"protocolVersion":1,"type":"hello"}"#)

        // The signature must verify against the payload string that actually travelled — this is the
        // property that breaks if the HMAC input and envelope.payload are serialized independently.
        let clientId = try XCTUnwrap(envelopeObject["clientId"] as? String)
        let counter = try XCTUnwrap((envelopeObject["counter"] as? NSNumber)?.int64Value)
        let timestamp = try XCTUnwrap((envelopeObject["timestamp"] as? NSNumber)?.int64Value)
        let type = try XCTUnwrap(envelopeObject["type"] as? String)
        let validUntil = try XCTUnwrap((envelopeObject["validUntil"] as? NSNumber)?.int64Value)
        let wantsAck = try XCTUnwrap(envelopeObject["wantsAck"] as? Bool)
        let signature = try XCTUnwrap(envelopeObject["signature"] as? String)

        XCTAssertEqual(type, "hello")
        XCTAssertEqual(validUntil, timestamp + ClientControlTiming.fireAndForgetMs)

        let rebuilt = SignedEnvelope(
            clientId: clientId,
            counter: counter,
            timestamp: timestamp,
            type: type,
            payload: payload,
            signature: "",
            validUntil: validUntil,
            wantsAck: wantsAck
        )
        XCTAssertTrue(ClientControlCrypto.verify(secret: secret, canonical: rebuilt.canonicalString(), signature: signature))
    }

    func test_pingPayloadIsTheBareDiscriminator() async throws {
        let mock = FixtureNightscoutClient()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        defer { store.unpair() }
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(ClientControlCrypto.newSecretBytes())))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        try await publisher.sendPing()

        let envelope = try XCTUnwrap(mock.putSettingsCalls.first?.document["envelope"] as? [String: Any])
        XCTAssertEqual(envelope["payload"] as? String, #"{"type":"ping"}"#)
        XCTAssertEqual(mock.putSettingsCalls.first?.identifier, "aaps_clientcontrol_cmd_ping_c1")
    }

    // MARK: - Immutable doc date

    func test_documentCarriesTheConstantDateNotNow() async throws {
        let mock = FixtureNightscoutClient()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        defer { store.unpair() }
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(ClientControlCrypto.newSecretBytes())))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        try await publisher.sendPing()

        let doc = try XCTUnwrap(mock.putSettingsCalls.first?.document)
        XCTAssertEqual(doc["date"] as? Int64, 946_684_800_001)
        XCTAssertEqual(doc["app"] as? String, "AAPS")
        XCTAssertEqual(doc["schemaVersion"] as? Int, 1)
        XCTAssertEqual(doc["utcOffset"] as? Int, 0)
        // The real time stays in the signed envelope.
        let envelope = try XCTUnwrap(doc["envelope"] as? [String: Any])
        let timestamp = try XCTUnwrap((envelope["timestamp"] as? NSNumber)?.int64Value)
        XCTAssertGreaterThan(timestamp, 1_700_000_000_000)
    }

    func test_immutableDateRejectionDeletesTheSlotAndRetriesOnce() async throws {
        let mock = FixtureNightscoutClient()
        mock.putSettingsErrors = [NsHttpStatusError(
            code: 400,
            detail: "HTTP 400 PUT /api/v3/settings/x — Field date cannot be modified by the client",
            body: "Field date cannot be modified by the client"
        )]
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        defer { store.unpair() }
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(ClientControlCrypto.newSecretBytes())))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        try await publisher.sendPing()

        XCTAssertEqual(mock.deleteSettingsCalls, ["aaps_clientcontrol_cmd_ping_c1"])
        XCTAssertEqual(mock.putSettingsCalls.count, 2)
        XCTAssertEqual(mock.putSettingsCalls.last?.identifier, "aaps_clientcontrol_cmd_ping_c1")
    }

    func test_otherHttpErrorsAreNotRetried() async throws {
        let mock = FixtureNightscoutClient()
        mock.putSettingsErrors = [NsHttpStatusError(code: 500, detail: "HTTP 500", body: "boom")]
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        defer { store.unpair() }
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(ClientControlCrypto.newSecretBytes())))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        do {
            try await publisher.sendPing()
            XCTFail("expected the 500 to propagate")
        } catch {
        }
        XCTAssertTrue(mock.deleteSettingsCalls.isEmpty)
        XCTAssertEqual(mock.putSettingsCalls.count, 1)
    }

    // MARK: - Ack phase handling

    func test_fetchAckTreatsMissingAckDocumentAsPending() async throws {
        let mock = FixtureNightscoutClient()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        defer { store.unpair() }
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(ClientControlCrypto.newSecretBytes())))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        // No override registered and no fixture for this identifier — the fake returns nil, the same
        // shape the live client now produces for NS's 404 on a never-written settings slot.
        let result = try await publisher.fetchAck(expectedCounter: 1)
        XCTAssertEqual(result, .pending)
    }

    func test_fetchAckTreatsDeliveryPhaseAsNonTerminal() async throws {
        let mock = FixtureNightscoutClient()
        let secret = ClientControlCrypto.newSecretBytes()
        let store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        defer { store.unpair() }
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(secret)))
        let publisher = ClientControlPublisher(client: mock, pairingStore: store)

        // A Delivery ack is a LATE out-of-band relay written after Done — it must never terminate
        // the round trip for the counter it echoes.
        var ack = AckEnvelope(clientId: "c1", commandCounter: 1, phase: .delivery, status: .failed, reason: "ExecutionFailed", payload: nil, timestamp: Int64(Date().timeIntervalSince1970 * 1000), signature: "")
        ack.signature = ClientControlCrypto.sign(secret: secret, canonical: ack.canonicalString())
        mock.settingsDocumentOverride["aaps_clientcontrol_ack_c1"] = try Self.ackDocument(ack)

        let result = try await publisher.fetchAck(expectedCounter: 1)
        XCTAssertEqual(result, .pending)
    }

    private static func ackDocument(_ ack: AckEnvelope) throws -> NsSettingsDocument {
        let ackData = try JSONEncoder().encode(ack)
        let ackJson = try JSONSerialization.jsonObject(with: ackData) as! [String: Any]
        return try XCTUnwrap(NsMapping.settingsDocument(
            from: JSONSerialization.data(withJSONObject: ["status": 200, "result": ["identifier": "aaps_clientcontrol_ack_c1", "date": 1, "utcOffset": 0, "app": "AAPS", "schemaVersion": 1, "ack": ackJson]]),
            identifier: "aaps_clientcontrol_ack_c1"
        ))
    }
}

/// Deterministic clock for the round-trip poll loop: `sleepNanos` advances it instead of blocking,
/// so a full 12-second ping window runs in microseconds.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

final class ClientControlRoundTripTests: XCTestCase {
    private var mock = FixtureNightscoutClient()
    private var store = ClientPairingStore(service: "unset")
    private var secret = Data()
    private var clock = TestClock(Date())

    override func setUp() {
        super.setUp()
        mock = FixtureNightscoutClient()
        secret = ClientControlCrypto.newSecretBytes()
        store = ClientPairingStore(service: "test.\(UUID().uuidString)")
        store.pair(MasterPairing(masterInstallId: "m1", clientId: "c1", secretHex: ClientControlCrypto.bytesToHex(secret)))
        clock = TestClock(Date())
    }

    override func tearDown() {
        store.unpair()
        super.tearDown()
    }

    private func makeRoundTrip(gate: RoundTripGate = RoundTripGate()) -> ClientControlRoundTrip {
        let clock = self.clock
        return ClientControlRoundTrip(
            publisher: ClientControlPublisher(client: mock, pairingStore: store),
            gate: gate,
            now: { clock.now() },
            sleepNanos: { nanos in clock.advance(Double(nanos) / 1_000_000_000) }
        )
    }

    private func installAck(counter: Int64, phase: AckPhase, status: AckStatus, reason: String?, payload: String?) throws {
        var ack = AckEnvelope(
            clientId: "c1", commandCounter: counter, phase: phase, status: status,
            reason: reason, payload: payload,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000), signature: ""
        )
        ack.signature = ClientControlCrypto.sign(secret: secret, canonical: ack.canonicalString())
        let ackJson = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ack)) as! [String: Any]
        mock.settingsDocumentOverride["aaps_clientcontrol_ack_c1"] = try NsMapping.settingsDocument(
            from: JSONSerialization.data(withJSONObject: ["status": 200, "result": ["identifier": "aaps_clientcontrol_ack_c1", "date": 1, "utcOffset": 0, "app": "AAPS", "schemaVersion": 1, "ack": ackJson]]),
            identifier: "aaps_clientcontrol_ack_c1"
        )
    }

    func test_appliedOnDoneOk() async throws {
        try installAck(counter: 1, phase: .done, status: .ok, reason: nil, payload: nil)
        let outcome = await makeRoundTrip().ping()
        XCTAssertEqual(outcome, .applied(payload: nil))
    }

    func test_preparedPreviewIsDecodableFromTheOutcome() async throws {
        let previewJson = #"{"bolusId":42,"lines":[{"role":"PRIMARY","text":"Scene: Sleep"}]}"#
        try installAck(counter: 1, phase: .done, status: .ok, reason: nil, payload: previewJson)
        let outcome = await makeRoundTrip().scenePrepare(sceneId: "sleep", durationMinutes: nil)
        XCTAssertEqual(outcome, .applied(payload: previewJson))
        XCTAssertEqual(outcome.preview?.bolusId, 42)
        // Copy lives in exactly one place now — `ClientControlText`, which localizes. The old
        // `RoundTripOutcome.failureText` was a second hardcoded-English table that only the tests
        // ever read, so the wording these assertions pinned was the wording nothing shipped.
        XCTAssertNil(ClientControlText.failureText(for: outcome))
    }

    func test_rejectedOnDoneFailedCarriesMasterReason() async throws {
        try installAck(counter: 1, phase: .done, status: .failed, reason: "ControlDisabled", payload: nil)
        let outcome = await makeRoundTrip().sceneCommit(bolusId: 42)
        XCTAssertEqual(outcome, .rejected(reason: "ControlDisabled"))
        assertLocalized(
            ClientControlText.failureText(for: outcome),
            equals: "Remote control is switched off on the master."
        )
    }

    /// The master puts the FailureReason NAME in `reason` and the human detail in `payload`
    /// (`AckOutcome(Failed, BolusComputeFailed, "no BG value available")`). Dropping the payload
    /// collapsed every compute failure into one generic sentence with no clue why.
    func test_rejectedOnDoneFailedKeepsTheMastersHumanDetail() async throws {
        try installAck(
            counter: 1, phase: .done, status: .failed,
            reason: "BolusComputeFailed", payload: "no BG value available"
        )
        let outcome = await makeRoundTrip().sceneCommit(bolusId: 42)
        XCTAssertEqual(
            outcome,
            .rejected(reason: "BolusComputeFailed" + RoundTripReason.detailSeparator + "no BG value available")
        )
        let text = try XCTUnwrap(ClientControlText.failureText(for: outcome))
        XCTAssertTrue(text.hasPrefix("The master could not calculate the dose"), text)
        XCTAssertTrue(text.hasSuffix("no BG value available"), text)
    }

    func test_rejectedOnDoneExpired() async throws {
        try installAck(counter: 1, phase: .done, status: .expired, reason: nil, payload: nil)
        let outcome = await makeRoundTrip().sceneStop(triggerChain: false)
        XCTAssertEqual(outcome, .rejected(reason: "Expired"))
    }

    /// The master ALWAYS attaches free text to an Expired ack, so `reason` is never a FailureReason
    /// code. Passing it through verbatim made `clientcontrol.fail.expired` unreachable and showed
    /// the user untranslated master-authored English.
    func test_expiredUsesOurOwnCodeSoTheLocalizedSentenceIsReachable() async throws {
        try installAck(
            counter: 1, phase: .done, status: .expired,
            reason: "expired before master applied it", payload: nil
        )
        let outcome = await makeRoundTrip().sceneStop(triggerChain: false)
        XCTAssertEqual(
            outcome,
            .rejected(reason: RoundTripReason.expired + RoundTripReason.detailSeparator + "expired before master applied it")
        )
        let text = try XCTUnwrap(ClientControlText.failureText(for: outcome))
        XCTAssertTrue(text.hasPrefix("The master received the command too late"), text)
    }

    /// A verified terminal ack we cannot DATE is not a refusal — the master may well have applied
    /// the command. Calling it "rejected" invites a re-tap, which for a scene means doing it twice.
    func test_skewedAckTimestampIsUnconfirmedNotRejected() async throws {
        var ack = AckEnvelope(
            clientId: "c1", commandCounter: 1, phase: .done, status: .ok, reason: nil, payload: nil,
            timestamp: Int64(Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000),
            signature: ""
        )
        ack.signature = ClientControlCrypto.sign(secret: secret, canonical: ack.canonicalString())
        let ackJson = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ack)) as! [String: Any]
        mock.settingsDocumentOverride["aaps_clientcontrol_ack_c1"] = try NsMapping.settingsDocument(
            from: JSONSerialization.data(withJSONObject: ["status": 200, "result": ["identifier": "aaps_clientcontrol_ack_c1", "date": 1, "utcOffset": 0, "app": "AAPS", "schemaVersion": 1, "ack": ackJson]]),
            identifier: "aaps_clientcontrol_ack_c1"
        )

        let outcome = await makeRoundTrip().sceneCommit(bolusId: 42)

        XCTAssertEqual(outcome, .unconfirmed)
    }

    /// An Executing/Pending ack is the master saying "still working" — it must not end the wait,
    /// and if nothing else arrives the outcome is UNKNOWN, never "stopped".
    func test_unconfirmedWhenOnlyExecutingAckEverArrives() async throws {
        try installAck(counter: 1, phase: .executing, status: .pending, reason: nil, payload: nil)
        let outcome = await makeRoundTrip().sceneStop(triggerChain: false)
        XCTAssertEqual(outcome, .unconfirmed)
        assertLocalized(
            ClientControlText.failureText(for: outcome),
            equals: "No reply from the master — the state of this command is unknown. Check the master before retrying."
        )
    }

    func test_unconfirmedWhenAckSlotNeverAppears() async throws {
        let outcome = await makeRoundTrip().sceneCommit(bolusId: 7)
        XCTAssertEqual(outcome, .unconfirmed)
    }

    /// The client must stop listening AFTER the master's own deadline, never before: validUntil is
    /// now + ttl, so the poll runs for ttl + propagation margin.
    func test_pollWindowExtendsPastTheSignedValidUntil() async throws {
        let start = clock.now()
        _ = await makeRoundTrip().sceneCommit(bolusId: 7)
        let elapsedMs = Int64(clock.now().timeIntervalSince(start) * 1000)
        XCTAssertGreaterThanOrEqual(elapsedMs, ClientControlTiming.roundTripMs + ClientControlTiming.propagationMarginMs)
    }

    func test_busyWhenAnotherCommandHoldsTheGate() async throws {
        let gate = RoundTripGate()
        XCTAssertTrue(gate.acquire())
        let outcome = await makeRoundTrip(gate: gate).ping()
        XCTAssertEqual(outcome, .rejected(reason: "Busy"))
        gate.release()
    }

    func test_gateIsReleasedAfterEachRoundTrip() async throws {
        let gate = RoundTripGate()
        try installAck(counter: 1, phase: .done, status: .ok, reason: nil, payload: nil)
        _ = await makeRoundTrip(gate: gate).ping()
        XCTAssertTrue(gate.acquire(), "gate must be free again after the round trip")
        gate.release()
    }

    func test_notPairedIsRejectedNotUnconfirmed() async throws {
        store.unpair()
        let outcome = await makeRoundTrip().ping()
        XCTAssertEqual(outcome, .rejected(reason: "NotPaired"))
        assertLocalized(
            ClientControlText.failureText(for: outcome),
            equals: "This device is not paired with a master."
        )
    }

    func test_unverifiableAckIsRejected() async throws {
        var ack = AckEnvelope(clientId: "c1", commandCounter: 1, phase: .done, status: .ok, reason: nil, payload: nil, timestamp: Int64(Date().timeIntervalSince1970 * 1000), signature: "")
        ack.signature = String(repeating: "0", count: 64)
        let ackJson = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ack)) as! [String: Any]
        mock.settingsDocumentOverride["aaps_clientcontrol_ack_c1"] = try NsMapping.settingsDocument(
            from: JSONSerialization.data(withJSONObject: ["status": 200, "result": ["identifier": "aaps_clientcontrol_ack_c1", "date": 1, "utcOffset": 0, "app": "AAPS", "schemaVersion": 1, "ack": ackJson]]),
            identifier: "aaps_clientcontrol_ack_c1"
        )
        let outcome = await makeRoundTrip().ping()
        XCTAssertEqual(outcome, .rejected(reason: "BadSignature"))
    }

    // MARK: - Hello

    /// Hello returns its OWN type. That is the point: `.sent` is a bare HTTP 200 from Nightscout and
    /// says nothing about the master, so making it a `RoundTripOutcome` let it reach
    /// `AppStore.recordRoundTripOutcome` and fake nine minutes of `masterReachable` against a master
    /// that might be switched off. The type makes that a compile error.
    func test_helloReportsSentWithoutClaimingTheMasterAnswered() async throws {
        let outcome = await makeRoundTrip().hello()
        XCTAssertEqual(outcome, .sent)
        // One PUT to the hello slot and nothing else — no ack poll, because Hello has no ack.
        XCTAssertEqual(mock.putSettingsCalls.map(\.identifier), ["aaps_clientcontrol_hello_c1"])
    }

    func test_helloFailsWhenTheEnvelopeCannotBePut() async throws {
        mock.putSettingsErrors = [NsHttpStatusError(code: 500, detail: "HTTP 500", body: "boom")]
        let outcome = await makeRoundTrip().hello()
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertTrue(reason?.hasPrefix(RoundTripReason.sendFailed) == true, reason ?? "nil")
    }

    func test_helloIsNotPairedAfterUnpair() async throws {
        store.unpair()
        let outcome = await makeRoundTrip().hello()
        XCTAssertEqual(outcome, .failed(reason: RoundTripReason.notPaired))
    }

    /// HTTP 410 on a command slot is a TOMBSTONE and it is permanent — NS never resurrects a deleted
    /// settings identifier. Reporting it as a generic `SendFailed` tells the user to try again, which
    /// will fail forever; only a re-pair (new clientId, hence a new slot identifier) fixes it.
    func test_tombstonedSlotIsNamedRatherThanReportedAsAGenericSendFailure() async throws {
        mock.putSettingsErrors = [NsHttpStatusError(
            code: 410,
            detail: "HTTP 410 PUT /api/v3/settings/aaps_clientcontrol_cmd_ping_c1 — Gone",
            body: "Gone"
        )]

        let outcome = await makeRoundTrip().ping()

        guard case .rejected(let reason) = outcome, let reason else {
            return XCTFail("expected a rejection, got \(outcome)")
        }
        XCTAssertTrue(reason.hasPrefix(RoundTripReason.slotTombstoned), reason)
        XCTAssertFalse(reason.hasPrefix(RoundTripReason.sendFailed), reason)
        let text = try XCTUnwrap(ClientControlText.failureText(for: outcome))
        assertNotARawKey(text)
        XCTAssertTrue(text.contains("Pair again"), text)
    }
}
