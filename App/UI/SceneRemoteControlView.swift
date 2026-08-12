import SwiftUI

/// Which of the master's scenes may be offered for activation.
enum RemoteSceneCatalog {
    /// Disabled scenes are hidden on the master's own sheet and rejected on activation, so listing
    /// them here would be offering a button that can only fail. Order is the master's `sortOrder`,
    /// which the parser has already applied.
    static func selectable(from definitions: [NsSceneDefinition]) -> [NsSceneDefinition] {
        definitions.filter(\.isEnabled)
    }
}

struct SceneRemoteControlView: View {
    @ObservedObject var store: AppStore

    @State private var preparedPreview: BolusPreview?
    @State private var preparedSceneId: String?
    @State private var statusText: String?
    @State private var isBusy = false

    /// The app's single pairing store. Three views used to hold a `@State` instance each, which made
    /// the durable counter and the master's single ack slot impossible to reason about.
    private var pairingStore: ClientPairingStore { store.clientPairingStore }

    /// `currentPairing()` returns nil while `needsRepair`, so it cannot answer "has the user ever
    /// paired" — that question needs the display accessor, and the repair banner explains the rest.
    private var isPaired: Bool { pairingStore.currentPairingIgnoringRepair() != nil }

    /// nil while commands may actually be sent.
    private var blockedReason: String? { ClientControlText.availability(store.masterControlAvailability) }

    private var scenes: [NsSceneDefinition] { RemoteSceneCatalog.selectable(from: store.remoteSceneDefinitions) }

    var body: some View {
        Form {
            if !isPaired {
                Section {
                    Text("scene.pair_first")
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

                if let active = store.activeRemoteSceneDefinition {
                    Section("scene.section_active") {
                        LabeledContent(String(localized: "scene.scene"),
                                       value: store.activeRemoteSceneDisplayName ?? active.sceneId)
                        Button(String(localized: "scene.stop"), role: .destructive) { stopScene(triggerChain: false) }
                            .disabled(isBusy)
                    }
                }

                Section("scene.section_available") {
                    if scenes.isEmpty {
                        Text("scene.none_available")
                            .foregroundColor(.secondary)
                    }
                    ForEach(scenes) { scene in
                        Button { prepare(scene) } label: {
                            HStack {
                                Text(scene.name ?? scene.sceneId)
                                if let minutes = scene.defaultDurationMinutes {
                                    Spacer()
                                    // What the master will actually apply, so the confirm sheet and
                                    // the master agree on what the user is about to get.
                                    Text(String(format: String(localized: "scene.default_duration"), minutes))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .disabled(isBusy)
                    }
                }

                if let preview = preparedPreview, let sceneId = preparedSceneId {
                    Section("scene.section_confirm") {
                        ForEach(preview.lines, id: \.text) { line in
                            Text(line.text)
                        }
                        Button(String(localized: "scene.confirm")) { commit(preview.bolusId) }
                            .disabled(isBusy)
                        Button("cancel", role: .cancel) {
                            preparedPreview = nil
                            preparedSceneId = nil
                        }
                        .accessibilityIdentifier("cancel_scene_prepare_\(sceneId)")
                    }
                }
            }

            if let statusText {
                Section {
                    Text(statusText)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("scene.title")
    }

    // MARK: - Commands

    /// One shape for all three commands: gate, run the round trip, feed the liveness clock, render.
    ///
    /// Every caller MUST go through here. `store.recordRoundTripOutcome` is what drives both the
    /// master-liveness clock and the counter-desync detector, and both are dead without it.
    private func run(
        _ progress: String,
        command: @escaping (ClientControlRoundTrip) async -> RoundTripOutcome,
        onFinish: @escaping (RoundTripOutcome) -> Void
    ) {
        guard store.masterControlAvailability.canSend else {
            // Rejecting locally beats burning a counter into a void and showing a generic timeout.
            statusText = blockedReason
            return
        }
        isBusy = true
        statusText = progress
        Task {
            let outcome = await command(store.clientControlRoundTrip)
            await MainActor.run {
                store.recordRoundTripOutcome(outcome)
                isBusy = false
                onFinish(outcome)
            }
        }
    }

    private func prepare(_ scene: NsSceneDefinition) {
        run(String(localized: "scene.preparing")) { coordinator in
            // nil defers to the scene's own stored default, resolved fresh by the master at receipt
            // time. Our cached `defaultDurationMinutes` comes from the `scene_definitions` cold pref
            // and can be a poll behind, so sending it would silently override an edited default.
            await coordinator.scenePrepare(sceneId: scene.sceneId, durationMinutes: nil)
        } onFinish: { outcome in
            switch outcome {
            case .applied:
                guard let preview = outcome.preview else {
                    statusText = String(localized: "scene.prepared_unreadable")
                    return
                }
                preparedPreview = preview
                preparedSceneId = scene.sceneId
                statusText = nil
            case .rejected, .unconfirmed:
                // A prepare that we cannot confirm reserved nothing we may commit against.
                preparedPreview = nil
                preparedSceneId = nil
                statusText = ClientControlText.failureText(for: outcome)
            }
        }
    }

    private func commit(_ bolusId: Int64) {
        run(String(localized: "scene.activating")) { coordinator in
            await coordinator.sceneCommit(bolusId: bolusId)
        } onFinish: { outcome in
            switch outcome {
            case .applied:
                preparedPreview = nil
                preparedSceneId = nil
                statusText = String(localized: "scene.activated")
                // Only refresh on a definite answer; an unconfirmed commit must not be painted as
                // applied by a status card that happens to update a second later.
                Task { try? await store.refresh() }
            case .rejected:
                // The prepared dose may still be live on the master (e.g. ControlDisabled), so the
                // confirm section stays up for a retry. NoPendingBolus tells the user to re-prepare.
                statusText = ClientControlText.failureText(for: outcome)
            case .unconfirmed:
                // The master may still have activated it after we stopped listening — never say
                // "activated", and never leave a stale confirm button that would double-apply it.
                preparedPreview = nil
                preparedSceneId = nil
                statusText = ClientControlText.failureText(for: outcome)
            }
        }
    }

    private func stopScene(triggerChain: Bool) {
        run(String(localized: "scene.stopping")) { coordinator in
            await coordinator.sceneStop(triggerChain: triggerChain)
        } onFinish: { outcome in
            switch outcome {
            case .applied:
                statusText = String(localized: "scene.stopped")
                Task { try? await store.refresh() }
            case .rejected, .unconfirmed:
                statusText = ClientControlText.failureText(for: outcome)
            }
        }
    }
}
