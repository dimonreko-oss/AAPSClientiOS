import WidgetKit
import Foundation

struct GlucoseTimelineEntry: TimelineEntry {
    let date: Date
    let entry: GlucoseWidgetEntry
}

struct GlucoseTimelineProvider: TimelineProvider {
    private let store = SharedStore()

    func placeholder(in context: Context) -> GlucoseTimelineEntry {
        GlucoseTimelineEntry(date: Date(), entry: fallbackEntry())
    }

    func getSnapshot(in context: Context, completion: @escaping (GlucoseTimelineEntry) -> Void) {
        completion(GlucoseTimelineEntry(date: Date(), entry: fallbackEntry()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlucoseTimelineEntry>) -> Void) {
        Task {
            let now = Date()
            let config = store.loadConfig()
            let snapshot = store.loadSnapshot()
            // Snapshot first. The app calls `reloadAllTimelines()` on every new reading, so the App
            // Group snapshot is normally fresher than anything this blind timeline could fetch —
            // and it costs no radio, no re-authorize and cannot fail. Only reach for the network
            // once the snapshot has aged past the user's own stale threshold, which is exactly when
            // the app has stopped being able to refresh in the background.
            let snapshotAge: TimeInterval = snapshot.map { now.timeIntervalSince($0.date) } ?? .greatestFiniteMagnitude
            let entry: GlucoseWidgetEntry
            if snapshotAge > Double(config.thresholds.staleMinutes) * 60 {
                entry = await fetchEntry(config: config, needsLoop: context.family == .systemMedium, now: now)
            } else {
                entry = fallbackEntry(now: now)
            }
            // Line up with the CGM's own five-minute grid plus a little slack instead of a fixed
            // 15-minute one — but anchor a STALE snapshot on `now`, never on the snapshot.
            //
            // `max(snapshotDate + 5:30, now + 60)` collapsed onto the 60 s floor exactly when the
            // snapshot was old, i.e. the app-is-dead branch that just did three HTTP requests from
            // the extension. WidgetKit's daily reload budget is a few dozen refreshes; burning it in
            // an hour freezes the widget on a stale value for the rest of the day. The mechanism
            // meant to keep the widget alive when the app dies was what killed it.
            let cadence: TimeInterval = 5 * 60 + 30
            let next: Date
            if let snapshotDate = snapshot?.date, now.timeIntervalSince(snapshotDate) < cadence {
                next = snapshotDate.addingTimeInterval(cadence)
            } else {
                next = now.addingTimeInterval(cadence)
            }
            completion(Timeline(entries: [GlucoseTimelineEntry(date: now, entry: entry)],
                                policy: .after(next)))
        }
    }

    /// Snapshot from App Group, used as placeholder and as fetch fallback.
    private func fallbackEntry(now: Date = Date()) -> GlucoseWidgetEntry {
        let config = store.loadConfig()
        guard let snap = store.loadSnapshot() else {
            return GlucoseWidgetEntry.noData(units: config.units, now: now)
        }
        let minutesAgo = max(0, Int(now.timeIntervalSince(snap.date) / 60))
        return GlucoseWidgetEntry(
            mgdl: snap.mgdl, trend: snap.trend, delta: snap.delta, date: snap.date,
            minutesAgo: minutesAgo, isStale: minutesAgo >= config.thresholds.staleMinutes,
            iob: snap.iob, cob: snap.cob,
            tempBasalRate: snap.tempBasalRate,
            activeProfileName: snap.activeProfileName,
            activeProfilePercentage: snap.activeProfilePercentage,
            classification: Formatting.classify(mgdl: snap.mgdl, thresholds: config.thresholds),
            units: config.units, state: .data
        )
    }

    private func fetchEntry(config: DisplayConfig, needsLoop: Bool, now: Date) async -> GlucoseWidgetEntry {
        // Same shared-group store the app writes credentials to; going through the factory keeps
        // the accessibility class in one place.
        let keychain = SharedConstants.credentialKeychain()
        let urlStr = (try? keychain.get(.nsUrl)) ?? nil
        let token = (try? keychain.get(.nsAccessToken)) ?? nil
        guard let urlStr, let url = URL(string: urlStr),
              let token, !token.isEmpty
        else {
            return GlucoseWidgetEntry.noData(units: config.units, now: now)
        }
        let client = NightscoutClientLive(baseURL: url, accessToken: token, transport: URLSessionTransport())
        do {
            try await client.authorize()
            let readings = try await client.fetchEntries(limit: 2)
            let loop: LoopStatus? = needsLoop ? (try? await client.fetchDeviceStatus()) ?? nil : nil
            let entry = WidgetEntryBuilder.build(readings: readings, loop: loop, config: config, now: now)
            return entry.state == .noData ? fallbackEntry(now: now) : entry
        } catch {
            return fallbackEntry(now: now)
        }
    }
}
