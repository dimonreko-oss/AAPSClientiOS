import AVFoundation
import Foundation
import os

/// Keeps Nightscout polling alive in the background by playing silence, and
/// recovers whenever the system takes the audio session away.
///
/// **Distribution trade-off, recorded deliberately.** Declaring the `audio`
/// background mode with no user-facing audio feature is a documented App Store
/// rejection under guideline 2.5.4 — it is exactly why LoopFollow cannot ship
/// there. This app's channel is TestFlight/sideload, where that is acceptable, and
/// the mechanism is what every comparable AAPS/Loop follower relies on. It costs
/// battery, which the Settings screen must state plainly.
///
/// If App Store distribution ever becomes the goal, `audio` must come out of
/// `UIBackgroundModes` and this whole file goes with it; the remaining coverage is
/// BGAppRefresh + BGProcessing + the dead-man notification ladder, at materially
/// worse latency the user has to be told about.
final class AudioKeepAlive {
    static let foregroundInterval: TimeInterval = 60
    static let watchdogInterval: TimeInterval = 60

    private let player: KeepAlivePlayer
    private let notificationCenter: NotificationCenter
    private var tickTimer: Timer?
    private var watchdogTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var isBackgroundKeepAliveActive = false
    private let log = Logger(subsystem: "com.nightaps.aapsclientios", category: "KeepAlive")

    let isAudioKeepAliveEnabled: Bool

    init(
        player: KeepAlivePlayer = SilentLoopPlayer(),
        notificationCenter: NotificationCenter = .default,
        isRunningOnMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac
    ) {
        self.player = player
        self.notificationCenter = notificationCenter
        self.isAudioKeepAliveEnabled = !isRunningOnMac
        observeAudioNotifications()
    }

    deinit {
        observers.forEach { notificationCenter.removeObserver($0) }
        tickTimer?.invalidate()
        watchdogTimer?.invalidate()
    }

    func enterForeground(onTick: @escaping () -> Void) {
        teardown()
        scheduleRepeatingTick(interval: Self.foregroundInterval, onTick: onTick)
    }

    func enterBackground(
        mode: KeepAliveMode,
        nextDelay: @escaping () -> TimeInterval,
        onTick: @escaping () -> Void
    ) {
        guard isAudioKeepAliveEnabled, mode.shouldKeepAlive else {
            teardown()
            return
        }
        isBackgroundKeepAliveActive = true
        player.start()
        startWatchdog()
        scheduleNextTick(nextDelay: nextDelay, onTick: onTick)
    }

    /// Everything the keep-alive owns, released.
    ///
    /// The disabled branch used to invalidate only the tick timer and got away with
    /// it purely because `enterForeground` always happened to run first. Any path
    /// that reaches `enterBackground(.disabled)` without that — a mode change made
    /// while already backgrounded, or a BGProcessing resurrect handler — otherwise
    /// leaks a playing `AVAudioPlayer` and a live 60 s watchdog into a mode the user
    /// explicitly switched off, which is both a battery cost and a lie.
    private func teardown() {
        isBackgroundKeepAliveActive = false
        player.stop()
        tickTimer?.invalidate()
        tickTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    func ensurePlaying() {
        guard isAudioKeepAliveEnabled, isBackgroundKeepAliveActive else { return }
        guard !player.isActuallyPlaying else { return }
        log.info("keep-alive playback stopped unexpectedly; restarting")
        player.start()
    }

    private func observeAudioNotifications() {
        let interruption = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self, self.isBackgroundKeepAliveActive else { return }
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let raw, AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.log.info("audio interruption ended; restarting keep-alive")
            self.player.start()
        }

        let reset = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self, self.isBackgroundKeepAliveActive else { return }
            self.log.info("media services were reset; rebuilding keep-alive player")
            self.player.reset()
        }

        let route = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.ensurePlaying()
        }

        observers = [interruption, reset, route]
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.watchdogInterval,
            repeats: true
        ) { [weak self] _ in
            self?.ensurePlaying()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func scheduleRepeatingTick(interval: TimeInterval, onTick: @escaping () -> Void) {
        tickTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            onTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func scheduleNextTick(
        nextDelay: @escaping () -> TimeInterval,
        onTick: @escaping () -> Void
    ) {
        tickTimer?.invalidate()
        let delay = max(1, nextDelay())
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.isBackgroundKeepAliveActive else { return }
            self.ensurePlaying()
            onTick()
            self.scheduleNextTick(nextDelay: nextDelay, onTick: onTick)
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }
}
