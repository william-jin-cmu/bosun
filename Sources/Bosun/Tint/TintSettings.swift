import SwiftUI
import UniformTypeIdentifiers

struct TintSettings: View {
    @ObservedObject var module: TintModule

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TintNowGroup(module: module)
            TintColorsGroup(module: module)
            TintScheduleGroup(module: module)
            TintOffGroup(module: module)
            TintDisplaysGroup(module: module)
            TintCompatibilityGroup(module: module)
        }
    }
}

private struct TintGroup<Content: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct TintRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).frame(width: 130, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

// MARK: Now

private struct TintNowGroup: View {
    @ObservedObject var module: TintModule

    var body: some View {
        TintGroup(title: "Today") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TintCopy.headline(module)).font(.title3.weight(.semibold)).monospacedDigit()
                Text(TintCopy.state(module)).foregroundStyle(.secondary)
                Spacer()
                Text(TintCopy.next(module)).font(.callout).foregroundStyle(.secondary)
            }
            if !module.isRunning {
                Text("Color Temperature is off. This is what the schedule would show now.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TintChart(timeline: module.timeline, strength: module.strength, marker: module.sweepDate)
                .frame(height: 104)
                .accessibilityLabel("Color temperature over today")
            HStack {
                Text(TintChart.eventSummary(module.timeline)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(module.sweepDate == nil ? "Preview 24 Hours" : "Stop Preview") { module.toggleDayPreview() }
                    .controlSize(.small)
                    .disabled(!module.isRunning || module.standby)
                    .help("Runs the next 24 hours of the schedule on screen in a few seconds")
            }
        }
    }
}

/// The colour curve for the local day: the band shows the tint, the line the Kelvin value.
struct TintChart: View {
    let timeline: TintTimeline
    let strength: Double
    /// Pretend time while the 24-hour preview runs.
    var marker: Date?

    static func dayRange(around date: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return start...end
    }

    /// Kelvin at evenly spaced moments across `range` (both ends included).
    static func samples(_ timeline: TintTimeline, strength: Double, range: ClosedRange<Date>, count: Int) -> [Double] {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        return (0..<count).map { i in
            let date = range.lowerBound.addingTimeInterval(span * Double(i) / Double(max(count - 1, 1)))
            return TintLevel.kelvin(scheduled: timeline.kelvin(at: date), strength: strength, offset: 0, active: true)
        }
    }

    @MainActor
    static func eventSummary(_ timeline: TintTimeline) -> String {
        let range = dayRange(around: Date())
        var parts: [String] = []
        let sun = timeline.schedule.mode == .sun
        for event in timeline.sunEvents(in: range) {
            parts.append("\(event.on ? (sun ? "Sunrise" : "Day") : (sun ? "Sunset" : "Evening")) \(TintCopy.time(event.date))")
        }
        if sun, parts.isEmpty { parts.append("No sunrise or sunset today") }
        if timeline.schedule.bedtimeEnabled {
            parts.append("Bedtime \(TintSchedule.clockString(timeline.schedule.bedtimeStartMinutes))")
            parts.append("Wake \(TintSchedule.clockString(timeline.schedule.wakeMinutes))")
        }
        return parts.joined(separator: "  ·  ")
    }

    static func color(_ kelvin: Double) -> Color {
        let m = ColorTemperature.multipliers(kelvin: kelvin)
        return Color(red: m.r, green: m.g, blue: m.b)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Canvas { graphics, size in
                draw(&graphics, size: size, now: context.date)
            }
        }
    }

    private func draw(_ graphics: inout GraphicsContext, size: CGSize, now: Date) {
        let range = Self.dayRange(around: now)
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        let axis: CGFloat = 16
        let plot = CGRect(x: 0, y: 0, width: size.width, height: size.height - axis)
        let columns = max(2, Int(plot.width / 2))
        let values = Self.samples(timeline, strength: strength, range: range, count: columns)
        func x(_ date: Date) -> CGFloat { plot.minX + plot.width * CGFloat(date.timeIntervalSince(range.lowerBound) / span) }
        func y(_ kelvin: Double) -> CGFloat {
            let low = ColorTemperature.range.lowerBound, high = ColorTemperature.range.upperBound
            return plot.maxY - 8 - (plot.height - 16) * CGFloat((kelvin - low) / (high - low))
        }

        // The band: each column painted in the colour white would have at that time.
        graphics.drawLayer { layer in
            layer.clip(to: Path(roundedRect: plot, cornerRadius: 6))
            let width = plot.width / CGFloat(columns)
            for (i, kelvin) in values.enumerated() {
                let rect = CGRect(x: plot.minX + CGFloat(i) * width, y: plot.minY, width: width + 0.5, height: plot.height)
                layer.fill(Path(rect), with: .color(Self.color(kelvin)))
            }
            // Hour grid.
            for hour in stride(from: 6, through: 18, by: 6) {
                let gx = plot.minX + plot.width * CGFloat(hour) / 24
                layer.stroke(Path { $0.move(to: CGPoint(x: gx, y: plot.minY)); $0.addLine(to: CGPoint(x: gx, y: plot.maxY)) },
                             with: .color(.black.opacity(0.10)), lineWidth: 1)
            }
            var curve = Path()
            for (i, kelvin) in values.enumerated() {
                let point = CGPoint(x: plot.minX + plot.width * CGFloat(i) / CGFloat(columns - 1), y: y(kelvin))
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            layer.stroke(curve, with: .color(.black.opacity(0.65)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        graphics.stroke(Path(roundedRect: plot.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6), with: .color(.primary.opacity(0.15)), lineWidth: 1)

        // Now (and the preview position while it runs).
        func mark(_ date: Date, solid: Bool) {
            var shown = date
            while shown > range.upperBound { shown = shown.addingTimeInterval(-span) }
            guard range.contains(shown) else { return }
            let mx = min(max(x(shown), plot.minX + 1), plot.maxX - 1)
            let kelvin = TintLevel.kelvin(scheduled: timeline.kelvin(at: date), strength: strength, offset: 0, active: true)
            graphics.stroke(Path { $0.move(to: CGPoint(x: mx, y: plot.minY)); $0.addLine(to: CGPoint(x: mx, y: plot.maxY)) },
                            with: .color(.black.opacity(solid ? 0.55 : 0.3)), style: StrokeStyle(lineWidth: 1, dash: solid ? [] : [3, 3]))
            let dot = CGRect(x: mx - 4, y: y(kelvin) - 4, width: 8, height: 8)
            graphics.fill(Path(ellipseIn: dot), with: .color(solid ? .accentColor : .gray))
            graphics.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1.5)
        }
        if let marker {
            mark(now, solid: false)
            mark(marker, solid: true)
        } else {
            mark(now, solid: true)
        }

        for hour in stride(from: 0, through: 24, by: 6) {
            let label = Text(String(format: "%02d", hour % 24)).font(.system(size: 9)).foregroundStyle(.secondary)
            let anchor: UnitPoint = hour == 0 ? .topLeading : hour == 24 ? .topTrailing : .top
            graphics.draw(label, at: CGPoint(x: plot.minX + plot.width * CGFloat(hour) / 24, y: plot.maxY + 3), anchor: anchor)
        }
    }
}

// MARK: Colours

private struct TintColorsGroup: View {
    @ObservedObject var module: TintModule

    var body: some View {
        TintGroup(title: "Colors",
                  caption: "Lower is warmer. 6500 K leaves the screen untouched. Hold a slider to see that color on screen.") {
            TintKelvinRow(module: module, phase: .day)
            TintKelvinRow(module: module, phase: .sunset)
            if module.schedule.bedtimeEnabled {
                TintKelvinRow(module: module, phase: .bedtime)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "circle.lefthalf.filled").frame(width: 18).foregroundStyle(.secondary)
                Text("Strength").frame(width: 70, alignment: .leading)
                Slider(value: $module.strength, in: 0...1).accessibilityLabel("Strength")
                Text("\(Int((module.strength * 100).rounded()))%").monospacedDigit().frame(width: 92, alignment: .trailing)
            }
            .font(.callout)
            .help("Scales the whole schedule towards no tint, without changing the colors above")
        }
    }
}

// MARK: Schedule

private struct TintScheduleGroup: View {
    @ObservedObject var module: TintModule

    private func clock(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }

    var body: some View {
        TintGroup(title: "Schedule") {
            TintRow(label: "Day and evening") {
                Picker("Day and evening follow", selection: $module.schedule.mode) {
                    ForEach(TintSchedule.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            switch module.schedule.mode {
            case .sun:
                TintLocationRows(module: module, location: module.location)
            case .fixed:
                TintRow(label: "Daytime starts") {
                    DatePicker("Daytime starts", selection: clock($module.schedule.fixedDayStart), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                TintRow(label: "Evening starts") {
                    DatePicker("Evening starts", selection: clock($module.schedule.fixedEveningStart), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text("The sunset color takes over").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            TintRow(label: "Wake time") {
                DatePicker("Wake time", selection: clock($module.schedule.wakeMinutes), displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            TintRow(label: "Bedtime") {
                Toggle("Use a bedtime color", isOn: $module.schedule.bedtimeEnabled)
            }
            if module.schedule.bedtimeEnabled {
                TintRow(label: "Bedtime starts") {
                    Stepper(value: $module.schedule.bedtimeLeadMinutes, in: 60...840, step: 30) {
                        Text("\(TintScheduleGroup.hours(module.schedule.bedtimeLeadMinutes)) before waking, at \(TintSchedule.clockString(module.schedule.bedtimeStartMinutes))")
                            .monospacedDigit()
                    }
                }
                Text("The bedtime color lasts until the wake time, whatever the sun is doing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            TintRow(label: "Transitions") {
                Picker("Transition speed", selection: $module.schedule.ramp) {
                    ForEach(TintRamp.allCases) { ramp in
                        Text(ramp == .natural && module.schedule.mode == .fixed ? "Very slow (60 minutes, no twilight to follow)" : ramp.title).tag(ramp)
                    }
                }
                .labelsHidden().fixedSize()
            }
            Text(module.schedule.sunRampDuration == nil
                 ? "The color follows the sun through twilight, from 6° above the horizon to 6° below."
                 : "Each scheduled change is centered on its time and eased, so there is no visible step.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static func hours(_ minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

private struct TintLocationRows: View {
    @ObservedObject var module: TintModule
    @ObservedObject var location: TintLocation

    var body: some View {
        TintRow(label: "Location") {
            TintCoordinateField(label: "Latitude", value: $module.schedule.latitude, range: -90...90)
            TintCoordinateField(label: "Longitude", value: $module.schedule.longitude, range: -180...180)
        }
        TintRow(label: "") {
            Button("Use Current Location") { location.request() }
                .disabled(location.state == .requesting)
            if location.state == .requesting { ProgressView().controlSize(.small) }
        }
        if let message = location.state.message {
            Text(message).font(.caption)
                .foregroundStyle(location.state.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TintCoordinateField: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: Binding(
                get: { value },
                set: { value = min(max($0, range.lowerBound), range.upperBound) }
            ), format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder).frame(width: 84)
        }
    }
}

// MARK: Turning it off

private struct TintOffGroup: View {
    @ObservedObject var module: TintModule

    var body: some View {
        TintGroup(title: "Turn Off Temporarily",
                  caption: "For color-critical work. The screen fades to its normal color and back; nothing snaps.") {
            HStack {
                if module.pausedUntil != nil {
                    Text("Off \(TintCopy.state(module))").foregroundStyle(.secondary)
                    Button("Resume") { module.resume() }
                } else {
                    Button("For an Hour") { module.pause(for: 3600) }
                    Button(module.schedule.mode == .sun ? "Until Sunrise" : "Until Daytime") { module.pauseUntilSunrise() }
                    Button("Until I Turn It Back On") { module.pauseIndefinitely() }
                }
            }
            .disabled(!module.isRunning)
            Divider()
            Text("Off while these apps are in front").font(.callout)
            if module.excludedApps.isEmpty {
                Text("No apps yet. Add a photo or video editor to see true colors while you work in it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(module.excludedApps) { app in
                HStack(spacing: 8) {
                    Image(nsImage: TintAppCatalog.icon(for: app.id)).resizable().frame(width: 20, height: 20)
                    Text(app.name)
                    Text(app.id).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { module.removeExclusion(app) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove \(app.name)").accessibilityLabel("Remove \(app.name)")
                }
            }
            Menu("Add App…") {
                let running = TintAppCatalog.running().filter { !module.isExcluded($0) }
                ForEach(running) { app in
                    Button(app.name) { module.exclude(app) }
                }
                if !running.isEmpty { Divider() }
                Button("Choose Application…") { TintAppCatalog.browse { module.exclude($0) } }
            }
            .fixedSize()
        }
    }
}

@MainActor
enum TintAppCatalog {
    /// Apps with a Dock presence, by name.
    static func running() -> [TintApp] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> TintApp? in
                guard let id = app.bundleIdentifier, id != own, seen.insert(id).inserted else { return nil }
                return TintApp(id: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }

    /// Non-modal on purpose: a modal panel would spin the run loop on the main thread.
    static func browse(_ pick: @escaping @MainActor (TintApp) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose apps that should always show true colors"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                for url in urls {
                    guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                    let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                        ?? url.deletingPathExtension().lastPathComponent
                    pick(TintApp(id: id, name: name))
                }
            }
        }
    }
}

// MARK: Displays

private struct TintDisplaysGroup: View {
    @ObservedObject var module: TintModule

    var body: some View {
        TintGroup(title: "Displays",
                  caption: "Leave a display untouched, or nudge it if it looks cooler or warmer than the others.") {
            if module.displays.isEmpty {
                Text("No displays found.").foregroundStyle(.secondary)
            }
            ForEach(module.displays) { display in
                let pref = module.pref(for: display)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: display.isBuiltin ? "laptopcomputer" : "display").frame(width: 18).foregroundStyle(.secondary)
                        Text(display.name)
                        Spacer()
                        Toggle("Tint \(display.name)", isOn: Binding(
                            get: { !pref.excluded },
                            set: { on in var p = pref; p.excluded = !on; module.setPref(p, for: display) }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    }
                    if !pref.excluded {
                        HStack(spacing: 8) {
                            Text("Offset").font(.callout).foregroundStyle(.secondary).frame(width: 96, alignment: .trailing)
                            Slider(value: Binding(
                                get: { pref.offset },
                                set: { value in var p = pref; p.offset = (value / 50).rounded() * 50; module.setPref(p, for: display) }),
                                   in: -1500...1500)
                                .accessibilityLabel("\(display.name) offset")
                            Text(TintDisplaysGroup.offsetLabel(pref.offset)).font(.callout).monospacedDigit()
                                .frame(width: 110, alignment: .trailing)
                            Button("Reset") { var p = pref; p.offset = 0; module.setPref(p, for: display) }
                                .controlSize(.small).disabled(pref.offset == 0)
                        }
                    }
                }
                if display.id != module.displays.last?.id { Divider() }
            }
        }
    }

    static func offsetLabel(_ offset: Double) -> String {
        if offset == 0 { return "No offset" }
        return "\(Int(abs(offset))) K \(offset < 0 ? "warmer" : "cooler")"
    }
}

// MARK: Other things that colour the screen

private struct TintCompatibilityGroup: View {
    @ObservedObject var module: TintModule

    var body: some View {
        let shift = module.nightShift?.summary
        if module.standby || module.otherTintApp != nil || shift != nil || module.reassertCount > 0 {
            TintGroup(title: "Other Things That Color the Screen") {
                if module.standby {
                    TintNotice(symbol: "exclamationmark.triangle", tint: .orange, text: TintCopy.standby(module.otherTintApp)) {
                        Button("Take Over Anyway") { module.takeOver() }
                    }
                } else if let other = module.otherTintApp {
                    TintNotice(symbol: "exclamationmark.triangle", tint: .orange,
                               text: "\(other) is running. Two apps cannot both own the screen color: if it starts tinting, Bosun stands by rather than flicker. Quit one of them.") { EmptyView() }
                }
                if let shift {
                    TintNotice(symbol: "moon", tint: .secondary,
                               text: "\(shift). It works below Bosun and the two add up, so evenings get warmer than the numbers above say. Use one or the other.") {
                        Button("Open Display Settings") { NightShift.openSettings() }
                    }
                }
                if module.reassertCount > 0, let last = module.lastReassert {
                    TintNotice(symbol: "arrow.clockwise", tint: .secondary,
                               text: "macOS reset the screen color \(module.reassertCount) time\(module.reassertCount == 1 ? "" : "s") since Bosun started (last at \(TintCopy.time(last))); Bosun put the tint back each time.") { EmptyView() }
                }
            }
        }
    }
}
