import Foundation

final class ClientControlPublisher {
    enum PublishError: Error {
        case notPaired
        case signingFailed
    }

    private let client: NightscoutClient
    private let pairingStore: ClientPairingStore

    init(client: NightscoutClient, pairingStore: ClientPairingStore) {
        self.client = client
        self.pairingStore = pairingStore
    }

    /// The master writes NO ack for Hello (it promotes the pairing entry Pending → Active instead),
    /// so this is fire-and-forget. Confirm promotion with a Ping and treat the pong as the receipt.
    @discardableResult
    func sendHello(ttlMs: Int64 = ClientControlTiming.fireAndForgetMs) async throws -> Int64 {
        try await send(
            type: ClientControlMessage.Hello.type,
            payload: ClientControlMessage.Hello(),
            ttlMs: ttlMs
        )
    }

    @discardableResult
    func sendPing(ttlMs: Int64 = ClientControlTiming.pingMs) async throws -> Int64 {
        try await send(
            type: ClientControlMessage.Ping.type,
            payload: ClientControlMessage.Ping(),
            wantsAck: true,
            ttlMs: ttlMs
        )
    }

    @discardableResult
    func sendWizardPrepare(_ inputs: ClientControlMessage.WizardPrepare, ttlMs: Int64 = ClientControlTiming.roundTripMs) async throws -> Int64 {
        try await send(
            type: ClientControlMessage.WizardPrepare.type,
            payload: inputs,
            wantsAck: true,
            ttlMs: ttlMs
        )
    }

    @discardableResult
    func sendScenePrepare(sceneId: String, durationMinutes: Int?, ttlMs: Int64 = ClientControlTiming.roundTripMs) async throws -> Int64 {
        try await send(
            type: ClientControlMessage.ScenePrepare.type,
            payload: ClientControlMessage.ScenePrepare(sceneId: sceneId, durationMinutes: durationMinutes),
            wantsAck: true,
            ttlMs: ttlMs
        )
    }

    @discardableResult
    func sendSceneCommit(bolusId: Int64, ttlMs: Int64 = ClientControlTiming.roundTripMs) async throws -> Int64 {
        try await send(
            type: ClientControlMessage.SceneCommit.type,
            payload: ClientControlMessage.SceneCommit(bolusId: bolusId),
            wantsAck: true,
            ttlMs: ttlMs
        )
    }

    /// `wantsAck: true` deliberately: the shipped master routes SceneStop through the acked
    /// round-trip like every other scene command. The spec line calling it fire-and-forget is stale.
    @discardableResult
    func sendSceneStop(triggerChain: Bool, ttlMs: Int64 = ClientControlTiming.roundTripMs) async throws -> Int64 {
        try await send(
            type: ClientControlMessage.SceneStop.type,
            payload: ClientControlMessage.SceneStop(triggerChain: triggerChain),
            wantsAck: true,
            ttlMs: ttlMs
        )
    }

    /// Result of checking the master's `aaps_clientcontrol_ack_<clientId>` document against a
    /// specific command counter this client sent with `wantsAck: true`.
    enum AckResult: Equatable {
        /// Ack doc doesn't exist yet, or still reflects an older counter — command not yet acked.
        case pending
        /// Master processed the command; terminal outcome with optional reason AND the raw ack
        /// payload string (JSON-decode as `BolusPreview` when the command was a `..Prepare`; nil
        /// for commands with no payload, like `Ping`).
        case terminal(AckStatus, reason: String?, payload: String?)
        /// A doc for this counter exists but the HMAC signature doesn't verify against our shared
        /// secret — reject it rather than trust an unverifiable "Ok". Never silently treat as success.
        case invalidSignature
        /// Signature verifies, but `ack.timestamp` falls outside the allowed clock-skew window —
        /// e.g. a stale ack doc served from a cache, or a master with a badly wrong clock. Reject
        /// rather than trust a terminal outcome we can't date.
        case staleTimestamp
    }

    /// Fetches and verifies the ack for a command sent with counter `expectedCounter`. Mirrors the
    /// master's `writeAck` lifecycle (Executing/Pending -> Done/{Ok,Failed,Expired}) — a `.pending`
    /// result covers both "not written yet" and "still on the Executing phase".
    func fetchAck(expectedCounter: Int64) async throws -> AckResult {
        guard let pairing = pairingStore.currentPairing(),
              let secret = ClientControlCrypto.hexToBytes(pairing.secretHex) else {
            throw PublishError.notPaired
        }
        guard let document = try await client.fetchSettings(identifier: ClientControlWire.ackIdentifier(clientId: pairing.clientId)),
              let ackData = document.runningConfigJson.data(using: .utf8),
              let ack = try? JSONDecoder().decode(AckEnvelope.self, from: ackData) else {
            return .pending
        }
        guard ack.clientId == pairing.clientId, ack.commandCounter == expectedCounter else {
            // Not ours, or not this command. `clientId` is already bound by the HMAC (it is part of
            // `canonicalString()`), so this is belt and braces — but it states the invariant instead
            // of leaving the ack path's safety resting on the canonical string's field order, and
            // the master's own `pollAck` checks exactly these two.
            return .pending
        }
        guard ClientControlCrypto.verify(secret: secret, canonical: ack.canonicalString(), signature: ack.signature) else {
            return .invalidSignature
        }
        let ackDate = Date(timeIntervalSince1970: Double(ack.timestamp) / 1000)
        guard ClientControlCrypto.timestampWithinSkew(ackDate, now: Date()) else {
            return .staleTimestamp
        }
        // ONLY the Done phase is terminal. Executing/Pending means "received it, applying now", and
        // Delivery is a LATE out-of-band relay of an async bolus failure the Done ack already closed
        // — neither may end a round trip.
        guard ack.phase == .done else {
            return .pending
        }
        return .terminal(ack.status, reason: ack.reason, payload: ack.payload)
    }

    /// `ttlMs` becomes the signed `validUntil`: the master refuses to apply the command after it and
    /// acks Expired instead. The caller's own give-up must therefore be LATER than `now + ttlMs`
    /// (see `ClientControlTiming.propagationMarginMs`), never earlier.
    @discardableResult
    private func send<T: Encodable>(type: ClientControlType, payload: T, wantsAck: Bool = false, ttlMs: Int64) async throws -> Int64 {
        guard let pairing = pairingStore.currentPairing(),
              let secret = ClientControlCrypto.hexToBytes(pairing.secretHex) else {
            throw PublishError.notPaired
        }

        // ONE string, used for both the HMAC canonical input and `envelope.payload` — signing a
        // second, independently produced serialization is how a signature stops matching the bytes
        // that travelled the wire.
        let payloadJson: String
        do {
            payloadJson = try ClientControlWire.signedPayloadJson(type: type, payload: payload)
        } catch {
            throw PublishError.signingFailed
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var envelope = SignedEnvelope(
            clientId: pairing.clientId,
            counter: pairingStore.nextCounter(),
            timestamp: nowMs,
            type: type.rawValue,
            payload: payloadJson,
            signature: "",
            validUntil: nowMs + ttlMs,
            wantsAck: wantsAck
        )
        envelope.signature = ClientControlCrypto.sign(secret: secret, canonical: envelope.canonicalString())

        let envelopeData = try JSONEncoder().encode(envelope)
        guard let envelopeObject = try JSONSerialization.jsonObject(with: envelopeData) as? [String: Any] else {
            throw PublishError.signingFailed
        }

        // `date` is the constant placeholder, NOT the current time: NS APIv3 makes it immutable after
        // create and these command slots are PUT over and over. The real time is envelope.timestamp.
        let document: [String: Any] = [
            "date": ClientControlWire.docDate,
            "utcOffset": 0,
            "app": "AAPS",
            "schemaVersion": ClientControlWire.schemaVersion,
            "envelope": envelopeObject,
        ]
        let identifier = ClientControlWire.identifier(for: type, clientId: pairing.clientId)
        try await putRecoveringPoisonedDate(identifier: identifier, document: document)
        return envelope.counter
    }

    /// Installs that shipped before `ClientControlWire.docDate` created their command slots with a
    /// live timestamp. NS then rejects every later PUT to that identifier with HTTP 400 "Field date
    /// cannot be modified by the client", leaving the slot permanently wedged. Delete it and re-PUT
    /// exactly once — a second failure is a real error and propagates.
    private func putRecoveringPoisonedDate(identifier: String, document: [String: Any]) async throws {
        do {
            try await client.putSettings(identifier: identifier, document: document)
        } catch let error as NsHttpStatusError where error.isImmutableDateRejection {
            try await client.deleteSettings(identifier: identifier)
            try await client.putSettings(identifier: identifier, document: document)
        }
    }
}
