import XCTest
@testable import AAPSClientiOS

final class NsMappingTests: XCTestCase {

    func test_mapsEntryToGlucoseReading() throws {
        let data = try loadFixture("entries")
        let readings = try NsMapping.glucose(from: data)
        XCTAssertEqual(readings.count, 2)
        XCTAssertEqual(readings[0].mgdl, 120)
        XCTAssertEqual(readings[0].trend, .flat)
        XCTAssertEqual(readings[1].mgdl, 124)
        XCTAssertEqual(readings[1].trend, .fortyFiveUp)
    }

    func test_mapsTreatments() throws {
        let data = try loadFixture("treatments")
        let treatments = try NsMapping.treatments(from: data)
        XCTAssertEqual(treatments.count, 4)

        let bolus = treatments[0]
        XCTAssertEqual(bolus.eventType, "Meal Bolus")
        XCTAssertEqual(bolus.insulin, 2.5)
        XCTAssertEqual(bolus.carbs, 30)

        let tt = treatments[1]
        XCTAssertEqual(tt.eventType, "Temporary Target")
        XCTAssertEqual(tt.durationMin, 60)
        XCTAssertEqual(tt.enteredBy, "AndroidAPS")

        let carbs = treatments[2]
        XCTAssertEqual(carbs.eventType, "Carb Correction")
        XCTAssertEqual(carbs.carbs, 15)
        XCTAssertEqual(carbs.enteredBy, "AAPSClient-iOS")
    }

    func test_mapsTreatmentDateFromCreatedAtWhenNumericFieldsMissing() throws {
        let data = try loadFixture("treatments")
        let treatments = try NsMapping.treatments(from: data)
        XCTAssertEqual(treatments.count, 4)

        let siteChange = treatments[3]
        XCTAssertEqual(siteChange.eventType, "Site Change")

        let expected = ISO8601DateFormatter().date(from: "2026-06-20T10:15:00Z")!
        XCTAssertEqual(siteChange.date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1.0)
    }

    func test_mapsDeviceStatusToLoopStatus() throws {
        let data = try loadFixture("devicestatus")
        let status = try XCTUnwrap(try NsMapping.loopStatus(from: data))
        XCTAssertEqual(status.iob, 1.85)
        XCTAssertEqual(status.cob, 24.0)
        XCTAssertEqual(status.eventualBgMgdl, 110)
        XCTAssertEqual(status.tempBasalRate, 0.6)
        XCTAssertEqual(status.pumpBattery, 76)
        XCTAssertEqual(status.pumpReservoir, 142.5)
    }

    func test_mapsProfile() throws {
        let data = try loadFixture("profile")
        let profile = try NsMapping.profile(from: data)
        XCTAssertEqual(profile.units, .mgdl)
        XCTAssertEqual(profile.dia, 5)
        XCTAssertEqual(profile.basal.count, 3)
        XCTAssertEqual(profile.basal[0].startSeconds, 0)
        XCTAssertEqual(profile.basal[0].rate, 0.5)
    }

    func test_mapsTrendStrings() {
        XCTAssertEqual(TrendArrow.from(nsDirection: "DoubleUp"), .doubleUp)
        XCTAssertEqual(TrendArrow.from(nsDirection: "SingleUp"), .singleUp)
        XCTAssertEqual(TrendArrow.from(nsDirection: "FortyFiveUp"), .fortyFiveUp)
        XCTAssertEqual(TrendArrow.from(nsDirection: "Flat"), .flat)
        XCTAssertEqual(TrendArrow.from(nsDirection: "FortyFiveDown"), .fortyFiveDown)
        XCTAssertEqual(TrendArrow.from(nsDirection: "SingleDown"), .singleDown)
        XCTAssertEqual(TrendArrow.from(nsDirection: "DoubleDown"), .doubleDown)
        XCTAssertEqual(TrendArrow.from(nsDirection: nil), .none)
        XCTAssertEqual(TrendArrow.from(nsDirection: "NONE"), .none)
    }

    func test_emptyDeviceStatusReturnsNil() throws {
        let json = #"{"status":200,"result":[]}"#
        let status = try NsMapping.loopStatus(from: json.data(using: .utf8)!)
        XCTAssertNil(status)
    }

    func test_profileSwitchParsesNameAndPercentage() throws {
        let json = #"{"status":200,"result":[{"eventType":"Profile Switch","profile":"автотюн 10_07","percentage":140,"date":1}]}"#
        let r = try NsMapping.treatments(from: json.data(using: .utf8)!)
        XCTAssertEqual(r[0].profileName, "автотюн 10_07")
        XCTAssertEqual(r[0].percentage, 140)
    }

    func test_tempTargetParsesTargetVariants() throws {
        func tts(from json: String) throws -> [Treatment] {
            try NsMapping.treatments(from: json.data(using: .utf8)!)
        }

        let standard = #"{"status":200,"result":[{"eventType":"Temporary Target","duration":60,"targetBottom":90,"targetTop":100,"date":1}]}"#
        let r1 = try tts(from: standard)
        XCTAssertEqual(r1[0].targetBottom, 90)
        XCTAssertEqual(r1[0].targetTop, 100)

        let mgdlVariant = #"{"status":200,"result":[{"eventType":"Temporary Target","duration":60,"targetBottomMgdl":80,"targetTopMgdl":80,"date":1}]}"#
        let r2 = try tts(from: mgdlVariant)
        XCTAssertEqual(r2[0].targetBottom, 80)

        let singleTarget = #"{"status":200,"result":[{"eventType":"Temporary Target","duration":60,"target":100,"date":1}]}"#
        let r3 = try tts(from: singleTarget)
        XCTAssertEqual(r3[0].targetBottom, 100)

        let mmolField = #"{"status":200,"result":[{"eventType":"Temporary Target","duration":60,"targetBottom":4.5,"date":1}]}"#
        let r4 = try tts(from: mmolField)
        XCTAssertEqual(r4[0].targetBottom, 81)

        let fromReason = #"{"status":200,"result":[{"eventType":"Temporary Target","duration":60,"reason":"120 mg/dl","date":1}]}"#
        let r5 = try tts(from: fromReason)
        XCTAssertEqual(r5[0].targetBottom, 120)

        let cancelled = #"{"status":200,"result":[{"eventType":"Temporary Target","duration":0,"date":1}]}"#
        let r6 = try tts(from: cancelled)
        XCTAssertNil(r6[0].targetBottom)
    }

    func test_profileStoreParsesAllNames() throws {
        let data = try loadFixture("profile")
        let store = try NsMapping.profileStore(from: data)
        XCTAssertEqual(store.defaultProfileName, "Default")
        XCTAssertTrue(store.profileNames.contains("Default"))
        XCTAssertNotNil(store.rawJson["Default"])
    }

    func test_mapsDeviceStatusHistory() throws {
        let data = try loadFixture("devicestatus_history")
        let entries = try NsMapping.deviceStatusHistory(from: data)
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries[0].iob, 1.20, accuracy: 0.001)
        XCTAssertEqual(entries[0].cob, 10.0, accuracy: 0.01)
        XCTAssertEqual(entries[3].iob, 2.10, accuracy: 0.001)
        XCTAssertEqual(entries[3].cob, 45.0, accuracy: 0.01)
        XCTAssertEqual(entries[4].iob, -0.30, accuracy: 0.001)
        XCTAssertTrue(entries[0].date > entries[4].date)
    }

    func test_mapsTempBasalAbsoluteAndPercent() throws {
        let data = try loadFixture("treatments_tempbasal")
        let treatments = try NsMapping.treatments(from: data)
        XCTAssertEqual(treatments.count, 3)

        let zero = treatments[0]
        XCTAssertEqual(zero.eventType, "Temp Basal")
        XCTAssertEqual(zero.durationMin, 30)
        XCTAssertEqual(zero.absolute, 0.0)
        XCTAssertNil(zero.tempBasalPercent)

        let pct = treatments[1]
        XCTAssertEqual(pct.durationMin, 45)
        XCTAssertNil(pct.absolute)
        XCTAssertEqual(pct.tempBasalPercent, 150)

        let cancel = treatments[2]
        XCTAssertEqual(cancel.durationMin, 0)
    }

    func test_mapsRunningConfigCold() throws {
        let data = try loadFixture("settings_aaps")
        let document = try XCTUnwrap(NsMapping.settingsDocument(from: data, identifier: NightscoutSettingsIdentifier.cold))
        let cold = try NsMapping.runningConfigCold(from: document)

        XCTAssertEqual(document.identifier, "aaps")
        XCTAssertEqual(document.app, "AAPS")
        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(cold.pump, "Dana-i")
        XCTAssertEqual(cold.version, "4.3.0")
        XCTAssertEqual(cold.isFakingTempsByExtendedBoluses, false)
        XCTAssertEqual(cold.authorizedClientIds, ["abc", "def"])
        XCTAssertTrue(cold.authorizedClientsPublished)
        XCTAssertEqual(cold.syncedPrefs["NsClientAcceptProfileSwitch"], "true")
        XCTAssertEqual(cold.syncedPrefsSnapshot.activePluginAps, "OpenAPSAMA")
        XCTAssertTrue(cold.remoteCapabilities.canRemoteProfileSwitch)
        XCTAssertTrue(cold.remoteCapabilities.canRemoteTempTarget)
        XCTAssertTrue(cold.remoteCapabilities.canRemoteCarbs)
        XCTAssertFalse(cold.remoteCapabilities.canRemoteRunningMode)
        XCTAssertTrue(cold.remoteCapabilities.usesWebSockets)
    }

    /// "No `authorizedClients` block at all" and "a block listing nobody" are different facts and
    /// the mapper flattens both to `[]`. Only the second is a revocation; treating the first as one
    /// durably un-authorizes every client of a master whose publisher path predates the roster, with
    /// a "Pair again" banner that cannot help — re-pairing does not make the master start publishing.
    func test_absentRosterIsDistinguishableFromAnEmptyOne() throws {
        let absent = try NsMapping.runningConfigCold(from: XCTUnwrap(
            NsMapping.settingsDocument(from: try loadFixture("settings_aaps_no_roster"),
                                       identifier: NightscoutSettingsIdentifier.cold)
        ))
        XCTAssertEqual(absent.authorizedClientIds, [])
        XCTAssertFalse(absent.authorizedClientsPublished)
    }

    func test_mapsRunningConfigHot() throws {
        let data = try loadFixture("settings_aaps_state")
        let document = try XCTUnwrap(NsMapping.settingsDocument(from: data, identifier: NightscoutSettingsIdentifier.state))
        let hot = try NsMapping.runningConfigHot(from: document)

        XCTAssertEqual(hot.usedAutosensOnMainPhone, true)
        XCTAssertEqual(hot.activeScene?.sceneId, "school-sport")
        XCTAssertEqual(hot.activeScene?.durationMs, 5_400_000)
        XCTAssertEqual(hot.activeScene?.lifecycle, "ACTIVE")
        XCTAssertEqual(hot.activeScene?.ttNsId, "667")
        XCTAssertEqual(hot.activeScene?.rmNsId, "669")
    }

    func test_settingsDocumentReturnsNilWhenMissing() throws {
        let json = #"{"status":200,"result":null}"#
        let document = try NsMapping.settingsDocument(from: Data(json.utf8), identifier: NightscoutSettingsIdentifier.cold)
        XCTAssertNil(document)
    }

    func test_settingsDocumentToleratesAckShapedDocument() throws {
        let json = #"""
        {"status":200,"result":{"identifier":"aaps_clientcontrol_ack_c1","date":1,"utcOffset":0,"app":"AAPS","schemaVersion":1,"ack":{"clientId":"c1","commandCounter":1,"phase":"Done","status":"Ok","timestamp":1000,"signature":"abc"}}}
        """#
        let document = try NsMapping.settingsDocument(from: Data(json.utf8), identifier: "aaps_clientcontrol_ack_c1")
        XCTAssertNotNil(document)
        XCTAssertTrue(document?.runningConfigJson.contains("\"status\":\"Ok\"") == true)
    }

    func test_settingsDocumentThrowsOnInvalidRunningConfig() throws {
        let data = try loadFixture("settings_invalid")
        XCTAssertThrowsError(try NsMapping.settingsDocument(from: data, identifier: NightscoutSettingsIdentifier.cold))
    }

    func test_settingsDocumentThrowsOnInvalidRunningConfig_stillThrows() throws {
        let data = try loadFixture("settings_invalid")
        XCTAssertThrowsError(try NsMapping.settingsDocument(from: data, identifier: NightscoutSettingsIdentifier.cold))
    }

    func test_parsesSyncedPrefsPayloads() {
        let presets = NsSyncedPrefsParser.tempTargetPresets(from: "[{\"name\":\"Eating Soon\",\"targetMgdl\":90,\"durationMin\":45}]")
        XCTAssertEqual(presets, [NsSyncedTempTargetPreset(name: "Eating Soon", targetMgdl: 90, durationMin: 45)])

        let scenes = NsSyncedPrefsParser.sceneDefinitions(from: "[{\"sceneId\":\"school-sport\",\"name\":\"School Sport\"}]")
        XCTAssertEqual(scenes, [NsSceneDefinition(sceneId: "school-sport", name: "School Sport")])

        let qw = NsSyncedPrefsParser.quickWizardEntries(from: "[{\"name\":\"Breakfast\",\"carbs\":30}]")
        XCTAssertEqual(qw, [NsQuickWizardEntry(name: "Breakfast", carbs: 30, percentage: nil, note: nil)])
    }

    func test_remoteCapabilitiesSupportPreferenceKeyAliases() {
        let capabilities = NsRemoteCapabilities(syncedPrefs: [
            "ns_receive_profile_switch": "true",
            "ns_receive_temp_target": "true",
            "ns_receive_carbs": "true",
            "ns_receive_therapy_events": "false",
            "ns_receive_running_mode": "false",
            "ns_use_ws": "true",
        ])

        XCTAssertTrue(capabilities.canRemoteProfileSwitch)
        XCTAssertTrue(capabilities.canRemoteTempTarget)
        XCTAssertTrue(capabilities.canRemoteCarbs)
        XCTAssertFalse(capabilities.canRemoteTherapyEvents)
        XCTAssertFalse(capabilities.canRemoteRunningMode)
        XCTAssertTrue(capabilities.usesWebSockets)
    }

    // MARK: - v4: syncedPrefs is keyed by the preference key string, not the Kotlin enum name

    func test_syncedPrefsAreReadByWireKeyString() throws {
        let data = try loadFixture("settings_aaps_v4")
        let document = try XCTUnwrap(NsMapping.settingsDocument(from: data, identifier: NightscoutSettingsIdentifier.cold))
        let snapshot = try NsMapping.runningConfigCold(from: document).syncedPrefsSnapshot

        XCTAssertEqual(snapshot.activePluginAps, "OpenAPSSMB")
        XCTAssertEqual(snapshot.activePluginSensitivity, "SensitivityOref1")
        XCTAssertEqual(snapshot.activePluginSmoothing, "ExponentialSmoothing")
        XCTAssertEqual(snapshot.activePluginCalibration, "NoCalibration")
        XCTAssertNotNil(snapshot.sceneDefinitionsJson)
        XCTAssertNotNil(snapshot.tempTargetPresetsJson)
        XCTAssertNotNil(snapshot.quickWizardJson)
        XCTAssertNotNil(snapshot.localProfileDataJson)
        XCTAssertNotNil(snapshot.insulinConfigurationJson)
    }

    func test_syncedPrefsStillAcceptLegacyPascalCaseNames() {
        let snapshot = NsSyncedPrefsSnapshot(rawValues: [
            "ActivePluginAps": "OpenAPSAMA",
            "SceneDefinitions": "[]",
        ])
        XCTAssertEqual(snapshot.activePluginAps, "OpenAPSAMA")
        XCTAssertEqual(snapshot.sceneDefinitionsJson, "[]")
    }

    /// The master publishes only keys carrying a `SyncSpec`, and none of `BooleanKey.NsClientAccept*`
    /// does — so a real v4 cold doc contains no capability flags at all. Absent must mean enabled, or
    /// every remote action is permanently greyed out against every real master.
    func test_absentCapabilityFlagsFailOpen() throws {
        let data = try loadFixture("settings_aaps_v4")
        let document = try XCTUnwrap(NsMapping.settingsDocument(from: data, identifier: NightscoutSettingsIdentifier.cold))
        let capabilities = try NsMapping.runningConfigCold(from: document).remoteCapabilities

        XCTAssertTrue(capabilities.canRemoteCarbs)
        XCTAssertTrue(capabilities.canRemoteTempTarget)
        XCTAssertTrue(capabilities.canRemoteProfileSwitch)
        XCTAssertTrue(capabilities.canRemoteTherapyEvents)
        XCTAssertTrue(capabilities.canRemoteRunningMode)
        XCTAssertNil(capabilities.publishedFlag(for: .carbs))
        XCTAssertNil(capabilities.publishedFlag(for: .runningMode))
        // The one accept-style key that IS declared synced comes through.
        XCTAssertTrue(capabilities.clientControlEnabled)
        XCTAssertEqual(capabilities.publishedClientControlEnabled, true)
    }

    func test_publishedFalseCapabilityStillDisables() {
        let capabilities = NsRemoteCapabilities(syncedPrefs: ["ns_receive_carbs": "false"])
        XCTAssertFalse(capabilities.canRemoteCarbs)
        XCTAssertEqual(capabilities.publishedFlag(for: .carbs), false)
        // Untouched keys keep failing open.
        XCTAssertTrue(capabilities.canRemoteTempTarget)
    }

    /// Client control is the one flag that fails CLOSED: it is genuinely published
    /// (`SyncSpec(Cold, MasterOnly)`), so absence means the master is too old to serve commands.
    func test_clientControlFailsClosedWhenAbsent() {
        let capabilities = NsRemoteCapabilities(syncedPrefs: [:])
        XCTAssertFalse(capabilities.clientControlEnabled)
        XCTAssertNil(capabilities.publishedClientControlEnabled)
    }

    // MARK: - v4: devicestatus

    func test_v4DeviceStatusReadsUppercaseRtFields() throws {
        let data = try loadFixture("devicestatus_v4")
        let status = try XCTUnwrap(try NsMapping.loopStatus(from: data))

        XCTAssertEqual(status.iob, 2.4)
        XCTAssertEqual(status.cob, 18.0)
        XCTAssertEqual(status.eventualBgMgdl, 118)
        XCTAssertEqual(status.tempBasalRate, 0.85)
        XCTAssertEqual(status.pumpReservoir, 118.4)
        XCTAssertEqual(status.pumpBattery, 71)
        XCTAssertEqual(status.carbsReq, 12)
        XCTAssertEqual(status.carbsReqWithin, 30)
        XCTAssertNotNil(status.timestamp)
    }

    func test_v4LoopReasonUsesRtNamesAndDerivesPredictionTrough() throws {
        let data = try loadFixture("devicestatus_v4")
        let status = try XCTUnwrap(try NsMapping.loopStatus(from: data))
        let reason = try XCTUnwrap(status.reason)

        XCTAssertEqual(reason.targetMgdl, 100)     // targetBG, not current_target
        XCTAssertEqual(reason.cr, 7.5)             // carbRatio, not CR
        XCTAssertEqual(reason.isfMgdl, 52.0)       // variable_sens
        // RT has no scalar minPredBG, so it is RECONSTRUCTED the way the master computes its own:
        // `max(minIOBPredBG, minCOBPredBG)` (DetermineBasalAutoISF.kt:1002-1017), the LEAST alarming
        // of the per-curve minima. The fixture's curve minima are IOB 110 / COB 118 / ZT 104 /
        // UAM 112, so the answer is 118 — never the global minimum 104, which is the ZT curve. ZT is
        // the zero-temp safety envelope; it dips below target on almost every loop cycle, so keying
        // the predicted-low alarm on it fired "consider carbs" every five minutes all night.
        XCTAssertEqual(reason.minPredBg, 118)
        XCTAssertEqual(reason.iobPredBg, 110)
        XCTAssertEqual(reason.cobPredBg, 118)
        XCTAssertFalse(reason.isEmpty)
    }

    /// The ZT trough is still parsed — it is display-only, and must never reach the alarm path.
    func test_zeroTempTroughIsAvailableButSeparateFromTheAlarmNumber() throws {
        let data = try loadFixture("devicestatus_v4")
        let status = try XCTUnwrap(try NsMapping.loopStatus(from: data))
        let predictions = try XCTUnwrap(status.predictions)

        XCTAssertEqual(predictions.zeroTempMinimumMgdl, 104)
        XCTAssertEqual(predictions.minimumMgdl, 118)
        XCTAssertNotEqual(
            predictions.minimumMgdl,
            predictions.zeroTempMinimumMgdl,
            "a global min() over the curves would collapse these two and re-introduce the alarm storm"
        )
    }

    /// v4 uploads a pump-only devicestatus every 5 min precisely while the loop is NOT running.
    /// Reporting that as a fresh loop with IOB 0 / COB 0 is the exact inverse of the truth.
    func test_pumpOnlyDeviceStatusYieldsNoLoopStatus() throws {
        let data = try loadFixture("devicestatus_v4_pump_only")
        XCTAssertNil(try NsMapping.loopStatus(from: data))
    }

    /// The heartbeat the liveness clock runs on. It must read the DOCUMENT's own `date` — which the
    /// master's `KeepAliveWorker` writes every five minutes whether or not the loop ran — and must
    /// therefore answer for exactly the record `loopStatus` correctly refuses. Keying master
    /// liveness on the APS run instead made a deliberately suspended loop read as an absent master,
    /// and the app then refused to send the one command that would resume it.
    func test_deviceStatusHeartbeatReadsThePumpOnlyKeepAliveRecord() throws {
        let data = try loadFixture("devicestatus_v4_pump_only")

        XCTAssertNil(try NsMapping.loopStatus(from: data), "no APS result, so no loop status")
        XCTAssertEqual(
            try NsMapping.deviceStatusHeartbeat(from: data),
            Date(timeIntervalSince1970: 1_760_000_400)
        )
    }

    func test_deviceStatusHeartbeatIsNilForAnEmptyPage() throws {
        let empty = Data(#"{"status":200,"result":[]}"#.utf8)
        XCTAssertNil(try NsMapping.deviceStatusHeartbeat(from: empty))
    }

    func test_pumpOnlyDeviceStatusIsUnknownNotLooping() throws {
        let data = try loadFixture("devicestatus_v4_pump_only")
        let status = try NsMapping.loopStatus(from: data)
        XCTAssertEqual(LoopStateCalc.from(statusTimestamp: status?.timestamp, now: Date()), .unknown)
    }

    /// With more than one record on the page the loop numbers come from the newest record that has an
    /// APS result, while pump telemetry stays on the newest record overall.
    func test_loopStatusMergesNewestApsResultWithNewestPumpBlock() throws {
        let data = try loadFixture("devicestatus_v4_history")
        let status = try XCTUnwrap(try NsMapping.loopStatus(from: data))

        XCTAssertEqual(status.iob, 2.4)
        XCTAssertEqual(status.cob, 18.0)
        XCTAssertEqual(status.pumpReservoir, 117.5)
        XCTAssertEqual(status.pumpBattery, 70)
    }

    /// A gap is honest; a sawtooth of zeros is not.
    func test_deviceStatusHistorySkipsPumpOnlyRecords() throws {
        let data = try loadFixture("devicestatus_v4_history")
        let entries = try NsMapping.deviceStatusHistory(from: data)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].iob, 2.4, accuracy: 0.001)
        XCTAssertEqual(entries[0].cob, 18.0, accuracy: 0.001)
        XCTAssertEqual(entries[1].iob, 2.85, accuracy: 0.001)
        XCTAssertEqual(entries[1].cob, 31.0, accuracy: 0.001)
    }

    // MARK: - v4: RunningMode treatments

    func test_v4RunningModeTreatmentFieldsAreParsed() throws {
        let data = try loadFixture("treatments_runningmode")
        let treatments = try NsMapping.treatments(from: data)
        let byID = Dictionary(uniqueKeysWithValues: treatments.map { ($0.id, $0) })

        let closed = try XCTUnwrap(byID["rm-closed-permanent"])
        XCTAssertEqual(closed.mode, "CLOSED_LOOP")
        XCTAssertEqual(closed.originalDurationMs, 0)
        XCTAssertEqual(closed.effectiveDurationMs, 0)
        XCTAssertEqual(closed.autoForced, false)
        XCTAssertTrue(closed.isValid)

        // Working modes ship `duration: 0` with the real span in `originalDuration` — reading
        // `duration` alone would render a 2 h OPEN_LOOP as an immediate cancel.
        let open = try XCTUnwrap(byID["rm-open-2h"])
        XCTAssertEqual(open.durationMin, 0)
        XCTAssertEqual(open.effectiveDurationMs, 7_200_000)

        // A permanent DISABLED_LOOP ships a decade on the wire so NS renders the marker, and 0 in
        // `originalDuration` — reading `duration` alone would show 5,256,000 minutes.
        let disabled = try XCTUnwrap(byID["rm-disabled-old"])
        XCTAssertEqual(disabled.durationMin, 5_256_000)
        XCTAssertEqual(disabled.effectiveDurationMs, 0)
        XCTAssertEqual(disabled.autoForced, true)
        XCTAssertEqual(disabled.reasons, "Loop invocation not allowed")

        let invalid = try XCTUnwrap(byID["rm-invalid-dst"])
        XCTAssertFalse(invalid.isValid)
        XCTAssertEqual(invalid.mode, "SUSPENDED_BY_DST")
    }

    func test_treatmentIsValidDefaultsToTrueWhenAbsent() throws {
        let json = #"{"status":200,"result":[{"eventType":"Carb Correction","carbs":20,"date":1}]}"#
        let r = try NsMapping.treatments(from: json.data(using: .utf8)!)
        XCTAssertTrue(r[0].isValid)
        XCTAssertNil(r[0].mode)
    }

    func test_loopModeLabelCoversEveryV4Mode() throws {
        let modes = [
            "OPEN_LOOP", "CLOSED_LOOP", "CLOSED_LOOP_LGS", "DISABLED_LOOP", "SUPER_BOLUS",
            "DISCONNECTED_PUMP", "SUSPENDED_BY_PUMP", "SUSPENDED_BY_USER", "SUSPENDED_BY_DST",
        ]
        for mode in modes {
            let json = #"{"status":200,"result":[{"eventType":"OpenAPS Offline","mode":"\#(mode)","duration":0,"date":1}]}"#
            let r = try NsMapping.treatments(from: json.data(using: .utf8)!)
            let notes = try XCTUnwrap(r[0].notes)
            XCTAssertFalse(notes.contains("_"), "\(mode) still renders as SCREAMING_SNAKE: \(notes)")
        }
    }

    // MARK: - v4: Profile Switch name

    func test_profileSwitchPrefersOriginalProfileName() throws {
        let json = #"{"status":200,"result":[{"eventType":"Profile Switch","profile":"Weekday (80%,2h)","originalProfileName":"Weekday","percentage":80,"timeshift":7200000,"date":1}]}"#
        let r = try NsMapping.treatments(from: json.data(using: .utf8)!)
        XCTAssertEqual(r[0].profileName, "Weekday")
        XCTAssertEqual(r[0].percentage, 80)
    }

    func test_profileSwitchFallsBackToProfileWhenOriginalMissing() throws {
        let json = #"{"status":200,"result":[{"eventType":"Profile Switch","profile":"автотюн 10_07","percentage":140,"date":1}]}"#
        let r = try NsMapping.treatments(from: json.data(using: .utf8)!)
        XCTAssertEqual(r[0].profileName, "автотюн 10_07")
    }

    // MARK: - v4: scene definitions

    func test_v4SceneDefinitionsParseIdEnabledAndDefaultDuration() throws {
        let data = try loadFixture("settings_aaps_v4")
        let document = try XCTUnwrap(NsMapping.settingsDocument(from: data, identifier: NightscoutSettingsIdentifier.cold))
        let cold = try NsMapping.runningConfigCold(from: document)
        let scenes = NsSyncedPrefsParser.sceneDefinitions(from: cold.syncedPrefsSnapshot.sceneDefinitionsJson)

        XCTAssertEqual(scenes.count, 2)
        XCTAssertEqual(scenes[0].sceneId, "school-sport")
        XCTAssertEqual(scenes[0].name, "School Sport")
        XCTAssertTrue(scenes[0].isEnabled)
        XCTAssertEqual(scenes[0].defaultDurationMinutes, 90)
        XCTAssertEqual(scenes[1].sceneId, "night-shift")
        XCTAssertFalse(scenes[1].isEnabled)
        XCTAssertEqual(scenes[1].defaultDurationMinutes, 480)
    }

    func test_sceneDefinitionDefaultsToEnabledWhenFlagAbsent() {
        let scenes = NsSyncedPrefsParser.sceneDefinitions(from: "[{\"id\":\"a\",\"name\":\"A\"}]")
        XCTAssertEqual(scenes.count, 1)
        XCTAssertTrue(scenes[0].isEnabled)
        XCTAssertNil(scenes[0].defaultDurationMinutes)
    }

    func test_activeSceneWithoutLifecycleIsTreatedAsActive() {
        let scene = NsActiveScene(
            sceneId: "school-sport", activatedAt: nil, durationMs: nil, lifecycle: nil,
            ttNsId: nil, psNsId: nil, rmNsId: nil, teNsId: nil
        )
        XCTAssertTrue(scene.isActive)

        let expired = NsActiveScene(
            sceneId: "school-sport", activatedAt: nil, durationMs: nil, lifecycle: "EXPIRED",
            ttNsId: nil, psNsId: nil, rmNsId: nil, teNsId: nil
        )
        XCTAssertFalse(expired.isActive)
    }

    func test_missingActiveSceneBlockMeansNoScene() throws {
        let json = #"{"status":200,"result":{"identifier":"aaps-state","date":946684800001,"app":"AAPS","schemaVersion":1,"runningConfig":{"usedAutosensOnMainPhone":false}}}"#
        let document = try XCTUnwrap(NsMapping.settingsDocument(from: Data(json.utf8), identifier: NightscoutSettingsIdentifier.state))
        let hot = try NsMapping.runningConfigHot(from: document)
        XCTAssertNil(hot.activeScene)
    }

    // MARK: - v4: temp-target presets

    func test_v4TempTargetPresetsParseTargetValueAndMillisecondDuration() throws {
        let data = try loadFixture("settings_aaps_v4")
        let document = try XCTUnwrap(NsMapping.settingsDocument(from: data, identifier: NightscoutSettingsIdentifier.cold))
        let cold = try NsMapping.runningConfigCold(from: document)
        let presets = NsSyncedPrefsParser.tempTargetPresets(from: cold.syncedPrefsSnapshot.tempTargetPresetsJson)

        XCTAssertEqual(presets.count, 2)
        // Built-in preset: `name` is null, so the reason is the label; 2 700 000 ms = 45 min.
        XCTAssertEqual(presets[0].name, "Eating Soon")
        XCTAssertEqual(presets[0].targetMgdl, 90)
        XCTAssertEqual(presets[0].durationMin, 45)
        // Custom preset keeps its own name.
        XCTAssertEqual(presets[1].name, "Football")
        XCTAssertEqual(presets[1].targetMgdl, 140)
        XCTAssertEqual(presets[1].durationMin, 90)
    }

    func test_tempTargetPresetDurationInMinutesIsNotRescaled() {
        let presets = NsSyncedPrefsParser.tempTargetPresets(from: "[{\"name\":\"Legacy\",\"targetMgdl\":110,\"duration\":45}]")
        XCTAssertEqual(presets, [NsSyncedTempTargetPreset(name: "Legacy", targetMgdl: 110, durationMin: 45)])
    }

    // MARK: - v4: DIA / iCfg

    func test_v4ProfileStoreCarriesNoDiaAndIsFilledFromInsulinConfiguration() throws {
        let profile = try NsMapping.profile(from: try loadFixture("profile_v4"))
        XCTAssertNil(profile.dia, "v4 stopped writing `dia` into the uploaded profile store")

        let data = try loadFixture("settings_aaps_v4")
        let document = try XCTUnwrap(NsMapping.settingsDocument(from: data, identifier: NightscoutSettingsIdentifier.cold))
        let cold = try NsMapping.runningConfigCold(from: document)
        let configs = NsSyncedPrefsParser.insulinConfigs(from: cold.syncedPrefsSnapshot.insulinConfigurationJson)

        XCTAssertEqual(configs.count, 1)
        XCTAssertEqual(configs[0].label, "Lyumjev")
        XCTAssertEqual(try XCTUnwrap(configs[0].diaHours), 7.0, accuracy: 0.001)
        XCTAssertEqual(configs[0].peakMinutes, 45)
        XCTAssertEqual(configs[0].concentration, 1.0)

        let filled = profile.fillingInsulin(from: configs.first)
        XCTAssertEqual(try XCTUnwrap(filled.dia), 7.0, accuracy: 0.001)
        XCTAssertEqual(filled.insulinLabel, "Lyumjev")
        XCTAssertEqual(filled.insulinPeakTimeMin, 45)
        XCTAssertEqual(filled.concentration, 1.0)
    }

    func test_legacyProfileDiaWinsOverSyncedInsulinConfig() throws {
        let profile = try NsMapping.profile(from: try loadFixture("profile"))
        XCTAssertEqual(profile.dia, 5)
        let config = NsInsulinConfig(label: "Lyumjev", nickname: nil, diaHours: 7, peakMinutes: 45, concentration: 1)
        XCTAssertEqual(profile.fillingInsulin(from: config).dia, 5)
    }

    func test_profileObjectReadsDiaFromICfgWhenPresent() throws {
        let icfg: [String: Any] = [
            "insulinLabel": "Fiasp",
            "insulinEndTime": 21_600_000,
            "insulinPeakTime": 3_000_000,
            "concentration": 2.0,
        ]
        let profile = NsMapping.parseProfileObject(["units": "mg/dl", "icfg": icfg])
        XCTAssertEqual(try XCTUnwrap(profile.dia), 6.0, accuracy: 0.001)
        XCTAssertEqual(profile.insulinLabel, "Fiasp")
        XCTAssertEqual(profile.insulinPeakTimeMin, 50)
        XCTAssertEqual(profile.concentration, 2.0)
    }

    // MARK: - settings document demux

    func test_settingsDocumentDemuxIsOrderStableAcrossBothEntryPoints() throws {
        let json = #"""
        {"status":200,"result":[{"identifier":"aaps_clientcontrol_offer_x","date":946684800001,"app":"AAPS","schemaVersion":1,"offer":{"clientId":"x","wrapped":"deadbeef"}}]}
        """#
        let documents = try NsMapping.settingsDocuments(from: Data(json.utf8))
        XCTAssertEqual(documents.count, 1)
        XCTAssertTrue(documents[0].runningConfigJson.contains("deadbeef"))
    }

    func test_settingsDocumentParsesProgressMirror() throws {
        let json = #"""
        {"status":200,"result":{"identifier":"aaps_clientcontrol_progress_c1","date":946684800001,"app":"AAPS","schemaVersion":1,"progress":{"clientId":"c1","phase":"Delivery","percent":40}}}
        """#
        let document = try XCTUnwrap(NsMapping.settingsDocument(from: Data(json.utf8), identifier: "aaps_clientcontrol_progress_c1"))
        XCTAssertTrue(document.runningConfigJson.contains("\"phase\":\"Delivery\""))
    }

    func test_remoteCapabilitiesSupportNumericBooleanValues() {
        let capabilities = NsRemoteCapabilities(syncedPrefs: [
            "NsClientAcceptTempTarget": "1",
            "NsClientAcceptCarbs": "1",
            "NsClientAcceptTherapyEvent": "0",
            "NsClientAcceptRunningMode": "0",
        ])

        XCTAssertTrue(capabilities.canRemoteTempTarget)
        XCTAssertTrue(capabilities.canRemoteCarbs)
        XCTAssertFalse(capabilities.canRemoteTherapyEvents)
        XCTAssertFalse(capabilities.canRemoteRunningMode)
    }

    func test_loopModeTreatmentGetsReadableNotesFallback() throws {
        let json = #"{"status":200,"result":[{"eventType":"OpenAPS Offline","mode":"DISCONNECTED_PUMP","duration":30,"date":1}]}"#
        let r = try NsMapping.treatments(from: json.data(using: .utf8)!)
        XCTAssertEqual(r[0].notes, "Pump Disconnected")
    }

    func test_loopModeTreatmentPrefersServerNotesOverModeFallback() throws {
        let json = #"{"status":200,"result":[{"eventType":"OpenAPS Offline","mode":"CLOSED_LOOP","duration":0,"notes":"Manual close","date":1}]}"#
        let r = try NsMapping.treatments(from: json.data(using: .utf8)!)
        XCTAssertEqual(r[0].notes, "Manual close")
    }
}
