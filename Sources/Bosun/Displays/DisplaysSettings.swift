import SwiftUI

struct DisplaysSettings: View {
    @ObservedObject var module: DisplaysModule

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            KeysGroup(module: module)
            ShortcutsGroup(module: module)
            AutomationGroup(module: module)
            DisplaysGroup(module: module)
        }
    }
}

// MARK: - Building blocks

private struct SettingsGroup<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if let footnote { Note(footnote) }
        }
    }
}

private struct Row<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            content()
        }
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private extension DisplaysModule {
    /// A binding to one global setting.
    func binding<Value>(_ keyPath: WritableKeyPath<DisplaysConfig, Value>) -> Binding<Value> {
        Binding(get: { self.config[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    /// A binding to one setting of one display.
    func binding<Value>(_ key: String, _ keyPath: WritableKeyPath<DisplayPrefs, Value>) -> Binding<Value> {
        Binding(get: { self.config.prefs(key)[keyPath: keyPath] },
                set: { value in self.updatePrefs(key) { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - Keys

private struct KeysGroup: View {
    @ObservedObject var module: DisplaysModule

    private var externals: [DisplayState] { module.displays.filter { !$0.isBuiltIn } }

    var body: some View {
        let config = module.config
        SettingsGroup(title: "Keyboard") {
            Toggle("Control external displays with the brightness keys", isOn: module.binding(\.brightnessKeys))
            Note("Off: the brightness keys change the built-in display only, as macOS does. On: Bosun takes the keys when they point at an external display and sets its brightness over DDC. The built-in display is always left to macOS.")
            if config.brightnessKeys {
                Row(label: "Brightness keys act on") {
                    Picker("Brightness keys act on", selection: module.binding(\.brightnessTarget)) {
                        ForEach(DisplayKeyTarget.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if config.brightnessTarget == .chosen {
                    DisplayPicker(label: "Display", displays: externals, selection: module.binding(\.brightnessChosen))
                }
                Toggle("Also use F14 and F15 as brightness keys", isOn: module.binding(\.alternateBrightnessKeys))
            }

            Divider()

            Toggle("Control display speakers with the volume keys", isOn: module.binding(\.volumeKeys))
            Note("macOS cannot change the volume of a monitor's own speakers. With this on, Bosun takes the volume and mute keys while such a monitor is the sound output and sets its volume over DDC. With any other output the keys work as usual.")
            if config.volumeKeys {
                Row(label: "Volume keys act on") {
                    Picker("Volume keys act on", selection: module.binding(\.volumeTarget)) {
                        ForEach(DisplayVolumeTarget.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if config.volumeTarget == .chosen {
                    DisplayPicker(label: "Display", displays: externals.filter { $0.volume != nil }, selection: module.binding(\.volumeChosen))
                }
                Toggle("Take the volume keys even when macOS can control the output", isOn: module.binding(\.volumeAlways))
                Note(volumeStatus)
            }

            if config.brightnessKeys || config.volumeKeys {
                Divider()
                KeyStatusRow(module: module)
                if NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == "MonitorControl" }) {
                    Label("MonitorControl is running and handles the same keys. Quit it, or each press will be applied twice.",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }

            Divider()

            Row(label: "Step size") {
                Picker("Step size", selection: module.binding(\.stepPercent)) {
                    Text("16 steps, like macOS").tag(6.25)
                    Text("10%").tag(10.0)
                    Text("5%").tag(5.0)
                    Text("2%").tag(2.0)
                    Text("1%").tag(1.0)
                }
                .labelsHidden().fixedSize()
            }
            Row(label: "On-screen display") {
                Picker("On-screen display", selection: module.binding(\.osd)) {
                    ForEach(DisplayOSDStyle.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Toggle("Change brightness gradually when a key is pressed", isOn: module.binding(\.smooth))
            Note("Hold ⌥⇧ for quarter steps. ⌃⌥⌘ with the brightness keys changes contrast. Step size and on-screen display also apply to the custom shortcuts below.")
        }
    }

    private var volumeStatus: String {
        guard let output = module.soundOutput else { return "No sound output found." }
        let targets = module.volumeKeyTargets
        if targets.isEmpty {
            return "Sound output is \"\(output.name)\": volume keys are left to macOS."
        }
        return "Sound output is \"\(output.name)\": volume keys control \(targets.joined(separator: ", "))."
    }
}

private struct KeyStatusRow: View {
    @ObservedObject var module: DisplaysModule

    var body: some View {
        switch module.keyStatus {
        case .active:
            Label("Listening for keys", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .nothingToControl:
            Label("Waiting: no connected display has a control these keys could drive", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        case .needsAccessibility:
            VStack(alignment: .leading, spacing: 6) {
                Label("Bosun needs Accessibility access to see these keys", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Note("Until access is granted the keys keep working as usual and only the sliders and custom shortcuts control external displays.")
                HStack {
                    Button("Request Access") { Accessibility.prompt() }
                    Button("Open Accessibility Settings") { Accessibility.openSettings() }
                    Button("Check Again") { module.updateKeyHandling() }
                }
            }
        case .off:
            Label("Displays is turned off, so no keys are intercepted", systemImage: "pause.circle").foregroundStyle(.secondary)
        }
    }
}

private struct DisplayPicker: View {
    let label: String
    let displays: [DisplayState]
    @Binding var selection: String?

    var body: some View {
        Row(label: label) {
            Picker(label, selection: $selection) {
                Text("Choose…").tag(String?.none)
                ForEach(displays) { Text($0.name).tag(String?.some($0.key)) }
                if let selection, !displays.contains(where: { $0.key == selection }) {
                    Text("Not connected").tag(String?.some(selection))
                }
            }
            .labelsHidden().fixedSize()
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsGroup: View {
    @ObservedObject var module: DisplaysModule

    var body: some View {
        SettingsGroup(title: "Custom shortcuts",
              footnote: "For keyboards without brightness or volume keys. These work without Accessibility access and act on the same displays as the keys above; here the built-in display is adjusted too when it is the target.") {
            ForEach(DisplayKeyAction.allCases, id: \.self) { action in
                Row(label: action.label) {
                    if module.shortcutFailures.contains(action) {
                        Text("In use by another app").font(.caption).foregroundStyle(.orange)
                    }
                    ShortcutRecorder(name: action.label, shortcut: Binding(
                        get: { module.config.shortcuts[action.rawValue] },
                        set: { value in module.update { $0.shortcuts[action.rawValue] = value } }))
                }
            }
        }
    }
}

/// Click, press a key combination, done. Esc cancels, Delete clears.
private struct ShortcutRecorder: View {
    let name: String
    @Binding var shortcut: DisplayShortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(recording ? "Press keys…" : shortcut?.label ?? "Record") {
                recording ? stopRecording() : startRecording()
            }
            .frame(minWidth: 110)
            .accessibilityLabel("\(name) shortcut")
            .accessibilityValue(recording ? "Recording" : shortcut?.label ?? "None")
            Button { shortcut = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .opacity(shortcut == nil || recording ? 0 : 1)
                .disabled(shortcut == nil || recording)
                .help("Remove shortcut")
                .accessibilityLabel("Remove \(name) shortcut")
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = Int(event.keyCode)
            var modifiers: DisplayKeyModifiers = []
            if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
            if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
            if keyCode == 53, modifiers.isEmpty {                   // Esc
                stopRecording()
            } else if keyCode == 51 || keyCode == 117, modifiers.isEmpty {   // Delete
                shortcut = nil
                stopRecording()
            } else if ShortcutRecorder.acceptable(keyCode: keyCode, modifiers: modifiers) {
                shortcut = DisplayShortcut(keyCode: keyCode, modifiers: modifiers,
                                    keyLabel: DisplayKeyNames.label(keyCode: keyCode, characters: event.charactersIgnoringModifiers))
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    /// Function keys may stand alone; everything else needs ⌘, ⌃ or ⌥ so that
    /// a shortcut cannot swallow ordinary typing.
    static func acceptable(keyCode: Int, modifiers: DisplayKeyModifiers) -> Bool {
        let functionKeys: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        if functionKeys.contains(keyCode) { return true }
        return !modifiers.isDisjoint(with: [.command, .control, .option])
    }
}

// MARK: - Sync and restore

private struct AutomationGroup: View {
    @ObservedObject var module: DisplaysModule

    var body: some View {
        SettingsGroup(title: "Automation") {
            Toggle("External displays follow the built-in display's brightness", isOn: module.binding(\.syncEnabled))
            Note("Ambient-light changes and the built-in brightness keys carry over. Each display can be offset or excluded below; moving a following display's slider changes its offset.")
            if module.config.syncEnabled, !module.displays.contains(where: { $0.isBuiltIn && $0.control == .native }) {
                Note("No built-in display is active right now, so nothing is being followed.")
            }
            Divider()
            Toggle("Restore brightness and contrast on launch, wake and reconnect", isOn: module.binding(\.restore))
            Note("Off: Bosun shows whatever the display reports. On: Bosun writes back the last values it knew, for displays that forget their settings or come back from sleep changed.")
        }
    }
}

// MARK: - Per display

private struct DisplaysGroup: View {
    @ObservedObject var module: DisplaysModule

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if module.displays.isEmpty {
                SettingsGroup(title: "Displays") {
                    Text(module.isRunning ? "No displays found." : "Turn Displays on to see the connected displays.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(module.displays) { display in
                DisplayCard(module: module, display: display, prefs: module.config.prefs(display.key))
            }
        }
    }
}

private struct DisplayCard: View {
    @ObservedObject var module: DisplaysModule
    let display: DisplayState
    let prefs: DisplayPrefs

    private var key: String { display.key }

    var body: some View {
        SettingsGroup(title: display.name) {
            Row(label: status) {
                Toggle("Control this display", isOn: module.binding(key, \.enabled))
                    .toggleStyle(.switch).controlSize(.mini).controlSize(.small)
            }
            .foregroundStyle(.secondary)

            if prefs.enabled {
                Row(label: "Name") {
                    TextField("Name", text: module.binding(key, \.friendlyName), prompt: Text(display.systemName))
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                        .accessibilityLabel("\(display.systemName) name")
                }

                if display.control == .native {
                    Note(display.isBuiltIn ? "Brightness is set through macOS. The brightness keys are never intercepted for this display."
                                           : "This display is controlled through macOS rather than DDC.")
                }

                if display.control == .ddc {
                    Row(label: "Show in the menu bar panel") {
                        HStack(spacing: 12) {
                            Toggle("Brightness", isOn: module.binding(key, \.showBrightness))
                            if display.contrast != nil { Toggle("Contrast", isOn: module.binding(key, \.showContrast)) }
                            if display.volume != nil { Toggle("Volume", isOn: module.binding(key, \.showVolume)) }
                            if display.input != nil { Toggle("Input", isOn: module.binding(key, \.showInput)) }
                        }
                        .toggleStyle(.checkbox)
                    }

                    ForEach(DisplayControl.allCases, id: \.self) { control in
                        if let deviceMax = display.deviceMax[control] {
                            ClampRow(module: module, display: display, control: control, deviceMax: Int(deviceMax))
                        }
                    }
                    Note("Limits are raw DDC values. Raise a minimum if the picture goes black too early, lower a maximum if the top of the range does nothing.")

                    if let input = display.input {
                        Row(label: "Input source") {
                            InputMenu(module: module, display: display, input: input).fixedSize()
                        }
                        Note("Switching to another input takes the picture away from this Mac. Most displays then stop listening to it, so switch back with the display's own buttons.")
                    }

                    if display.volume != nil {
                        Row(label: "Mute") {
                            HStack {
                                Text(muteDescription).foregroundStyle(.secondary)
                                if prefs.muteSupport != .unknown {
                                    Button("Test Again") { module.resetMuteSupport(key) }.controlSize(.small)
                                }
                            }
                        }
                    }
                }

                if !display.isBuiltIn, display.control != .native {
                    Toggle(display.answersDDC ? "Dim further in software below the display's minimum brightness"
                                              : "Dim this display in software",
                           isOn: module.binding(key, \.softwareDimming))
                    Note(display.answersDDC
                        ? "The lowest quarter of the brightness slider then darkens the picture with a black overlay once the backlight is at its minimum."
                        : "This display does not answer DDC. A black overlay darkens the picture instead; the backlight stays as it is.")

                    if module.config.syncEnabled, display.control != .none {
                        Toggle("Follow the built-in display", isOn: module.binding(key, \.followBuiltIn))
                        if prefs.followBuiltIn {
                            Row(label: "Offset") {
                                HStack {
                                    Slider(value: module.binding(key, \.syncOffset), in: -0.5...0.5, step: 0.05)
                                        .frame(width: 200)
                                        .accessibilityLabel("\(display.name) brightness offset")
                                    Text(String(format: "%+d%%", Int((prefs.syncOffset * 100).rounded())))
                                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            } else {
                Note("Bosun does not read from or write to this display, and the keys ignore it.")
            }
        }
    }

    private var status: String {
        if !prefs.enabled { return "Not controlled" }
        switch display.control {
        case .native: return display.isBuiltIn ? "Built-in display" : "Controlled through macOS"
        case .ddc: return "DDC control"
        case .software: return "No DDC control, software dimming"
        case .none: return "No DDC control"
        }
    }

    private var muteDescription: String {
        switch prefs.muteSupport {
        case .unknown: "Tested the first time you mute"
        case .hardware: "Uses the display's mute"
        case .fallback: "Sets volume to zero (the display has no working mute)"
        }
    }
}

private struct ClampRow: View {
    @ObservedObject var module: DisplaysModule
    let display: DisplayState
    let control: DisplayControl
    let deviceMax: Int

    var body: some View {
        let prefs = module.config.prefs(display.key)
        Row(label: "\(control.label) range") {
            HStack(spacing: 6) {
                field("minimum", value: prefs.clampMin[control.rawValue] ?? 0) { value in
                    module.updatePrefs(display.key) { $0.clampMin[control.rawValue] = value == 0 ? nil : value }
                }
                Text("to")
                field("maximum", value: prefs.clampMax[control.rawValue] ?? deviceMax) { value in
                    module.updatePrefs(display.key) { $0.clampMax[control.rawValue] = value >= deviceMax ? nil : value }
                }
                Text("of 0–\(deviceMax)").foregroundStyle(.secondary)
            }
        }
    }

    private func field(_ name: String, value: Int, set: @escaping (Int) -> Void) -> some View {
        TextField(name, value: Binding(get: { value }, set: { set(Swift.min(Swift.max($0, 0), deviceMax)) }), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel("\(display.name) \(control.label.lowercased()) \(name)")
    }
}
