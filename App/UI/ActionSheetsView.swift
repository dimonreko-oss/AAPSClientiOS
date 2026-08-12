import SwiftUI

// MARK: - Remote Action State

struct RemoteActionState {
    let isEnabled: Bool
    let reason: String?
}

// MARK: - Action helper

func remoteActionState(for key: NsRemoteCapabilityKey, capabilities: NsRemoteCapabilities?) -> RemoteActionState {
    // No cold doc yet — nothing to gate on.
    guard let capabilities else {
        return RemoteActionState(isEnabled: true, reason: nil)
    }
    // `NsRemoteCapabilities` fails OPEN per key: an unpublished flag reads as enabled, so only an
    // explicitly published `false` disables an action and this can no longer lock the user out.
    // Carbs and tempTarget therefore no longer need — and must not have — a hard-coded bypass: a
    // master that really publishes `ns_receive_carbs = false` discards the record, and reporting
    // "Carbs sent" for it is how a user ends up bolusing for carbs the loop never saw.
    let enabled = capabilities.isEnabled(for: key)
    let reason = enabled ? nil : disabledReason(for: key)
    return RemoteActionState(isEnabled: enabled, reason: reason)
}

private func disabledReason(for key: NsRemoteCapabilityKey) -> String {
    String(format: String(localized: "remote.disabled_reason"), NSLocalizedString(key.localizationKey, comment: ""))
}

/// Therapy events the master will actually ingest.
///
/// "Sensor Start" is deliberately absent: `TreatmentMapper`'s therapy-event branch has no
/// `SENSOR_STARTED` case, so `RemoteTreatment.toTreatment()` returns null and the row never becomes
/// a therapy event on the master. The treatment still lands in Nightscout, so the follower's own
/// history and SAGE reset while the master's never do — a silent divergence with no error shown.
/// "Sensor Change" covers the same intent and is accepted.
enum TherapyEventCatalog {
    static let offered = [
        "Site Change",
        "Insulin Change",
        "Pump Battery Change",
        "Sensor Change",
        "Note",
        "BG Check",
        "Exercise",
    ]
}

// MARK: - Action logic (static methods that call the writer)

enum HomeActions {
    static func sendCarbs(grams: Double, writer: NsTreatmentWriter, store: AppStore) async -> (message: String, isError: Bool) {
        do {
            try await writer.sendCarbs(grams: grams, at: Date())
            try? await store.refresh()
            return (String(localized: "home.carbs_sent"), false)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    static func sendTarget(mgdl: Int, durationMin: Int, reason: TtReason, writer: NsTreatmentWriter, store: AppStore) async -> (message: String, isError: Bool) {
        do {
            try await writer.sendTempTarget(targetMgdl: mgdl, durationMin: durationMin, reason: reason)
            try? await store.refresh()
            return (String(localized: "home.target_set"), false)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    static func cancelTarget(writer: NsTreatmentWriter, store: AppStore) async -> (message: String, isError: Bool) {
        do {
            try await writer.cancelTempTarget()
            try? await store.refresh()
            return (String(localized: "home.target_cancelled"), false)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    static func switchProfile(
        name: String, percentage: Int, durationMin: Int, timeshiftHours: Int,
        profileJson: String?, startActivityTarget: Bool,
        writer: NsTreatmentWriter, store: AppStore
    ) async -> (message: String, isError: Bool) {
        do {
            try await writer.switchProfile(name: name, percentage: percentage, durationMin: durationMin, timeshiftHours: timeshiftHours, profileJson: profileJson)
            // Matches AndroidAPS's ProfileSwitchDialog.submit(): only dose-reducing,
            // time-limited switches can optionally start the Activity temp target.
            if startActivityTarget, durationMin > 0, percentage < 100 {
                let presets = await store.ttPresets
                let targetMgdl = presets[.activity]?.targetMgdl ?? TtReason.activity.defaultTargetMgdl
                try? await writer.sendTempTarget(targetMgdl: targetMgdl, durationMin: durationMin, reason: .activity)
            }
            try? await store.refresh()
            return ("Profile switched", false)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    static func logEvent(eventType: String, notes: String?, glucoseMgdl: Int?, durationMin: Int?, writer: NsTreatmentWriter, store: AppStore) async -> (message: String, isError: Bool) {
        do {
            try await writer.logEvent(eventType: eventType, at: Date(), notes: notes, glucoseMgdl: glucoseMgdl, durationMin: durationMin)
            try? await store.refresh()
            return ("Event logged", false)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    static func setLoopMode(_ mode: String, durationMin: Int, useIapsAnnouncement: Bool, writer: NsTreatmentWriter, store: AppStore) async -> (message: String, isError: Bool) {
        do {
            if useIapsAnnouncement, let notes = IapsAnnouncementMapping.notes(forMode: mode) {
                try await writer.sendAnnouncement(notes: notes)
            } else {
                try await writer.setLoopMode(mode, durationMin: durationMin)
            }
            try? await store.refresh()
            return ("Loop command sent", false)
        } catch {
            return (error.localizedDescription, true)
        }
    }
}

// MARK: - Sheet content views

struct CarbsSheetView: View {
    @Binding var isPresented: Bool
    @Binding var carbsGrams: String
    @Binding var statusMessage: String?
    @Binding var statusIsError: Bool
    let action: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("action.grams", text: $carbsGrams).keyboardType(.decimalPad)
            }
            .navigationTitle("home.add_carbs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { isPresented = false } }
                ToolbarItem(placement: .confirmationAction) { Button("send") { action() }.disabled(carbsGrams.isEmpty) }
            }
        }
    }
}

struct TargetSheetView: View {
    @ObservedObject var store: AppStore
    @Binding var isPresented: Bool
    @Binding var targetMgdl: String
    @Binding var targetDuration: String
    @Binding var targetReason: TtReason
    @Binding var statusMessage: String?
    @Binding var statusIsError: Bool
    let units: GlucoseUnits
    let action: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if !store.remoteTempTargetPresets.isEmpty {
                    Section(String(localized: "remote.master_presets")) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(store.remoteTempTargetPresets) { preset in
                                    Button(preset.name) {
                                        targetMgdl = Formatting.format(preset.targetMgdl, units: units)
                                        targetDuration = "\(preset.durationMin)"
                                        targetReason = .custom
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .font(.caption)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                Section(store.remoteTempTargetPresets.isEmpty ? "Presets" : String(localized: "remote.local_presets")) {
                    HStack(spacing: 8) {
                        let presets = store.ttPresets
                        ttPresetButton("Eating Soon", .eatingSoon, preset: presets[.eatingSoon])
                        ttPresetButton("Activity", .activity, preset: presets[.activity])
                        ttPresetButton("Hypo", .hypo, preset: presets[.hypo])
                    }
                }
                HStack {
                    TextField("action.target", text: $targetMgdl).keyboardType(.decimalPad)
                    Text(units == .mmol ? "mmol/l" : "mg/dl").foregroundColor(.secondary)
                }
                TextField("action.duration_min", text: $targetDuration).keyboardType(.numberPad)
                Picker("action.reason", selection: $targetReason) {
                    Text("Eating Soon").tag(TtReason.eatingSoon)
                    Text("Activity").tag(TtReason.activity)
                    Text("Hypo").tag(TtReason.hypo)
                    Text("Custom").tag(TtReason.custom)
                }
                .onChange(of: targetReason) { reason in
                    let presets = store.ttPresets
                    if let preset = presets[reason] {
                        targetMgdl = Formatting.format(preset.targetMgdl, units: units)
                        targetDuration = "\(preset.durationMin)"
                    }
                }
                Button("action.cancel_target", role: .destructive) { cancelAction(); isPresented = false }
            }
            .navigationTitle("home.temp_target")
            .onAppear {
                if units == .mmol, let v = Double(targetMgdl) {
                    targetMgdl = String(format: "%.1f", v / glucoseMmolFactor)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { isPresented = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("set") { action(); isPresented = false }.disabled(targetMgdl.isEmpty || targetDuration.isEmpty)
                }
            }
        }
    }

    private func ttPresetButton(_ label: String, _ reason: TtReason, preset: TtPreset?) -> some View {
        Button(label) {
            let mgdl = preset?.targetMgdl ?? reason.defaultTargetMgdl
            let dur = preset?.durationMin ?? reason.defaultDurationMin
            targetMgdl = Formatting.format(mgdl, units: units)
            targetDuration = "\(dur)"
            targetReason = reason
        }
        .buttonStyle(.bordered)
        .font(.caption)
        .controlSize(.small)
    }

}

struct ProfileSwitchSheetView: View {
    @ObservedObject var store: AppStore
    @Binding var isPresented: Bool
    @Binding var selectedProfileName: String
    @Binding var profilePercentage: String
    @Binding var profileDuration: String
    @Binding var profileTimeshift: String
    @Binding var startActivityTarget: Bool
    @Binding var statusMessage: String?
    @Binding var statusIsError: Bool
    let units: GlucoseUnits
    let action: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if let store = store.profileStore {
                    Picker("Profile", selection: $selectedProfileName) {
                        ForEach(store.profileNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
                TextField("Percentage (30-250)", text: $profilePercentage).keyboardType(.numberPad)
                TextField("Duration (0=permanent)", text: $profileDuration).keyboardType(.numberPad)
                TextField("Timeshift hours (-23 to 23)", text: $profileTimeshift).keyboardType(.numbersAndPunctuation)
                Toggle("Also start Activity temp target (needs % < 100 and duration > 0)", isOn: $startActivityTarget)
            }
            .navigationTitle("Profile Switch")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { isPresented = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Switch") {
                        action()
                        isPresented = false
                    }
                    .disabled(selectedProfileName.isEmpty)
                }
            }
        }
    }
}

struct EventSheetView: View {
    @Binding var isPresented: Bool
    @Binding var eventType: String
    @Binding var eventNotes: String
    @Binding var eventGlucose: String
    @Binding var eventDuration: String
    let action: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Picker("Event", selection: $eventType) {
                    ForEach(TherapyEventCatalog.offered, id: \.self) { type in
                        Text(type).tag(type)
                    }
                }
                TextField("Notes", text: $eventNotes)
                if eventType == "BG Check" {
                    TextField("Glucose (mg/dl)", text: $eventGlucose).keyboardType(.numberPad)
                }
            }
            .navigationTitle("Log Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { isPresented = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("send") {
                        action()
                        isPresented = false
                    }
                }
            }
        }
    }
}
