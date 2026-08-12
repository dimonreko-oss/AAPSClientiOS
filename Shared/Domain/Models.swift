import Foundation

enum TrendArrow: String, Codable {
    case doubleUp, singleUp, fortyFiveUp, flat, fortyFiveDown, singleDown, doubleDown, none
}

enum GlucoseClassification {
    case urgentLow, low, inRange, high, urgentHigh
}

enum GlucoseUnits: String, Codable {
    case mgdl = "mg/dl"
    case mmol = "mmol/l"

    /// Lenient parse of a Nightscout/AAPS units string. Profiles commonly use
    /// "mmol", "mmol/L", or "mmol/l" — the strict rawValue only matches "mmol/l",
    /// so anything containing "mmol" maps to .mmol, everything else to .mgdl.
    init(nsUnits: String?) {
        self = (nsUnits?.lowercased().contains("mmol") == true) ? .mmol : .mgdl
    }
}

struct GlucoseReading: Equatable, Identifiable {
    var id: Date { date }
    let date: Date
    let mgdl: Int
    let trend: TrendArrow
}

struct LoopStatus: Equatable {
    let iob: Double
    let cob: Double
    let eventualBgMgdl: Int?
    let tempBasalRate: Double?
    let suggestedReason: String?
    /// APS-run time taken from the `openaps` block. Optional because a devicestatus without a usable
    /// APS result must never be given a synthesized `Date()` — that renders a stopped loop as fresh.
    /// `nil` here makes `LoopStateCalc` report `.unknown` instead of `.looping`.
    let timestamp: Date?
    let predictions: Predictions?
    let pumpBattery: Int?
    let pumpReservoir: Double?
    let uploaderBattery: Int?
    let reason: LoopReason?
    /// `RT.carbsReq` — grams the master wants the user to eat. The one piece of v4 telemetry a carer
    /// can act on directly, so it is carried even though nothing renders it yet.
    let carbsReq: Int?
    /// `RT.carbsReqWithin` — minutes within which those carbs are needed.
    let carbsReqWithin: Int?
    /// The newest devicestatus DOCUMENT's own `date` — the master's upload heartbeat, which v4's
    /// `KeepAliveWorker` writes every five minutes *whether or not the loop ran*.
    ///
    /// Deliberately separate from `timestamp`: that one dates the APS result and is the freshness
    /// signal for the loop dot, while this one only says "the master is still uploading". Master
    /// liveness must key on THIS, or a legitimately suspended loop reads as an absent master and the
    /// app refuses to send the very command that would resume it.
    let deviceDate: Date?

    /// Explicit init so appending v4 fields does not break existing positional call sites.
    init(
        iob: Double,
        cob: Double,
        eventualBgMgdl: Int?,
        tempBasalRate: Double?,
        suggestedReason: String?,
        timestamp: Date?,
        predictions: Predictions?,
        pumpBattery: Int?,
        pumpReservoir: Double?,
        uploaderBattery: Int?,
        reason: LoopReason?,
        carbsReq: Int? = nil,
        carbsReqWithin: Int? = nil,
        deviceDate: Date? = nil
    ) {
        self.iob = iob
        self.cob = cob
        self.eventualBgMgdl = eventualBgMgdl
        self.tempBasalRate = tempBasalRate
        self.suggestedReason = suggestedReason
        self.timestamp = timestamp
        self.predictions = predictions
        self.pumpBattery = pumpBattery
        self.pumpReservoir = pumpReservoir
        self.uploaderBattery = uploaderBattery
        self.reason = reason
        self.carbsReq = carbsReq
        self.carbsReqWithin = carbsReqWithin
        self.deviceDate = deviceDate
    }
}

struct DeviceStatusEntry: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let iob: Double
    let cob: Double
}

struct Predictions: Equatable {
    let iob: [Int]
    let cob: [Int]
    let zt: [Int]
    let uam: [Int]

    /// Reconstruction of the master's own scalar `minPredBG`, for the predicted-low alarm.
    ///
    /// v4 serializes the APS result from `RT`, which has no `minPredBG` key at all, so it has to be
    /// derived from `predBGs`. It is NOT a global minimum: `DetermineBasalAutoISF.doDetermineBasal`
    /// takes the *least alarming* of the per-curve minima — `max(minIOBPredBG, minCOBPredBG)` when
    /// carbs are in play, `max(minIOBPredBG, minZTUAMPredBG)` in pure-UAM mode — and clamps each
    /// curve at 39. `zt` never enters directly: the zero-temp curve is a safety envelope that dips
    /// below target on almost every loop cycle by construction, and oref tracks it separately as
    /// `minZTGuardBG`. A global `min()` over all four curves is therefore systematically lower than
    /// the number the master itself acts on, which means "Predicted Low — consider carbs" every five
    /// minutes all night against a perfectly healthy loop. In a follower an alarm storm is a safety
    /// failure: it teaches the user to mute the app.
    ///
    /// The COB curve stands in for "carbs are in play" (the master only publishes it then), and UAM
    /// stands in for `minZTUAMPredBG`, whose ZT blend we cannot reproduce from the published arrays.
    var minimumMgdl: Int? {
        let secondary = cob.isEmpty ? uam.min() : cob.min()
        guard let iobMin = iob.min() else { return secondary }
        guard let secondary else { return iobMin }
        return max(iobMin, secondary)
    }

    /// The zero-temp guard trough. Display only — never alarm on it; see `minimumMgdl`.
    var zeroTempMinimumMgdl: Int? { zt.min() }
}

struct Treatment: Equatable, Identifiable, Codable {
    let id: String
    let eventType: String
    let date: Date
    let insulin: Double?
    let carbs: Double?
    let durationMin: Int?
    let enteredBy: String?
    let notes: String?
    let targetBottom: Int?
    let targetTop: Int?
    let profileName: String?
    let percentage: Int?
    let absolute: Double?
    let tempBasalPercent: Int?

    // MARK: v4 RunningMode fields (`OpenAPS Offline` treatments)

    /// Raw `RM.Mode` name as written by the master (`CLOSED_LOOP`, `SUSPENDED_BY_DST`, …).
    /// Kept verbatim rather than pre-translated so the mode can be reasoned about, not just printed.
    let mode: String?
    /// `originalDuration`, in **milliseconds**. v4 writes working modes with a wire `duration` of 0
    /// and the real span here, and substitutes a decade for a permanent `DISABLED_LOOP` (so the NS
    /// offline marker renders) while keeping 0 here. Reading `duration` alone therefore inverts both.
    let originalDurationMs: Int64?
    /// True when the master forced the mode from a constraint rather than the user choosing it.
    let autoForced: Bool?
    /// Master's reason list for an auto-forced mode change.
    let reasons: String?
    /// NS API v3 sets this false on deleted documents. Absent means valid.
    let isValid: Bool

    /// Duration the master itself reconstructs in `NSOfflineEvent.toRunningMode()`:
    /// `originalDuration ?: duration`, where `originalDuration` is already milliseconds and the wire
    /// `duration` is minutes. 0 means "permanent" for a RunningMode row.
    var effectiveDurationMs: Int64 {
        originalDurationMs ?? Int64(durationMin ?? 0) * 60_000
    }

    /// New fields are defaulted so existing positional call sites keep compiling.
    init(
        id: String,
        eventType: String,
        date: Date,
        insulin: Double?,
        carbs: Double?,
        durationMin: Int?,
        enteredBy: String?,
        notes: String?,
        targetBottom: Int?,
        targetTop: Int?,
        profileName: String?,
        percentage: Int?,
        absolute: Double?,
        tempBasalPercent: Int?,
        mode: String? = nil,
        originalDurationMs: Int64? = nil,
        autoForced: Bool? = nil,
        reasons: String? = nil,
        isValid: Bool = true
    ) {
        self.id = id
        self.eventType = eventType
        self.date = date
        self.insulin = insulin
        self.carbs = carbs
        self.durationMin = durationMin
        self.enteredBy = enteredBy
        self.notes = notes
        self.targetBottom = targetBottom
        self.targetTop = targetTop
        self.profileName = profileName
        self.percentage = percentage
        self.absolute = absolute
        self.tempBasalPercent = tempBasalPercent
        self.mode = mode
        self.originalDurationMs = originalDurationMs
        self.autoForced = autoForced
        self.reasons = reasons
        self.isValid = isValid
    }

    enum CodingKeys: String, CodingKey {
        case id, eventType, date, insulin, carbs, durationMin, enteredBy, notes
        case targetBottom, targetTop, profileName, percentage, absolute, tempBasalPercent
        case mode, originalDurationMs, autoForced, reasons, isValid
    }

    /// Explicit decode so a `HistoryCache` written by a build without the v4 fields still loads —
    /// the synthesized decoder would throw `keyNotFound` on `isValid` and wipe the cached window.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        eventType = try c.decode(String.self, forKey: .eventType)
        date = try c.decode(Date.self, forKey: .date)
        insulin = try c.decodeIfPresent(Double.self, forKey: .insulin)
        carbs = try c.decodeIfPresent(Double.self, forKey: .carbs)
        durationMin = try c.decodeIfPresent(Int.self, forKey: .durationMin)
        enteredBy = try c.decodeIfPresent(String.self, forKey: .enteredBy)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        targetBottom = try c.decodeIfPresent(Int.self, forKey: .targetBottom)
        targetTop = try c.decodeIfPresent(Int.self, forKey: .targetTop)
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName)
        percentage = try c.decodeIfPresent(Int.self, forKey: .percentage)
        absolute = try c.decodeIfPresent(Double.self, forKey: .absolute)
        tempBasalPercent = try c.decodeIfPresent(Int.self, forKey: .tempBasalPercent)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        originalDurationMs = try c.decodeIfPresent(Int64.self, forKey: .originalDurationMs)
        autoForced = try c.decodeIfPresent(Bool.self, forKey: .autoForced)
        reasons = try c.decodeIfPresent(String.self, forKey: .reasons)
        isValid = try c.decodeIfPresent(Bool.self, forKey: .isValid) ?? true
    }

    static func activeTempTarget(in treatments: [Treatment], now: Date = Date()) -> Treatment? {
        guard let latest = treatments
            .filter({ $0.eventType == "Temporary Target" && $0.date <= now })
            .max(by: { $0.date < $1.date }),
              let duration = latest.durationMin,
              duration > 0,
              latest.targetBottom != nil || latest.targetTop != nil,
              latest.date.addingTimeInterval(Double(duration) * 60) > now else {
            return nil
        }
        return latest
    }

    static func mergedHistoryWindow(
        existing: [Treatment],
        incoming: [Treatment],
        now: Date = Date(),
        days: Int = 7
    ) -> [Treatment] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var byID: [String: Treatment] = [:]

        for treatment in existing where treatment.date >= cutoff {
            byID[treatment.id] = treatment
        }
        for treatment in incoming where treatment.date >= cutoff {
            byID[treatment.id] = treatment
        }

        return byID.values.sorted { $0.date > $1.date }
    }
}

struct NsProfile: Equatable {
    let units: GlucoseUnits
    /// Insulin duration in hours.
    ///
    /// v4 no longer writes `dia` into the uploaded profile store (`ProfileRepositoryImpl`
    /// .createAndStoreConvertedProfile puts only carbratio/sens/basal/targets/units/timezone), because
    /// insulin duration moved into `ICfg.insulinEndTime`. So this is nil on every v4 profile unless
    /// filled from an insulin config — see `fillingInsulin(from:)`.
    let dia: Double?
    let basal: [BasalEntry]
    let targetLow: [ScheduledValue]
    let targetHigh: [ScheduledValue]
    let carbRatio: [ScheduledValue]
    let sensitivity: [ScheduledValue]
    /// `ICfg.insulinLabel` — e.g. "Rapid-Acting Oref".
    let insulinLabel: String?
    /// `ICfg.insulinPeakTime` converted to minutes.
    let insulinPeakTimeMin: Int?
    /// `ICfg.concentration` — 1.0 for U100, 2.0 for U200. Affects how amounts must be rendered.
    let concentration: Double?

    init(
        units: GlucoseUnits,
        dia: Double?,
        basal: [BasalEntry],
        targetLow: [ScheduledValue],
        targetHigh: [ScheduledValue],
        carbRatio: [ScheduledValue],
        sensitivity: [ScheduledValue],
        insulinLabel: String? = nil,
        insulinPeakTimeMin: Int? = nil,
        concentration: Double? = nil
    ) {
        self.units = units
        self.dia = dia
        self.basal = basal
        self.targetLow = targetLow
        self.targetHigh = targetHigh
        self.carbRatio = carbRatio
        self.sensitivity = sensitivity
        self.insulinLabel = insulinLabel
        self.insulinPeakTimeMin = insulinPeakTimeMin
        self.concentration = concentration
    }

    /// Fill the insulin fields this profile is missing from the master's published insulin config.
    ///
    /// Only fills what is absent, so a legacy master that still writes `dia` into the store keeps
    /// winning over the synced pref.
    func fillingInsulin(from config: NsInsulinConfig?) -> NsProfile {
        guard let config else { return self }
        return NsProfile(
            units: units,
            dia: dia ?? config.diaHours,
            basal: basal,
            targetLow: targetLow,
            targetHigh: targetHigh,
            carbRatio: carbRatio,
            sensitivity: sensitivity,
            insulinLabel: insulinLabel ?? config.label,
            insulinPeakTimeMin: insulinPeakTimeMin ?? config.peakMinutes,
            concentration: concentration ?? config.concentration
        )
    }
}

/// One entry of the master's `insulin_configuration` cold-synced pref
/// (`{"insulin":[{insulinLabel, insulinEndTime, insulinPeakTime, concentration, insulinNickname}]}`).
/// `insulinEndTime`/`insulinPeakTime` are milliseconds on the wire; exposed here in the units the UI uses.
struct NsInsulinConfig: Equatable, Identifiable, Sendable {
    let label: String
    let nickname: String?
    /// `insulinEndTime` in hours — the v4 replacement for the profile store's old `dia`.
    let diaHours: Double?
    let peakMinutes: Int?
    let concentration: Double?

    var id: String { label }
}

struct NsProfileStore: Equatable {
    let defaultProfileName: String
    let profileNames: [String]
    let rawJson: [String: String]
    let active: NsProfile
}

struct NsSettingsDocument: Equatable, Sendable {
    let identifier: String
    let app: String?
    let schemaVersion: Int?
    let date: Date?
    let srvModified: Date?
    let runningConfigJson: String
}

struct NsAuthorizedClients: Equatable, Sendable {
    let clientIds: [String]
}

struct NsActiveScene: Equatable, Sendable {
    let sceneId: String?
    let activatedAt: Date?
    let durationMs: Int?
    let lifecycle: String?
    let ttNsId: String?
    let psNsId: String?
    let rmNsId: String?
    let teNsId: String?

    /// The master publishes the hot doc with `explicitNulls = false`, so a pre-lifecycle master omits
    /// `lifecycle` entirely — which it documents as meaning ACTIVE. Absence of the whole `activeScene`
    /// block (handled in `NsMapping.runningConfigHot`) is what means "no scene".
    var isActive: Bool {
        (lifecycle ?? "ACTIVE") == "ACTIVE"
    }
}

/// Open, never-enumerated view of the master's flat `syncedPrefs` block.
///
/// AAPS keys this map by `key.key` — the **preference key string** declared on each `*Key` enum entry
/// (`StringNonKey.SceneDefinitions(key = "scene_definitions", …)`), never by the Kotlin enum name.
/// The PascalCase spellings are kept only as a fallback for hand-written fixtures and any pre-release
/// master; the snake_case wire key is authoritative. Unknown keys stay in `rawValues` untouched.
struct NsSyncedPrefsSnapshot: Equatable, Sendable {
    let rawValues: [String: String]

    var activePluginAps: String? { value("active_plugin_aps", "ActivePluginAps") }
    var activePluginSensitivity: String? { value("active_plugin_sensitivity", "ActivePluginSensitivity") }
    var activePluginSmoothing: String? { value("active_plugin_smoothing", "ActivePluginSmoothing") }
    var activePluginCalibration: String? { value("active_plugin_calibration", "ActivePluginCalibration") }
    var tempTargetPresetsJson: String? { value("temp_target_presets", "TempTargetPresets") }
    /// The one key whose wire string really is PascalCase (`StringNonKey.QuickWizard(key = "QuickWizard")`).
    var quickWizardJson: String? { value("QuickWizard", "quick_wizard") }
    var sceneDefinitionsJson: String? { value("scene_definitions", "SceneDefinitions") }
    /// Whole local profile list: `{"lastChange": <ms>, "profiles": [{name, mgdl, ic, isf, basal, targetLow, targetHigh}]}`.
    var localProfileDataJson: String? { value("local_profile_data", "LocalProfileData") }
    /// `{"insulin":[{insulinLabel, insulinEndTime, insulinPeakTime, concentration, insulinNickname}]}`.
    var insulinConfigurationJson: String? { value("insulin_configuration", "InsulinConfiguration") }

    private func value(_ wireKey: String, _ legacyName: String) -> String? {
        let raw = rawValues[wireKey] ?? rawValues[legacyName]
        return (raw?.isEmpty == false) ? raw : nil
    }
}

struct NsRunningConfigCold: Equatable, Sendable {
    var pump: String?
    var version: String?
    var isFakingTempsByExtendedBoluses: Bool?
    var syncedPrefs: [String: String]
    var authorizedClientIds: [String]
    /// Whether the document actually CARRIED an `authorizedClients` block.
    ///
    /// The distinction matters and cannot be recovered from `authorizedClientIds` alone: an absent
    /// block is no evidence about this client (`OrphanDetector.kt` returns early on a null roster),
    /// while a block listing nobody is a real revocation. Flattening both to `[]` meant a master on
    /// an older fork build durably revoked every follower — persisted, notified, and with a
    /// "Pair again" that could not fix it.
    var authorizedClientsPublished: Bool = true
    var srvModified: Date?

    var syncedPrefsSnapshot: NsSyncedPrefsSnapshot {
        NsSyncedPrefsSnapshot(rawValues: syncedPrefs)
    }

    var remoteCapabilities: NsRemoteCapabilities {
        NsRemoteCapabilities(syncedPrefs: syncedPrefs)
    }
}

struct NsRunningConfigHot: Equatable, Sendable {
    var activeScene: NsActiveScene?
    var usedAutosensOnMainPhone: Bool?
    var srvModified: Date?
}

/// What the master says a follower is allowed to send it.
///
/// **Fail open on absence.** Verified against `core/keys/BooleanKey.kt` on `dev4_main_cust`: none of
/// the `NsClientAccept*` entries (nor `NsClient3UseWs`) declares a `SyncSpec`, and
/// `RunningConfigurationImpl.buildSyncedPrefs()` publishes only keys whose `sync?.channel == Cold`.
/// So those flags never reach the wire at all today, and treating "absent" as "false" would
/// permanently grey out Profile Switch, Log Event and the whole Loop Mode menu against every real v4
/// master. A master that does not advertise a capability must not lock the follower out; only an
/// explicitly published `false` disables an action.
///
/// `NsClientAllowClientControl` is the exception: it *is* declared `SyncSpec(Cold, MasterOnly)` and is
/// published with its computed effective value, so its absence genuinely means "master too old to
/// serve client control" and it fails closed.
struct NsRemoteCapabilities: Equatable, Sendable {
    let canReceiveProfileStore: Bool
    let canRemoteProfileSwitch: Bool
    let canRemoteTempTarget: Bool
    let canRemoteCarbs: Bool
    let canRemoteTherapyEvents: Bool
    let canRemoteRunningMode: Bool
    let canRemoteTbrEb: Bool
    let clientControlEnabled: Bool
    let usesWebSockets: Bool

    /// Raw published values, `nil` where the master published nothing. Consumers that need to
    /// distinguish "not advertised" from "explicitly off" (e.g. a master-reachability gate) read these
    /// rather than the fail-open booleans above.
    let publishedFlags: [NsRemoteCapabilityKey: Bool]
    /// Raw `ns_allow_client_control`, `nil` when the master published nothing.
    let publishedClientControlEnabled: Bool?

    init(syncedPrefs: [String: String]) {
        let profileStore = NsRemoteCapabilities.boolFlag(["ns_receive_profile_store", "NsClientAcceptProfileStore"], in: syncedPrefs)
        let profileSwitch = NsRemoteCapabilities.boolFlag(["ns_receive_profile_switch", "NsClientAcceptProfileSwitch"], in: syncedPrefs)
        let tempTarget = NsRemoteCapabilities.boolFlag(["ns_receive_temp_target", "NsClientAcceptTempTarget"], in: syncedPrefs)
        let carbs = NsRemoteCapabilities.boolFlag(["ns_receive_carbs", "NsClientAcceptCarbs"], in: syncedPrefs)
        let therapyEvents = NsRemoteCapabilities.boolFlag(["ns_receive_therapy_events", "NsClientAcceptTherapyEvent"], in: syncedPrefs)
        let runningMode = NsRemoteCapabilities.boolFlag(["ns_receive_running_mode", "NsClientAcceptRunningMode"], in: syncedPrefs)
        let tbrEb = NsRemoteCapabilities.boolFlag(["ns_receive_tbr_eb", "NsClientAcceptTbrEb"], in: syncedPrefs)
        let clientControl = NsRemoteCapabilities.boolFlag(["ns_allow_client_control", "NsClientAllowClientControl"], in: syncedPrefs)
        let webSockets = NsRemoteCapabilities.boolFlag(["ns_use_ws", "NsClient3UseWs"], in: syncedPrefs)

        canReceiveProfileStore = profileStore ?? true
        canRemoteProfileSwitch = profileSwitch ?? true
        canRemoteTempTarget = tempTarget ?? true
        canRemoteCarbs = carbs ?? true
        canRemoteTherapyEvents = therapyEvents ?? true
        canRemoteRunningMode = runningMode ?? true
        canRemoteTbrEb = tbrEb ?? true
        clientControlEnabled = clientControl ?? false
        usesWebSockets = webSockets ?? true

        // Assigning nil through the subscript removes the key, so `publishedFlags[key] == nil`
        // means "the master published nothing for it".
        var published: [NsRemoteCapabilityKey: Bool] = [:]
        published[.profileSwitch] = profileSwitch
        published[.tempTarget] = tempTarget
        published[.carbs] = carbs
        published[.therapyEvents] = therapyEvents
        published[.runningMode] = runningMode
        publishedFlags = published
        publishedClientControlEnabled = clientControl
    }

    /// `nil` when no spelling of the key was published — the caller decides the default.
    private static func boolFlag(_ keys: [String], in syncedPrefs: [String: String]) -> Bool? {
        var normalized: [String: String] = [:]
        for (key, value) in syncedPrefs {
            // First spelling wins so a duplicate key differing only in case cannot flip the verdict.
            let name = normalize(key)
            if normalized[name] == nil { normalized[name] = value }
        }
        for key in keys {
            guard let raw = normalized[normalize(key)]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !raw.isEmpty else { continue }
            switch raw {
            case "true", "1": return true
            case "false", "0": return false
            default: continue
            }
        }
        return nil
    }

    private static func normalize(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension NsRemoteCapabilities {
    func isEnabled(for key: NsRemoteCapabilityKey) -> Bool {
        switch key {
        case .profileSwitch: return canRemoteProfileSwitch
        case .tempTarget: return canRemoteTempTarget
        case .carbs: return canRemoteCarbs
        case .therapyEvents: return canRemoteTherapyEvents
        case .runningMode: return canRemoteRunningMode
        }
    }

    /// `nil` when the master published nothing for this capability.
    func publishedFlag(for key: NsRemoteCapabilityKey) -> Bool? {
        publishedFlags[key]
    }
}

enum NsRemoteCapabilityKey: String, Sendable, CaseIterable, Hashable {
    // Raw values are the real AAPS preference key strings, so they are safe to show and to match
    // against `syncedPrefs` directly. The Kotlin enum names (`NsClientAcceptCarbs`, …) are NOT the wire.
    case profileSwitch = "ns_receive_profile_switch"
    case tempTarget = "ns_receive_temp_target"
    case carbs = "ns_receive_carbs"
    case therapyEvents = "ns_receive_therapy_events"
    case runningMode = "ns_receive_running_mode"

    var localizationKey: String {
        switch self {
        case .profileSwitch: return "remote.capability.profile"
        case .tempTarget: return "remote.capability.target"
        case .carbs: return "remote.capability.carbs"
        case .therapyEvents: return "remote.capability.events"
        case .runningMode: return "remote.capability.loop"
        }
    }
}

struct NsSyncedTempTargetPreset: Equatable, Identifiable, Sendable {
    let name: String
    let targetMgdl: Int
    let durationMin: Int

    var id: String { name }
}

/// One entry of the master's `scene_definitions` cold-synced pref. The wire object has no `sceneId`
/// field — `SceneSerializer.toJson()` writes `id`, `name`, `icon`, `defaultDurationMinutes`,
/// `isDeletable`, `isEnabled`, `sortOrder`, `actions`, `endAction`.
struct NsSceneDefinition: Equatable, Identifiable, Sendable {
    let sceneId: String
    let name: String?
    /// Disabled scenes are hidden from the master's own sheet and rejected on activation, so they must
    /// not be offered here either. Absent means enabled (the master's own `optBoolean` default).
    let isEnabled: Bool
    /// Duration the master will apply when the client sends `durationMinutes: nil`.
    let defaultDurationMinutes: Int?
    /// Master's display order — lower first.
    let sortOrder: Int

    var id: String { sceneId }

    init(
        sceneId: String,
        name: String?,
        isEnabled: Bool = true,
        defaultDurationMinutes: Int? = nil,
        sortOrder: Int = 0
    ) {
        self.sceneId = sceneId
        self.name = name
        self.isEnabled = isEnabled
        self.defaultDurationMinutes = defaultDurationMinutes
        self.sortOrder = sortOrder
    }
}

struct NsQuickWizardEntry: Equatable, Identifiable, Sendable {
    let name: String
    let carbs: Int?
    let percentage: Int?
    let note: String?

    var id: String { name }
}

enum NsSyncedPrefsParser {
    /// v4 emits `[{"id":…,"name":null,"reason":"Eating Soon","targetValue":90.0,"duration":2700000,"isDeletable":false}]`
    /// — `targetValue` is always mg/dL, `duration` is **milliseconds**, and `name` is null for the
    /// built-in presets, whose label on the master comes from the localized reason.
    static func tempTargetPresets(from json: String?) -> [NsSyncedTempTargetPreset] {
        guard let items = jsonArray(from: json) else { return [] }
        return items.compactMap { item in
            // `reason` last-but-one: it is the built-in presets' only human label. `id` is the final
            // fallback so a preset is shown with an ugly name rather than silently dropped.
            let name = firstString(in: item, keys: ["name", "displayName", "label", "reason", "id"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name, !name.isEmpty else { return nil }
            let rawTarget = number(item["targetMgdl"])
                ?? number(item["targetValue"])
                ?? number(item["target"])
                ?? number(item["targetBottom"])
                ?? number(item["targetTop"])
            guard let durationMin = durationMinutes(in: item), durationMin > 0, let rawTarget else { return nil }
            let targetMgdl = normalizeGlucoseTarget(rawTarget)
            return NsSyncedTempTargetPreset(name: name, targetMgdl: targetMgdl, durationMin: durationMin)
        }
    }

    static func sceneDefinitions(from json: String?) -> [NsSceneDefinition] {
        guard let items = jsonArray(from: json) else { return [] }
        return items.compactMap { item in
            guard let sceneId = firstString(in: item, keys: ["id", "sceneId"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sceneId.isEmpty else { return nil }
            let name = firstString(in: item, keys: ["name", "title", "displayName"])
            return NsSceneDefinition(
                sceneId: sceneId,
                name: name,
                isEnabled: bool(item["isEnabled"]) ?? true,
                defaultDurationMinutes: int(item["defaultDurationMinutes"]),
                sortOrder: int(item["sortOrder"]) ?? 0
            )
        }
        .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Parses the master's `insulin_configuration` pref: `{"insulin":[ICfg, …]}`.
    /// `insulinEndTime`/`insulinPeakTime` are milliseconds on the wire.
    static func insulinConfigs(from json: String?) -> [NsInsulinConfig] {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let root = object as? [String: Any],
              let items = root["insulin"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            let label = firstString(in: item, keys: ["insulinLabel", "insulinNickname"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let label, !label.isEmpty else { return nil }
            let endTimeMs = number(item["insulinEndTime"])
            let peakMs = number(item["insulinPeakTime"])
            return NsInsulinConfig(
                label: label,
                nickname: firstString(in: item, keys: ["insulinNickname"]),
                // The DB v33 migration writes -1 into rows that predate ICfg; such a record is not an
                // insulin and must not be reported as a 0 h DIA.
                diaHours: (endTimeMs.map { $0 > 0 } == true) ? endTimeMs.map { $0 / 3_600_000 } : nil,
                peakMinutes: (peakMs.map { $0 > 0 } == true) ? peakMs.map { Int(($0 / 60_000).rounded()) } : nil,
                concentration: number(item["concentration"])
            )
        }
    }

    static func quickWizardEntries(from json: String?) -> [NsQuickWizardEntry] {
        guard let items = jsonArray(from: json) else { return [] }
        return items.compactMap { item in
            guard let name = firstString(in: item, keys: ["name", "buttonText", "label"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return NsQuickWizardEntry(
                name: name,
                carbs: int(item["carbs"]) ?? int(item["carbInput"]),
                percentage: int(item["percentage"]),
                note: firstString(in: item, keys: ["note", "notes", "description"])
            )
        }
    }

    private static func jsonArray(from json: String?) -> [[String: Any]]? {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return object as? [[String: Any]]
    }

    private static func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        number(value).map { Int($0) }
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// v4 stores preset durations in milliseconds (`TTPreset.duration`), older/hand-written payloads in
    /// minutes. An explicit minutes key always wins; a bare `duration` is read as milliseconds once it
    /// is too large to be a plausible minute count (10000 min ≈ 7 days, well past any TT).
    private static func durationMinutes(in item: [String: Any]) -> Int? {
        if let explicit = int(item["durationMin"]) ?? int(item["minutes"]) { return explicit }
        guard let raw = number(item["duration"]) else { return nil }
        return raw >= 10_000 ? Int((raw / 60_000).rounded()) : Int(raw)
    }

    private static func normalizeGlucoseTarget(_ value: Double) -> Int {
        let mgdl = value < 40 ? value * glucoseMmolFactor : value
        return Int(mgdl.rounded())
    }
}

struct BasalEntry: Equatable {
    let startSeconds: Int
    let rate: Double
}

struct ScheduledValue: Equatable {
    let startSeconds: Int
    let value: Double
}

struct EditableBlock: Identifiable {
    let id = UUID()
    var startSeconds: Int
    var valueString: String
}

struct AlarmThresholds: Equatable, Codable {
    let urgentLow: Int
    let low: Int
    let high: Int
    let urgentHigh: Int
    let staleMinutes: Int

    static let defaults = AlarmThresholds(
        urgentLow: 55, low: 70, high: 180, urgentHigh: 250, staleMinutes: 15
    )
}

struct ConsumableThresholds: Equatable, Codable {
    let cageWarnHours: Int
    let cageCriticalHours: Int
    let iageWarnHours: Int
    let iageCriticalHours: Int
    let sageWarnHours: Int
    let sageCriticalHours: Int
    let bageWarnHours: Int
    let bageCriticalHours: Int
    let reservoirWarnUnits: Int
    let reservoirCriticalUnits: Int
    let pumpBattWarnPercent: Int
    let pumpBattCriticalPercent: Int

    static let defaults = ConsumableThresholds(
        cageWarnHours: 48, cageCriticalHours: 72,
        iageWarnHours: 72, iageCriticalHours: 144,
        sageWarnHours: 216, sageCriticalHours: 240,
        bageWarnHours: 216, bageCriticalHours: 240,
        reservoirWarnUnits: 80, reservoirCriticalUnits: 10,
        pumpBattWarnPercent: 51, pumpBattCriticalPercent: 26
    )
}

/// `String`-backed so the snooze table can be persisted across process death. A snooze that does not
/// survive an OOM kill or the BGProcessing resurrect path is not a snooze — the fresh engine re-fires
/// the same Time-Sensitive alarm against the same reading minutes after the user silenced it.
/// The raw values are a storage contract: never rename a case without a migration.
enum AlarmType: String, Equatable, Hashable, CaseIterable {
    case urgentLow, low, high, urgentHigh, noData, connectionLost, predictedLow
}

enum TtReason: String {
    case eatingSoon = "Eating Soon"
    case activity = "Activity"
    case hypo = "Hypo"
    case custom = "Custom"

    var defaultTargetMgdl: Int {
        switch self {
        case .eatingSoon: return 90
        case .activity:   return 140
        case .hypo:       return 150
        case .custom:     return 110
        }
    }

    var defaultDurationMin: Int {
        switch self {
        case .eatingSoon: return 45
        case .activity:   return 90
        case .hypo:       return 60
        case .custom:     return 60
        }
    }
}

struct TtPreset: Equatable, Codable {
    var targetMgdl: Int
    var durationMin: Int
}

/// Numbers pulled out of the APS result for the status-card chips.
///
/// v4 serializes the result from `RT`, whose field names are `IOB`/`COB`, `targetBG`, `carbRatio`,
/// `variable_sens`, `isfMgdlForCarbs` and `predBGs` — none of the oref0-era scalar keys this used to
/// look for. `tdd`, `deviation` and `bgi` have no `RT` counterpart and are therefore always nil
/// against a v4 master; they are retained only so the 3.x/oref0 path keeps rendering them.
struct LoopReason: Equatable {
    let isfMgdl: Double?
    let cr: Double?
    let targetMgdl: Int?
    let tdd: Double?
    let deviation: Double?
    let bgi: Double?
    /// Trough of the prediction curves. Derived from `predBGs` on v4 — the predicted-low alarm keys on it.
    let minPredBg: Int?
    let iobPredBg: Int?
    let cobPredBg: Int?
    var isEmpty: Bool {
        isfMgdl == nil && cr == nil && targetMgdl == nil && tdd == nil
            && deviation == nil && bgi == nil && minPredBg == nil
            && iobPredBg == nil && cobPredBg == nil
    }
}

enum NsError: LocalizedError {
    case noNetwork
    case unauthorized
    case badURL
    case decoding(String)
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .noNetwork:      return String(localized: "error.no_network")
        case .unauthorized:   return String(localized: "error.unauthorized")
        case .badURL:         return String(localized: "error.bad_url")
        case .decoding(let d): return String(localized: "error.decoding") + ": \(d)"
        case .server(let c):  return String(format: String(localized: "error.server"), c)
        }
    }
}

/// Conversion factor between mg/dl and mmol/l for glucose.
/// mmol/l = mg/dl / glucoseMmolFactor
let glucoseMmolFactor = 18.0182

func convertUnit(value: Double, from: GlucoseUnits, to: GlucoseUnits) -> Double {
    if from == to { return value }
    return from == .mgdl ? value / glucoseMmolFactor : value * glucoseMmolFactor
}

enum SettingsValueConverter {
    static func convert(_ text: String, from: GlucoseUnits, to: GlucoseUnits) -> String {
        guard from != to, let value = Double(text) else { return text }
        let converted = convertUnit(value: value, from: from, to: to)
        return to == .mmol
            ? String(format: "%.1f", converted)
            : String(Int(converted.rounded()))
    }
}

func liveActivityStaleDate(for readingDate: Date, staleMinutes: Int = 15) -> Date {
    readingDate.addingTimeInterval(Double(staleMinutes) * 60)
}
