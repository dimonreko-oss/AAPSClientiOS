import SwiftUI

struct BolusCalculatorView: View {
    @ObservedObject var store: AppStore

    @State private var carbsText = ""
    @State private var bgText = ""
    @State private var useCob = true
    @State private var useIob = true
    @State private var useTt = true
    @State private var useTrend = true
    @State private var useBg = true
    @State private var percentage = 100
    @State private var isBusy = false
    @State private var statusText: String?
    @State private var preview: BolusPreview?

    private var pairingStore: ClientPairingStore { store.clientPairingStore }

    /// Display accessor: `currentPairing()` is nil while `needsRepair`, which is a paired install
    /// that must re-pair — a different sentence from "you have never paired".
    private var isPaired: Bool { pairingStore.currentPairingIgnoringRepair() != nil }

    private var blockedReason: String? { ClientControlText.availability(store.masterControlAvailability) }

    var body: some View {
        Form {
            Section {
                Text("bolus.disclaimer")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !isPaired {
                Section {
                    Text("bolus.pair_first")
                        .foregroundColor(.secondary)
                }
            } else {
                if let blockedReason {
                    Section {
                        Label(blockedReason, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                }

                Section("bolus.section_inputs") {
                    TextField("bolus.carbs", text: $carbsText).keyboardType(.numberPad)
                    // Always mg/dL — `calculate()` converts to the master's units on send, so the
                    // numberPad (no decimal point) is correct whatever the master's profile says.
                    TextField("bolus.bg_override", text: $bgText).keyboardType(.numberPad)
                    Toggle("bolus.use_cob", isOn: $useCob)
                    Toggle("bolus.use_iob", isOn: $useIob)
                    Toggle("bolus.use_tt", isOn: $useTt)
                    Toggle("bolus.use_trend", isOn: $useTrend)
                    Toggle("bolus.use_bg", isOn: $useBg)
                    Stepper(String(format: String(localized: "bolus.correction"), percentage),
                            value: $percentage, in: 0...200, step: 5)
                }

                Section {
                    Button(isBusy ? String(localized: "bolus.calculating") : String(localized: "bolus.calculate")) {
                        calculate()
                    }
                    .disabled(isBusy || carbsText.isEmpty)
                }

                if let detail = preview?.wizardDetail {
                    Section("bolus.section_result") {
                        LabeledContent(String(localized: "bolus.total"), value: String(format: "%.2f U", detail.totalInsulin))
                        if detail.wasCapped, let unclamped = detail.unclampedInsulin {
                            // The master only sends `unclampedInsulin` when a constraint reduced the
                            // dose, so its presence IS the "your dose was capped" signal.
                            LabeledContent(String(localized: "bolus.capped_from"), value: String(format: "%.2f U", unclamped))
                                .foregroundColor(.orange)
                        }
                        LabeledContent(String(localized: "bolus.from_carbs"), value: String(format: "%.2f U", detail.insulinFromCarbs))
                        LabeledContent(String(localized: "bolus.from_bg"), value: String(format: "%.2f U", detail.insulinFromBG))
                        LabeledContent(String(localized: "bolus.from_cob"), value: String(format: "%.2f U", detail.insulinFromCOB))
                        LabeledContent(String(localized: "bolus.from_iob"),
                                       value: String(format: "%.2f U", detail.insulinFromBolusIOB + detail.insulinFromBasalIOB))
                        LabeledContent("IC", value: String(format: "%.1f", detail.ic))
                        LabeledContent("ISF", value: String(format: "%.1f", detail.sens))
                        if detail.wasCapped {
                            Text("bolus.capped_note")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let preview {
                    Section("bolus.section_master_text") {
                        ForEach(preview.lines, id: \.text) { Text($0.text) }
                    }
                }
            }

            if let statusText {
                Section { Text(statusText).foregroundColor(.secondary) }
            }
        }
        .navigationTitle("bolus.title")
        .onAppear {
            if bgText.isEmpty, let last = store.readings.first {
                bgText = String(last.mgdl)
            }
        }
    }

    private func calculate() {
        guard let carbs = Int(carbsText) else { return }
        // The field is mg/dL (numberPad, prefilled from the last reading), but `WizardPrepare.bg`
        // travels in the MASTER's display units — `BolusWizard.doCalc` compares it against
        // `fromMgdlToUnits(target)`. Convert on send, using the master's uploaded profile units.
        let bgMgdl = Double(bgText) ?? Double(store.readings.first?.mgdl ?? 0)
        let bg = ClientControlMessage.WizardPrepare.bgValue(
            mgdl: bgMgdl,
            masterUnits: store.profile?.units ?? .mgdl
        )
        guard store.masterControlAvailability.canSend else {
            statusText = blockedReason
            return
        }
        isBusy = true
        statusText = String(localized: "bolus.calculating")
        preview = nil
        Task {
            let inputs = ClientControlMessage.WizardPrepare(
                bg: bg, carbs: carbs, percentage: percentage, directCorrection: 0, carbTime: 0,
                useBg: useBg, useCob: useCob, useIob: useIob, useTt: useTt, useTrend: useTrend,
                alarm: false, notes: "", eCarbsGrams: 0, eCarbsDelayMinutes: 0, eCarbsDurationHours: 0,
                profileName: nil
            )
            // Read-only by design: there is no commit for this in the app, ever.
            let outcome = await store.clientControlRoundTrip.wizardPrepare(inputs)
            await MainActor.run {
                store.recordRoundTripOutcome(outcome)
                isBusy = false
                switch outcome {
                case .applied:
                    guard let decoded = outcome.preview else {
                        statusText = String(localized: "bolus.unreadable")
                        return
                    }
                    preview = decoded
                    statusText = nil
                case .rejected, .unconfirmed:
                    preview = nil
                    statusText = ClientControlText.failureText(for: outcome)
                }
            }
        }
    }
}
