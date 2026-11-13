import SwiftUI
import AppKit

/// The System tab of the settings window.
struct MonitorSettings: View {
    @ObservedObject var module: MonitorModule

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            MenuBarSettings(module: module)
            PanelSettings(module: module)
            ReadingSettings(module: module)
            AlertSettings(module: module, notifier: module.notifier)
            SensorBrowser(module: module)
        }
        .frame(maxWidth: 560, alignment: .leading)
        // The tab previews live readings, so it counts as "visible" for polling while
        // its window is on screen. Tracked here because the shell has no hook for it.
        .background(VisibilityProbe { module.settingsVisibilityChanged($0) })
    }
}

// MARK: - Menu bar

private struct MenuBarSettings: View {
    @ObservedObject var module: MonitorModule

    var body: some View {
        let prefs = module.prefs
        let pieces = StatusComposer.pieces(prefs: prefs, snapshot: module.snapshot)
        SettingsGroup("Menu bar", note: "Choose what sits in the menu bar and in which order. Each item keeps a fixed width, so the menu bar does not shift as the numbers change.") {
            HStack(spacing: 10) {
                StatusPreview(pieces: pieces, dark: false)
                StatusPreview(pieces: pieces, dark: true)
                Text("Preview").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Show the Bosun icon", isOn: $module.prefs.showIcon)
            if !prefs.showIcon && prefs.widgets.isEmpty {
                Text("The icon stays visible until at least one item below is turned on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Show captions (CPU, MEM, …) above the numbers", isOn: $module.prefs.widgetLabels)

            VStack(spacing: 0) {
                ForEach(prefs.widgetOrder) { widget in
                    ReorderRow(
                        isOn: Binding(get: { prefs.widgets.contains(widget) }, set: { setWidget(widget, $0) }),
                        title: widget.title, detail: widget.detail,
                        canMoveUp: widget != prefs.widgetOrder.first, canMoveDown: widget != prefs.widgetOrder.last,
                        move: { moveWidget(widget, $0) }) { EmptyView() }
                    if widget != prefs.widgetOrder.last { Divider() }
                }
            }
            .listBox()
        }
    }

    private func setWidget(_ widget: StatusWidget, _ on: Bool) {
        var enabled = Set(module.prefs.widgets)
        if on { enabled.insert(widget) } else { enabled.remove(widget) }
        module.prefs.widgets = module.prefs.widgetOrder.filter(enabled.contains)
    }

    private func moveWidget(_ widget: StatusWidget, _ offset: Int) {
        var prefs = module.prefs
        prefs.widgetOrder = MonitorPrefs.moved(widget, by: offset, in: prefs.widgetOrder)
        prefs.widgets = prefs.widgetOrder.filter(Set(prefs.widgets).contains)
        module.prefs = prefs
    }
}

private struct StatusPreview: View {
    let pieces: [StatusPiece]
    let dark: Bool

    var body: some View {
        Image(nsImage: StatusRenderer.image(pieces))
            .renderingMode(.template)
            .foregroundStyle(dark ? Color.white : Color.black)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(dark ? Color(white: 0.14) : Color(white: 0.93), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .accessibilityLabel("Menu bar preview, \(dark ? "dark" : "light")")
    }
}

// MARK: - Panel

private struct PanelSettings: View {
    @ObservedObject var module: MonitorModule

    var body: some View {
        let prefs = module.prefs
        SettingsGroup("Panel", note: "Blocks appear in this order. A compact block is one line; a detailed block opens its full readings. The chevron next to each block in the panel switches the same setting.") {
            VStack(spacing: 0) {
                ForEach(prefs.blockOrder) { block in
                    ReorderRow(
                        isOn: Binding(get: { !prefs.hiddenBlocks.contains(block) },
                                      set: { if $0 { module.prefs.hiddenBlocks.remove(block) } else { module.prefs.hiddenBlocks.insert(block) } }),
                        title: block.title, detail: block.detailSummary,
                        canMoveUp: block != prefs.blockOrder.first, canMoveDown: block != prefs.blockOrder.last,
                        move: { module.prefs.blockOrder = MonitorPrefs.moved(block, by: $0, in: module.prefs.blockOrder) }) {
                        Picker("\(block.title) density", selection: Binding(
                            get: { prefs.detailedBlocks.contains(block) },
                            set: { if $0 { module.prefs.detailedBlocks.insert(block) } else { module.prefs.detailedBlocks.remove(block) } })) {
                            Text("Compact").tag(false)
                            Text("Detailed").tag(true)
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.small)
                        .disabled(prefs.hiddenBlocks.contains(block))
                    }
                    if block != prefs.blockOrder.last { Divider() }
                }
            }
            .listBox()
            Picker("Processes in the detailed list", selection: $module.prefs.processCount) {
                ForEach(MonitorPrefs.processCounts, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.menu).fixedSize()
        }
    }
}

// MARK: - Readings

private struct ReadingSettings: View {
    @ObservedObject var module: MonitorModule

    var body: some View {
        SettingsGroup("Readings") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Refresh every")
                    Picker("Refresh every", selection: $module.prefs.interval) {
                        ForEach(MonitorPrefs.intervals, id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                GridRow {
                    Text("Temperature in")
                    Picker("Temperature in", selection: $module.prefs.fahrenheit) {
                        Text("°C").tag(false)
                        Text("°F").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                GridRow {
                    Text("Network speed counts")
                    Picker("Network speed counts", selection: $module.prefs.networkInterface) {
                        Text("All physical interfaces").tag("")
                        ForEach(interfaceChoices, id: \.name) { Text($0.title).tag($0.name) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Text("While the panel is closed Bosun reads only what a menu bar item or an alert needs. Battery and disk space change slowly and are read every 10 seconds while visible, once a minute otherwise.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var interfaceChoices: [InterfaceReading] {
        var choices = module.snapshot.network.interfaces
        let selected = module.prefs.networkInterface
        if !selected.isEmpty, !choices.contains(where: { $0.name == selected }) {
            choices.append(InterfaceReading(name: selected))
        }
        return choices
    }
}

// MARK: - Alerts

private struct AlertSettings: View {
    @ObservedObject var module: MonitorModule
    @ObservedObject var notifier: MonitorNotifier

    var body: some View {
        SettingsGroup("Alerts", note: "Notifications when a reading crosses a level. Each alert fires once, then waits until the reading has clearly recovered before it can fire again.") {
            statusLine
            VStack(spacing: 0) {
                ForEach(AlertKind.allCases) { kind in
                    HStack(spacing: 8) {
                        Toggle(kind.title, isOn: Binding(
                            get: { module.prefs.alertsEnabled.contains(kind) },
                            set: { if $0 { module.prefs.alertsEnabled.insert(kind) } else { module.prefs.alertsEnabled.remove(kind) } }))
                        Spacer(minLength: 8)
                        threshold(kind).disabled(!module.prefs.alertsEnabled.contains(kind))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    if kind != AlertKind.allCases.last { Divider() }
                }
            }
            .listBox()
            Button("Send a test notification") {
                if notifier.status == .notDetermined { notifier.requestAuthorization() }
                notifier.post(AlertEvent(kind: .cpuTemperature, title: "Bosun test notification",
                                         body: "Alerts from the System module will look like this."))
            }
            .disabled(notifier.status == .unavailable || notifier.status == .denied)
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch notifier.status {
        case .denied:
            HStack(spacing: 8) {
                Label("Notifications are turned off for Bosun, so alerts cannot be shown.", systemImage: "bell.slash")
                    .foregroundStyle(.orange)
                Button("Open Notification Settings") { notifier.openSystemSettings() }
            }
            .font(.callout)
        case .unavailable:
            Label("Notifications need Bosun to run as an app (this copy is running outside an app bundle).", systemImage: "bell.slash")
                .font(.callout).foregroundStyle(.secondary)
        case .notDetermined:
            if !module.prefs.alertsEnabled.isEmpty {
                HStack(spacing: 8) {
                    Label("Bosun has not been allowed to send notifications yet.", systemImage: "bell.badge")
                    Button("Allow…") { notifier.requestAuthorization() }
                }
                .font(.callout)
            }
        case .authorized, .unknown:
            EmptyView()
        }
    }

    @ViewBuilder private func threshold(_ kind: AlertKind) -> some View {
        let value = module.prefs.threshold(kind)
        let binding = Binding<Double>(get: { module.prefs.threshold(kind) }, set: { module.prefs.alertThresholds[kind] = $0 })
        if kind == .memoryPressure {
            Picker("Level", selection: binding) {
                Text("Warning").tag(2.0)
                Text("Critical").tag(4.0)
            }
            .labelsHidden().fixedSize().controlSize(.small)
        } else {
            Stepper(value: binding, in: kind.range, step: kind.step) {
                Text(label(kind, value)).monospacedDigit().frame(minWidth: 52, alignment: .trailing)
            }
            .controlSize(.small)
            .accessibilityLabel(kind.title)
            .accessibilityValue(label(kind, value))
        }
    }

    private func label(_ kind: AlertKind, _ value: Double) -> String {
        switch kind {
        case .cpuTemperature: Format.temperature(value, fahrenheit: module.prefs.fahrenheit)
        case .diskSpace: "\(Int(value)) GB"
        case .batteryLow, .batteryCharged, .batteryHealth: "\(Int(value))%"
        case .memoryPressure: ""
        }
    }
}

// MARK: - Sensors

private struct SensorBrowser: View {
    @ObservedObject var module: MonitorModule
    @State private var expanded = false

    var body: some View {
        let sensors = module.snapshot.sensors
        SettingsGroup("Sensors") {
            Toggle("Also list SMC temperature sensors that have no known name", isOn: $module.prefs.showAllSensors)
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(sensors.fans.enumerated()), id: \.offset) { index, fan in
                        DetailRow("Fan \(index + 1)", fan.rpm == 0 ? "Off" : "\(fan.rpm) rpm  (range \(fan.min)–\(fan.max))")
                    }
                    if let power = sensors.systemPower { DetailRow("System power", String(format: "%.1f W", power)) }
                    SensorGrid(sensors: sensors.named, fahrenheit: module.prefs.fahrenheit, columns: 3)
                }
                .font(.caption)
                .padding(.top, 6)
            } label: {
                Text(sensors.named.isEmpty ? "All sensors" : "All sensors (\(sensors.named.count) temperatures, \(sensors.fans.count) fans)")
            }
        }
    }
}

// MARK: - Building blocks

private struct SettingsGroup<Content: View>: View {
    let title: String
    let note: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String, note: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.note = note
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
    }
}

/// A checkbox row with a description, an optional trailing control and move up / down buttons.
private struct ReorderRow<Trailing: View>: View {
    @Binding var isOn: Bool
    let title: String
    let detail: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
            ControlGroup {
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(!canMoveUp).help("Move \(title) up").accessibilityLabel("Move \(title) up")
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(!canMoveDown).help("Move \(title) down").accessibilityLabel("Move \(title) down")
            }
            .controlSize(.small).fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

private extension View {
    func listBox() -> some View {
        background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

/// Reports whether the hosting window is on screen (ordered in and not miniaturised).
/// SwiftUI's onDisappear does not fire when an AppKit-owned window is closed, so the
/// window's own notifications are observed instead.
private struct VisibilityProbe: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.detach()
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var reported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                             NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                             NSWindow.didBecomeKeyNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                        let closing = note.name == NSWindow.willCloseNotification
                        MainActor.assumeIsolated { self?.report(closing: closing) }
                    })
                }
            }
            // The window may be ordered in just after the view is attached.
            report()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.report() }
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            send(false)
        }

        private func report(closing: Bool = false) {
            send(!closing && (window?.isVisible ?? false) && !(window?.isMiniaturized ?? false))
        }

        private func send(_ visible: Bool) {
            guard reported != visible else { return }
            reported = visible
            // Never mutate the model from inside a view update.
            DispatchQueue.main.async { [onChange] in onChange?(visible) }
        }
    }
}
