import SwiftUI

struct StatusCardView: View {
    @ObservedObject var store: AppStore
    let units: GlucoseUnits
    let remoteCapabilities: NsRemoteCapabilities?
    @Binding var statusMessage: String?
    @Binding var statusIsError: Bool
    @Binding var showLoopMenu: Bool
    @Binding var showEventSheet: Bool
    @Binding var showProfileSwitch: Bool
    @State private var showStatusDetails = false

    var body: some View {
        VStack(spacing: 10) {
            mainGlucoseRow
            statusRow
            remoteStatusCard
            changeAgesRow
            if let tt = activeTempTarget {
                tempTargetRow(tt)
            }
            reasonChips
            profileChip
        }
        .padding(14)
        .background(Color(.systemGray6))
        .cornerRadius(14)
    }

    // MARK: - Status card items

    private struct StatusLevel {
        let color: Color
        let icon: String
        init(_ level: StatusLevelEnum) {
            switch level {
            case .ok:    self.color = .green;  self.icon = "checkmark.circle.fill"
            case .warn:  self.color = .orange; self.icon = "exclamationmark.triangle.fill"
            case .error: self.color = .red;    self.icon = "xmark.octagon.fill"
            }
        }
    }

    private enum StatusLevelEnum {
        case ok, warn, error
    }

    private struct StatusCardItem: Identifiable {
        let title: String
        let value: String
        let level: StatusLevelEnum
        let details: [String]
        var id: String { title }
    }

    private var loopState: LoopState { loopHealth.freshness }

    /// Freshness AND the master's RunningMode, resolved together. Either one alone lies: a master
    /// that is `SUSPENDED_BY_USER` keeps uploading a devicestatus every five minutes, and a master
    /// that is closed-looping but offline stops uploading anything.
    private var loopHealth: LoopHealth {
        LoopHealth.resolve(
            statusTimestamp: store.loopStatus?.timestamp,
            runningModeRecords: store.runningModeRecords,
            now: Date()
        )
    }

    private var loopStateColor: Color {
        // Fresh-but-not-running is its own state: green here would assert therapy is happening.
        if !loopHealth.isHealthy && loopHealth.freshness == .looping { return .orange }
        switch loopHealth.freshness {
        case .looping: return .green
        case .warning: return .yellow
        case .stale:   return .red
        case .unknown: return .gray
        }
    }

    private var overallStatusLevel: StatusLevelEnum {
        if statusCardItems.contains(where: { $0.level == .error }) { return .error }
        if statusCardItems.contains(where: { $0.level == .warn })  { return .warn }
        return .ok
    }

    private var overallStatusSummary: String {
        switch overallStatusLevel {
        case .ok:    return String(localized: "status.summary_ok")
        case .warn:  return String(localized: "status.summary_warn")
        case .error: return String(localized: "status.summary_error")
        }
    }

    private var statusCardItems: [StatusCardItem] {
        let now = Date()
        let readingAgeMin = store.readings.first.map { max(0, Int(now.timeIntervalSince($0.date) / 60)) }
        // `timestamp` is optional since a pump-only devicestatus (v4 uploads one every 5 min while
        // the loop is stopped) carries no APS result and therefore no loop time at all.
        let loopTimestamp: Date? = store.loopStatus?.timestamp
        let loopAgeMin = loopTimestamp.map { max(0, Int(now.timeIntervalSince($0) / 60)) }

        let masterLevel: StatusLevelEnum = {
            if store.connectionLost { return .error }
            guard let loopAgeMin else { return .warn }
            if loopAgeMin >= 10 { return .error }
            if loopAgeMin >= 4  { return .warn }
            return .ok
        }()

        let masterValue: String = {
            if store.connectionLost { return String(localized: "status.offline") }
            return ageText(minutes: loopAgeMin)
        }()

        let masterDetails: [String] = {
            var lines: [String] = []
            if let ts = store.loopStatus?.timestamp {
                lines.append(String(format: String(localized: "status.last_loop"), ts.formatted(date: .abbreviated, time: .shortened)))
            } else {
                lines.append(String(localized: "status.loop_missing"))
            }
            lines.append(String(format: String(localized: "status.loop_mode"), loopModeText()))
            if let mode = loopHealth.mode {
                // Alongside freshness, never instead of it — "fresh" and "running" are different
                // questions and the user needs both answered.
                var text = mode.displayName
                if loopHealth.autoForced {
                    text += " (" + String(localized: "runningmode.auto_forced") + ")"
                }
                lines.append(String(format: String(localized: "status.running_mode"), text))
            }
            if let eventual = store.loopStatus?.eventualBgMgdl {
                lines.append(String(format: String(localized: "status.eventual_bg"), Formatting.format(Double(eventual), units: units)))
            }
            if let rate = store.loopStatus?.tempBasalRate {
                lines.append(String(format: String(localized: "status.temp_basal"), String(format: "%.2f", rate)))
            }
            if let reason = store.loopStatus?.suggestedReason, !reason.isEmpty {
                lines.append(reason)
            }
            return lines
        }()

        let pumpLevel: StatusLevelEnum = {
            guard let status = store.loopStatus else { return .warn }
            let t = store.consumableThresholds
            if let reservoir = status.pumpReservoir, Int(reservoir) <= t.reservoirCriticalUnits { return .error }
            if let battery = status.pumpBattery, battery <= t.pumpBattCriticalPercent            { return .error }
            if let reservoir = status.pumpReservoir, Int(reservoir) <= t.reservoirWarnUnits       { return .warn }
            if let battery = status.pumpBattery, battery <= t.pumpBattWarnPercent                 { return .warn }
            return .ok
        }()

        let pumpValue: String = {
            guard let status = store.loopStatus else { return String(localized: "status.waiting") }
            if let reservoir = status.pumpReservoir {
                return "\(String(format: "%.0f", reservoir))U"
            }
            if let battery = status.pumpBattery {
                return "\(battery)%"
            }
            return String(localized: "status.connected")
        }()

        let pumpDetails: [String] = {
            guard let status = store.loopStatus else { return [String(localized: "status.pump_missing")] }
            var lines: [String] = []
            if let reservoir = status.pumpReservoir {
                lines.append(String(format: String(localized: "status.reservoir"), String(format: "%.0f", reservoir)))
            }
            if let battery = status.pumpBattery {
                lines.append(String(format: String(localized: "status.battery"), "\(battery)"))
            }
            if lines.isEmpty {
                lines.append(String(localized: "status.pump_fields_missing"))
            }
            return lines
        }()

        let uploaderLevel: StatusLevelEnum = {
            guard let readingAgeMin else { return .warn }
            if readingAgeMin >= store.thresholds.staleMinutes { return .error }
            if readingAgeMin >= max(5, store.thresholds.staleMinutes / 2) { return .warn }
            if let battery = store.loopStatus?.uploaderBattery, battery <= 15 { return .error }
            if let battery = store.loopStatus?.uploaderBattery, battery <= 30 { return .warn }
            return .ok
        }()

        let uploaderValue: String = {
            if let battery = store.loopStatus?.uploaderBattery {
                return "\(battery)%"
            }
            return ageText(minutes: readingAgeMin)
        }()

        let uploaderDetails: [String] = {
            var lines: [String] = []
            if let reading = store.readings.first {
                lines.append(String(format: String(localized: "status.latest_glucose"), reading.date.formatted(date: .omitted, time: .shortened)))
            } else {
                lines.append(String(localized: "status.glucose_missing"))
            }
            if let battery = store.loopStatus?.uploaderBattery {
                lines.append(String(format: String(localized: "status.uploader_battery"), "\(battery)"))
            }
            return lines
        }()

        return [
            StatusCardItem(title: String(localized: "status.master"),    value: masterValue,    level: masterLevel,    details: masterDetails),
            StatusCardItem(title: String(localized: "status.pump"),      value: pumpValue,      level: pumpLevel,      details: pumpDetails),
            StatusCardItem(title: String(localized: "status.uploader"),  value: uploaderValue,  level: uploaderLevel,  details: uploaderDetails),
        ]
    }

    // MARK: - Sub-views

    private var mainGlucoseRow: some View {
        HStack(alignment: .top) {
            ZStack {
                Circle()
                    .stroke(loopStateColor.opacity(0.3), lineWidth: 6)
                    .frame(width: 100, height: 100)
                if let latest = store.readings.first {
                    let classif = Formatting.classify(mgdl: latest.mgdl, thresholds: store.thresholds)
                    let delta = store.readings.dropFirst().first.map { latest.mgdl - $0.mgdl }
                    VStack(spacing: 0) {
                        Text(Formatting.format(latest.mgdl, units: units))
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(Formatting.color(for: classif))
                        HStack(spacing: 2) {
                            Text(Formatting.trendSymbol(latest.trend))
                                .font(.system(size: 16))
                            if let d = delta, d != 0 {
                                Text(deltaString(d))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(d > 0 ? .orange : .cyan)
                            }
                        }
                        let secs = Int(Date().timeIntervalSince(latest.date))
                        Text("\(secs / 60)m").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                } else {
                    Text("home.no_data").font(.system(size: 20, weight: .bold)).foregroundColor(.gray)
                }
            }
            .contentShape(Circle())
            .onTapGesture {
                let actionState = remoteActionState(for: .runningMode, capabilities: remoteCapabilities)
                guard actionState.isEnabled else {
                    presentDisabledReason(actionState.reason)
                    return
                }
                showLoopMenu = true
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let latest = store.readings.first {
                    Text(latest.date.formatted(date: .omitted, time: .shortened)).font(.headline)
                }
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            if let status = store.loopStatus {
                statusItem(icon: "syringe", label: "IOB", value: "\(String(format: "%.1f", status.iob))U")
                statusItem(icon: "takeoutbag.and.cup.and.straw", label: "COB", value: "\(String(format: "%.0f", status.cob))g")
            }
            Spacer()
        }
    }

    private func statusItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.caption2).foregroundColor(.secondary)
            Text("\(label) \(value)").font(.caption2)
        }
    }

    private var remoteStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: StatusLevel(overallStatusLevel).icon)
                    .font(.caption)
                    .foregroundColor(StatusLevel(overallStatusLevel).color)
                Text(overallStatusSummary)
                    .font(.caption.weight(.semibold))
                Spacer()
            }

            HStack(spacing: 8) {
                ForEach(statusCardItems) { item in
                    statusSummaryChip(item)
                }
            }

            DisclosureGroup(isExpanded: $showStatusDetails) {
                VStack(spacing: 8) {
                    ForEach(statusCardItems) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: StatusLevel(item.level).icon)
                                    .font(.caption)
                                    .foregroundColor(StatusLevel(item.level).color)
                                Text(item.title)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(item.value)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            ForEach(item.details, id: \.self) { detail in
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemBackground).opacity(0.55))
                        .cornerRadius(8)
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Text(String(localized: "status.remote_status"))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(showStatusDetails ? String(localized: "status.hide_details") : String(localized: "status.show_details"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .tint(.primary)
        }
    }

    private func statusSummaryChip(_ item: StatusCardItem) -> some View {
        let lvl = StatusLevel(item.level)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: lvl.icon)
                    .font(.system(size: 10))
                    .foregroundColor(lvl.color)
                Text(item.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            Text(item.value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(lvl.color.opacity(0.12))
        .cornerRadius(8)
    }

    private var activeTempTarget: Treatment? {
        // `isValid == false` is the NS v3 tombstone; the master's own query has `AND (isValid = 1)`,
        // so a deleted temp target must not keep showing as running here.
        Treatment.activeTempTarget(in: store.treatments.filter(\.isValid))
    }

    private func tempTargetRow(_ t: Treatment) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "target").font(.caption2).foregroundColor(.secondary)
            let lo = t.targetBottom ?? 0
            let hi = t.targetTop ?? lo
            Text("Target \(Formatting.targetRangeText(lo: lo, hi: hi, units: units))").font(.caption2)
            Spacer()
            if let dur = t.durationMin {
                let remaining = max(0, Int(t.date.addingTimeInterval(Double(dur) * 60).timeIntervalSinceNow) / 60)
                Text("\(remaining)m left").font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var changeAgesRow: some View {
        let eventState = remoteActionState(for: .therapyEvents, capabilities: remoteCapabilities)
        return HStack(spacing: 8) {
            ForEach(changeAges, id: \.label) { item in
                HStack(spacing: 2) {
                    Image(systemName: item.icon).font(.caption2).foregroundColor(consumableColor(item.level))
                    Text(item.age).font(.caption2).foregroundColor(consumableColor(item.level))
                }
            }
            Spacer()
            Button {
                guard eventState.isEnabled else {
                    presentDisabledReason(eventState.reason)
                    return
                }
                showEventSheet = true
            } label: {
                Image(systemName: "plus.circle").font(.caption)
            }
            .opacity(eventState.isEnabled ? 1 : 0.45)
        }
    }

    private var changeAges: [(icon: String, label: String, age: String, level: ConsumableLevel)] {
        let now = Date()
        // Deleted care events must not keep a cannula or sensor age alive.
        let events = store.careEvents.filter(\.isValid)
        let t = store.consumableThresholds
        let site = TreatmentAgeCalc.lastEventAge(treatments: events, eventTypes: ["Site Change"], now: now)
        let insulin = TreatmentAgeCalc.lastEventAge(treatments: events, eventTypes: ["Insulin Change"], now: now)
        let sensor = TreatmentAgeCalc.lastEventAge(treatments: events, eventTypes: ["Sensor Change", "Sensor Start"], now: now)
        let battery = TreatmentAgeCalc.lastEventAge(treatments: events, eventTypes: ["Pump Battery Change"], now: now)
        return [
            ("ivfluid.bag", "Cannula",  TreatmentAgeCalc.formatAge(site),
             ConsumableAgeCalc.level(ageSeconds: site,   warnHours: t.cageWarnHours, criticalHours: t.cageCriticalHours)),
            ("syringe", "Insulin",       TreatmentAgeCalc.formatAge(insulin),
             ConsumableAgeCalc.level(ageSeconds: insulin, warnHours: t.iageWarnHours, criticalHours: t.iageCriticalHours)),
            ("waveform.path.ecg", "Sensor", TreatmentAgeCalc.formatAge(sensor),
             ConsumableAgeCalc.level(ageSeconds: sensor, warnHours: t.sageWarnHours, criticalHours: t.sageCriticalHours)),
            ("battery.100percent", "Battery", TreatmentAgeCalc.formatAge(battery),
             ConsumableAgeCalc.level(ageSeconds: battery, warnHours: t.bageWarnHours, criticalHours: t.bageCriticalHours)),
        ]
    }

    private func consumableColor(_ level: ConsumableLevel) -> Color {
        switch level {
        case .ok: return .secondary
        case .warn: return .orange
        case .critical: return .red
        }
    }

    private var reasonChips: some View {
        Group {
            if let r = store.loopStatus?.reason, !r.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let isf = r.isfMgdl { reasonChip("ISF", Formatting.format(isf, units: units)) }
                        if let cr = r.cr       { reasonChip("CR", String(format: "%.0f", cr)) }
                        if let tg = r.targetMgdl { reasonChip("Target", Formatting.format(Double(tg), units: units)) }
                        if let dev = r.deviation { reasonChip("Dev", Formatting.format(dev, units: units)) }
                        if let bgi = r.bgi      { reasonChip("BGI", Formatting.format(bgi, units: units)) }
                        if let minBg = r.minPredBg { reasonChip("minBG", Formatting.format(Double(minBg), units: units)) }
                    }
                }
            }
        }
    }

    private func reasonChip(_ label: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
            Text(value).font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color(.systemGray5))
        .cornerRadius(4)
    }

    private var profileChip: some View {
        Group {
            if let name = store.activeProfileName {
                let pct = store.activeProfileSwitch?.percentage ?? 100
                HStack {
                    Image(systemName: "person.crop.circle").font(.caption)
                    Text(name).font(.caption).lineLimit(1)
                    if pct != 100 {
                        Text("(\(pct)%)").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                }
                .padding(6)
                .background(Color(.systemGray5))
                .cornerRadius(6)
                .contentShape(Rectangle())
                .onTapGesture {
                    let actionState = remoteActionState(for: .profileSwitch, capabilities: remoteCapabilities)
                    guard actionState.isEnabled else {
                        // Silently doing nothing on tap is indistinguishable from a broken chip.
                        presentDisabledReason(actionState.reason)
                        return
                    }
                    showProfileSwitch = true
                }
            }
        }
    }

    // MARK: - Helpers

    /// Same contract as `HomeView.presentDisabledReason`: a gated action must say why, not no-op.
    private func presentDisabledReason(_ reason: String?) {
        statusMessage = reason ?? String(localized: "remote.config_unavailable")
        statusIsError = true
    }

    private func ageText(minutes: Int?) -> String {
        guard let minutes else { return String(localized: "status.waiting") }
        if minutes <= 0 { return String(localized: "status.now") }
        return String(format: String(localized: "status.minutes_ago"), minutes)
    }

    private func loopModeText() -> String {
        switch loopState {
        case .looping: return String(localized: "status.loop_ok")
        case .warning: return String(localized: "status.loop_warn")
        case .stale:   return String(localized: "status.loop_stale")
        case .unknown: return String(localized: "status.waiting")
        }
    }

    private func deltaString(_ d: Int) -> String {
        if units == .mmol {
            let v = Double(d) / glucoseMmolFactor
            return v >= 0 ? String(format: "+%.1f", v) : String(format: "%.1f", v)
        }
        return d >= 0 ? "+\(d)" : "\(d)"
    }
}
