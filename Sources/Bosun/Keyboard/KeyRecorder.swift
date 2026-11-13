import SwiftUI
import UniformTypeIdentifiers

/// One control for choosing a key, a key with modifiers, or an action: click
/// it and press the key, or open the chooser for keys that cannot be pressed
/// (media keys, keys this keyboard lacks, shortcuts macOS keeps for itself).
struct KeyCapture: View {
    struct Options: OptionSet {
        let rawValue: Int
        /// Modifiers can be part of the value (a shortcut rather than a bare key).
        static let mods = Options(rawValue: 1)
        /// Modifier keys and Caps Lock are valid choices.
        static let modifierKeys = Options(rawValue: 2)
        /// Keys without a keycode (media keys, F21–F24) are valid choices.
        static let hidOnlyKeys = Options(rawValue: 4)
        /// "Open an app" is a valid choice.
        static let apps = Options(rawValue: 8)
    }

    @ObservedObject var module: KeyboardModule
    @Binding var value: KeyAction
    var options: Options = []
    var recording: KeyboardModule.RecordingMode = .logical
    var placeholder = "Record…"

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var heldModifier: UInt16?
    @State private var capsBefore: Bool?
    @State private var showChooser = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggleRecording) {
                Text(isRecording ? "Press a key…" : (value.isEmpty ? placeholder : value.label))
                    .lineLimit(1)
                    .foregroundStyle(isRecording ? Color.accentColor : value.isEmpty ? .secondary : .primary)
                    .frame(minWidth: 86, maxWidth: .infinity)
            }
            .help(isRecording ? "Click to cancel" : "Click, then press the key")
            Button { stopRecording(); showChooser = true } label: {
                Image(systemName: "chevron.down").imageScale(.small)
            }
            .help("Choose from a list")
            .accessibilityLabel("Choose from a list")
            .popover(isPresented: $showChooser, arrowEdge: .bottom) {
                KeyChooser(value: $value, options: options) { showChooser = false }
            }
        }
        .controlSize(.small)
        .onDisappear(perform: stopRecording)
    }

    // MARK: Recording

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    /// A local monitor sees the key before any view does and swallows it, so the
    /// recorded keystroke goes nowhere else. It needs no event tap or permission.
    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        heldModifier = nil
        capsBefore = CapsLock.isOn
        module.beginRecording(recording)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        isRecording = false
        module.endRecording()
        // Recording Caps Lock itself toggles the lock; put it back.
        if let capsBefore, CapsLock.isOn != capsBefore { CapsLock.set(capsBefore) }
    }

    private func handle(_ event: NSEvent) {
        let flags = UInt64(event.modifierFlags.rawValue)
        switch event.type {
        case .keyDown:
            guard !event.isARepeat, let key = KeyCatalog.key(keycode: event.keyCode) else { return }
            value = KeyAction(key: key.id, mods: options.contains(.mods) ? Mods(flags: flags) : [])
            stopRecording()
        case .flagsChanged:
            guard options.contains(.modifierKeys) else { return }
            if event.keyCode == KeyCatalog.capsLockKeycode {
                value = KeyAction(key: "caps_lock")
                stopRecording()
            } else if let modifier = KeyCatalog.modifierKey(keycode: event.keyCode) {
                // A modifier key is taken when released without another key in between.
                if flags & modifier.downBit != 0 {
                    heldModifier = event.keyCode
                } else if heldModifier == event.keyCode, let key = KeyCatalog.key(keycode: event.keyCode) {
                    value = KeyAction(key: key.id)
                    stopRecording()
                }
            }
        default:
            break
        }
    }
}

/// Searchable list of every key, plus modifier toggles and apps where allowed.
struct KeyChooser: View {
    @Binding var value: KeyAction
    let options: KeyCapture.Options
    let close: () -> Void
    @State private var search = ""

    private var keys: [KeyInfo] {
        KeyCatalog.all.filter { info in
            let isModifier = info.keycode.map { KeyCatalog.modifierKey(keycode: $0) != nil || $0 == KeyCatalog.capsLockKeycode } ?? false
            if isModifier && !options.contains(.modifierKeys) { return false }
            if info.keycode == nil && !options.contains(.hidOnlyKeys) { return false }
            return search.isEmpty || info.label.localizedCaseInsensitiveContains(search)
                || info.id.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if options.contains(.mods) {
                HStack(spacing: 6) {
                    Text("Modifiers").font(.caption).foregroundStyle(.secondary)
                    ModifierToggles(mods: $value.mods)
                }
            }
            TextField("Search keys", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(KeyInfo.Group.allCases, id: \.self) { group in
                        let members = keys.filter { $0.group == group }
                        if !members.isEmpty {
                            Section {
                                ForEach(members) { info in
                                    Button {
                                        value.key = info.id
                                        value.app = nil
                                        value.appName = nil
                                        if !options.contains(.mods) { close() }
                                    } label: {
                                        HStack {
                                            Text(info.label)
                                            Spacer()
                                            if value.key == info.id && value.app == nil { Image(systemName: "checkmark") }
                                        }
                                        .contentShape(Rectangle())
                                        .padding(.vertical, 3).padding(.horizontal, 6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                Text(group.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 3).padding(.horizontal, 6)
                                    .background(.regularMaterial)
                            }
                        }
                    }
                }
            }
            .frame(height: 260)
            if options.contains(.apps) {
                Divider()
                AppMenu(title: value.app == nil ? "Open an App Instead" : "Opens \(value.appName ?? value.app ?? "")") { app in
                    value = .openApp(app.bundleID, name: app.name)
                    close()
                }
            }
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

/// ⌃ ⌥ ⇧ ⌘ as four small toggles.
struct ModifierToggles: View {
    @Binding var mods: Mods

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Mods.all, id: \.name) { info in
                Toggle(info.symbol, isOn: Binding(
                    get: { mods.contains(info.mod) },
                    set: { if $0 { mods.insert(info.mod) } else { mods.remove(info.mod) } }))
                    .toggleStyle(.button)
                    .help(info.name.capitalized)
                    .accessibilityLabel(info.name.capitalized)
            }
        }
        .controlSize(.small)
    }
}

/// A menu of running apps plus "Browse…".
struct AppMenu: View {
    let title: String
    let pick: (AppFilter.App) -> Void

    private var running: [AppFilter.App] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { AppFilter.App(bundleID: $0, name: app.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Menu(title) {
            ForEach(running) { app in
                Button(app.name) { pick(app) }
            }
            Divider()
            Button("Browse…", action: browse)
        }
        .controlSize(.small)
        .fixedSize()
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            pick(.init(bundleID: bundleID, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")))
        }
    }
}

// MARK: Bindings between the rule types and KeyCapture's value

extension Binding where Value == String {
    /// A bare key id as a KeyCapture value.
    var asKeyAction: Binding<KeyAction> {
        Binding<KeyAction>(get: { KeyAction(key: wrappedValue.isEmpty ? nil : wrappedValue) },
                           set: { wrappedValue = $0.key ?? "" })
    }
}

extension Binding where Value == KeyCombo {
    var asKeyAction: Binding<KeyAction> {
        Binding<KeyAction>(get: { KeyAction(key: wrappedValue.key.isEmpty ? nil : wrappedValue.key, mods: wrappedValue.mods) },
                           set: { wrappedValue = KeyCombo(key: $0.key ?? "", mods: $0.mods) })
    }
}
