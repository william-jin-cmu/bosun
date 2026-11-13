import AppKit
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

/// The compact Sound card in the menu bar panel.
struct AudioSection: View {
    @ObservedObject var module: AudioModule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DevicePickerRow(
                label: "Output", devices: module.outputs, selection: module.defaultOutput,
                select: module.setDefaultOutput)
            if let device = module.defaultOutputState {
                DeviceVolumeRow(module: module, device: device, direction: .output, name: "Output")
            }
            DevicePickerRow(
                label: "Input", devices: module.inputs, selection: module.defaultInput,
                select: module.setDefaultInput)
            Divider()
            HStack {
                Text("Apps").foregroundStyle(.secondary)
                Spacer()
                PinMenu(module: module)
            }
            if !module.perAppAvailable {
                CapturePermissionNote(module: module)
            }
            if module.rows.isEmpty {
                Text("No apps are playing audio")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(module.rows) { row in
                    AppVolumeRow(module: module, row: row, nameWidth: 84)
                }
            }
        }
        .font(.callout)
    }
}

struct CapturePermissionNote: View {
    @ObservedObject var module: AudioModule
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Per-app volume needs the System Audio Recording permission.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings…") { module.openCaptureSettings() }
                .controlSize(.small)
        }
    }
}

struct PercentLabel: View {
    let text: String
    var width: CGFloat = 40
    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}

struct DevicePickerRow: View {
    let label: String
    let devices: [AudioDeviceState]
    let selection: AudioDeviceID
    let select: (AudioDeviceID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if devices.isEmpty {
                Text("No devices").foregroundStyle(.secondary)
            } else {
                Picker("\(label) device", selection: Binding(get: { selection }, set: select)) {
                    if !devices.contains(where: { $0.id == selection }) {
                        Text("None").tag(selection)
                    }
                    ForEach(devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 230, alignment: .trailing)
                .accessibilityLabel("\(label) device")
            }
        }
    }
}

/// Mute button + volume slider + percentage for one device.
struct DeviceVolumeRow: View {
    @ObservedObject var module: AudioModule
    let device: AudioDeviceState
    let direction: AudioDevices.Direction
    /// Used in accessibility labels, e.g. "Output" or the device name.
    let name: String

    var body: some View {
        let volume = Double(device.volume ?? 0)
        HStack(spacing: 8) {
            Button {
                module.setMuted(!device.isMuted, device: device.id, direction)
            } label: {
                Image(systemName: symbol).frame(width: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!device.canMute)
            .help(device.isMuted ? "Unmute" : "Mute")
            .accessibilityLabel(device.isMuted ? "Unmute \(name)" : "Mute \(name)")

            if device.canSetVolume {
                Slider(
                    value: Binding(get: { volume }, set: { module.setVolume(Float($0), device: device.id, direction) }),
                    in: 0...1
                )
                .controlSize(.small)
                .accessibilityLabel(direction == .output ? "\(name) volume" : "\(name) input gain")
                .accessibilityValue("\(AudioMath.percent(volume)) percent")
                PercentLabel(text: device.isMuted ? "Muted" : "\(AudioMath.percent(volume))%", width: 44)
            } else {
                Text(direction == .output ? "No volume control on this device" : "No gain control on this device")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private var symbol: String {
        if direction == .input { return device.isMuted ? "mic.slash.fill" : "mic.fill" }
        if device.isMuted { return "speaker.slash.fill" }
        switch device.volume ?? 1 {
        case ..<0.01: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

/// "+" menu: pin a running app, or pick one from disk.
struct PinMenu: View {
    @ObservedObject var module: AudioModule

    var body: some View {
        Menu {
            let candidates = module.pinCandidates()
            if !candidates.isEmpty {
                Section("Running apps") {
                    ForEach(candidates, id: \.id) { app in
                        Button(app.name) { module.pin(bundleID: app.id, name: app.name, path: app.path) }
                    }
                }
            }
            Button("Choose App…") { chooseApp() }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Keep an app in this list")
        .accessibilityLabel("Pin an app")
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.message = "Choose apps to keep in Bosun's Sound list"
        panel.prompt = "Pin"
        // Not runModal(): that would spin the run loop inside a SwiftUI action.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                module.pin(bundleID: id, name: name, path: url.path)
            }
        }
    }
}

/// One app: icon, name, mute, volume slider (with boost), and a menu for the
/// output device, pinning and reset.
struct AppVolumeRow: View {
    @ObservedObject var module: AudioModule
    let row: AudioAppRow
    var nameWidth: CGFloat = 84

    var body: some View {
        let saved = module.appSettings(row.id)
        let shown = min(saved.volume, module.boostLimit)
        let enabled = module.perAppAvailable
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Group {
                    if let icon = module.icon(for: row) {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                    }
                }
                .frame(width: 18, height: 18)
                .opacity(row.isLive ? 1 : 0.5)
                .accessibilityHidden(true)

                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(row.isPlaying ? .primary : .secondary)
                    .frame(width: nameWidth, alignment: .leading)
                    .help(row.isLive ? row.name : "\(row.name) (not running)")

                Button {
                    module.setAppMuted(row.id, !saved.muted)
                } label: {
                    Image(systemName: saved.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(saved.muted ? Color.red : Color.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .disabled(!enabled)
                .help(saved.muted ? "Unmute \(row.name)" : "Mute \(row.name)")
                .accessibilityLabel(saved.muted ? "Unmute \(row.name)" : "Mute \(row.name)")

                Slider(
                    value: Binding(get: { shown }, set: { module.setAppVolume(row.id, $0) }),
                    in: 0...module.boostLimit
                )
                .controlSize(.small)
                .disabled(!enabled)
                .opacity(saved.muted ? 0.5 : 1)
                .accessibilityLabel("\(row.name) volume")
                .accessibilityValue("\(AudioMath.percent(shown)) percent")

                PercentLabel(text: "\(AudioMath.percent(shown))%")
                    .foregroundStyle(shown > 1 ? Color.orange : Color.secondary)

                AppOptionsMenu(module: module, row: row)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 24)
            }
        }
    }

    private var note: String? {
        if let error = module.appErrors[row.id] { return error }
        if let device = module.chosenOverride(row.id) {
            return module.isRouted(row.id) ? "Playing on \(device.name)" : "Output: \(device.name)"
        }
        if module.overrideUnavailable(row.id) { return "Chosen output not connected; using the default" }
        return nil
    }
}

struct AppOptionsMenu: View {
    @ObservedObject var module: AudioModule
    let row: AudioAppRow

    var body: some View {
        let saved = module.appSettings(row.id)
        Menu {
            Picker("Output", selection: Binding(
                get: { saved.outputUID ?? "" }, set: { module.setAppOutput(row.id, $0.isEmpty ? nil : $0) })
            ) {
                Text("System Default").tag("")
                ForEach(module.outputs) { device in
                    Text(device.name).tag(device.uid)
                }
                if let uid = saved.outputUID, !module.outputs.contains(where: { $0.uid == uid }) {
                    Text("Not connected").tag(uid)
                }
            }
            .pickerStyle(.inline)
            .disabled(!module.perAppAvailable)
            Divider()
            Button(row.isPinned ? "Unpin" : "Keep in List") { module.setPinned(row.id, !row.isPinned) }
            Button("Reset") { module.resetApp(row.id) }
                .disabled(saved.isAudioDefault)
        } label: {
            Image(systemName: saved.outputUID == nil ? "ellipsis.circle" : "arrow.triangle.branch")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Output device and options for \(row.name)")
        .accessibilityLabel("\(row.name) options")
    }
}
