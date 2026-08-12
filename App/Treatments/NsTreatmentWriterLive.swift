import Foundation

final class NsTreatmentWriterLive: NsTreatmentWriter, @unchecked Sendable {
    /// Identifier used for both `app` (required by NS API v3) and `enteredBy`.
    static let appName = "AAPSClient-iOS"

    private nonisolated(unsafe) let clientProvider: () -> NightscoutClient

    init(client: NightscoutClient) {
        self.clientProvider = { client }
    }

    init(clientProvider: @escaping () -> NightscoutClient) {
        self.clientProvider = clientProvider
    }

    private var client: NightscoutClient { clientProvider() }

    func sendCarbs(grams: Double, at date: Date) async throws {
        try await client.postTreatment(Self.buildCarbs(grams: grams, at: date))
    }

    func sendTempTarget(targetMgdl: Int, durationMin: Int, reason: TtReason) async throws {
        try await client.postTreatment(Self.buildTempTarget(targetMgdl: targetMgdl, durationMin: durationMin, reason: reason))
    }

    func cancelTempTarget() async throws {
        try await client.postTreatment(Self.buildTempTargetCancel())
    }

    func switchProfile(name: String, percentage: Int, durationMin: Int, timeshiftHours: Int, profileJson: String?) async throws {
        try await client.postTreatment(Self.buildProfileSwitch(name: name, percentage: percentage, durationMin: durationMin, timeshiftHours: timeshiftHours, profileJson: profileJson))
    }

    func logEvent(eventType: String, at date: Date, notes: String?, glucoseMgdl: Int?, durationMin: Int?) async throws {
        try await client.postTreatment(Self.buildEvent(eventType: eventType, at: date, notes: notes, glucoseMgdl: glucoseMgdl, durationMin: durationMin))
    }

    func setLoopMode(_ mode: String, durationMin: Int) async throws {
        try await client.postTreatment(Self.buildLoopMode(mode, durationMin: durationMin))
    }

    func sendAnnouncement(notes: String) async throws {
        try await client.postTreatment(Self.buildAnnouncement(notes: notes))
    }

    static func buildCarbs(grams: Double, at date: Date) -> [String: Any] {
        [
            "app": appName,
            "eventType": "Carb Correction",
            "carbs": grams,
            "date": Int64(date.timeIntervalSince1970 * 1000),
            "enteredBy": appName,
        ]
    }

    static func buildTempTarget(targetMgdl: Int, durationMin: Int, reason: TtReason) -> [String: Any] {
        [
            "app": appName,
            "eventType": "Temporary Target",
            "duration": durationMin,
            "targetBottom": targetMgdl,
            "targetTop": targetMgdl,
            "units": "mg/dl",
            "reason": reason.rawValue,
            "date": Int64(Date().timeIntervalSince1970 * 1000),
            "enteredBy": appName,
        ]
    }

    static func buildTempTargetCancel() -> [String: Any] {
        [
            "app": appName,
            "eventType": "Temporary Target",
            "duration": 0,
            "date": Int64(Date().timeIntervalSince1970 * 1000),
            "enteredBy": appName,
        ]
    }

    static func buildProfileSwitch(name: String, percentage: Int, durationMin: Int, timeshiftHours: Int, profileJson: String?) -> [String: Any] {
        var payload: [String: Any] = [
            "app": appName,
            "eventType": "Profile Switch",
            "profile": name,
            "percentage": percentage,
            "duration": durationMin,
            // MILLISECONDS on this channel. `RemoteTreatment.timeshift` flows straight into
            // `NSProfileSwitch.timeShift` and then into `PS.timeshift`, which is documented and used as
            // milliseconds throughout the master (`PS.kt: var timeshift: Long // [milliseconds]`).
            // Sending hours here made a 2 h shift arrive as 2 ms and round to zero, silently.
            //
            // Do NOT hoist this into a shared helper: the client-control channel takes the opposite
            // unit (`BatchActionDto.timeShiftHours` is hours), so the conversion belongs only here.
            "timeshift": Int64(timeshiftHours) * 3_600_000,
            "date": Int64(Date().timeIntervalSince1970 * 1000),
            "enteredBy": appName,
        ]
        if let json = profileJson {
            payload["profileJson"] = json
        }
        return payload
    }

    static func buildEvent(eventType: String, at date: Date, notes: String?, glucoseMgdl: Int?, durationMin: Int?) -> [String: Any] {
        var payload: [String: Any] = [
            "app": appName,
            "eventType": eventType,
            "date": Int64(date.timeIntervalSince1970 * 1000),
            "enteredBy": appName,
        ]
        if let notes { payload["notes"] = notes }
        if let glucose = glucoseMgdl { payload["glucose"] = glucose; payload["units"] = "mg/dl" }
        if let dur = durationMin { payload["duration"] = dur }
        return payload
    }

    static func buildLoopMode(_ mode: String, durationMin: Int) -> [String: Any] {
        [
            "app": appName,
            "eventType": "OpenAPS Offline",
            "mode": mode,
            "duration": durationMin,
            "date": Int64(Date().timeIntervalSince1970 * 1000),
            "enteredBy": appName,
        ]
    }

    static func buildAnnouncement(notes: String) -> [String: Any] {
        [
            "app": appName,
            "eventType": "Announcement",
            "notes": notes,
            "date": Int64(Date().timeIntervalSince1970 * 1000),
            // iAPS's own Shortcuts (OpenClosedShortcuts.swift, SuspendResumeShortcut.swift) hard-code
            // enteredBy: "remote" for every Announcement they send — match that exactly. This is the
            // one payload in this app that intentionally does NOT use `appName` for enteredBy.
            "enteredBy": "remote",
        ]
    }
}
