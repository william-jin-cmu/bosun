import SwiftUI

struct DisplaysSection: View {
    @ObservedObject var module: DisplaysModule

    var body: some View {
        if module.displays.isEmpty {
            Text("No displays found").foregroundStyle(.secondary).font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(module.displays) { display in
                    DisplayBlock(module: module, display: display)
                }
            }
        }
    }
}

private struct DisplayBlock: View {
    let module: DisplaysModule
    let display: DisplayState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(display.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            if display.control == .none {
                Text("No DDC control").font(.caption).foregroundStyle(.secondary)
            } else {
                LevelRow(
                    value: display.brightness,
                    label: "\(display.name) brightness",
                    set: { module.setBrightness($0, for: display.id) }
                ) {
                    Image(systemName: "sun.max").accessibilityHidden(true)
                }
                if let volume = display.volume {
                    LevelRow(
                        value: volume,
                        label: "\(display.name) volume",
                        set: { module.setVolume($0, for: display.id) }
                    ) {
                        if let muted = display.muted {
                            Button {
                                module.setMuted(!muted, for: display.id)
                            } label: {
                                Image(systemName: muted ? "speaker.slash" : "speaker.wave.2")
                            }
                            .buttonStyle(.plain)
                            .help(muted ? "Unmute" : "Mute")
                            .accessibilityLabel("\(display.name) mute")
                            .accessibilityValue(muted ? "Muted" : "Not muted")
                        } else {
                            Image(systemName: "speaker.wave.2").accessibilityHidden(true)
                        }
                    }
                }
            }
        }
    }
}

/// Icon, slider and percent readout on one line.
private struct LevelRow<Icon: View>: View {
    let value: Double
    let label: String
    let set: (Double) -> Void
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        HStack(spacing: 8) {
            icon()
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Slider(value: Binding(get: { value }, set: set), in: 0...1)
                .controlSize(.small)
                .accessibilityLabel(label)
                .accessibilityValue("\(percent) percent")
            Text("\(percent)%")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var percent: Int { Int((value * 100).rounded()) }
}
