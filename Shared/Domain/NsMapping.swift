import Foundation

/// Maps Nightscout API v3 JSON to domain models.
///
/// IMPORTANT: parsing goes through `JSONSerialization`, NOT `JSONDecoder`.
/// The iOS 18+ swift-foundation `JSONDecoder` number parser throws
/// "Number 82.8000000000001 is not representable in Swift" (dataCorrupted)
/// on high-precision floats that AAPS/OpenAPS commonly emit (iob, cob, etc.).
/// `JSONSerialization` parses those into `NSNumber` without error, so we map
/// manually from the resulting dictionaries.
enum NsMapping {

    // MARK: - Public mappers

    static func glucose(from data: Data) throws -> [GlucoseReading] {
        try resultArray(data)
            .filter { ($0["type"] as? String) == "sgv" }
            .compactMap { d in
                guard let sgv = num(d["sgv"]) else { return nil }
                return GlucoseReading(
                    date: date(from: num(d["date"])),
                    mgdl: Int(sgv),
                    trend: TrendArrow.from(nsDirection: d["direction"] as? String)
                )
            }
    }

    static func treatments(from data: Data) throws -> [Treatment] {
        try resultArray(data).map { d in
            let ts = num(d["date"]) ?? num(d["mills"]) ?? num(d["timestamp"])
            let createdAt = (d["created_at"] as? String).flatMap(isoParse)
            let eventType = (d["eventType"] as? String) ?? ""
            let rawNotes = d["notes"] as? String
            let mode = d["mode"] as? String
            let target = parseTTTarget(from: d)
            return Treatment(
                id: (d["identifier"] as? String) ?? (d["_id"] as? String) ?? UUID().uuidString,
                eventType: eventType,
                date: ts.map { Date(timeIntervalSince1970: $0 / 1000) } ?? createdAt ?? Date(),
                insulin: num(d["insulin"]),
                carbs: num(d["carbs"]),
                durationMin: intVal(d["duration"]),
                enteredBy: d["enteredBy"] as? String,
                notes: (rawNotes?.isEmpty == false) ? rawNotes : loopModeLabel(eventType: eventType, mode: mode),
                targetBottom: target.bottom,
                targetTop: target.top,
                // v4 writes the customized display name ("Weekday (80%,2h)") into `profile` and the plain
                // name into `originalProfileName`; the master's own read-back
                // (`NSProfileSwitch.toProfileSwitch`) prefers `originalProfileName`, and only that one
                // matches an entry in `NsProfileStore.profileNames`.
                profileName: (d["originalProfileName"] as? String) ?? (d["profile"] as? String),
                percentage: intVal(d["percentage"]),
                absolute: num(d["absolute"]),
                tempBasalPercent: intVal(d["percent"]),
                mode: mode,
                originalDurationMs: num(d["originalDuration"]).map { Int64($0) },
                autoForced: boolVal(d["autoForced"]),
                reasons: d["reasons"] as? String,
                isValid: boolVal(d["isValid"]) ?? true
            )
        }
    }

    /// Maps a `devicestatus` page to the current loop state.
    ///
    /// AAPS v4 uploads a devicestatus every 5 minutes even while the loop is *not* running
    /// (`KeepAliveWorker` → `scheduleBuildAndStoreDeviceStatus`), and `LoopPlugin.buildAndStoreDeviceStatus`
    /// omits `suggested`/`enacted`/`iob` entirely once the last APS run is older than 300 s. Such a
    /// document carries only the pump block. Reporting it as a fresh loop with IOB 0 / COB 0 is the
    /// exact inverse of the truth and is the *normal* shape while the master is suspended, so a page
    /// with no APS result anywhere yields nil and the loop dot goes `.unknown`.
    ///
    /// When the page holds more than one record (fetch with `limit > 1`) the newest record carrying an
    /// APS result supplies the loop numbers while pump/battery/reservoir still come from the newest
    /// record overall — the pump telemetry is fresh even when the loop is stopped.
    static func loopStatus(from data: Data) throws -> LoopStatus? {
        let records = try resultArray(data)
        guard let newest = records.first else { return nil }
        guard let apsRecord = records.first(where: { hasApsResult($0) }) else { return nil }

        let openaps = apsRecord["openaps"] as? [String: Any]
        let enacted = openaps?["enacted"] as? [String: Any]
        let suggested = openaps?["suggested"] as? [String: Any]
        let active = enacted ?? suggested
        let iobObj = openaps?["iob"] as? [String: Any]
        let pump = newest["pump"] as? [String: Any]
        let battery = pump?["battery"] as? [String: Any]
        let preds = predictions(from: suggested) ?? predictions(from: enacted)

        return LoopStatus(
            iob: iobValue(active: active, iobObject: iobObj) ?? 0,
            cob: cobValue(active: active) ?? 0,
            eventualBgMgdl: intVal(active?["eventualBG"]) ?? intVal(suggested?["eventualBG"]),
            tempBasalRate: num(active?["rate"]),
            suggestedReason: active?["reason"] as? String,
            // Never `Date()`. `RT.timestamp` is an ISO string written from `lastRun.lastAPSRun`; the
            // document's own `date` is the only honest fallback (the APS result is at most 5 min older).
            timestamp: (active?["timestamp"] as? String).flatMap(isoParse) ?? millisDate(from: num(apsRecord["date"])),
            predictions: preds,
            pumpBattery: intVal(battery?["percent"]),
            pumpReservoir: num(pump?["reservoir"]),
            uploaderBattery: intVal(newest["uploaderBattery"]),
            reason: parseReason(from: enacted ?? suggested, predictions: preds),
            carbsReq: intVal(active?["carbsReq"]),
            carbsReqWithin: intVal(active?["carbsReqWithin"]),
            // From the NEWEST record, not the APS one: this is the upload heartbeat, and it is the
            // only thing that stays fresh while the loop is stopped. See `LoopStatus.deviceDate`.
            deviceDate: millisDate(from: num(newest["date"]))
        )
    }

    /// The newest devicestatus document's `date`, ignoring whether it carries an APS result.
    ///
    /// The master's keep-alive uploads one every five minutes even with the loop stopped, so this is
    /// the honest answer to "is the master still there" when `loopStatus` has (correctly) returned
    /// nil because no APS run is left in the fetched window.
    static func deviceStatusHeartbeat(from data: Data) throws -> Date? {
        guard let newest = try resultArray(data).first else { return nil }
        return millisDate(from: num(newest["date"]))
    }

    static func deviceStatusHistory(from data: Data) throws -> [DeviceStatusEntry] {
        try resultArray(data).compactMap { d in
            guard let ts = num(d["date"]) else { return nil }
            // Same rule as `loopStatus`: a pump-only keep-alive record has no IOB/COB to plot. Charting
            // it as 0 draws a sawtooth of zeros across up to 288 records instead of an honest gap.
            guard hasApsResult(d) else { return nil }
            let openaps = d["openaps"] as? [String: Any]
            let enacted = openaps?["enacted"] as? [String: Any]
            let suggested = openaps?["suggested"] as? [String: Any]
            let active = enacted ?? suggested
            let iobObj = openaps?["iob"] as? [String: Any]
            return DeviceStatusEntry(
                date: date(from: ts),
                iob: iobValue(active: active, iobObject: iobObj) ?? 0,
                cob: cobValue(active: active) ?? 0
            )
        }
    }

    /// True when the record carries something the APS actually produced. `NSDeviceStatus.OpenAps` is
    /// always serialized, but with `suggested`/`enacted`/`iob` all omitted when the loop did not run.
    private static func hasApsResult(_ record: [String: Any]) -> Bool {
        guard let openaps = record["openaps"] as? [String: Any] else { return false }
        return (openaps["suggested"] as? [String: Any]) != nil
            || (openaps["enacted"] as? [String: Any]) != nil
            || (openaps["iob"] as? [String: Any]) != nil
    }

    /// v4 serializes the APS result from `RT`, which spells these `IOB`/`COB`. The lowercase keys are
    /// the oref0/3.x spelling and stay as fallbacks; `openaps.iob.iob` is a separate, still-lowercase
    /// upload and is the last resort.
    private static func iobValue(active: [String: Any]?, iobObject: [String: Any]?) -> Double? {
        num(active?["IOB"]) ?? num(active?["iob"]) ?? num(iobObject?["iob"])
    }

    private static func cobValue(active: [String: Any]?) -> Double? {
        num(active?["COB"]) ?? num(active?["cob"])
    }

    static func profile(from data: Data) throws -> NsProfile {
        guard let latest = try resultArray(data).first,
              let store = latest["store"] as? [String: Any],
              let defaultName = latest["defaultProfile"] as? String,
              let prof = store[defaultName] as? [String: Any] else {
            throw NsError.decoding("No default profile found")
        }
        return parseProfileObject(prof)
    }

    static func parseProfileObject(_ prof: [String: Any]) -> NsProfile {
        func schedule(_ key: String) -> [(Int, Double)] {
            (prof[key] as? [[String: Any]])?.compactMap {
                guard let t = intVal($0["timeAsSeconds"]), let v = num($0["value"]) else { return nil }
                return (t, v)
            } ?? []
        }

        // v4's uploaded profile store carries no `dia` — insulin duration moved into `ICfg`, and
        // `ProfileRepositoryImpl.createAndStoreConvertedProfile` writes only the schedules, units and
        // timezone. Treatments spell the block `icfg` (lowercase, see `RemoteTreatment.iCfg`); accept
        // the camelCase spelling too for anything that mirrors the local model. When neither is here the
        // caller fills the gap from `insulin_configuration` via `NsProfile.fillingInsulin(from:)`.
        let icfg = (prof["icfg"] as? [String: Any]) ?? (prof["iCfg"] as? [String: Any])
        let insulinEndTimeMs = num(icfg?["insulinEndTime"])
        let insulinPeakMs = num(icfg?["insulinPeakTime"])

        return NsProfile(
            units: GlucoseUnits(nsUnits: prof["units"] as? String),
            dia: (insulinEndTimeMs.map { $0 > 0 } == true)
                ? insulinEndTimeMs.map { $0 / 3_600_000 }
                : num(prof["dia"]),
            basal: schedule("basal").map { BasalEntry(startSeconds: $0.0, rate: $0.1) },
            targetLow: schedule("target_low").map { ScheduledValue(startSeconds: $0.0, value: $0.1) },
            targetHigh: schedule("target_high").map { ScheduledValue(startSeconds: $0.0, value: $0.1) },
            carbRatio: schedule("carbratio").map { ScheduledValue(startSeconds: $0.0, value: $0.1) },
            sensitivity: schedule("sens").map { ScheduledValue(startSeconds: $0.0, value: $0.1) },
            insulinLabel: icfg?["insulinLabel"] as? String,
            insulinPeakTimeMin: (insulinPeakMs.map { $0 > 0 } == true)
                ? insulinPeakMs.map { Int(($0 / 60_000).rounded()) }
                : nil,
            concentration: num(icfg?["concentration"])
        )
    }

    static func profileStore(from data: Data) throws -> NsProfileStore {
        guard let latest = try resultArray(data).first,
              let store = latest["store"] as? [String: Any],
              let defaultName = latest["defaultProfile"] as? String else {
            throw NsError.decoding("No default profile found")
        }
        let names = Array(store.keys)
        let rawJson: [String: String] = names.reduce(into: [:]) { d, name in
            if let obj = store[name] as? [String: Any],
               let jd = try? JSONSerialization.data(withJSONObject: obj),
               let str = String(data: jd, encoding: .utf8) {
                d[name] = str
            }
        }
        let active = try profile(from: data)
        return NsProfileStore(
            defaultProfileName: defaultName,
            profileNames: names,
            rawJson: rawJson,
            active: active
        )
    }

    /// Payload keys a `settings` document may carry, in the order they are tried.
    ///
    /// One list for both demux sites: they used to disagree on the order of `envelope`/`offer`, which
    /// was harmless only because no document carries two of these at once. `progress` is included so
    /// the client-control progress mirror parses if it is ever adopted.
    private static let settingsPayloadKeys = ["runningConfig", "ack", "envelope", "offer", "progress"]

    private static func settingsPayload(in doc: [String: Any]) -> Any {
        for key in settingsPayloadKeys {
            if let value = doc[key], !(value is NSNull) { return value }
        }
        return [String: Any]()
    }

    static func settingsDocument(from data: Data, identifier: String) throws -> NsSettingsDocument? {
        guard let doc = try resultObject(data) else { return nil }
        return try settingsDocument(from: doc, identifier: identifier, configValue: settingsPayload(in: doc))
    }

    static func settingsDocuments(from data: Data) throws -> [NsSettingsDocument] {
        try resultArray(data).compactMap { doc in
            guard let identifier = doc["identifier"] as? String else { return nil }
            return try settingsDocument(from: doc, identifier: identifier, configValue: settingsPayload(in: doc))
        }
    }

    static func runningConfigCold(from document: NsSettingsDocument) throws -> NsRunningConfigCold {
        let config = try runningConfigObject(from: document)
        let authorized = config["authorizedClients"] as? [String: Any]
        let clientIds = (authorized?["clientIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        return NsRunningConfigCold(
            pump: config["pump"] as? String,
            version: config["version"] as? String,
            isFakingTempsByExtendedBoluses: boolVal(config["isFakingTempsByExtendedBoluses"]),
            syncedPrefs: stringMap(config["syncedPrefs"]),
            authorizedClientIds: clientIds,
            // Absent block vs. block listing nobody — see `authorizedClientsPublished`.
            authorizedClientsPublished: authorized != nil,
            srvModified: document.srvModified
        )
    }

    static func runningConfigHot(from document: NsSettingsDocument) throws -> NsRunningConfigHot {
        let config = try runningConfigObject(from: document)
        let activeSceneDict = config["activeScene"] as? [String: Any]
        let activeScene = activeSceneDict.map { scene in
            NsActiveScene(
                sceneId: scene["sceneId"] as? String,
                activatedAt: millisDate(from: num(scene["activatedAt"])),
                durationMs: intVal(scene["durationMs"]),
                lifecycle: scene["lifecycle"] as? String,
                ttNsId: scene["ttNsId"] as? String,
                psNsId: scene["psNsId"] as? String,
                rmNsId: scene["rmNsId"] as? String,
                teNsId: scene["teNsId"] as? String
            )
        }
        return NsRunningConfigHot(
            activeScene: activeScene,
            usedAutosensOnMainPhone: boolVal(config["usedAutosensOnMainPhone"]),
            srvModified: document.srvModified
        )
    }

    // MARK: - Private helpers

    private static func resultArray(_ data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dict = object as? [String: Any] else {
            throw NsError.decoding("Unexpected NS v3 response shape")
        }
        return (dict["result"] as? [[String: Any]]) ?? []
    }

    private static func resultObject(_ data: Data) throws -> [String: Any]? {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dict = object as? [String: Any] else {
            throw NsError.decoding("Unexpected NS v3 response shape")
        }
        if dict["result"] is NSNull { return nil }
        if let result = dict["result"] as? [String: Any] { return result }
        if dict["result"] == nil { return nil }
        throw NsError.decoding("Unexpected NS settings response shape")
    }

    private static func runningConfigObject(from document: NsSettingsDocument) throws -> [String: Any] {
        guard let data = document.runningConfigJson.data(using: .utf8),
              let config = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw NsError.decoding("Settings \(document.identifier) has invalid runningConfig")
        }
        return config
    }

    private static func settingsDocument(from doc: [String: Any], identifier: String, configValue: Any) throws -> NsSettingsDocument {
        guard JSONSerialization.isValidJSONObject(configValue),
              let configData = try? JSONSerialization.data(withJSONObject: configValue),
              let configJson = String(data: configData, encoding: .utf8) else {
            throw NsError.decoding("Settings \(identifier) has invalid runningConfig")
        }
        return NsSettingsDocument(
            identifier: identifier,
            app: doc["app"] as? String,
            schemaVersion: intVal(doc["schemaVersion"]),
            date: millisDate(from: num(doc["date"])),
            srvModified: millisDate(from: num(doc["srvModified"])),
            runningConfigJson: configJson
        )
    }

    private static func predictions(from src: [String: Any]?) -> Predictions? {
        guard let p = src?["predBGs"] as? [String: Any] else { return nil }
        func arr(_ key: String) -> [Int] {
            (p[key] as? [Any])?.compactMap { intVal($0) } ?? []
        }
        return Predictions(iob: arr("IOB"), cob: arr("COB"), zt: arr("ZT"), uam: arr("UAM"))
    }

    private static func num(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func intVal(_ value: Any?) -> Int? {
        num(value).map { Int($0) }
    }

    private static func boolVal(_ value: Any?) -> Bool? {
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

    private static func stringMap(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        return dict.reduce(into: [:]) { partialResult, item in
            switch item.value {
            case let string as String:
                partialResult[item.key] = string
            case let number as NSNumber:
                partialResult[item.key] = number.stringValue
            default:
                break
            }
        }
    }

    private static func date(from millis: Double?) -> Date {
        millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
    }

    private static func millisDate(from millis: Double?) -> Date? {
        millis.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// Reads the v4 `RT` spellings first (`targetBG`, `carbRatio`, `variable_sens`, `isfMgdlForCarbs`)
    /// and falls back to the oref0-era scalars. `minPredBG`/`IOBpredBG`/`COBpredBG` do not exist on
    /// `RT` at all, so the troughs are derived from the already-parsed `predBGs` curves — without this
    /// the predicted-low alarm can never fire against a v4 master.
    private static func parseReason(from enacted: [String: Any]?, predictions preds: Predictions?) -> LoopReason {
        let e = enacted ?? [:]
        return LoopReason(
            isfMgdl: num(e["ISF"]) ?? num(e["variable_sens"]) ?? num(e["isfMgdlForCarbs"]),
            cr: num(e["CR"]) ?? num(e["carbRatio"]),
            targetMgdl: intVal(e["targetBG"]) ?? intVal(e["current_target"]) ?? intVal(e["target_bg"]),
            tdd: num(e["TDD"]),
            deviation: num(e["deviation"]),
            bgi: num(e["BGI"]),
            minPredBg: intVal(e["minPredBG"]) ?? preds?.minimumMgdl,
            iobPredBg: intVal(e["IOBpredBG"]) ?? preds?.iob.min(),
            cobPredBg: intVal(e["COBpredBG"]) ?? preds?.cob.min()
        )
    }

    /// Human label for an `OpenAPS Offline` row when the master sent no `notes`.
    ///
    /// This is the fallback only — `Treatment.mode` now carries the raw `RM.Mode` name, and the app
    /// target maps it to a localized name via `RunningMode.displayName`. `NsMapping` lives in `Shared`,
    /// which the widget extension also compiles, so it cannot reach into `App/Domain`.
    private static func loopModeLabel(eventType: String, mode: String?) -> String? {
        guard eventType == "OpenAPS Offline" else { return nil }
        switch mode {
        case "OPEN_LOOP":         return "Open Loop"
        case "CLOSED_LOOP":       return "Closed Loop"
        case "CLOSED_LOOP_LGS":   return "Closed Loop (LGS)"
        case "DISABLED_LOOP":     return "Loop Disabled"
        case "SUPER_BOLUS":       return "Super Bolus"
        case "DISCONNECTED_PUMP": return "Pump Disconnected"
        case "SUSPENDED_BY_PUMP": return "Suspended by Pump"
        case "SUSPENDED_BY_USER": return "Suspended"
        case "SUSPENDED_BY_DST":  return "Suspended (DST)"
        case "RESUME":            return "Resume"
        default: return mode
        }
    }

    private static func parseTTTarget(from d: [String: Any]) -> (bottom: Int?, top: Int?) {
        let eventType = d["eventType"] as? String ?? ""
        guard eventType == "Temporary Target" else { return (nil, nil) }
        let duration = intVal(d["duration"]) ?? 0
        if duration == 0 { return (nil, nil) }

        func normalize(_ v: Double?) -> Int? {
            guard var value = v else { return nil }
            if value < 40 { value *= glucoseMmolFactor }
            return Int(value.rounded())
        }

        let rawBottom = num(d["targetBottom"]) ?? num(d["targetBottomMgdl"])
        let rawTop = num(d["targetTop"]) ?? num(d["targetTopMgdl"])

        if let b = rawBottom ?? rawTop {
            let bottom = normalize(rawBottom ?? b)
            let top = normalize(rawTop ?? b)
            return (bottom, top)
        }

        if let rawTarget = num(d["target"]) {
            let v = normalize(rawTarget)
            return (v, v)
        }

        for key in ["reason", "notes"] {
            if let s = d[key] as? String, let n = Double(s.split(separator: " ").first ?? "") {
                let v = normalize(n)
                return (v, v)
            }
        }
        return (nil, nil)
    }
}

// MARK: - TrendArrow helper

extension TrendArrow {
    static func from(nsDirection: String?) -> TrendArrow {
        switch nsDirection {
        case "DoubleUp": return .doubleUp
        case "SingleUp": return .singleUp
        case "FortyFiveUp": return .fortyFiveUp
        case "Flat": return .flat
        case "FortyFiveDown": return .fortyFiveDown
        case "SingleDown": return .singleDown
        case "DoubleDown": return .doubleDown
        default: return .none
        }
    }
}

// MARK: - ISO 8601 parse

private func isoParse(_ string: String) -> Date? {
    ISO8601DateFormatter().date(from: string)
}
