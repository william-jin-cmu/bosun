import SwiftUI

struct DisplaysSection: View {
    @ObservedObject var module: DisplaysModule

    var body: some View {
        let visible = module.displays.filter { module.config.prefs($0.key).enabled }
        if visible.isEmpty {
            Text(module.displays.isEmpty ? "No displays found" : "All displays are turned off in Settings")
                .foregroundStyle(.secondary).font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(visible) { display in
                    DisplayBlock(module: module, display: display, prefs: module.config.prefs(display.key))
                }
            }
        }
    }
}

private struct DisplayBlock: View {
    let module: DisplaysModule
    let display: DisplayState
    let prefs: DisplayPrefs

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(display.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if prefs.showInput, let input = display.input {
                    InputMenu(module: module, display: display, input: input)
                        .controlSize(.small).fixedSize()
                }
            }
            if display.control == .none {
                Text("No DDC control").font(.caption).foregroundStyle(.secondary)
            } else {
                if prefs.showBrightness {
                    LevelRow(value: display.brightness, label: "\(display.name) brightness",
                             set: { module.setBrightness($0, for: display.id) }) {
                        Image(systemName: "sun.max").accessibilityHidden(true)
                    }
                }
                if prefs.showContrast, let contrast = display.contrast {
                    LevelRow(value: contrast, label: "\(display.name) contrast",
                             set: { module.setContrast($0, for: display.id) }) {
                        Image(systemName: "circle.lefthalf.filled").accessibilityHidden(true)
                    }
                }
                if prefs.showVolume, let volume = display.volume {
                    LevelRow(value: volume, label: "\(display.name) volume",
                             set: { module.setVolume($0, for: display.id) }) {
                        Button {
                            module.toggleMute(for: display.id)
                        } label: {
                            Image(systemName: display.muted ? "speaker.slash" : "speaker.wave.2")
                        }
                        .buttonStyle(.plain)
                        .help(display.muted ? "Unmute" : "Mute")
                        .accessibilityLabel("\(display.name) mute")
                        .accessibilityValue(display.muted ? "Muted" : "Not muted")
                    }
                }
                if !prefs.showBrightness, !(prefs.showContrast && display.contrast != nil),
                   !(prefs.showVolume && display.volume != nil), !(prefs.showInput && display.input != nil) {
                    Text("All controls hidden in Settings").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Input source picker. Switching away from this Mac's input usually cannot
/// be undone from here, so it sits behind a menu rather than a one-click control.
struct InputMenu: View {
    let module: DisplaysModule
    let display: DisplayState
    let input: UInt16

    var body: some View {
        Menu(DisplayInputSource.name(input)) {
            ForEach(options, id: \.self) { value in
                Button {
                    module.setInput(value, for: display.id)
                } label: {
                    if value == input { Label(DisplayInputSource.name(value), systemImage: "checkmark") } else { Text(DisplayInputSource.name(value)) }
                }
            }
        }
        .accessibilityLabel("\(display.name) input source")
    }

    private var options: [UInt16] {
        var values = DisplayInputSource.known.map(\.value)
        if !values.contains(input) { values.insert(input, at: 0) }
        return values
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
