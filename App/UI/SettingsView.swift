import SwiftUI
import WidgetKit

struct SettingsView: View {
    @ObservedObject var store: AppStore
    let writer: NsTreatmentWriter

    @State private var nsUrl = ""
    @State private var accessToken = ""
    @State private var urgentLow: String
    @State private var low: String
    @State private var high: String
    @State private var urgentHigh: String
    @State private var staleMinutes: String
    @State private var cageWarn: String
    @State private var cageCritical: String
    @State private var iageWarn: String
    @State private var iageCritical: String
    @State private var sageWarn: String
    @State private var sageCritical: String
    @State private var bageWarn: String
    @State private var bageCritical: String
    @State private var reservoirWarn: String
    @State private var reservoirCritical: String
    @State private var pumpBattWarn: String
    @State private var pumpBattCritical: String
    @State private var testingConnection = false
    @State private var connectionResult: String?
    @State private var liveActivityOn: Bool
    @State private var glucoseNotificationOn: Bool
    @State private var announcementRelayOn: Bool
    @State private var iapsMasterModeOn: Bool
    @State private var eatingSoonTarget: String = ""
    @State private var eatingSoonDuration: String = ""
    @State private var activityTarget: String = ""
    @State private var activityDuration: String = ""
    @State private var hypoTarget: String = ""
    @State private var hypoDuration: String = ""

    private let keychain = SharedConstants.credentialKeychain()
    private var thresholdUnit: String { store.displayUnits == .mmol ? "mmol/l" : "mg/dl" }

    init(store: AppStore, writer: NsTreatmentWriter) {
        self.store = store
        self.writer = writer
        let t = store.thresholds
        let isMmol = store.displayUnits == .mmol
        _urgentLow = State(initialValue: isMmol ? String(format: "%.1f", Double(t.urgentLow) / glucoseMmolFactor) : String(t.urgentLow))
        _low = State(initialValue: isMmol ? String(format: "%.1f", Double(t.low) / glucoseMmolFactor) : String(t.low))
        _high = State(initialValue: isMmol ? String(format: "%.1f", Double(t.high) / glucoseMmolFactor) : String(t.high))
        _urgentHigh = State(initialValue: isMmol ? String(format: "%.1f", Double(t.urgentHigh) / glucoseMmolFactor) : String(t.urgentHigh))
        _staleMinutes = State(initialValue: String(t.staleMinutes))
        _liveActivityOn = State(initialValue: store.isLiveActivityEnabled)
        _glucoseNotificationOn = State(initialValue: store.isGlucoseNotificationEnabled)
        _announcementRelayOn = State(initialValue: store.isAnnouncementRelayEnabled)
        _iapsMasterModeOn = State(initialValue: store.isIapsMasterModeEnabled)
        let presets = store.ttPresets
        func fmt(_ mgdl: Int) -> String {
            isMmol ? String(format: "%.1f", Double(mgdl) / glucoseMmolFactor) : String(mgdl)
        }
        _eatingSoonTarget = State(initialValue: fmt(presets[.eatingSoon]?.targetMgdl ?? TtReason.eatingSoon.defaultTargetMgdl))
        _eatingSoonDuration = State(initialValue: String(presets[.eatingSoon]?.durationMin ?? TtReason.eatingSoon.defaultDurationMin))
        _activityTarget = State(initialValue: fmt(presets[.activity]?.targetMgdl ?? TtReason.activity.defaultTargetMgdl))
        _activityDuration = State(initialValue: String(presets[.activity]?.durationMin ?? TtReason.activity.defaultDurationMin))
        _hypoTarget = State(initialValue: fmt(presets[.hypo]?.targetMgdl ?? TtReason.hypo.defaultTargetMgdl))
        _hypoDuration = State(initialValue: String(presets[.hypo]?.durationMin ?? TtReason.hypo.defaultDurationMin))
        let ct = store.consumableThresholds
        _cageWarn = State(initialValue: String(ct.cageWarnHours))
        _cageCritical = State(initialValue: String(ct.cageCriticalHours))
        _iageWarn = State(initialValue: String(ct.iageWarnHours))
        _iageCritical = State(initialValue: String(ct.iageCriticalHours))
        _sageWarn = State(initialValue: String(ct.sageWarnHours))
        _sageCritical = State(initialValue: String(ct.sageCriticalHours))
        _bageWarn = State(initialValue: String(ct.bageWarnHours))
        _bageCritical = State(initialValue: String(ct.bageCriticalHours))
        _reservoirWarn = State(initialValue: String(ct.reservoirWarnUnits))
        _reservoirCritical = State(initialValue: String(ct.reservoirCriticalUnits))
        _pumpBattWarn = State(initialValue: String(ct.pumpBattWarnPercent))
        _pumpBattCritical = State(initialValue: String(ct.pumpBattCriticalPercent))
    }

    var body: some View {
        Form {
            Section("settings.ns_connection") {
                TextField("settings.ns_url", text: $nsUrl)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                SecureField("settings.access_token", text: $accessToken)
                    .autocapitalization(.none)

                Button(testingConnection ? String(localized: "settings.testing") : String(localized: "settings.test_connection")) {
                    testConnection()
                }
                .disabled(testingConnection || nsUrl.isEmpty || accessToken.isEmpty)

                if let result = connectionResult {
                    Text(result)
                        .foregroundColor(result.hasPrefix("OK") ? .green : .red)
                }

                // The socket falls back to polling silently by design; without this row a realtime
                // feature that never engages on a given server is invisible instead of diagnosable.
                HStack {
                    Text("settings.realtime")
                    Spacer()
                    Text(store.realtimeStatus)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Section("settings.glucose_units") {
                Picker("settings.units", selection: Binding(
                    get: { store.displayUnits },
                    set: { changeDisplayUnits(to: $0) }
                )) {
                    Text("mg/dl").tag(GlucoseUnits.mgdl)
                    Text("mmol/l").tag(GlucoseUnits.mmol)
                }
                .pickerStyle(.segmented)
            }

            Section("settings.alarm_thresholds") {
                HStack {
                    TextField("settings.urgent_low", text: $urgentLow).keyboardType(.decimalPad)
                    Text(thresholdUnit).foregroundColor(.secondary)
                }
                HStack {
                    TextField("settings.low", text: $low).keyboardType(.decimalPad)
                    Text(thresholdUnit).foregroundColor(.secondary)
                }
                HStack {
                    TextField("settings.high", text: $high).keyboardType(.decimalPad)
                    Text(thresholdUnit).foregroundColor(.secondary)
                }
                HStack {
                    TextField("settings.urgent_high", text: $urgentHigh).keyboardType(.decimalPad)
                    Text(thresholdUnit).foregroundColor(.secondary)
                }
                HStack {
                    TextField("settings.stale_min", text: $staleMinutes).keyboardType(.numberPad)
                    Text("min").foregroundColor(.secondary)
                }
            }

            Section("settings.consumable_warnings") {
                HStack {
                    TextField("settings.cage_warn", text: $cageWarn).keyboardType(.numberPad)
                    Text("h").foregroundColor(.secondary)
                    TextField("settings.cage_critical", text: $cageCritical).keyboardType(.numberPad)
                    Text("h").foregroundColor(.secondary)
                }
                HStack {
                    TextField("settings.iage_warn", text: $iageWarn).keyboardType(.numberPad)
                    Text("h").foregroundColor(.secondary)
                    TextField("settings.iage_critical", text: $iageCritical).keyboardType(.numberPad)
                    Text("h").foregroundColor(.secondary)
                }
                HStack {
                    TextField("settings.sage_warn", text: $sageWarn).keyboardType(.numberPad)
                    Text("h").foregroundColor(.secondary)
                    TextField("settings.sage_critical", text: $sageCritical).keyboardType(.numberPad)
                    Text("h").foregroundColor(.secondary)
                }
                HStack {
                    TextField("settings.bage_warn", text: $bageWarn).keyboardType(.numberPad)
                    Text("h").foregroundColor(.secondary)
                    TextField("settings.bage_critical", text: $bageCritical).keyboardType(.numberPad)
                    Text("h").foregroundColor(.secondary)
                }
                HStack {
                    TextField("settings.reservoir_warn", text: $reservoirWarn).keyboardType(.numberPad)
                    Text("U").foregroundColor(.secondary)
                    TextField("settings.reservoir_critical", text: $reservoirCritical).keyboardType(.numberPad)
                    Text("U").foregroundColor(.secondary)
                }
                HStack {
                    TextField("settings.pump_batt_warn", text: $pumpBattWarn).keyboardType(.numberPad)
                    Text("%").foregroundColor(.secondary)
                    TextField("settings.pump_batt_critical", text: $pumpBattCritical).keyboardType(.numberPad)
                    Text("%").foregroundColor(.secondary)
                }
            }

            if !store.remoteTempTargetPresets.isEmpty {
                Section {
                    ForEach(store.remoteTempTargetPresets) { preset in
                        HStack {
                            Text(preset.name)
                            Spacer()
                            Text("\(displayGlucose(preset.targetMgdl)) • \(preset.durationMin)m")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text(String(localized: "remote.master_presets"))
                } footer: {
                    Text(String(localized: "remote.master_presets_footer"))
                }
            }

            Section("Temp Target Presets") {
                ttPresetRow(reason: .eatingSoon, label: "Eating Soon")
                ttPresetRow(reason: .activity, label: "Activity")
                ttPresetRow(reason: .hypo, label: "Hypo")
            }

            if !store.remoteSceneDefinitions.isEmpty {
                Section {
                    ForEach(store.remoteSceneDefinitions) { scene in
                        HStack {
                            Text(scene.name ?? scene.sceneId)
                                // A disabled scene is listed here (this screen mirrors the master's
                                // config) but is not offered for activation — see SceneRemoteControlView.
                                .foregroundColor(scene.isEnabled ? .primary : .secondary)
                            Spacer()
                            if let minutes = scene.defaultDurationMinutes {
                                Text(String(format: String(localized: "scene.default_duration"), minutes))
                                    .foregroundColor(.secondary)
                            }
                            if !scene.isEnabled {
                                Text("remote.disabled")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(String(localized: "remote.scene_definitions"))
                }
            }

            NavigationLink {
                ProfileView(store: store, writer: writer)
            } label: {
                Text("Profile")
            }

            NavigationLink {
                MasterConfigView(store: store)
            } label: {
                Text(String(localized: "remote.master_title"))
            }

            NavigationLink {
                ClientControlPairingView(store: store)
            } label: {
                Text("Pair with Master (Client Control)")
            }

            NavigationLink {
                BolusCalculatorView(store: store)
            } label: {
                Text("Bolus Calculator (Client Control)")
            }

            NavigationLink {
                SceneRemoteControlView(store: store)
            } label: {
                Text("Scenes (Client Control)")
            }

            if #available(iOS 16.1, *) {
                Section {
                    Toggle(String(localized: "settings.live_activity"), isOn: $liveActivityOn)
                        .onChange(of: liveActivityOn) { on in store.setLiveActivityEnabled(on) }
                } footer: {
                    Text(String(localized: "settings.live_activity_caption"))
                }
            }

            Section {
                Toggle(String(localized: "settings.glucose_notification"), isOn: $glucoseNotificationOn)
                    .onChange(of: glucoseNotificationOn) { on in
                        store.setGlucoseNotificationEnabled(on)
                    }
            } footer: {
                Text(String(localized: "settings.glucose_notification_caption"))
            }

            Section {
                Toggle(String(localized: "settings.announcement_relay"), isOn: $announcementRelayOn)
                    .onChange(of: announcementRelayOn) { on in
                        store.setAnnouncementRelayEnabled(on)
                    }
            } footer: {
                Text(String(localized: "settings.announcement_relay_caption"))
            }

            Section {
                Toggle(String(localized: "settings.iaps_master_mode"), isOn: $iapsMasterModeOn)
                    .onChange(of: iapsMasterModeOn) { on in
                        store.setIapsMasterModeEnabled(on)
                    }
            } footer: {
                Text(String(localized: "settings.iaps_master_mode_caption"))
            }

            Section {
                Picker("settings.keepalive_mode", selection: Binding(
                    get: { store.keepAliveMode },
                    set: { store.setKeepAliveMode($0) }
                )) {
                    Text("settings.keepalive_disabled").tag(KeepAliveMode.disabled)
                    Text("settings.keepalive_normal").tag(KeepAliveMode.normal)
                    Text("settings.keepalive_aggressive").tag(KeepAliveMode.aggressive)
                }
            } header: {
                Text("settings.keepalive")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "settings.keepalive_caption"))
                    // The battery cost has to be explicit: keep-alive is the only sub-5-minute path
                    // without Apple push, and it is paid for in overnight battery.
                    Text(String(localized: "settings.keepalive.battery_note"))
                    Text(String(localized: "settings.alarms.focus_note"))
                }
            }
        }
        .navigationTitle("settings.title")
        .onAppear { loadSettings() }
        .onDisappear { saveThresholds(); saveTtPresets(); saveConsumableThresholds() }
    }

    private func displayGlucose(_ mgdl: Int) -> String {
        store.displayUnits == .mmol
            ? String(format: "%.1f mmol/l", Double(mgdl) / glucoseMmolFactor)
            : "\(mgdl) mg/dl"
    }

    private func ttPresetRow(reason: TtReason, label: String) -> some View {
        let isMmol = store.displayUnits == .mmol
        return Group {
            switch reason {
            case .eatingSoon:
                ttPresetFields(label: label, target: $eatingSoonTarget, duration: $eatingSoonDuration, isMmol: isMmol)
            case .activity:
                ttPresetFields(label: label, target: $activityTarget, duration: $activityDuration, isMmol: isMmol)
            case .hypo:
                ttPresetFields(label: label, target: $hypoTarget, duration: $hypoDuration, isMmol: isMmol)
            case .custom:
                EmptyView()
            }
        }
    }

    private func ttPresetFields(label: String, target: Binding<String>, duration: Binding<String>, isMmol: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline).bold()
            HStack {
                TextField("Target", text: target).keyboardType(.decimalPad)
                Text(isMmol ? "mmol/l" : "mg/dl").foregroundColor(.secondary)
                TextField("Duration", text: duration).keyboardType(.numberPad)
                Text("min").foregroundColor(.secondary)
            }
        }
    }

    private func loadSettings() {
        nsUrl = (try? keychain.get(.nsUrl)) ?? ""
        accessToken = (try? keychain.get(.nsAccessToken)) ?? ""
        liveActivityOn = store.isLiveActivityEnabled
        glucoseNotificationOn = store.isGlucoseNotificationEnabled
        announcementRelayOn = store.isAnnouncementRelayEnabled
        iapsMasterModeOn = store.isIapsMasterModeEnabled
    }

    private func changeDisplayUnits(to units: GlucoseUnits) {
        let previous = store.displayUnits
        guard previous != units else { return }
        urgentLow = SettingsValueConverter.convert(urgentLow, from: previous, to: units)
        low = SettingsValueConverter.convert(low, from: previous, to: units)
        high = SettingsValueConverter.convert(high, from: previous, to: units)
        urgentHigh = SettingsValueConverter.convert(urgentHigh, from: previous, to: units)
        eatingSoonTarget = SettingsValueConverter.convert(eatingSoonTarget, from: previous, to: units)
        activityTarget = SettingsValueConverter.convert(activityTarget, from: previous, to: units)
        hypoTarget = SettingsValueConverter.convert(hypoTarget, from: previous, to: units)
        store.setDisplayUnits(units)
    }

    private func saveThresholds() {
        let isMmol = store.displayUnits == .mmol
        let toMgdl: (String, Int) -> Int = { str, fallback in
            guard let v = Double(str) else { return fallback }
            return isMmol ? Int((v * glucoseMmolFactor).rounded()) : Int(v)
        }
        let d = UserDefaults.standard
        let ulVal = toMgdl(urgentLow, 55)
        let loVal = toMgdl(low, 70)
        let hiVal = toMgdl(high, 180)
        let uhiVal = toMgdl(urgentHigh, 250)
        let staleVal = Int(staleMinutes) ?? 15
        d.set(ulVal, forKey: "threshold.urgentLow")
        d.set(loVal, forKey: "threshold.low")
        d.set(hiVal, forKey: "threshold.high")
        d.set(uhiVal, forKey: "threshold.urgentHigh")
        d.set(staleVal, forKey: "threshold.staleMinutes")
        store.updateThresholds(AlarmThresholds(
            urgentLow: ulVal,
            low: loVal,
            high: hiVal,
            urgentHigh: uhiVal,
            staleMinutes: staleVal
        ))
    }

    private func saveConsumableThresholds() {
        let d = ConsumableThresholds(
            cageWarnHours: Int(cageWarn) ?? ConsumableThresholds.defaults.cageWarnHours,
            cageCriticalHours: Int(cageCritical) ?? ConsumableThresholds.defaults.cageCriticalHours,
            iageWarnHours: Int(iageWarn) ?? ConsumableThresholds.defaults.iageWarnHours,
            iageCriticalHours: Int(iageCritical) ?? ConsumableThresholds.defaults.iageCriticalHours,
            sageWarnHours: Int(sageWarn) ?? ConsumableThresholds.defaults.sageWarnHours,
            sageCriticalHours: Int(sageCritical) ?? ConsumableThresholds.defaults.sageCriticalHours,
            bageWarnHours: Int(bageWarn) ?? ConsumableThresholds.defaults.bageWarnHours,
            bageCriticalHours: Int(bageCritical) ?? ConsumableThresholds.defaults.bageCriticalHours,
            reservoirWarnUnits: Int(reservoirWarn) ?? ConsumableThresholds.defaults.reservoirWarnUnits,
            reservoirCriticalUnits: Int(reservoirCritical) ?? ConsumableThresholds.defaults.reservoirCriticalUnits,
            pumpBattWarnPercent: Int(pumpBattWarn) ?? ConsumableThresholds.defaults.pumpBattWarnPercent,
            pumpBattCriticalPercent: Int(pumpBattCritical) ?? ConsumableThresholds.defaults.pumpBattCriticalPercent
        )
        store.updateConsumableThresholds(d)
    }

    private func saveTtPresets() {
        let isMmol = store.displayUnits == .mmol
        let toMgdl: (String, Int) -> Int = { str, fallback in
            guard let v = Double(str) else { return fallback }
            return isMmol ? Int((v * glucoseMmolFactor).rounded()) : Int(v)
        }
        var presets: [TtReason: TtPreset] = [:]
        presets[.eatingSoon] = TtPreset(targetMgdl: toMgdl(eatingSoonTarget, 90),
                                         durationMin: Int(eatingSoonDuration) ?? 45)
        presets[.activity] = TtPreset(targetMgdl: toMgdl(activityTarget, 140),
                                       durationMin: Int(activityDuration) ?? 90)
        presets[.hypo] = TtPreset(targetMgdl: toMgdl(hypoTarget, 150),
                                   durationMin: Int(hypoDuration) ?? 60)
        store.ttPresets = presets
    }

    private func testConnection() {
        testingConnection = true
        connectionResult = nil

        guard let url = AppStore.normalizedURL(nsUrl) else {
            connectionResult = String(localized: "settings.invalid_url")
            testingConnection = false
            return
        }
        // keychain is already the shared-group store, so the widget sees these.
        try? keychain.set(url.absoluteString, for: .nsUrl)
        try? keychain.set(accessToken.trimmingCharacters(in: .whitespacesAndNewlines), for: .nsAccessToken)
        WidgetCenter.shared.reloadAllTimelines()

        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let transport = URLSessionTransport()
            let client = NightscoutClientLive(baseURL: url, accessToken: token, transport: transport)
            do {
                try await client.authorize()
                _ = try await client.fetchEntries(limit: 1)
                await MainActor.run {
                    connectionResult = String(localized: "settings.ok_connected")
                    store.reconnect(baseURL: url, accessToken: token)
                }
                try? await store.refresh()
            } catch {
                await MainActor.run { connectionResult = error.localizedDescription }
            }
            await MainActor.run { testingConnection = false }
        }
    }
}
