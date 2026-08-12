import SwiftUI
import Charts

struct ProfileView: View {
    @ObservedObject var store: AppStore
    let writer: NsTreatmentWriter
    @State private var selectedName: String?
    @State private var switchTarget: ProfileSelection?
    @State private var editTarget: ProfileSelection?
    @State private var switchPct = "100"
    @State private var switchDur = "1440"
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private var canSwitchProfile: Bool {
        store.remoteCapabilities?.canRemoteProfileSwitch ?? true
    }

    private var profileSwitchReason: String? {
        guard store.remoteCapabilities != nil, !canSwitchProfile else { return nil }
        // The raw value is the wire key (`ns_receive_profile_switch`) — truthful, but not a name to
        // show a user. Every other gated action already renders the localized capability name.
        return String(
            format: String(localized: "remote.disabled_reason"),
            NSLocalizedString(NsRemoteCapabilityKey.profileSwitch.localizationKey, comment: "")
        )
    }

    private var units: GlucoseUnits { store.displayUnits }

    var body: some View {
        List {
            if let ps = store.profileStore {
                Section("Profiles") {
                    ForEach(ps.profileNames, id: \.self) { name in
                        profileCard(name, isActive: isActive(name))
                            .onTapGesture {
                                guard canSwitchProfile else {
                                    statusMessage = profileSwitchReason
                                    statusIsError = true
                                    return
                                }
                                selectedName = name
                            }
                    }
                }
                if let active = store.activeProfileSwitch?.profileName,
                   let prof = store.profile {
                    Section("Active: \(active)") {
                        basalChart(prof)
                        targetChart(prof)
                        isfChart(prof)
                        icrChart(prof)
                    }
                }
            } else {
                Text("No profile loaded")
            }

            if let msg = statusMessage {
                Text(msg).foregroundColor(statusIsError ? .red : .green)
            }

            if let reason = profileSwitchReason {
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Profile")
        .confirmationDialog("Profile", isPresented: Binding(
            get: { selectedName != nil },
            set: { if !$0 { selectedName = nil } }
        )) {
            if let name = selectedName {
                Button("Switch") { switchTarget = ProfileSelection(name: name) }
                Button("Edit Values") { editTarget = ProfileSelection(name: name) }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if let name = selectedName {
                Text(name)
            }
        }
        .sheet(item: $switchTarget) { sel in
            profileSwitchSheet(for: sel.name)
        }
        .sheet(item: $editTarget) { sel in
            if let json = store.profileStore?.rawJson[sel.name] {
                ProfileEditView(store: store, writer: writer, profileName: sel.name, rawJson: json)
            }
        }
    }

    private func isActive(_ name: String) -> Bool {
        store.activeProfileSwitch?.profileName == name
    }

    private func profileSwitchSheet(for name: String) -> some View {
        NavigationStack {
            Form {
                TextField("Percentage (30-250)", text: $switchPct).keyboardType(.numberPad)
                TextField("Duration (0=permanent)", text: $switchDur).keyboardType(.numberPad)
            }
            .navigationTitle("Switch to \(name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { switchTarget = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Switch") {
                        switchTo(name)
                        switchTarget = nil
                    }
                }
            }
        }
    }

    private struct ProfileSelection: Identifiable {
        let name: String
        var id: String { name }
    }

    private func switchTo(_ name: String) {
        guard canSwitchProfile else {
            statusMessage = profileSwitchReason
            statusIsError = true
            return
        }
        guard let pct = Int(switchPct), (30...250).contains(pct),
              let dur = Int(switchDur), dur > 0 else { return }
        let json = store.profileStore?.rawJson[name]
        Task {
            do {
                try await writer.switchProfile(name: name, percentage: pct, durationMin: dur, profileJson: json)
                try? await store.refresh()
                statusMessage = "Profile switch sent"
                statusIsError = false
            } catch {
                statusMessage = error.localizedDescription
                statusIsError = true
            }
        }
    }

    private func profileCard(_ name: String, isActive: Bool) -> some View {
        let basalSum: Double? = {
            guard let json = store.profileStore?.rawJson[name],
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let prof = NsMapping.parseProfileObject(obj)
            return dailyBasalUnits(prof.basal.map { ($0.startSeconds, $0.rate) })
        }()

        return HStack {
            VStack(alignment: .leading) {
                Text(name).font(.headline)
                HStack {
                    if let sum = basalSum {
                        Text("Σ \(String(format: "%.2f", sum)) ед")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let pct = store.activeProfileSwitch?.percentage, isActive, pct != 100 {
                        Text("\(pct)%").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            if isActive {
                Text("Active").font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.green.opacity(0.2)).cornerRadius(4)
            }
            if !canSwitchProfile {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Charts

    private func basalChart(_ p: NsProfile) -> some View {
        StepChart(
            points: stepChartPoints(p.basal.map { ($0.startSeconds, $0.rate) }),
            unitLabel: "U/h",
            color: .blue
        )
    }

    private func targetChart(_ p: NsProfile) -> some View {
        let lo = p.targetLow.map { ($0.startSeconds, gVal($0.value, p)) }
        let hi = p.targetHigh.map { ($0.startSeconds, gVal($0.value, p)) }
        return TargetBandChart(loBlocks: lo, hiBlocks: hi, unitLabel: units.rawValue)
    }

    private func isfChart(_ p: NsProfile) -> some View {
        StepChart(
            points: stepChartPoints(p.sensitivity.map { ($0.startSeconds, gVal($0.value, p)) }),
            unitLabel: units.rawValue,
            color: .orange
        )
    }

    private func icrChart(_ p: NsProfile) -> some View {
        StepChart(
            points: stepChartPoints(p.carbRatio.map { ($0.startSeconds, $0.value) }),
            unitLabel: "g/U",
            color: .purple
        )
    }

    private func gVal(_ value: Double, _ p: NsProfile) -> Double {
        convertUnit(value: value, from: p.units, to: units)
    }
}

// MARK: - Target band chart (two lines + fill between)

private struct TargetBandChart: View {
    let loBlocks: [(startSeconds: Int, value: Double)]
    let hiBlocks: [(startSeconds: Int, value: Double)]
    let unitLabel: String

    var body: some View {
        let lo = stepChartPoints(loBlocks)
        let hi = stepChartPoints(hiBlocks)
        let allX = Array(Set(lo.map(\.hour) + hi.map(\.hour))).sorted()
        Chart {
            ForEach(Array(zip(allX, allX.dropFirst())), id: \.0) { (x, nextX) in
                RectangleMark(
                    xStart: .value("S", x),
                    xEnd: .value("E", nextX),
                    yStart: .value("L", stepValue(at: x, in: lo)),
                    yEnd: .value("H", stepValue(at: x, in: hi))
                )
                .foregroundStyle(.green.opacity(0.2))
            }
            ForEach(lo, id: \.hour) { LineMark(x: .value("h", $0.hour), y: .value("v", $0.value)) }
                .foregroundStyle(.green)
            ForEach(hi, id: \.hour) { LineMark(x: .value("h", $0.hour), y: .value("v", $0.value)) }
                .foregroundStyle(.green)
        }
        .chartXScale(domain: 0.0...24.0)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 7)) }
        .chartYAxisLabel(unitLabel)
        .frame(height: 100)
    }

    private func stepValue(at hour: Double, in points: [(hour: Double, value: Double)]) -> Double {
        points.last(where: { $0.hour <= hour })?.value ?? points.first?.value ?? 0
    }
}
