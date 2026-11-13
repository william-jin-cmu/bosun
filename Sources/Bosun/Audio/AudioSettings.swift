import AVFoundation
import CoreAudio
import SwiftUI

/// The Sound tab of the settings window.
struct AudioSettings: View {
    @ObservedObject var module: AudioModule
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if module.isRunning {
                permissions
                outputDevices
                inputDevices
                appOptions
                savedApps
                Divider()
                HStack {
                    Button("Reset All Sound Settings…", role: .destructive) { confirmingReset = true }
                    Text("Returns every app to its own volume and output.")
                        .foregroundStyle(.secondary)
                }
                .confirmationDialog(
                    "Reset all Sound settings?", isPresented: $confirmingReset
                ) {
                    Button("Reset", role: .destructive) { module.resetAll() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Per-app volumes, mutes, output choices and pinned apps are removed. Device volumes are not changed.")
                }
            } else {
                Text("Turn on Sound to see devices and per-app settings.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { module.settingsVisibilityChanged(true) }
        .onDisappear { module.settingsVisibilityChanged(false) }
    }

    // MARK: Permissions

    private var permissions: some View {
        SettingsGroup("Permissions") {
            PermissionRow(
                title: "System Audio Recording",
                detail: "Lets Bosun change the volume and output of individual apps. Audio is never recorded or stored.",
                state: captureState)
            Divider()
            PermissionRow(
                title: "Microphone",
                detail: "Only used to show the input level meter below.",
                state: micState)
        }
    }

    private var captureState: PermissionRow.State {
        switch module.captureAccess {
        case .granted: .init(label: "Allowed", ok: true, button: nil, action: {})
        case .denied: .init(label: "Not allowed", ok: false, button: "Open Privacy Settings…", action: module.openCaptureSettings)
        case .undetermined: .init(label: "Not asked yet", ok: nil, button: "Request Access…", action: module.requestCaptureAccess)
        case .unknown: .init(label: "Unknown", ok: nil, button: "Open Privacy Settings…", action: module.openCaptureSettings)
        }
    }

    private var micState: PermissionRow.State {
        switch module.micStatus {
        case .authorized: .init(label: "Allowed", ok: true, button: nil, action: {})
        case .notDetermined where AudioMicAccess.canRequest:
            .init(label: "Not asked yet", ok: nil, button: "Request Access…", action: module.requestMicAccess)
        case .notDetermined: .init(label: "Not available in this build", ok: nil, button: nil, action: {})
        default: .init(label: "Not allowed", ok: false, button: "Open Privacy Settings…", action: module.openMicSettings)
        }
    }

    // MARK: Devices

    private var outputDevices: some View {
        SettingsGroup("Output Devices") {
            if module.outputs.isEmpty {
                Text("No output devices").foregroundStyle(.secondary)
            }
            ForEach(Array(module.outputs.enumerated()), id: \.element.id) { index, device in
                if index > 0 { Divider() }
                DeviceCard(
                    module: module, device: device, direction: .output,
                    isDefault: device.id == module.defaultOutput)
            }
        }
    }

    private var inputDevices: some View {
        SettingsGroup("Input Devices") {
            if module.inputs.isEmpty {
                Text("No input devices").foregroundStyle(.secondary)
            }
            ForEach(Array(module.inputs.enumerated()), id: \.element.id) { index, device in
                if index > 0 { Divider() }
                DeviceCard(
                    module: module, device: device, direction: .input,
                    isDefault: device.id == module.defaultInput)
            }
        }
    }

    // MARK: Apps

    private var appOptions: some View {
        SettingsGroup("App Volume") {
            LabeledContent("Maximum app volume") {
                Picker("Maximum app volume", selection: Binding(get: { module.boostLimit }, set: module.setBoostLimit)) {
                    ForEach(AudioMath.boostLimits, id: \.self) { limit in
                        Text("\(AudioMath.percent(limit))%").tag(limit)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            Text("Above 100% an app is boosted. A limiter holds the peaks just under full scale, so boosted audio gets denser instead of clipping.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            LabeledContent("Keep apps listed after they stop playing") {
                Picker("Keep apps listed", selection: Binding(get: { module.recentWindow }, set: module.setRecentWindow)) {
                    ForEach(AudioMath.recentChoices, id: \.self) { seconds in
                        Text(Self.durationLabel(seconds)).tag(seconds)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    static func durationLabel(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) seconds" : seconds == 60 ? "1 minute" : "\(Int(seconds / 60)) minutes"
    }

    private var savedApps: some View {
        SettingsGroup("Pinned and Saved Apps", trailing: { PinMenu(module: module) }) {
            if !module.perAppAvailable {
                CapturePermissionNote(module: module)
            }
            if module.savedRows.isEmpty {
                Text("Apps you pin, or whose volume or output you change, are listed here, whether or not they are running.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(module.savedRows) { row in
                HStack(spacing: 6) {
                    Button {
                        module.setPinned(row.id, !row.isPinned)
                    } label: {
                        Image(systemName: row.isPinned ? "pin.fill" : "pin")
                            .foregroundStyle(row.isPinned ? Color.accentColor : Color.secondary)
                            .frame(width: 16)
                    }
                    .buttonStyle(.borderless)
                    .help(row.isPinned ? "Unpin: list only while playing" : "Pin: always list in the panel")
                    .accessibilityLabel(row.isPinned ? "Unpin \(row.name)" : "Pin \(row.name)")

                    AppVolumeRow(module: module, row: row, nameWidth: 130)

                    Button("Forget") { module.forgetApp(row.id) }
                        .controlSize(.small)
                        .help("Remove everything saved for \(row.name)")
                        .accessibilityLabel("Forget \(row.name)")
                }
            }
        }
    }
}

/// A titled block of settings.
private struct SettingsGroup<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                trailing()
            }
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

extension SettingsGroup where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, trailing: { EmptyView() }, content: content)
    }
}

private struct PermissionRow: View {
    struct State {
        let label: String
        /// true = granted, false = denied, nil = undecided.
        let ok: Bool?
        let button: String?
        let action: () -> Void
    }

    let title: String
    let detail: String
    let state: State

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Label(state.label, systemImage: state.ok == true ? "checkmark.circle.fill" : state.ok == false ? "xmark.circle.fill" : "questionmark.circle")
                .foregroundStyle(state.ok == true ? Color.green : state.ok == false ? Color.red : Color.secondary)
                .fixedSize()
            if let button = state.button {
                Button(button, action: state.action).controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(state.label)")
    }
}

/// One device: name, default marker, volume and mute, balance, sample rate,
/// and (default input only) the level meter.
private struct DeviceCard: View {
    @ObservedObject var module: AudioModule
    let device: AudioDeviceState
    let direction: AudioDevices.Direction
    let isDefault: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: direction == .input ? "mic" : device.symbol)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(device.name).fontWeight(.medium).lineLimit(1)
                if isDefault {
                    Text("Default")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                }
                Spacer()
                if !isDefault {
                    Button("Make Default") {
                        direction == .output ? module.setDefaultOutput(device.id) : module.setDefaultInput(device.id)
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Make \(device.name) the default \(direction == .output ? "output" : "input")")
                }
                rate
            }
            DeviceVolumeRow(module: module, device: device, direction: direction, name: device.name)
            if let balance = device.balance {
                HStack(spacing: 8) {
                    Text("Balance").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    Text("L").font(.caption).foregroundStyle(.secondary)
                    Slider(
                        value: Binding(get: { Double(balance) }, set: { module.setBalance(Float($0), device: device.id) }),
                        in: 0...1
                    )
                    .controlSize(.small)
                    .accessibilityLabel("\(device.name) balance")
                    .accessibilityValue(Self.balanceLabel(balance))
                    Text("R").font(.caption).foregroundStyle(.secondary)
                    PercentLabel(text: Self.balanceLabel(balance), width: 60)
                }
            }
            if direction == .input, isDefault {
                InputLevelRow(module: module, meter: module.inputMeter)
            }
        }
    }

    @ViewBuilder private var rate: some View {
        if device.sampleRates.count > 1 {
            Picker("Sample rate", selection: Binding(
                get: { device.sampleRate }, set: { module.setSampleRate($0, device: device.id) })
            ) {
                if !device.sampleRates.contains(device.sampleRate) {
                    Text(AudioMath.rateLabel(device.sampleRate)).tag(device.sampleRate)
                }
                ForEach(device.sampleRates, id: \.self) { rate in
                    Text(AudioMath.rateLabel(rate)).tag(rate)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("\(device.name) sample rate")
        } else {
            Text(AudioMath.rateLabel(device.sampleRate))
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(device.name) sample rate \(AudioMath.rateLabel(device.sampleRate))")
        }
    }

    static func balanceLabel(_ balance: Float) -> String {
        let offset = Int(((balance - 0.5) * 200).rounded())
        return offset == 0 ? "Centre" : offset < 0 ? "L \(-offset)" : "R \(offset)"
    }
}

private struct InputLevelRow: View {
    @ObservedObject var module: AudioModule
    @ObservedObject var meter: InputMeterModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Level").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            if module.micStatus == .authorized {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(meter.level > 0.92 ? Color.red : meter.level > 0.75 ? Color.yellow : Color.green)
                            .frame(width: max(0, proxy.size.width * meter.level))
                    }
                }
                .frame(height: 6)
                .accessibilityElement()
                .accessibilityLabel("Input level")
                .accessibilityValue("\(AudioMath.percent(meter.level)) percent")
            } else {
                Text(module.micStatus == .notDetermined && !AudioMicAccess.canRequest
                     ? "The level meter is not available in this build."
                     : "Allow microphone access above to see the input level.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
