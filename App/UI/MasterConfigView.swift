import SwiftUI

struct MasterConfigView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Form {
            if let cold = store.remoteConfigCold {
                Section {
                    if let pump = cold.pump {
                        valueRow("remote.master_pump", value: pump)
                    }
                    if let version = cold.version {
                        valueRow("remote.master_version", value: version)
                    }
                    if store.isForkMaster {
                        // Display only. The client-control surface is byte-identical on both AAPS
                        // branches, so nothing may be gated on this.
                        valueRow("remote.fork_master", value: String(localized: "remote.enabled"))
                    }
                    if let autosens = store.remoteConfigHot?.usedAutosensOnMainPhone {
                        booleanRow("remote.autosens", value: autosens)
                    }
                }

                let plugins = cold.syncedPrefsSnapshot
                Section {
                    if let aps = plugins.activePluginAps {
                        valueRow("remote.active_aps", value: aps)
                    }
                    if let sensitivity = plugins.activePluginSensitivity {
                        valueRow("remote.active_sensitivity", value: sensitivity)
                    }
                    if let smoothing = plugins.activePluginSmoothing {
                        valueRow("remote.active_smoothing", value: smoothing)
                    }
                    // Exposed all along but never rendered; it only started populating once the
                    // synced-prefs key names were corrected to the real AAPS preference strings.
                    if let calibration = plugins.activePluginCalibration {
                        valueRow("remote.active_calibration", value: calibration)
                    }
                }

                if let scene = store.remoteConfigHot?.activeScene {
                    Section {
                        if let name = store.activeRemoteSceneDisplayName {
                            valueRow("remote.active_scene", value: name)
                        }
                        if let sceneId = scene.sceneId {
                            valueRow("remote.active_scene_id", value: sceneId)
                        }
                        if let lifecycle = scene.lifecycle {
                            valueRow("remote.scene_lifecycle", value: lifecycle)
                        }
                    }
                }

                if let capabilities = store.remoteCapabilities {
                    Section {
                        // Published values, not the fail-open booleans the action gates use: on this
                        // screen "the master never said" is the answer, and today it is the usual
                        // one — none of the `NsClientAccept*` keys carries a `SyncSpec`, so a stock
                        // master publishes none of them.
                        capabilityRow("remote.capability.profile", value: capabilities.publishedFlag(for: .profileSwitch))
                        capabilityRow("remote.capability.loop", value: capabilities.publishedFlag(for: .runningMode))
                        capabilityRow("remote.capability.target", value: capabilities.publishedFlag(for: .tempTarget))
                        capabilityRow("remote.capability.carbs", value: capabilities.publishedFlag(for: .carbs))
                        capabilityRow("remote.capability.events", value: capabilities.publishedFlag(for: .therapyEvents))
                        capabilityRow("remote.capability.client_control", value: capabilities.publishedClientControlEnabled)
                        booleanRow("remote.capability.websocket", value: capabilities.usesWebSockets)
                    } footer: {
                        Text(String(localized: "remote.capability_footer"))
                    }
                }

                if !cold.authorizedClientIds.isEmpty {
                    Section {
                        ForEach(cold.authorizedClientIds, id: \.self) { clientId in
                            Text(clientId)
                        }
                    } header: {
                        Text(String(localized: "remote.authorized_clients"))
                    }
                }

                if !store.remoteQuickWizardEntries.isEmpty {
                    Section {
                        ForEach(store.remoteQuickWizardEntries) { entry in
                            VStack(alignment: .leading) {
                                Text(entry.name)
                                Text(entry.note ?? String(localized: "remote.quickwizard_no_details"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        Text(String(localized: "remote.quickwizard"))
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    Text(String(localized: "remote.master_footer"))
                }
            } else {
                Text(String(localized: "remote.config_unavailable"))
                if let error = store.remoteConfigError {
                    Text(error)
                }
            }
        }
        .navigationTitle(String(localized: "remote.master_title"))
    }

    private func valueRow(_ label: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func booleanRow(_ label: LocalizedStringKey, value: Bool) -> some View {
        valueRow(label, value: String(localized: value ? "remote.enabled" : "remote.disabled"))
    }

    /// Tri-state: an absent flag is "not advertised", which is a different fact from "off" and the
    /// reason the follower fails open on it.
    private func capabilityRow(_ label: LocalizedStringKey, value: Bool?) -> some View {
        let text: String
        if let value {
            text = String(localized: value ? "remote.enabled" : "remote.disabled")
        } else {
            text = String(localized: "remote.not_advertised")
        }
        return valueRow(label, value: text)
    }
}
