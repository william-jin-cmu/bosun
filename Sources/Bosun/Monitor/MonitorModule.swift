import SwiftUI

/// The System module: samples on a utility queue and hands results to the main actor
/// only when something on screen needs them.
///
/// Cost model. Every tick reads three kernel counters (CPU ticks, VM statistics,
/// interface byte counts) so the history graphs are already filled when the panel
/// opens. Everything else (GPU, SMC sensors, battery, volumes, disk I/O, processes) is
/// read only for a block that is on screen, a menu bar widget that shows it, or an alert
/// that watches it. With the panel closed, no widgets and no alerts, a tick never
/// reaches the main thread at all.
@MainActor
final class MonitorModule: ObservableObject, BosunModule {
    let id = "monitor"
    let title = "System"
    let symbol = "cpu"

    @Published private(set) var snapshot = MonitorSnapshot()
    @Published var prefs: MonitorPrefs {
        didSet {
            guard prefs != oldValue else { return }
            prefs.save(changedFrom: oldValue)
            if prefs.interval != oldValue.interval, timer != nil { schedule() }
            if !prefs.alertsEnabled.subtracting(oldValue.alertsEnabled).isEmpty, notifier.status != .authorized {
                notifier.requestAuthorization()
            }
            apply()
        }
    }
    /// The rendered menu bar item; observed by the label only.
    let status = StatusModel()
    let notifier = MonitorNotifier()

    private var panelVisible = false
    private var settingsVisible = false
    private var timer: DispatchSourceTimer?

    private let queue = DispatchQueue(label: "bosun.monitor", qos: .utility)
    // Touched only on `queue`.
    nonisolated(unsafe) private let sampler = MonitorSampler()
    nonisolated(unsafe) private var queueNeeds = MonitorNeeds()
    nonisolated(unsafe) private var queuePrefs = MonitorPrefs()
    nonisolated(unsafe) private var queuePieces: [StatusPiece] = [.icon]
    nonisolated(unsafe) private var queueRunning = false

    init() {
        prefs = MonitorPrefs.load()
    }

    func start() {
        guard timer == nil else { return }
        apply(running: true)
        schedule()
        if !prefs.alertsEnabled.isEmpty { notifier.refresh() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        panelVisible = false
        status.show([.icon])
        queue.async { [weak self] in
            self?.queueRunning = false
            self?.queuePieces = [.icon]
        }
    }

    func panelVisibilityChanged(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible
        apply()
        if visible { sampleSoon(after: 0.7) }   // second sample quickly, so rates and the process list fill in
    }

    /// Called by the settings tab while it is on screen; it previews live readings.
    func settingsVisibilityChanged(_ visible: Bool) {
        guard settingsVisible != visible else { return }
        settingsVisible = visible
        if visible { notifier.refresh() }
        apply()
        if visible { sampleSoon(after: 0.7) }
    }

    /// Toggles a block between compact and detailed (the chevron in the panel).
    func toggleDetail(_ block: PanelBlock) {
        if prefs.detailedBlocks.contains(block) { prefs.detailedBlocks.remove(block) } else { prefs.detailedBlocks.insert(block) }
    }

    // MARK: Sampling

    private func schedule() {
        timer?.cancel()
        let interval = prefs.interval
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway lets the system batch the wake-up with others.
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Pushes the current needs and preferences to the queue and samples once, so a change
    /// in what is visible shows up immediately rather than at the next tick.
    private func apply(running: Bool? = nil) {
        let needs = MonitorNeeds.make(prefs: prefs, panelVisible: panelVisible, settingsVisible: settingsVisible)
        let prefs = prefs
        let isRunning = running ?? (timer != nil)
        queue.async { [weak self] in
            guard let self else { return }
            self.queueNeeds = needs
            self.queuePrefs = prefs
            self.queueRunning = isRunning
            if isRunning { self.tick() }
        }
    }

    private func sampleSoon(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.tick() }
    }

    /// Runs on `queue`.
    nonisolated private func tick() {
        guard queueRunning else { return }
        let needs = queueNeeds, prefs = queuePrefs
        let events = sampler.sample(needs, thresholds: prefs.threshold, fahrenheit: prefs.fahrenheit)
        let snapshot = sampler.snapshot
        let pieces = StatusComposer.pieces(prefs: prefs, snapshot: snapshot)
        let piecesChanged = pieces != queuePieces
        queuePieces = pieces
        // Nothing to show and nothing to say: stay off the main thread.
        guard needs.visible || piecesChanged || !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.timer != nil else { return }
                if needs.visible { self.snapshot = snapshot }
                if piecesChanged { self.status.show(pieces) }
                for event in events { self.notifier.post(event) }
            }
        }
    }
}
