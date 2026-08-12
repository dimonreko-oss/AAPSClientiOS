import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: AppStore

    @State private var selectedSection: HistorySection = .carbs
    @State private var treatments: [Treatment] = []
    @State private var errorMessage: String?

    private var units: GlucoseUnits { store.displayUnits }

    private var filteredTreatments: [Treatment] {
        // `isValid == false` is NS API v3's tombstone for a deleted document. The master's own
        // queries all carry `AND (isValid = 1)`, so showing them here would be showing rows the
        // master has already forgotten.
        treatments.filter { $0.isValid && selectedSection.matches($0) }
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(HistorySection.allCases) { section in
                            Button {
                                selectedSection = section
                            } label: {
                                Text(section.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(selectedSection == section ? Color.white : Color.primary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(selectedSection == section ? Color.accentColor : Color(.secondarySystemFill))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)

            if filteredTreatments.isEmpty {
                Group {
                    if let errorMessage, treatments.isEmpty {
                        Text(errorMessage)
                    } else {
                        Text("history.empty")
                    }
                }
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(filteredTreatments, id: \.id) { treatment in
                    historyRow(treatment)
                }
            }
        }
        .navigationTitle("history.title")
        .task {
            await loadHistory()
        }
    }

    private func historyRow(_ treatment: Treatment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(treatment.eventType)
                    .font(.headline)
                Text(treatment.date, format: .dateTime.day().month().hour().minute())
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let subtitle = subtitle(for: treatment) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                ForEach(trailingValues(for: treatment), id: \.self) { value in
                    Text(value)
                }
            }
            .font(.caption)
        }
    }

    private func subtitle(for treatment: Treatment) -> String? {
        HistoryRowText.subtitle(for: treatment)
    }

    private func trailingValues(for treatment: Treatment) -> [String] {
        var values: [String] = []

        if let insulin = treatment.insulin {
            values.append("\(String(format: "%.3f", insulin)) U")
        }
        if let carbs = treatment.carbs {
            values.append("\(String(format: "%.0f", carbs)) g")
        }
        if let absolute = treatment.absolute {
            values.append("\(String(format: "%.2f", absolute)) U/h")
        } else if let pct = treatment.tempBasalPercent {
            values.append("\(pct)% basal")
        }
        if let lo = treatment.targetBottom {
            values.append(Formatting.targetRangeText(lo: lo, hi: treatment.targetTop ?? lo, units: units))
        }
        if let duration = treatment.durationMin {
            values.append("\(duration) min")
        }
        if let percentage = treatment.percentage {
            values.append("\(percentage)%")
        }

        return values
    }

    private func loadHistory() async {
        let cached = HistoryCache.load()
        if !cached.isEmpty {
            treatments = cached
            updateSelection(for: cached)
        }
        await refreshHistory(using: cached)
    }

    private func refreshHistory(using cached: [Treatment]) async {
        do {
            store.ensureConfigured()
            // Refetch the WHOLE window rather than `since: newest cached date`. The merge unions by
            // id, so an incremental fetch can only ever ADD rows: a treatment deleted or edited on
            // the master kept its stale copy here (and in the on-disk cache) forever. A full-window
            // read makes the server authoritative for everything inside the window.
            let incoming = try await store.client.fetchTreatmentsHistory(since: HistoryCache.cutoffDate)
            let merged = Treatment.mergedHistoryWindow(
                existing: [],
                incoming: incoming,
                days: HistoryCache.windowDays
            )
            treatments = merged
            updateSelection(for: merged)
            errorMessage = nil
            HistoryCache.save(merged)
        } catch is CancellationError {
            return
        } catch {
            if cached.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updateSelection(for treatments: [Treatment]) {
        guard !treatments.contains(where: selectedSection.matches),
              let firstNonEmpty = HistorySection.allCases.first(where: { section in
                  treatments.contains(where: section.matches)
              }) else { return }
        selectedSection = firstNonEmpty
    }
}

/// Row copy for the history list. Pure, so the RunningMode rendering is testable without a view.
enum HistoryRowText {
    static func subtitle(for treatment: Treatment) -> String? {
        if treatment.eventType == RunningModeParser.eventType {
            let mode = RunningMode.from(wire: treatment.mode)
            // A pre-v4 master writes no `mode`; `notes` carries `NsMapping.loopModeLabel`'s English
            // text, which is still better than rendering "Unknown".
            guard mode != .unknown else { return nonEmpty(treatment.notes) }
            var text = mode.displayName
            if treatment.autoForced == true, let reasons = nonEmpty(treatment.reasons) {
                // The master forced this from a constraint — the reason is the whole story.
                text += " — " + reasons
            }
            return text
        }
        if let profile = nonEmpty(treatment.profileName) {
            return profile
        }
        return nonEmpty(treatment.notes)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private enum HistoryCache {
    static let windowDays = 7
    static let fileName = "history-treatments.plist"

    static var cutoffDate: Date {
        Date().addingTimeInterval(-Double(windowDays) * 86_400)
    }

    static func load(now: Date = Date()) -> [Treatment] {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let cached = try? PropertyListDecoder().decode([Treatment].self, from: data) else {
            return []
        }
        return Treatment.mergedHistoryWindow(existing: cached, incoming: [], now: now, days: windowDays)
    }

    static func save(_ treatments: [Treatment], now: Date = Date()) {
        guard let url = cacheURL else { return }
        let trimmed = Treatment.mergedHistoryWindow(existing: treatments, incoming: [], now: now, days: windowDays)
        guard let data = try? PropertyListEncoder().encode(trimmed) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName)
    }
}

private enum HistorySection: String, CaseIterable, Identifiable {
    case carbs
    case targets
    case basal
    case loopMode
    case profile
    case events

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .carbs: return "history.section.carbs"
        case .targets: return "history.section.targets"
        case .basal: return "history.section.basal"
        case .loopMode: return "history.section.loop_mode"
        case .profile: return "history.section.profile"
        case .events: return "history.section.events"
        }
    }

    func matches(_ treatment: Treatment) -> Bool {
        switch self {
        case .carbs:
            return ["Carb Correction", "Meal Bolus", "Snack Bolus", "Correction Bolus"].contains(treatment.eventType)
                || (treatment.carbs ?? 0) > 0
                || (treatment.insulin ?? 0) > 0
        case .targets:
            return treatment.eventType == "Temporary Target"
        case .basal:
            return treatment.eventType == "Temp Basal"
        case .loopMode:
            return treatment.eventType == "OpenAPS Offline"
        case .profile:
            return treatment.eventType == "Profile Switch"
        case .events:
            return !Self.primaryTypes.contains(treatment.eventType)
                && (treatment.carbs ?? 0) == 0
                && (treatment.insulin ?? 0) == 0
        }
    }

    private static let primaryTypes: Set<String> = [
        "Carb Correction",
        "Meal Bolus",
        "Snack Bolus",
        "Correction Bolus",
        "Temporary Target",
        "Temp Basal",
        "OpenAPS Offline",
        "Profile Switch"
    ]
}
