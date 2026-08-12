import Foundation

/// The twelve `@SerialName` strings of AndroidAPS's sealed `ClientControlMessage`. Frozen wire
/// contract: the raw value is simultaneously the kotlinx class discriminator inside the signed
/// payload AND the `<type>` segment of the command identifier. Deriving those two independently
/// is exactly how a command ends up written to a slot the master reads under another name — so
/// they both come from here. Never rename a raw value.
enum ClientControlType: String {
    case hello
    case ping
    case scenePrepare = "scene_prepare"
    case sceneCommit = "scene_commit"
    case sceneStop = "scene_stop"
    case preferencesUpdate = "preferences_update"
    case bolusPrepare = "bolus_prepare"
    /// Present for wire completeness only. This app NEVER sends it — permanent, deliberate
    /// exclusion of bolus delivery. `wizard_prepare` is used read-only to display the master's dose.
    case bolusCommit = "bolus_commit"
    case wizardPrepare = "wizard_prepare"
    case batchPrepare = "batch_prepare"
    case dismissAlarm = "dismiss_alarm"
    case stopBolus = "stop_bolus"
}

enum ClientControlWireError: Error, Equatable {
    /// The Codable payload did not encode to a JSON object, so there is nowhere to put the
    /// kotlinx `type` discriminator the master's polymorphic decoder requires.
    case payloadNotAnObject
}

/// Constants every client-control document shares. Mirrors `ClientControlPublisher.kt`'s companion.
enum ClientControlWire {
    /// NS APIv3 `MIN_TIMESTAMP` (2000-01-01 UTC) + 1 ms. `validateCommon` demands a `date`, but the
    /// server rejects any change to it on a later PUT to the same identifier ("Field date cannot be
    /// modified by the client") — and the command slots are per-type latest-wins, so they get PUT
    /// over and over. Every client-control doc therefore carries this constant placeholder; the real
    /// time lives in the signed `envelope.timestamp`.
    static let docDate: Int64 = 946_684_800_001
    static let schemaVersion = 1

    static let identifierPrefix = "aaps_clientcontrol_"
    static let helloPrefix = identifierPrefix + "hello_"
    static let cmdPrefix = identifierPrefix + "cmd_"
    static let ackPrefix = identifierPrefix + "ack_"
    static let offerPrefix = identifierPrefix + "offer_"

    /// `aaps_clientcontrol_hello_<clientId>` for Hello, `aaps_clientcontrol_cmd_<serialName>_<clientId>`
    /// for everything else — one latest-wins slot per message type, so a fresh `scene_prepare` can
    /// never overwrite an unprocessed `scene_stop`.
    static func identifier(for type: ClientControlType, clientId: String) -> String {
        switch type {
        case .hello: return helloPrefix + clientId
        default:     return "\(cmdPrefix)\(type.rawValue)_\(clientId)"
        }
    }

    /// The master's single per-client ack slot, overwritten in place.
    static func ackIdentifier(clientId: String) -> String { ackPrefix + clientId }

    /// Builds the payload string that is BOTH the HMAC canonical input and `envelope.payload` —
    /// one string value, never two independent serializations, because the master verifies the
    /// signature against the bytes it received.
    ///
    /// The master decodes the payload with `json.decodeFromString(ClientControlMessage.serializer(), …)`,
    /// a polymorphic decode of a sealed class using kotlinx's default `classDiscriminator = "type"`.
    /// `JSONEncoder` knows nothing about that discriminator, so it is injected here after encoding;
    /// without it the master's decode throws and the command is dropped with no ack at all.
    ///
    /// `Ping` encodes to `{}` (see its explicit `encode(to:)`) — `jsonObject(with:)` turns that into
    /// an empty dictionary, so the injection still yields exactly `{"type":"ping"}`.
    ///
    /// `.sortedKeys` only makes the output pinnable in tests: the master re-derives its canonical
    /// string from the payload string it received, so key order carries no meaning on the wire.
    ///
    /// `JSONEncoder` omits nil Optionals while the master encodes with `encodeDefaults = true`. That
    /// is safe in this direction: every Kotlin field this app can leave out (`ScenePrepare.durationMinutes`,
    /// `WizardPrepare.profileName` and its eCarbs trio) carries a Kotlin default.
    static func signedPayloadJson<T: Encodable>(type: ClientControlType, payload: T) throws -> String {
        let encoded = try JSONEncoder().encode(payload)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw ClientControlWireError.payloadNotAnObject
        }
        object["type"] = type.rawValue
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let json = String(data: data, encoding: .utf8) else {
            throw ClientControlWireError.payloadNotAnObject
        }
        return json
    }
}

/// Command lifetimes, all mirrored from `ClientControlRoundTrip.kt`. The signed `validUntil` is the
/// master's hard "do not apply after this" line, so the client's own give-up must be LATER than it
/// (never earlier) or the master can still act on a command the user was told had timed out.
enum ClientControlTiming {
    /// A healthy round trip is sub-second — fast or never.
    static let roundTripMs: Int64 = 8_000
    static let pingMs: Int64 = 10_000
    /// Fire-and-forget keeps the historical ±5 min skew window as its validity.
    static let fireAndForgetMs: Int64 = 300_000
    /// Extra grace for the Done ack to travel back after `validUntil` has passed.
    static let propagationMarginMs: Int64 = 2_000
    /// The master's `timestamp` acceptance window, applied to its acks in the other direction.
    static let maxSkewSeconds: TimeInterval = 300
}

struct PairingOffer: Codable, Equatable {
    let schemaVersion: Int
    let clientId: String
    let expiresAt: Int64
    let kdfSaltB64: String
    let ivB64: String
    let wrappedB64: String
}

struct PairingPayload: Codable, Equatable {
    let v: Int
    let masterInstallId: String
    let clientId: String
    let secretHex: String
    let expiresAt: Int64
}

struct MasterPairing: Codable, Equatable {
    let masterInstallId: String
    let clientId: String
    let secretHex: String
}

struct SignedEnvelope: Codable, Equatable {
    let clientId: String
    let counter: Int64
    let timestamp: Int64
    let type: String
    let payload: String
    var signature: String
    var validUntil: Int64 = .max
    var wantsAck: Bool = false

    func canonicalString() -> String {
        "\(clientId)|\(counter)|\(timestamp)|\(validUntil)|\(wantsAck)|\(type)|\(payload)"
    }
}

/// Mirrors AndroidAPS `AckEnvelope.kt` exactly — the master's signed acknowledgement for a
/// single client-control command, written to `aaps_clientcontrol_ack_<clientId>` (overwritten
/// in place) under a top-level `"ack"` field. Field order in `canonicalString()` is the wire
/// contract for HMAC verification — do not reorder.
struct AckEnvelope: Codable, Equatable {
    let clientId: String
    let commandCounter: Int64
    let phase: AckPhase
    let status: AckStatus
    let reason: String?
    let payload: String?
    let timestamp: Int64
    var signature: String

    func canonicalString() -> String {
        "\(clientId)|\(commandCounter)|\(phase.rawValue)|\(status.rawValue)|\(reason ?? "")|\(payload ?? "")|\(timestamp)"
    }
}

/// Matches Kotlin's `@SerialName`-annotated enum cases exactly (case-sensitive on the wire).
enum AckPhase: String, Codable {
    case executing = "Executing"
    case done = "Done"
    case delivery = "Delivery"
}

enum AckStatus: String, Codable {
    case pending = "Pending"
    case ok = "Ok"
    case failed = "Failed"
    case expired = "Expired"
}

enum ClientControlMessage {
    struct Hello: Codable {
        var protocolVersion: Int = 1
        static let type: ClientControlType = .hello
    }

    /// Kotlin `data object Ping` — on the wire it is exactly `{"type":"ping"}`.
    ///
    /// `encode(to:)` is written out rather than synthesized: a struct with no stored properties gives
    /// `JSONEncoder` nothing to write, and a top-level value that writes nothing makes it throw
    /// "did not encode any values". Emitting an explicit empty object keeps the discriminator
    /// injection in `ClientControlWire.signedPayloadJson` working.
    struct Ping: Codable {
        static let type: ClientControlType = .ping

        init() {}
        init(from decoder: Decoder) throws {}

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode([String: String]())
        }
    }

    /// Asks the master to PREPARE a manual wizard-computed bolus from these raw inputs — the master
    /// recomputes the dose on its OWN live profile/COB/IOB, constraint-caps it, and returns the full
    /// breakdown in `BolusPreview.wizardDetail`. This app NEVER sends the matching commit — see the
    /// plan header for why (permanent, deliberate bolus exclusion). `bg`/`carbs` mirror the master's
    /// own manual bolus-wizard dialog inputs exactly.
    struct WizardPrepare: Codable {
        let bg: Double
        let carbs: Int
        let percentage: Int
        let directCorrection: Double
        let carbTime: Int
        let useBg: Bool
        let useCob: Bool
        let useIob: Bool
        let useTt: Bool
        let useTrend: Bool
        let alarm: Bool
        let notes: String
        let eCarbsGrams: Int
        let eCarbsDelayMinutes: Int
        let eCarbsDurationHours: Int
        let profileName: String?
        static let type: ClientControlType = .wizardPrepare

        /// Converts a mg/dL glucose value into the units `bg` must travel in.
        ///
        /// `bg` is NOT mg/dL — it is the value in the master's own BG field, i.e. the master's
        /// display units. `BolusWizard.doCalc` compares it against `targetBGLow/High =
        /// profileUtil.fromMgdlToUnits(...)` and only ever converts it back with
        /// `profileUtil.convertToMgdl(bg, units)`. Sending 120 to an mmol/L master therefore means
        /// 120 mmol/L: `bgDiff ≈ 114`, `insulinFromBG ≈ 38 U`, the constraint check trips and the
        /// master answers `BolusComputeFailed`/`wizard_constraint_bolus_size`. The calculator was
        /// permanently non-functional against every mmol master.
        ///
        /// Pass the MASTER's units (`NsProfile.units` from its uploaded profile), never the local
        /// display preference — the two are set independently.
        static func bgValue(mgdl: Double, masterUnits: GlucoseUnits) -> Double {
            masterUnits == .mmol ? mgdl / glucoseMmolFactor : mgdl
        }
    }

    /// Asks the master to PREPARE activating the named scene — validated + parked, returns a
    /// `BolusPreview` in the signed ack. Nothing activates until a matching `SceneCommit`.
    /// `durationMinutes: nil` uses the scene's own stored default duration.
    struct ScenePrepare: Codable {
        let sceneId: String
        let durationMinutes: Int?
        static let type: ClientControlType = .scenePrepare
    }

    /// Confirms a prepared scene: the master activates the parked scene matching `bolusId` exactly
    /// once (a re-sent commit safely no-ops on an already-consumed id).
    struct SceneCommit: Codable {
        let bolusId: Int64
        static let type: ClientControlType = .sceneCommit
    }

    /// Deactivates whatever scene is currently active. `triggerChain: true` mirrors the master's own
    /// "Skip to <chain target>" — the master resolves the chain target FRESH at receipt time using
    /// its own current config, so a stale client view can never trigger an unintended scene.
    struct SceneStop: Codable {
        var triggerChain: Bool = false
        static let type: ClientControlType = .sceneStop
    }
}

/// The master's computed preview for any two-step prepare→commit action (scene/wizard/bolus/batch),
/// carried in `AckEnvelope.payload` for a `..Prepare` ack. Mirrors AndroidAPS `BolusPreview.kt`
/// exactly — despite the name, this is the generic "prepared action" envelope reused across every
/// prepare type on the master, not bolus-specific.
///
/// **General rule for every master→client DTO in this file:** the master writes acks with
/// `Json { ignoreUnknownKeys = true }`, leaving `encodeDefaults` at kotlinx's default of FALSE, so
/// any Kotlin field sitting at its default is simply absent from the JSON. Swift's synthesized
/// `init(from:)` calls `decode(_:forKey:)` for every non-Optional property and throws `keyNotFound`
/// — memberwise defaults do not participate in Codable synthesis. So: a Kotlin field with a default
/// MUST be read with `decodeIfPresent` and the Kotlin default supplied here, or be Optional.
struct BolusPreview: Codable, Equatable {
    let bolusId: Int64
    let lines: [ConfirmationLineDto]
    let advisorApplies: Bool
    let advisorLines: [ConfirmationLineDto]
    let wizardDetail: WizardDetailDto?

    init(bolusId: Int64, lines: [ConfirmationLineDto] = [], advisorApplies: Bool = false, advisorLines: [ConfirmationLineDto] = [], wizardDetail: WizardDetailDto? = nil) {
        self.bolusId = bolusId
        self.lines = lines
        self.advisorApplies = advisorApplies
        self.advisorLines = advisorLines
        self.wizardDetail = wizardDetail
    }

    /// A scene prepare really does arrive as `{"bolusId":…,"lines":[…]}` — everything else omitted.
    /// Only `bolusId` is non-defaulted in Kotlin and therefore always present.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bolusId = try c.decode(Int64.self, forKey: .bolusId)
        lines = try c.decodeIfPresent([ConfirmationLineDto].self, forKey: .lines) ?? []
        advisorApplies = try c.decodeIfPresent(Bool.self, forKey: .advisorApplies) ?? false
        advisorLines = try c.decodeIfPresent([ConfirmationLineDto].self, forKey: .advisorLines) ?? []
        wizardDetail = try c.decodeIfPresent(WizardDetailDto.self, forKey: .wizardDetail)
    }
}

/// One confirmation line — the master's already-localized, color-coded wizard/scene confirmation text.
/// Mirrors AndroidAPS `ConfirmationLineDto.kt`.
struct ConfirmationLineDto: Codable, Equatable {
    let role: String
    let text: String
}

/// Raw wizard calculation breakdown, present only on `WizardPrepare`/`BolusPrepare` acks (absent for
/// scene/batch-only prepares, hence optional on `BolusPreview`). Mirrors AndroidAPS `WizardDetailDto.kt`.
///
/// Every field declared here except `unclampedInsulin` is non-defaulted in Kotlin and therefore
/// always on the wire. The Kotlin DTO carries eight further defaulted fields (the eCarbs trio,
/// `carbTimeMinutes`, `alarm`, `maxBolus`, `bolusStep`) that this app does not render — leaving
/// them undeclared is safe in both directions.
struct WizardDetailDto: Codable, Equatable {
    let totalInsulin: Double
    /// The dose BEFORE constraint capping. Kotlin defaults it to `totalInsulin`, so with
    /// `encodeDefaults = false` it reaches the wire only when it DIFFERS — i.e. exactly when a
    /// constraint reduced what the user asked for. Absent (nil) therefore means "nothing was capped".
    let unclampedInsulin: Double?
    let carbs: Int
    let insulinFromBG: Double
    let insulinFromTrend: Double
    let insulinFromCOB: Double
    let insulinFromCarbs: Double
    let insulinFromBolusIOB: Double
    let insulinFromBasalIOB: Double
    let includeBolusIOB: Bool
    let includeBasalIOB: Bool
    let percentageCorrection: Int
    let cob: Double
    let tempTargetLabel: String?
    let ic: Double
    let sens: Double

    /// The master reduced the requested dose — render "capped from X U" when this is true.
    var wasCapped: Bool {
        guard let unclampedInsulin else { return false }
        return unclampedInsulin - totalInsulin > 0.0001
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalInsulin = try c.decode(Double.self, forKey: .totalInsulin)
        unclampedInsulin = try c.decodeIfPresent(Double.self, forKey: .unclampedInsulin)
        carbs = try c.decode(Int.self, forKey: .carbs)
        insulinFromBG = try c.decode(Double.self, forKey: .insulinFromBG)
        insulinFromTrend = try c.decode(Double.self, forKey: .insulinFromTrend)
        insulinFromCOB = try c.decode(Double.self, forKey: .insulinFromCOB)
        insulinFromCarbs = try c.decode(Double.self, forKey: .insulinFromCarbs)
        insulinFromBolusIOB = try c.decode(Double.self, forKey: .insulinFromBolusIOB)
        insulinFromBasalIOB = try c.decode(Double.self, forKey: .insulinFromBasalIOB)
        includeBolusIOB = try c.decode(Bool.self, forKey: .includeBolusIOB)
        includeBasalIOB = try c.decode(Bool.self, forKey: .includeBasalIOB)
        percentageCorrection = try c.decode(Int.self, forKey: .percentageCorrection)
        cob = try c.decode(Double.self, forKey: .cob)
        tempTargetLabel = try c.decodeIfPresent(String.self, forKey: .tempTargetLabel)
        ic = try c.decode(Double.self, forKey: .ic)
        sens = try c.decode(Double.self, forKey: .sens)
    }

    /// Declaring `init(from:)` above suppresses the synthesized memberwise init, and
    /// `init?(jsonObject:)` below needs one.
    init(
        totalInsulin: Double,
        unclampedInsulin: Double?,
        carbs: Int,
        insulinFromBG: Double,
        insulinFromTrend: Double,
        insulinFromCOB: Double,
        insulinFromCarbs: Double,
        insulinFromBolusIOB: Double,
        insulinFromBasalIOB: Double,
        includeBolusIOB: Bool,
        includeBasalIOB: Bool,
        percentageCorrection: Int,
        cob: Double,
        tempTargetLabel: String?,
        ic: Double,
        sens: Double
    ) {
        self.totalInsulin = totalInsulin
        self.unclampedInsulin = unclampedInsulin
        self.carbs = carbs
        self.insulinFromBG = insulinFromBG
        self.insulinFromTrend = insulinFromTrend
        self.insulinFromCOB = insulinFromCOB
        self.insulinFromCarbs = insulinFromCarbs
        self.insulinFromBolusIOB = insulinFromBolusIOB
        self.insulinFromBasalIOB = insulinFromBasalIOB
        self.includeBolusIOB = includeBolusIOB
        self.includeBasalIOB = includeBasalIOB
        self.percentageCorrection = percentageCorrection
        self.cob = cob
        self.tempTargetLabel = tempTargetLabel
        self.ic = ic
        self.sens = sens
    }
}

// MARK: - JSONSerialization decoding of the ack payload
//
// The ack payload is Kotlin `Json.encodeToString(...)` of `Double`s, i.e. full 17-significant-digit
// values like `0.30000000000000004`. The iOS 18+ swift-foundation `JSONDecoder` number parser throws
// `dataCorrupted` ("Number … is not representable in Swift") on exactly those, which is why the whole
// app reads AAPS JSON through `JSONSerialization` — see the header of `NsMapping`. These initializers
// are that rule applied to the client-control ack path; `Codable` above stays for the fixtures and
// for anything that round-trips these DTOs locally.

extension ConfirmationLineDto {
    static func list(fromJsonArray value: Any?) -> [ConfirmationLineDto] {
        (value as? [[String: Any]])?.compactMap {
            guard let role = $0["role"] as? String, let text = $0["text"] as? String else { return nil }
            return ConfirmationLineDto(role: role, text: text)
        } ?? []
    }
}

extension WizardDetailDto {
    init?(jsonObject: Any?) {
        guard let d = jsonObject as? [String: Any], d["totalInsulin"] != nil else { return nil }
        func number(_ key: String) -> Double? { (d[key] as? NSNumber)?.doubleValue }
        func required(_ key: String) -> Double { number(key) ?? 0 }
        func flag(_ key: String) -> Bool { (d[key] as? NSNumber)?.boolValue ?? false }
        self.init(
            totalInsulin: required("totalInsulin"),
            unclampedInsulin: number("unclampedInsulin"),
            carbs: Int(required("carbs")),
            insulinFromBG: required("insulinFromBG"),
            insulinFromTrend: required("insulinFromTrend"),
            insulinFromCOB: required("insulinFromCOB"),
            insulinFromCarbs: required("insulinFromCarbs"),
            insulinFromBolusIOB: required("insulinFromBolusIOB"),
            insulinFromBasalIOB: required("insulinFromBasalIOB"),
            includeBolusIOB: flag("includeBolusIOB"),
            includeBasalIOB: flag("includeBasalIOB"),
            percentageCorrection: Int(required("percentageCorrection")),
            cob: required("cob"),
            tempTargetLabel: d["tempTargetLabel"] as? String,
            ic: required("ic"),
            sens: required("sens")
        )
    }
}

extension BolusPreview {
    /// nil when the object is not a preview at all. `bolusId` is the one field Kotlin never defaults,
    /// so its absence means this is not a `..Prepare` ack payload.
    init?(jsonObject: Any?) {
        guard let d = jsonObject as? [String: Any],
              let bolusId = (d["bolusId"] as? NSNumber)?.int64Value else { return nil }
        self.init(
            bolusId: bolusId,
            lines: ConfirmationLineDto.list(fromJsonArray: d["lines"]),
            advisorApplies: (d["advisorApplies"] as? NSNumber)?.boolValue ?? false,
            advisorLines: ConfirmationLineDto.list(fromJsonArray: d["advisorLines"]),
            wizardDetail: WizardDetailDto(jsonObject: d["wizardDetail"])
        )
    }
}
