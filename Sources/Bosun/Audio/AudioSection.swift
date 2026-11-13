import CoreAudio
import SwiftUI

struct AudioSection: View {
    @ObservedObject var module: AudioModule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DevicePickerRow(
                label: "Output", devices: module.outputDevices, selection: module.defaultOutput,
                select: module.setDefaultOutput)
            masterVolume
            DevicePickerRow(
                label: "Input", devices: module.inputDevices, selection: module.defaultInput,
                select: module.setDefaultInput)
            Divider()
            appList
        }
        .font(.callout)
    }

    private var masterVolume: some View {
        HStack(spacing: 8) {
            Button {
                module.setMuted(!module.isMuted)
            } label: {
                Image(systemName: speakerSymbol).frame(width: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!module.canMute)
            .help(module.isMuted ? "Unmute" : "Mute")
            .accessibilityLabel(module.isMuted ? "Unmute output" : "Mute output")

            if module.canSetVolume {
                Slider(
                    value: Binding(get: { Double(module.volume) }, set: { module.setVolume(Float($0)) }),
                    in: 0...1
                )
                .controlSize(.small)
                .accessibilityLabel("Output volume")
                .accessibilityValue("\(percent(Double(module.volume))) percent")
                PercentLabel(text: module.isMuted ? "Muted" : "\(percent(Double(module.volume)))%")
            } else {
                Text("This device has no volume control")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private var speakerSymbol: String {
        if module.isMuted { return "speaker.slash.fill" }
        switch module.volume {
        case ..<0.01: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    @ViewBuilder private var appList: some View {
        if !module.perAppAvailable {
            VStack(alignment: .leading, spacing: 6) {
                Text("Per-app volume needs the System Audio Recording permission.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings…") { module.openCaptureSettings() }
                    .controlSize(.small)
            }
        }
        if module.apps.isEmpty {
            Text("No apps are playing audio")
                .foregroundStyle(.secondary)
        } else {
            ForEach(module.apps) { app in
                AppVolumeRow(module: module, app: app)
            }
        }
    }
}

private func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }

private struct PercentLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
    }
}

private struct DevicePickerRow: View {
    let label: String
    let devices: [AudioDeviceInfo]
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

private struct AppVolumeRow: View {
    @ObservedObject var module: AudioModule
    let app: AudioApp

    var body: some View {
        let value = module.appVolume(app.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Group {
                    if let icon = module.icon(for: app) {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                    }
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)

                Text(app.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(app.isPlaying ? .primary : .secondary)
                    .frame(width: 92, alignment: .leading)
                    .help(app.name)

                Slider(
                    value: Binding(get: { value }, set: { module.setAppVolume(app.id, $0) }),
                    in: 0...1
                )
                .controlSize(.small)
                .disabled(!module.perAppAvailable)
                .accessibilityLabel("\(app.name) volume")
                .accessibilityValue("\(percent(value)) percent")

                PercentLabel(text: "\(percent(value))%")
            }
            if let error = module.appErrors[app.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            }
        }
    }
}
