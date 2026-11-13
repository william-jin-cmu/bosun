import SwiftUI
import UniformTypeIdentifiers

/// The Keyboard tab of the settings window: status, the rule list, and the
/// ways to add rules (blank, from a preset, from a Karabiner config).
struct KeyboardSettings: View {
    @ObservedObject var module: KeyboardModule
    @State private var sheet: Sheet?

    enum Sheet: Identifiable {
        case edit(KeyRule, isNew: Bool)
        case presets
        case importer(KarabinerImport.Result)

        var id: String {
            switch self {
            case .edit(let rule, _): "edit-\(rule.id)"
            case .presets: "presets"
            case .importer: "import"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            KeyboardStatus(module: module)

            HStack {
                Text("Rules").font(.headline)
                Spacer()
                Menu {
                    Button("Key Remap") { new(.remap(RemapRule(from: "", to: ""))) }
                    Button("Shortcut") { new(.shortcut(ShortcutRule(from: KeyCombo(key: ""), to: KeyAction()))) }
                    Button("Layer") { new(.hold(HoldRule(trigger: "", mappings: [.init(from: KeyCombo(key: ""), to: KeyAction())]))) }
                    Button("Tap / Hold Key") { new(.hold(HoldRule(trigger: "", alone: .send, holdMods: .control))) }
                    Button("Hyper Key") { new(.hold(HoldRule(trigger: "", alone: .nothing, holdMods: .hyper))) }
                } label: { Label("Add Rule", systemImage: "plus") }
                .fixedSize()
                Button("Presets…") { sheet = .presets }
                Button("Import from Karabiner…") { importKarabiner() }
            }

            if module.rules.isEmpty {
                Text("No rules yet. Add one, pick a preset, or import your Karabiner-Elements configuration.")
                    .foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(module.rules.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 { Divider() }
                        RuleRow(module: module, rule: rule, index: index) { sheet = .edit(rule, isNew: false) }
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("Key remaps happen first, in the keyboard driver; shortcuts, layers and tap/hold keys then see the remapped keys. Among those, a held layer wins over a hold key, which wins over a shortcut; within a kind, the rule higher in the list wins. Password fields and other secure input bypass everything except key remaps.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if let debug = Self.debugView { debugContent(debug) }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .edit(let rule, let isNew):
                RuleEditor(module: module, draft: rule, isNew: isNew) { self.sheet = nil }
            case .presets:
                PresetGallery(module: module) { self.sheet = nil }
            case .importer(let result):
                ImportReport(module: module, result: result) { self.sheet = nil }
            }
        }
    }

    private func new(_ body: KeyRule.Body) {
        sheet = .edit(KeyRule(body), isNew: true)
    }

    private func importKarabiner() {
        var url = URL(fileURLWithPath: KarabinerImport.defaultPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            panel.message = "Choose a Karabiner-Elements configuration (karabiner.json)"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        sheet = .importer(Self.runImport(url))
    }

    static func runImport(_ url: URL) -> KarabinerImport.Result {
        guard let data = try? Data(contentsOf: url) else {
            var result = KarabinerImport.Result()
            result.error = "Could not read \(url.path)."
            return result
        }
        return KarabinerImport.run(data: data) { name in
            let fileName = name.hasSuffix(".app") ? name : name + ".app"
            return ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
                .lazy.compactMap { Bundle(path: $0 + "/" + fileName)?.bundleIdentifier }.first
        }
    }

    // MARK: Off-screen rendering of the sheets (`-keyboard.debugView editor:0`)

    private static var debugView: String? { UserDefaults.standard.string(forKey: "keyboard.debugView") }

    @ViewBuilder private func debugContent(_ debug: String) -> some View {
        Divider()
        if debug.hasPrefix("editor:"), let index = Int(debug.dropFirst(7)), module.rules.indices.contains(index) {
            RuleEditor(module: module, draft: module.rules[index], isNew: false) {}
        } else if debug == "presets" {
            PresetGallery(module: module) {}
        } else if debug == "import" {
            ImportReport(module: module, result: Self.runImport(URL(fileURLWithPath: KarabinerImport.defaultPath))) {}
        } else if debug == "chooser" {
            KeyChooser(value: .constant(.key("up_arrow", .control)), options: [.mods, .apps]) {}
        }
    }
}

/// Permission, conflicts and failures; shared by the settings tab and the panel.
struct KeyboardStatus: View {
    @ObservedObject var module: KeyboardModule
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if module.karabinerRunning {
                StatusLine(symbol: "exclamationmark.triangle.fill", tint: .orange,
                           text: "Karabiner-Elements is running. If it remaps the same keys, both apply; quit it to switch over.")
            }
            if let error = module.mappingError {
                StatusLine(symbol: "xmark.octagon.fill", tint: .red, text: "Key remaps failed: \(error)")
            }
            if module.needsTap && module.isRunning && !module.tapRunning {
                HStack(alignment: .firstTextBaseline) {
                    StatusLine(symbol: "hand.raised.fill", tint: .orange, text: module.accessibilityGranted
                        ? "The key event tap could not start. Remove Bosun from Accessibility in System Settings, then add it again."
                        : "Shortcuts, layers and tap/hold keys are waiting for Accessibility permission. Key remaps already work.")
                    Spacer(minLength: 4)
                    Button(module.accessibilityGranted ? "Open…" : "Grant…") { module.requestAccessibility() }
                        .controlSize(.small)
                }
            } else if !compact && module.isRunning {
                StatusLine(symbol: "checkmark.circle.fill", tint: .green, text: activeText)
            } else if !compact {
                StatusLine(symbol: "pause.circle", tint: .secondary, text: "Keyboard is off. Rules can be edited; they apply once it is enabled.")
            }
        }
    }

    private var activeText: String {
        let remaps = module.program.remapCount - (module.tapRunning ? 0 : module.program.carriers.count)
        let tapRules = module.program.tap.shortcuts.count + module.program.tap.holds.count
        var parts = ["\(remaps) key remap\(remaps == 1 ? "" : "s") active"]
        if module.tapRunning {
            parts.append("\(tapRules) shortcut/hold rule\(tapRules == 1 ? "" : "s") active (event tap at the \(module.tapLocation?.rawValue ?? "?") level)")
        }
        return parts.joined(separator: " · ")
    }
}

struct StatusLine: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        Label {
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.caption)
    }
}

private struct RuleRow: View {
    @ObservedObject var module: KeyboardModule
    let rule: KeyRule
    let index: Int
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(rule.title, isOn: Binding(get: { rule.enabled }, set: { module.setEnabled(rule.id, $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .padding(.top, 2)
            Image(systemName: rule.symbol).foregroundStyle(.secondary).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(rule.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if rule.enabled {
                    ForEach(Array(module.issues(rule.id).enumerated()), id: \.offset) { _, issue in
                        IssueLine(issue: issue)
                    }
                }
            }
            .opacity(rule.enabled ? 1 : 0.55)
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                Button { module.move(rule.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0).help("Move up").accessibilityLabel("Move \(rule.title) up")
                Button { module.move(rule.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == module.rules.count - 1).help("Move down").accessibilityLabel("Move \(rule.title) down")
                Button("Edit", action: edit).buttonStyle(.bordered)
                Menu {
                    Button("Duplicate") { module.duplicate(rule.id) }
                    Button("Delete", role: .destructive) { module.delete(rule.id) }
                } label: { Image(systemName: "ellipsis") }
                    .menuIndicator(.hidden).fixedSize().accessibilityLabel("More actions for \(rule.title)")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

// MARK: Presets

private struct PresetGallery: View {
    @ObservedObject var module: KeyboardModule
    let done: () -> Void
    @State private var added = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Presets").font(.headline)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(KeyPresets.all.enumerated()), id: \.element.id) { index, preset in
                        if index > 0 { Divider() }
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.title).font(.callout.weight(.medium))
                                Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Button(added.contains(preset.id) ? "Added" : "Add") {
                                module.add(preset.instantiate())
                                added.insert(preset.id)
                            }
                            .disabled(added.contains(preset.id))
                            .controlSize(.small)
                            .accessibilityLabel("Add \(preset.title)")
                        }
                        .padding(.vertical, 7)
                    }
                }
            }
            .frame(maxHeight: 420)
            HStack {
                Text("Presets are ordinary rules: edit or delete them afterwards.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 500)
    }
}

// MARK: Karabiner import

private struct ImportReport: View {
    @ObservedObject var module: KeyboardModule
    let result: KarabinerImport.Result
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from Karabiner-Elements").font(.headline)
            if let error = result.error {
                Text(error).foregroundStyle(.secondary)
            } else {
                Text("Profile “\(result.profile)”").font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        section("Will be imported (\(result.imported.count))", result.imported, symbol: "checkmark.circle.fill", tint: .green)
                        section("Skipped (\(result.skipped.count))", result.skipped, symbol: "minus.circle.fill", tint: .orange)
                    }
                }
                .frame(maxHeight: 380)
            }
            HStack {
                Text("Imported rules are added below the existing ones, switched off.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Import \(result.rules.count) Rule\(result.rules.count == 1 ? "" : "s")") {
                    module.add(result.rules.map { rule in
                        var rule = rule
                        rule.enabled = false
                        return rule
                    })
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(result.rules.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [KarabinerImport.Result.Item], symbol: String, tint: Color) -> some View {
        if !items.isEmpty {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(items) { item in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.callout).fixedSize(horizontal: false, vertical: true)
                        if let why = item.skipped ?? item.note {
                            Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
            }
        }
    }
}
