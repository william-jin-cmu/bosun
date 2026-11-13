import SwiftUI

/// The compact panel section: what the screen is doing now, the colour of the
/// current phase, overall strength, and the ways to switch it off for a while.
struct TintSection: View {
    @ObservedObject var module: TintModule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if module.standby {
                TintNotice(symbol: "exclamationmark.triangle", tint: .orange, text: TintCopy.standby(module.otherTintApp)) {
                    Button("Take Over") { module.takeOver() }
                }
            }
            TintKelvinRow(module: module, phase: module.phase, labelled: false)
            HStack(spacing: 8) {
                Image(systemName: "circle.lefthalf.filled").frame(width: 18).foregroundStyle(.secondary)
                Slider(value: $module.strength, in: 0...1).accessibilityLabel("Strength")
                Text("\(Int((module.strength * 100).rounded()))%").font(.callout).monospacedDigit()
                    .frame(width: 92, alignment: .trailing)
            }
            .help("Strength: how much of the scheduled color is applied")
            HStack {
                if module.suppression != nil, module.pausedUntil != nil {
                    Button("Resume") { module.resume() }
                } else {
                    TintPauseMenu(module: module)
                }
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(TintCopy.headline(module)).font(.title3.weight(.semibold)).monospacedDigit()
            Text(TintCopy.state(module)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(TintCopy.next(module)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// The wording shared by the panel and the Settings tab.
@MainActor
enum TintCopy {
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    static func headline(_ module: TintModule) -> String {
        if module.standby { return "Standing by" }
        if module.isRunning, module.suppression != nil, module.currentKelvin >= ColorTemperature.neutral - 1 { return "Off" }
        return "\(Int(module.currentKelvin)) K"
    }

    static func state(_ module: TintModule) -> String {
        if module.standby { return "" }
        if module.sweepDate != nil { return "Preview" }
        switch module.suppression {
        case .paused(let until)?: return until.map { "until \(time($0))" } ?? "until turned back on"
        case .app(let name)?: return "while \(name) is in front"
        case nil: return module.phase.title
        }
    }

    static func next(_ module: TintModule) -> String {
        if let sweep = module.sweepDate { return time(sweep) }
        guard let change = module.nextChange else { return "" }
        return "\(change.phase.title) at \(time(change.date))"
    }

    static func standby(_ other: String?) -> String {
        if let other {
            return "\(other) is tinting the screen, so Bosun is standing by instead of fighting it. Quit \(other) and Bosun takes over by itself."
        }
        return "Another app is changing the screen color, so Bosun is standing by instead of fighting it. It takes over by itself when that app stops."
    }
}

struct TintNotice<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                actions().controlSize(.small)
            }
        }
        .font(.caption)
    }
}

/// Icon, slider and preset menu for one phase's colour.
struct TintKelvinRow: View {
    @ObservedObject var module: TintModule
    let phase: TintPhase
    var labelled = true

    private var value: Binding<Double> {
        Binding(get: { module.schedule.kelvin(for: phase) },
                set: { module.schedule.setKelvin(($0 / 100).rounded() * 100, for: phase) })
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: phase.symbol).frame(width: 18).foregroundStyle(.secondary)
            if labelled { Text(phase.title).frame(width: 70, alignment: .leading) }
            Slider(value: value, in: ColorTemperature.range) { editing in
                // Holding a slider shows that phase's colour even if it is not the current one.
                if editing { module.beginPreview(of: phase) } else { module.endPreview() }
            }
            .accessibilityLabel("\(phase.title) color temperature")
            Menu {
                ForEach(ColorTemperature.presets.reversed()) { preset in
                    Button {
                        module.schedule.setKelvin(preset.kelvin, for: phase)
                    } label: {
                        Text(verbatim: "\(preset.name) — \(Int(preset.kelvin)) K")
                    }
                }
            } label: {
                Text(verbatim: "\(Int(value.wrappedValue)) K").monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(width: 92, alignment: .trailing)
            .help("\(phase.title) color: \(ColorTemperature.name(for: value.wrappedValue)). Click for presets.")
            .accessibilityLabel("\(phase.title) color presets")
        }
        .font(.callout)
    }
}

struct TintPauseMenu: View {
    @ObservedObject var module: TintModule

    var body: some View {
        Menu("Turn Off…") {
            Button("For an Hour") { module.pause(for: 3600) }
            Button(module.schedule.mode == .sun ? "Until Sunrise" : "Until Daytime") { module.pauseUntilSunrise() }
            Button("Until I Turn It Back On") { module.pauseIndefinitely() }
            if let app = module.frontApp {
                Divider()
                if module.isExcluded(app) {
                    Button("Tint \(app.name) Again") { module.removeExclusion(app) }
                } else {
                    Button("Whenever \(app.name) Is in Front") { module.exclude(app) }
                }
            }
        }
        .fixedSize()
        .disabled(!module.isRunning)
    }
}
