import XCTest
@testable import AAPSClientiOS

final class ClientControlModelsTests: XCTestCase {
    func test_signedEnvelopeCanonicalStringMatchesAndroidApsFormat() {
        let envelope = SignedEnvelope(
            clientId: "c1",
            counter: 1,
            timestamp: 1000,
            type: "hello",
            payload: "{\"protocolVersion\":1}",
            signature: "",
            validUntil: 9999,
            wantsAck: false
        )
        XCTAssertEqual(envelope.canonicalString(), "c1|1|1000|9999|false|hello|{\"protocolVersion\":1}")
    }

    func test_pairingOfferDecodesFromNsJson() throws {
        let json = #"{"schemaVersion":1,"clientId":"c1","expiresAt":123,"kdfSaltB64":"AAA=","ivB64":"BBB=","wrappedB64":"CCC="}"#
        let offer = try JSONDecoder().decode(PairingOffer.self, from: Data(json.utf8))
        XCTAssertEqual(offer.clientId, "c1")
        XCTAssertEqual(offer.expiresAt, 123)
    }

    func test_pairingPayloadDecodesFromDecryptedJson() throws {
        let json = #"{"v":1,"masterInstallId":"m1","clientId":"c1","secretHex":"aa","expiresAt":456}"#
        let payload = try JSONDecoder().decode(PairingPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.masterInstallId, "m1")
        XCTAssertEqual(payload.secretHex, "aa")
    }

    func test_ackEnvelopeCanonicalStringMatchesAndroidApsFormat() {
        let ack = AckEnvelope(
            clientId: "c1", commandCounter: 1, phase: .done, status: .ok,
            reason: nil, payload: nil, timestamp: 1000, signature: ""
        )
        XCTAssertEqual(ack.canonicalString(), "c1|1|Done|Ok|||1000")
    }

    func test_ackEnvelopeDecodesFromNsJson() throws {
        let json = #"{"clientId":"c1","commandCounter":2,"phase":"Executing","status":"Pending","timestamp":500,"signature":"deadbeef"}"#
        let ack = try JSONDecoder().decode(AckEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(ack.phase, .executing)
        XCTAssertEqual(ack.status, .pending)
        XCTAssertNil(ack.reason)
    }

    func test_bolusPreviewDecodesFromNsJson() throws {
        let json = #"""
        {"bolusId":123,"lines":[{"role":"NORMAL","text":"Scene: Exercise"}],"advisorApplies":false,"advisorLines":[]}
        """#
        let preview = try JSONDecoder().decode(BolusPreview.self, from: Data(json.utf8))
        XCTAssertEqual(preview.bolusId, 123)
        XCTAssertEqual(preview.lines.first?.role, "NORMAL")
        XCTAssertEqual(preview.lines.first?.text, "Scene: Exercise")
        XCTAssertFalse(preview.advisorApplies)
        XCTAssertNil(preview.wizardDetail)
    }

    func test_bolusPreviewDecodesWizardDetailWhenPresent() throws {
        let json = #"""
        {"bolusId":1,"lines":[],"advisorApplies":false,"advisorLines":[],"wizardDetail":{
            "totalInsulin":2.5,"carbs":40,"insulinFromBG":0.5,"insulinFromTrend":0,"insulinFromCOB":0.3,
            "insulinFromCarbs":1.7,"insulinFromBolusIOB":0,"insulinFromBasalIOB":0,"includeBolusIOB":true,
            "includeBasalIOB":true,"percentageCorrection":100,"cob":10,"tempTargetLabel":null,"ic":8,"sens":50
        }}
        """#
        let preview = try JSONDecoder().decode(BolusPreview.self, from: Data(json.utf8))
        XCTAssertEqual(preview.wizardDetail?.totalInsulin, 2.5)
        XCTAssertEqual(preview.wizardDetail?.carbs, 40)
    }

    func test_wizardPrepareEncodesAllFields() throws {
        let msg = ClientControlMessage.WizardPrepare(
            bg: 120, carbs: 40, percentage: 100, directCorrection: 0, carbTime: 0,
            useBg: true, useCob: true, useIob: true, useTt: true, useTrend: false,
            alarm: false, notes: "", eCarbsGrams: 0, eCarbsDelayMinutes: 0, eCarbsDurationHours: 0,
            profileName: nil
        )
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["bg"] as? Double, 120)
        XCTAssertEqual(json["carbs"] as? Int, 40)
        XCTAssertEqual(json["useBg"] as? Bool, true)
        XCTAssertEqual(json["useTrend"] as? Bool, false)
        XCTAssertNil(json["profileName"] as? String)
    }

    func test_scenePrepareEncodesSceneIdAndDuration() throws {
        let msg = ClientControlMessage.ScenePrepare(sceneId: "abc", durationMinutes: 30)
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["sceneId"] as? String, "abc")
        XCTAssertEqual(json["durationMinutes"] as? Int, 30)
    }

    func test_sceneCommitEncodesBolusId() throws {
        let msg = ClientControlMessage.SceneCommit(bolusId: 999)
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["bolusId"] as? Int64, 999)
    }

    // MARK: - kotlinx `type` discriminator (the whole channel is dead without it)

    func test_pingPayloadIsExactlyTheDiscriminator() throws {
        let json = try ClientControlWire.signedPayloadJson(type: .ping, payload: ClientControlMessage.Ping())
        XCTAssertEqual(json, #"{"type":"ping"}"#)
    }

    func test_helloPayloadCarriesDiscriminatorAndProtocolVersion() throws {
        let json = try ClientControlWire.signedPayloadJson(type: .hello, payload: ClientControlMessage.Hello())
        XCTAssertEqual(json, #"{"protocolVersion":1,"type":"hello"}"#)
    }

    func test_scenePrepareOmitsNilDurationButKeepsDiscriminator() throws {
        let json = try ClientControlWire.signedPayloadJson(
            type: .scenePrepare,
            payload: ClientControlMessage.ScenePrepare(sceneId: "sleep", durationMinutes: nil)
        )
        // durationMinutes carries a Kotlin default of null, so omitting it is wire-legal.
        XCTAssertEqual(json, #"{"sceneId":"sleep","type":"scene_prepare"}"#)
    }

    func test_scenePrepareKeepsExplicitDuration() throws {
        let json = try ClientControlWire.signedPayloadJson(
            type: .scenePrepare,
            payload: ClientControlMessage.ScenePrepare(sceneId: "s", durationMinutes: 30)
        )
        XCTAssertEqual(json, #"{"durationMinutes":30,"sceneId":"s","type":"scene_prepare"}"#)
    }

    func test_sceneCommitPayloadCarriesBolusIdAndDiscriminator() throws {
        let json = try ClientControlWire.signedPayloadJson(type: .sceneCommit, payload: ClientControlMessage.SceneCommit(bolusId: 42))
        XCTAssertEqual(json, #"{"bolusId":42,"type":"scene_commit"}"#)
    }

    func test_sceneStopPayloadCarriesTriggerChainAndDiscriminator() throws {
        let json = try ClientControlWire.signedPayloadJson(type: .sceneStop, payload: ClientControlMessage.SceneStop(triggerChain: true))
        XCTAssertEqual(json, #"{"triggerChain":true,"type":"scene_stop"}"#)
    }

    func test_wizardPreparePayloadCarriesEveryNonDefaultedKotlinField() throws {
        let msg = ClientControlMessage.WizardPrepare(
            bg: 120, carbs: 40, percentage: 100, directCorrection: 0, carbTime: 0,
            useBg: true, useCob: true, useIob: true, useTt: true, useTrend: false,
            alarm: false, notes: "", eCarbsGrams: 0, eCarbsDelayMinutes: 0, eCarbsDurationHours: 0,
            profileName: nil
        )
        let json = try ClientControlWire.signedPayloadJson(type: .wizardPrepare, payload: msg)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(object["type"] as? String, "wizard_prepare")
        // Everything except profileName and the eCarbs trio is non-defaulted in Kotlin, so absence
        // would make the master's decode throw.
        for key in ["bg", "carbs", "percentage", "directCorrection", "carbTime", "useBg", "useCob",
                    "useIob", "useTt", "useTrend", "alarm", "notes"] {
            XCTAssertNotNil(object[key], "missing required field \(key)")
        }
        XCTAssertNil(object["profileName"])
    }

    func test_serialNamesAreTheFrozenWireContract() {
        XCTAssertEqual(ClientControlType.hello.rawValue, "hello")
        XCTAssertEqual(ClientControlType.ping.rawValue, "ping")
        XCTAssertEqual(ClientControlType.scenePrepare.rawValue, "scene_prepare")
        XCTAssertEqual(ClientControlType.sceneCommit.rawValue, "scene_commit")
        XCTAssertEqual(ClientControlType.sceneStop.rawValue, "scene_stop")
        XCTAssertEqual(ClientControlType.preferencesUpdate.rawValue, "preferences_update")
        XCTAssertEqual(ClientControlType.bolusPrepare.rawValue, "bolus_prepare")
        XCTAssertEqual(ClientControlType.bolusCommit.rawValue, "bolus_commit")
        XCTAssertEqual(ClientControlType.wizardPrepare.rawValue, "wizard_prepare")
        XCTAssertEqual(ClientControlType.batchPrepare.rawValue, "batch_prepare")
        XCTAssertEqual(ClientControlType.dismissAlarm.rawValue, "dismiss_alarm")
        XCTAssertEqual(ClientControlType.stopBolus.rawValue, "stop_bolus")
    }

    func test_identifierSchemeMatchesMaster() {
        XCTAssertEqual(ClientControlWire.identifier(for: .hello, clientId: "c1"), "aaps_clientcontrol_hello_c1")
        XCTAssertEqual(ClientControlWire.identifier(for: .scenePrepare, clientId: "c1"), "aaps_clientcontrol_cmd_scene_prepare_c1")
        XCTAssertEqual(ClientControlWire.identifier(for: .ping, clientId: "c1"), "aaps_clientcontrol_cmd_ping_c1")
        XCTAssertEqual(ClientControlWire.ackIdentifier(clientId: "c1"), "aaps_clientcontrol_ack_c1")
        XCTAssertEqual(ClientControlWire.docDate, 946_684_800_001)
    }

    // MARK: - Master→client DTOs with defaulted Kotlin fields

    func test_bolusPreviewDecodesMinimalMasterShape() throws {
        // Exactly what a scene prepare produces: the master writes acks with encodeDefaults = false,
        // so advisorApplies / advisorLines / wizardDetail never reach the wire at their defaults.
        let json = #"{"bolusId":42,"lines":[{"role":"PRIMARY","text":"x"}]}"#
        let preview = try JSONDecoder().decode(BolusPreview.self, from: Data(json.utf8))
        XCTAssertEqual(preview.bolusId, 42)
        XCTAssertEqual(preview.lines.count, 1)
        XCTAssertEqual(preview.lines.first?.role, "PRIMARY")
        XCTAssertFalse(preview.advisorApplies)
        XCTAssertTrue(preview.advisorLines.isEmpty)
        XCTAssertNil(preview.wizardDetail)
    }

    func test_bolusPreviewDecodesBolusIdOnly() throws {
        let preview = try JSONDecoder().decode(BolusPreview.self, from: Data(#"{"bolusId":7}"#.utf8))
        XCTAssertEqual(preview.bolusId, 7)
        XCTAssertTrue(preview.lines.isEmpty)
    }

    func test_wizardDetailWithoutUnclampedInsulinIsNotCapped() throws {
        let json = #"""
        {"bolusId":1,"wizardDetail":{
            "totalInsulin":2.5,"carbs":40,"insulinFromBG":0.5,"insulinFromTrend":0,"insulinFromCOB":0.3,
            "insulinFromCarbs":1.7,"insulinFromBolusIOB":0,"insulinFromBasalIOB":0,"includeBolusIOB":true,
            "includeBasalIOB":true,"percentageCorrection":100,"cob":10,"tempTargetLabel":null,"ic":8,"sens":50
        }}
        """#
        let preview = try JSONDecoder().decode(BolusPreview.self, from: Data(json.utf8))
        let detail = try XCTUnwrap(preview.wizardDetail)
        XCTAssertNil(detail.unclampedInsulin)
        XCTAssertFalse(detail.wasCapped)
    }

    func test_wizardDetailSurfacesCappedDose() throws {
        // unclampedInsulin only reaches the wire when it differs from totalInsulin — i.e. exactly
        // when a constraint reduced the dose the user asked for.
        let json = #"""
        {"bolusId":1,"wizardDetail":{
            "totalInsulin":3.0,"unclampedInsulin":7.4,"carbs":40,"insulinFromBG":0.5,"insulinFromTrend":0,
            "insulinFromCOB":0.3,"insulinFromCarbs":1.7,"insulinFromBolusIOB":0,"insulinFromBasalIOB":0,
            "includeBolusIOB":true,"includeBasalIOB":true,"percentageCorrection":100,"cob":10,
            "tempTargetLabel":"Activity","ic":8,"sens":50
        }}
        """#
        let preview = try JSONDecoder().decode(BolusPreview.self, from: Data(json.utf8))
        let detail = try XCTUnwrap(preview.wizardDetail)
        XCTAssertEqual(detail.unclampedInsulin, 7.4)
        XCTAssertTrue(detail.wasCapped)
        XCTAssertEqual(detail.tempTargetLabel, "Activity")
    }

    func test_ackEnvelopeDecodesWithoutOptionalDefaults() throws {
        // reason/payload carry Kotlin defaults of null, so they are absent at their default.
        let json = #"{"clientId":"c1","commandCounter":3,"phase":"Done","status":"Ok","timestamp":500,"signature":"ab"}"#
        let ack = try JSONDecoder().decode(AckEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(ack.phase, .done)
        XCTAssertNil(ack.payload)
    }

    // MARK: - Full-precision Kotlin doubles

    /// The shape every fixture above avoids by using round numbers. The master serializes Kotlin
    /// `Double`s at full precision, so a real wizard ack carries `0.30000000000000004` and
    /// `82.80000000000001` — exactly the values the iOS 18+ swift-foundation `JSONDecoder` number
    /// parser rejects with `dataCorrupted`. Behind `RoundTripOutcome.preview`'s `try?` that turned a
    /// command that SUCCEEDED into "unreadable", and for a scene prepare it lost the parked
    /// `bolusId` for good. `JSONSerialization` parses these into `NSNumber` without complaint.
    private static let fullPrecisionPreviewJson = #"""
    {"bolusId":42,"lines":[{"role":"PRIMARY","text":"Bolus 2.3 U"}],
     "advisorApplies":false,"advisorLines":[],
     "wizardDetail":{
        "totalInsulin":2.3000000000000003,"carbs":40,"insulinFromBG":0.5000000000000001,
        "insulinFromTrend":0,"insulinFromCOB":0.30000000000000004,"insulinFromCarbs":1.7000000000000002,
        "insulinFromBolusIOB":0,"insulinFromBasalIOB":0,"includeBolusIOB":true,"includeBasalIOB":true,
        "percentageCorrection":100,"cob":10.100000000000001,"ic":7.5,"sens":82.80000000000001
     }}
    """#

    func test_previewSurvivesFullPrecisionKotlinDoubles() throws {
        let outcome = RoundTripOutcome.applied(payload: Self.fullPrecisionPreviewJson)

        let preview = try XCTUnwrap(
            outcome.preview,
            "a real master ack must not read as 'unreadable' — that loses the parked bolusId"
        )

        XCTAssertEqual(preview.bolusId, 42)
        XCTAssertEqual(preview.lines.first?.text, "Bolus 2.3 U")
        let detail = try XCTUnwrap(preview.wizardDetail)
        XCTAssertEqual(detail.totalInsulin, 2.3, accuracy: 0.0001)
        XCTAssertEqual(detail.insulinFromCOB, 0.3, accuracy: 0.0001)
        XCTAssertEqual(detail.sens, 82.8, accuracy: 0.0001)
        // Absent on the wire: Kotlin only emits it when a constraint actually reduced the dose.
        XCTAssertNil(detail.unclampedInsulin)
        XCTAssertFalse(detail.wasCapped)
    }

    /// A scene prepare really does arrive as just `{"bolusId":…,"lines":[…]}`.
    func test_previewDecodesASceneAckWithNoWizardDetail() throws {
        let outcome = RoundTripOutcome.applied(payload: #"{"bolusId":7,"lines":[{"role":"PRIMARY","text":"Scene: Sleep"}]}"#)
        let preview = try XCTUnwrap(outcome.preview)
        XCTAssertEqual(preview.bolusId, 7)
        XCTAssertNil(preview.wizardDetail)
        XCTAssertFalse(preview.advisorApplies)
    }

    func test_previewIsNilForNonAppliedOutcomesAndForGarbage() {
        XCTAssertNil(RoundTripOutcome.unconfirmed.preview)
        XCTAssertNil(RoundTripOutcome.rejected(reason: "ControlDisabled").preview)
        XCTAssertNil(RoundTripOutcome.applied(payload: nil).preview)
        XCTAssertNil(RoundTripOutcome.applied(payload: "not json").preview)
        // `bolusId` is the one field Kotlin never defaults, so its absence means "not a prepare ack".
        XCTAssertNil(RoundTripOutcome.applied(payload: #"{"lines":[]}"#).preview)
    }
}
