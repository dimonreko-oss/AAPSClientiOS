import SwiftUI

struct HomeView: View {
    @ObservedObject var store: AppStore
    let writer: NsTreatmentWriter

    @State private var showCarbs = false
    @State private var showTarget = false
    @State private var carbsGrams = ""
    @State private var targetMgdl = "100"
    @State private var targetDuration = "60"
    @State private var targetReason: TtReason = .eatingSoon
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var selectedHours = 3
    @State private var refreshError: String?
    @State private var tappedTreatment: Treatment?
    @State private var showProfileSwitch = false
    @State private var selectedProfileName = ""
    @State private var profilePercentage = "100"
    @State private var profileDuration = "0"
    @State private var profileTimeshift = "0"
    @State private var startActivityTarget = false
    @State private var showEventSheet = false
    @State private var showLoopMenu = false
    @State private var showCarbsConfirm = false
    @State private var showIOB = false
    @State private var showCOB = false
    @State private var eventType = "Site Change"
    @State private var eventNotes = ""
    @State private var eventGlucose = ""
    @State private var eventDuration = ""

    private var units: GlucoseUnits { store.displayUnits }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                AlarmBannerView(store: store)
                permanentFailureBanners
                StatusCardView(
                    store: store,
                    units: units,
                    remoteCapabilities: store.remoteCapabilities,
                    statusMessage: $statusMessage,
                    statusIsError: $statusIsError,
                    showLoopMenu: $showLoopMenu,
                    showEventSheet: $showEventSheet,
                    showProfileSwitch: $showProfileSwitch
                )
                if let err = refreshError {
                    Text(err).font(.caption2).foregroundColor(.red).padding(6).background(Color.red.opacity(0.1)).cornerRadius(6)
                }
                GlucoseChartView(store: store, selectedHours: $selectedHours, showIOB: $showIOB, showCOB: $showCOB, tappedTreatment: $tappedTreatment)
                actionBar
                if let msg = statusMessage {
                    Text(msg).foregroundColor(statusIsError ? .red : .green).font(.caption)
                }
            }
            .padding(.horizontal, 8)
        }
        .background(Color(.systemBackground))
        .navigationTitle("app.title")
        .refreshable {
            do { try await store.refresh(); refreshError = nil }
            catch { refreshError = error.localizedDescription }
        }
        .task {
            guard store.isStale else { return }
            do { try await store.refresh(); refreshError = nil }
            catch { refreshError = error.localizedDescription }
        }
        .sheet(isPresented: $showCarbs) { carbsSheet }
        .sheet(isPresented: $showTarget) { targetSheet }
        .sheet(isPresented: $showProfileSwitch) { profileSwitchSheet }
        .sheet(isPresented: $showEventSheet) { eventSheet }
        .confirmationDialog("Loop Mode", isPresented: $showLoopMenu) {
            Button("Close Loop")  { setLoop("CLOSED_LOOP", 1440) }
            Button("Open Loop")   { setLoop("OPEN_LOOP", 120) }
            Button("Suspend 30m") { setLoop("SUSPENDED_BY_USER", 30) }
            Button("Suspend 1h")  { setLoop("SUSPENDED_BY_USER", 60) }
            Button("Suspend 2h")  { setLoop("SUSPENDED_BY_USER", 120) }
            Button("Disconnect Pump 15m") { setLoop("DISCONNECTED_PUMP", 15) }
            Button("Disconnect Pump 30m") { setLoop("DISCONNECTED_PUMP", 30) }
            Button("Disconnect Pump 1h")  { setLoop("DISCONNECTED_PUMP", 60) }
            Button("Disconnect Pump 2h")  { setLoop("DISCONNECTED_PUMP", 120) }
            Button("Disconnect Pump 3h")  { setLoop("DISCONNECTED_PUMP", 180) }
            Button("Reconnect") { setLoop("CLOSED_LOOP", 1440) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Requires NS Accept Running Mode on master device")
        }
    }

    // MARK: - Permanent failures

    /// Two conditions that the offline banner used to swallow, and that no amount of waiting fixes:
    /// a Nightscout token the server rejected (fix it in Settings) and a pairing the master will
    /// never answer again (re-pair). Both need a different sentence and a different destination
    /// from "connection lost".
    @ViewBuilder
    private var permanentFailureBanners: some View {
        if store.credentialsInvalid {
            Label("home.credentials_invalid", systemImage: "key.slash")
                .font(.caption)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
        }
        if store.clientControlState.requiresRepairing,
           let banner = ClientControlText.banner(store.clientControlState) {
            NavigationLink {
                ClientControlPairingView(store: store)
            } label: {
                Label(banner, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
            }
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        let carbsState = remoteActionState(for: .carbs, capabilities: store.remoteCapabilities)
        let targetState = remoteActionState(for: .tempTarget, capabilities: store.remoteCapabilities)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    if !carbsState.isEnabled {
                        presentDisabledReason(carbsState.reason)
                        return
                    }
                    showCarbs = true
                } label: { Label("home.carbs", systemImage: "fork.knife").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .opacity(carbsState.isEnabled ? 1 : 0.45)
                Button {
                    if !targetState.isEnabled {
                        presentDisabledReason(targetState.reason)
                        return
                    }
                    showTarget = true
                } label: { Label("home.target", systemImage: "target").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
                    .opacity(targetState.isEnabled ? 1 : 0.45)
            }
            if let warning = primaryActionWarning {
                Text(warning)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var primaryActionWarning: String? {
        [remoteActionState(for: .carbs, capabilities: store.remoteCapabilities),
         remoteActionState(for: .tempTarget, capabilities: store.remoteCapabilities)]
            .compactMap(\.reason)
            .first
    }

    // MARK: - Sheets

    private var carbsSheet: some View {
        CarbsSheetView(
            isPresented: $showCarbs,
            carbsGrams: $carbsGrams,
            statusMessage: $statusMessage,
            statusIsError: $statusIsError
        ) {
            showCarbsConfirm = true
        }
        .confirmationDialog("Confirm Carbs", isPresented: $showCarbsConfirm) {
            Button("Send \(carbsGrams)g", role: .destructive) {
                sendCarbs()
                showCarbs = false
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Send \(carbsGrams)g carbs to Nightscout?")
        }
    }

    private var targetSheet: some View {
        TargetSheetView(
            store: store,
            isPresented: $showTarget,
            targetMgdl: $targetMgdl,
            targetDuration: $targetDuration,
            targetReason: $targetReason,
            statusMessage: $statusMessage,
            statusIsError: $statusIsError,
            units: units,
            action: { sendTarget() },
            cancelAction: { cancelTarget() }
        )
    }

    private var profileSwitchSheet: some View {
        ProfileSwitchSheetView(
            store: store,
            isPresented: $showProfileSwitch,
            selectedProfileName: $selectedProfileName,
            profilePercentage: $profilePercentage,
            profileDuration: $profileDuration,
            profileTimeshift: $profileTimeshift,
            startActivityTarget: $startActivityTarget,
            statusMessage: $statusMessage,
            statusIsError: $statusIsError,
            units: units
        ) {
            switchProfile()
        }
    }

    private var eventSheet: some View {
        EventSheetView(
            isPresented: $showEventSheet,
            eventType: $eventType,
            eventNotes: $eventNotes,
            eventGlucose: $eventGlucose,
            eventDuration: $eventDuration
        ) {
            logEvent(eventType: eventType, notes: eventNotes, glucose: eventGlucose, duration: eventDuration)
        }
    }

    // MARK: - Actions

    private func sendCarbs() {
        Task {
            let grams = Double(carbsGrams) ?? 0
            guard grams > 0 else { return }
            let result = await HomeActions.sendCarbs(grams: grams, writer: writer, store: store)
            statusMessage = result.message
            statusIsError = result.isError
            if !result.isError { carbsGrams = "" }
        }
    }

    private func sendTarget() {
        let raw = targetMgdl.replacingOccurrences(of: ",", with: ".")
        guard let entered = Double(raw), let dur = Int(targetDuration), entered > 0, dur > 0 else { return }
        let mgdl = units == .mmol ? Int((entered * glucoseMmolFactor).rounded()) : Int(entered)
        Task {
            let result = await HomeActions.sendTarget(mgdl: mgdl, durationMin: dur, reason: targetReason, writer: writer, store: store)
            statusMessage = result.message
            statusIsError = result.isError
        }
    }

    private func cancelTarget() {
        Task {
            let result = await HomeActions.cancelTarget(writer: writer, store: store)
            statusMessage = result.message
            statusIsError = result.isError
        }
    }

    private func switchProfile() {
        let actionState = remoteActionState(for: .profileSwitch, capabilities: store.remoteCapabilities)
        guard actionState.isEnabled else {
            presentDisabledReason(actionState.reason)
            return
        }
        guard let pct = Int(profilePercentage), (30...250).contains(pct),
              let dur = Int(profileDuration), dur >= 0,
              let shift = Int(profileTimeshift), (-23...23).contains(shift) else { return }
        let json = store.profileStore?.rawJson[selectedProfileName]
        Task {
            let result = await HomeActions.switchProfile(
                name: selectedProfileName,
                percentage: pct,
                durationMin: dur,
                timeshiftHours: shift,
                profileJson: json,
                startActivityTarget: startActivityTarget,
                writer: writer,
                store: store
            )
            statusMessage = result.message
            statusIsError = result.isError
        }
    }

    private func logEvent(eventType: String, notes: String, glucose: String, duration: String) {
        let actionState = remoteActionState(for: .therapyEvents, capabilities: store.remoteCapabilities)
        guard actionState.isEnabled else {
            presentDisabledReason(actionState.reason)
            return
        }
        let glucoseMgdl = Int(glucose)
        Task {
            let result = await HomeActions.logEvent(
                eventType: eventType,
                notes: notes.isEmpty ? nil : notes,
                glucoseMgdl: glucoseMgdl,
                durationMin: duration.isEmpty ? nil : Int(duration),
                writer: writer,
                store: store
            )
            statusMessage = result.message
            statusIsError = result.isError
        }
    }

    private func setLoop(_ mode: String, _ durationMin: Int) {
        let actionState = remoteActionState(for: .runningMode, capabilities: store.remoteCapabilities)
        guard actionState.isEnabled else {
            presentDisabledReason(actionState.reason)
            return
        }
        Task {
            let result = await HomeActions.setLoopMode(mode, durationMin: durationMin, useIapsAnnouncement: store.isIapsMasterModeEnabled, writer: writer, store: store)
            statusMessage = result.message
            statusIsError = result.isError
        }
    }

    private func presentDisabledReason(_ reason: String?) {
        statusMessage = reason ?? String(localized: "remote.config_unavailable")
        statusIsError = true
    }
}
