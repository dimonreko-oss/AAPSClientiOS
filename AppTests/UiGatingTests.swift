import XCTest
@testable import AAPSClientiOS

/// Pure UI-layer logic: the capability gate, the client-control sentence table, the scene filter and
/// the history row copy. All four decide what the user is told or allowed to do, and all four were
/// silently wrong before (an always-on carbs tile, a "Scene activated." that never read the ack, a
/// list offering scenes the master rejects, and English-only mode labels).
final class UiGatingTests: XCTestCase {

    // MARK: - v4-capability-gating

    func test_absentCapabilityFlagFailsOpen() {
        // A stock v4 master publishes none of the `ns_receive_*` keys (they carry no SyncSpec), so
        // failing closed here locked the follower out of every gated action.
        let capabilities = NsRemoteCapabilities(syncedPrefs: [:])
        for key in NsRemoteCapabilityKey.allCases {
            let state = remoteActionState(for: key, capabilities: capabilities)
            XCTAssertTrue(state.isEnabled, "\(key.rawValue) should fail open")
            XCTAssertNil(state.reason)
        }
    }

    func test_publishedFalseDisablesCarbsAndTempTarget() {
        // These two used to bypass the gate entirely, so "Carbs sent" was reported for a record the
        // master discards.
        let capabilities = NsRemoteCapabilities(syncedPrefs: [
            "ns_receive_carbs": "false",
            "ns_receive_temp_target": "false",
        ])
        let carbs = remoteActionState(for: .carbs, capabilities: capabilities)
        let target = remoteActionState(for: .tempTarget, capabilities: capabilities)
        XCTAssertFalse(carbs.isEnabled)
        XCTAssertNotNil(carbs.reason)
        XCTAssertFalse(target.isEnabled)
        XCTAssertNotNil(target.reason)
        // Unpublished keys in the same document still fail open.
        XCTAssertTrue(remoteActionState(for: .runningMode, capabilities: capabilities).isEnabled)
    }

    func test_noColdDocumentLeavesEverythingEnabled() {
        XCTAssertTrue(remoteActionState(for: .carbs, capabilities: nil).isEnabled)
    }

    // MARK: - v4-sensor-start

    func test_logEventPickerOmitsSensorStart() {
        // The master's TreatmentMapper has no SENSOR_STARTED branch: the row lands in Nightscout,
        // resets the follower's SAGE and never becomes a therapy event on the master.
        XCTAssertFalse(TherapyEventCatalog.offered.contains("Sensor Start"))
        XCTAssertTrue(TherapyEventCatalog.offered.contains("Sensor Change"))
    }

    // MARK: - v4-scene-definitions-shape

    func test_disabledScenesAreNotOffered() {
        let scenes = [
            NsSceneDefinition(sceneId: "a", name: "School", isEnabled: true, defaultDurationMinutes: 120, sortOrder: 0),
            NsSceneDefinition(sceneId: "b", name: "Off", isEnabled: false, defaultDurationMinutes: nil, sortOrder: 1),
        ]
        XCTAssertEqual(RemoteSceneCatalog.selectable(from: scenes).map(\.sceneId), ["a"])
    }

    // MARK: - Client-control copy

    func test_appliedHasNoFailureText() {
        XCTAssertNil(ClientControlText.failureText(for: .applied(payload: nil)))
    }

    func test_unconfirmedNeverClaimsTheCommandApplied() throws {
        let text = try XCTUnwrap(ClientControlText.failureText(for: .unconfirmed))
        assertNotARawKey(text)
        XCTAssertFalse(text.lowercased().contains("activated"))
    }

    /// `XCTAssertNotEqual(text, "ControlDisabled")` used to be the whole test — and it passes with
    /// the entry deleted from BOTH `.strings` files, because `String(localized:)` returns the KEY
    /// when the lookup misses. So does comparing against `NSLocalizedString` of the same key. Pin
    /// the sentence, and reject anything that still looks like a dotted key.
    func test_knownReasonCodeIsTranslated() {
        // ControlDisabled is a policy answer, not a network failure, and must not read as one.
        assertLocalized(
            ClientControlText.rejectionText("ControlDisabled"),
            equals: "Remote control is switched off on the master."
        )
    }

    /// Every code the table claims to cover must resolve to a real sentence, not to its own key.
    /// This is the mechanical guard that catches a `.strings` line lost in a merge.
    func test_everyMappedFailureCodeResolvesToRealCopy() {
        let codes = [
            RoundTripReason.notPaired, RoundTripReason.busy, RoundTripReason.sendFailed,
            RoundTripReason.badSignature, RoundTripReason.staleAck, RoundTripReason.expired,
            RoundTripReason.slotTombstoned,
            "NotReachable", "NoReply", "NeedsRepair", "Revoked", "NoActiveProfile",
            "SceneNotFound", "SceneDisabled", "PartialFailure", "ExecutionFailed",
            "ControlDisabled", "NoAction", "NoPendingBolus", "BolusComputeFailed",
            "Internal", "Unknown",
        ]
        for code in codes {
            let text = ClientControlText.rejectionText(code)
            assertNotARawKey(text)
            XCTAssertNotEqual(text, code, "\(code) is not mapped to a sentence")
        }
    }

    /// The one code the master minted for a slot NS will never accept again. It has to name
    /// re-pairing, because "try again" is advice that fails forever.
    func test_tombstonedSlotTellsTheUserToPairAgain() {
        let text = ClientControlText.rejectionText(RoundTripReason.slotTombstoned)
        assertNotARawKey(text)
        XCTAssertTrue(text.contains("Pair again"), text)
    }

    func test_unknownReasonCodeIsShownVerbatim() {
        // A newer master's FailureReason must still reach the user rather than becoming "failed".
        let raw = "SomeFutureReason — with detail"
        XCTAssertEqual(ClientControlText.rejectionText(raw), raw)
    }

    func test_detailIsPreservedForKnownCodes() {
        let text = ClientControlText.rejectionText("SendFailed — offline")
        assertNotARawKey(text)
        XCTAssertTrue(text.hasPrefix("Could not reach Nightscout"), text)
        XCTAssertTrue(text.hasSuffix("offline"), text)
    }

    func test_availabilityDistinguishesControlDisabledFromUnreachable() {
        XCTAssertNil(ClientControlText.availability(.available))
        // Two DIFFERENT missing keys are also != each other, so the old inequality check passed on
        // a `.strings` file with both entries deleted. Assert the sentences.
        assertLocalized(
            ClientControlText.availability(.controlDisabled),
            equals: "Remote control is switched off on the master."
        )
        assertLocalized(
            ClientControlText.availability(.unreachable),
            equals: "The master has not reported in recently — commands would time out."
        )
    }

    /// Exhaustive: a case added to `MasterControlAvailability` must get copy, and every existing one
    /// must still resolve. `.available` is the only one that may be silent.
    func test_everyBlockingAvailabilityHasRealCopy() {
        let blocking: [MasterControlAvailability] = [
            .notPaired, .needsRepair, .revoked, .notAdvertised, .controlDisabled, .unreachable,
        ]
        for state in blocking {
            guard let text = ClientControlText.availability(state) else {
                return XCTFail("\(state) blocks sending but says nothing")
            }
            assertNotARawKey(text)
        }
    }

    func test_bannerOnlyForActionableStates() {
        XCTAssertNil(ClientControlText.banner(.pairedActive))
        XCTAssertNil(ClientControlText.banner(.nsOnly))
        XCTAssertNil(ClientControlText.banner(.unconfigured))

        for state in [ClientControlAuthorizationState.pairedPending, .pairedPendingExpired,
                      .needsRepair, .revoked, .counterDesynced] {
            guard let text = ClientControlText.banner(state) else {
                return XCTFail("\(state) is actionable but has no banner")
            }
            assertNotARawKey(text)
        }
    }

    /// The banner for a pairing whose window closed must name re-pairing, since it is the only fix —
    /// and it must be UNREACHABLE for a healthy pairing, which is why `sendHello` chains `sendPing`.
    func test_expiredPairingBannerNamesTheOnlyFix() throws {
        let text = try XCTUnwrap(ClientControlText.banner(.pairedPendingExpired))
        assertNotARawKey(text)
        XCTAssertTrue(text.contains("Pair again"), text)
    }

    // MARK: - Running-mode copy

    func test_everyRunningModeHasARealDisplayName() {
        for mode in RunningMode.allCases {
            assertNotARawKey(mode.displayName)
            XCTAssertFalse(mode.displayName.isEmpty)
        }
    }

    // MARK: - v4-running-mode history rows

    func test_runningModeRowUsesTheModeFieldNotTheNotesFallback() {
        let treatment = makeTreatment(
            eventType: RunningModeParser.eventType,
            notes: "SUSPENDED_BY_USER",
            mode: "SUSPENDED_BY_USER"
        )
        let subtitle = HistoryRowText.subtitle(for: treatment)
        XCTAssertEqual(subtitle, RunningMode.suspendedByUser.displayName)
    }

    func test_autoForcedRunningModeShowsTheMastersReason() {
        let treatment = makeTreatment(
            eventType: RunningModeParser.eventType,
            notes: nil,
            mode: "DISCONNECTED_PUMP",
            autoForced: true,
            reasons: "pump unreachable"
        )
        XCTAssertEqual(HistoryRowText.subtitle(for: treatment)?.contains("pump unreachable"), true)
    }

    func test_preV4RunningModeRowFallsBackToNotes() {
        // A 3.x master writes no `mode`; the English notes label is all there is.
        let treatment = makeTreatment(eventType: RunningModeParser.eventType, notes: "Loop disabled", mode: nil)
        XCTAssertEqual(HistoryRowText.subtitle(for: treatment), "Loop disabled")
    }

    func test_ordinaryRowStillPrefersProfileName() {
        let treatment = makeTreatment(eventType: "Profile Switch", notes: "note", mode: nil, profileName: "Weekend")
        XCTAssertEqual(HistoryRowText.subtitle(for: treatment), "Weekend")
    }

    private func makeTreatment(
        eventType: String,
        notes: String?,
        mode: String?,
        autoForced: Bool? = nil,
        reasons: String? = nil,
        profileName: String? = nil
    ) -> Treatment {
        Treatment(
            id: UUID().uuidString,
            eventType: eventType,
            date: Date(),
            insulin: nil,
            carbs: nil,
            durationMin: nil,
            enteredBy: nil,
            notes: notes,
            targetBottom: nil,
            targetTop: nil,
            profileName: profileName,
            percentage: nil,
            absolute: nil,
            tempBasalPercent: nil,
            mode: mode,
            autoForced: autoForced,
            reasons: reasons
        )
    }
}
