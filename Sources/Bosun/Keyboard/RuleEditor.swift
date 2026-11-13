import SwiftUI

/// Edits one rule on a draft copy; nothing changes until Save.
struct RuleEditor: View {
    @ObservedObject var module: KeyboardModule
    @State var draft: KeyRule
    let isNew: Bool
    let done: () -> Void

    /// What the compiler says about the draft in the context of the other rules.
    private var issues: [KeyProgram.Issue] {
        var rules = module.rules
        var candidate = draft
        candidate.enabled = true
        if let index = rules.firstIndex(where: { $0.id == draft.id }) { rules[index] = candidate } else { rules.append(candidate) }
        return KeyCompiler.compile(rules).issues[draft.id] ?? []
    }

    private var typeName: String {
        switch draft.body {
        case .remap: "Key Remap"
        case .shortcut: "Shortcut"
        case .hold(let rule): rule.flavor == .hyper ? "Hyper Key" : rule.flavor == .layer ? "Layer" : "Tap / Hold Key"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(isNew ? "New \(typeName)" : typeName, systemImage: draft.symbol).font(.headline)
                Spacer()
                TextField("Name (optional)", text: $draft.name)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
            }
            switch draft.body {
            case .remap(let rule):
                RemapEditor(module: module, rule: Binding(get: { rule }, set: { draft.body = .remap($0) }))
            case .shortcut(let rule):
                ShortcutEditor(module: module, rule: Binding(get: { rule }, set: { draft.body = .shortcut($0) }))
            case .hold(let rule):
                HoldEditor(module: module, rule: Binding(get: { rule }, set: { draft.body = .hold($0) }))
            }
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                IssueLine(issue: issue)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Rule" : "Save") {
                    module.save(draft)
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 540)
    }
}

struct IssueLine: View {
    let issue: KeyProgram.Issue
    var body: some View {
        Label {
            Text(issue.text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: issue.isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(issue.isError ? .orange : .secondary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// A labelled row of an editor.
private struct Field<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 118, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }
}

private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 128)
    }
}

// MARK: Key remap

private struct RemapEditor: View {
    @ObservedObject var module: KeyboardModule
    @Binding var rule: RemapRule

    /// Attached keyboards, plus the rule's own keyboard if it is unplugged.
    private var devices: [KeyboardDevice] {
        var list = module.keyboards
        if let device = rule.device, !list.contains(device) { list.append(device) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Field(label: "This key") {
                KeyCapture(module: module, value: $rule.from.asKeyAction, options: [.modifierKeys, .hidOnlyKeys],
                           recording: .physical)
                    .frame(width: 200)
            }
            Field(label: "Becomes") {
                KeyCapture(module: module, value: $rule.to.asKeyAction, options: [.modifierKeys, .hidOnlyKeys],
                           recording: .physical, placeholder: "Record or choose…")
                    .frame(width: 200)
            }
            Field(label: "On") {
                Picker("Keyboard", selection: $rule.device) {
                    Text("All keyboards").tag(KeyboardDevice?.none)
                    ForEach(devices) { device in
                        Text(module.keyboards.contains(device) ? device.name : "\(device.name) (not connected)")
                            .tag(KeyboardDevice?.some(device))
                    }
                }
                .labelsHidden().fixedSize()
            }
            Hint("A key remap replaces the key everywhere, including password fields, and needs no permission. Other rules see the remapped key.")
        }
        .onAppear { module.refreshKeyboards() }
    }
}

// MARK: Shortcut

private struct ShortcutEditor: View {
    @ObservedObject var module: KeyboardModule
    @Binding var rule: ShortcutRule

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Field(label: "When I press") {
                KeyCapture(module: module, value: $rule.from.asKeyAction, options: [.mods])
                    .frame(width: 200)
                ModifierToggles(mods: $rule.from.mods)
            }
            Field(label: "") {
                Toggle("Also when other modifiers are held (they carry over)", isOn: $rule.anyModifiers)
                    .toggleStyle(.checkbox)
            }
            Field(label: "Send") {
                KeyCapture(module: module, value: $rule.to, options: [.mods, .apps], placeholder: "Record or choose…")
                    .frame(width: 200)
                if rule.to.app == nil { ModifierToggles(mods: $rule.to.mods) }
            }
            AppFilterEditor(filter: $rule.apps)
        }
    }
}

// MARK: Layer / tap-hold / hyper

private struct HoldEditor: View {
    @ObservedObject var module: KeyboardModule
    @Binding var rule: HoldRule

    private var triggerIsModifier: Bool {
        KeyCatalog.key(rule.trigger)?.keycode.flatMap(KeyCatalog.modifierKey(keycode:)) != nil
    }
    private var triggerLabel: String { rule.trigger.isEmpty ? "the key" : KeyCatalog.label(rule.trigger) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Field(label: "Hold key") {
                KeyCapture(module: module, value: $rule.trigger.asKeyAction, options: [.modifierKeys])
                    .frame(width: 200)
            }
            Field(label: "Pressed alone") {
                Picker("Pressed alone", selection: $rule.alone) {
                    Text("Normal \(triggerLabel)").tag(HoldRule.Alone.normal)
                    Text("Does nothing").tag(HoldRule.Alone.nothing)
                    Text("Sends…").tag(HoldRule.Alone.send)
                }
                .labelsHidden().fixedSize()
                if rule.alone == .send {
                    KeyCapture(module: module, value: $rule.tap, options: [.mods, .apps, .modifierKeys], placeholder: "Record or choose…")
                        .frame(width: 170)
                }
            }
            if rule.trigger == "caps_lock" && rule.alone == .normal {
                Hint(CapsLock.switchesInputSource
                     ? "macOS is set to switch input sources with Caps Lock: a short press switches, a long press locks. Bosun re-creates this itself while the rule is on."
                     : "A short press toggles Caps Lock as usual. Bosun re-creates this itself while the rule is on.")
            }
            Field(label: "While held, acts as") {
                ModifierToggles(mods: $rule.holdMods)
                Button("Hyper") { rule.holdMods = .hyper }.controlSize(.small)
                if !rule.holdMods.isEmpty { Button("None") { rule.holdMods = [] }.controlSize(.small) }
            }
            Hint(rule.holdMods.isEmpty
                 ? "Off: \(triggerLabel) is not a modifier. Only the layer keys below change while it is held."
                 : "\(triggerLabel) + any key that is not listed below is sent with \(rule.holdMods.symbols).")

            Divider()
            HStack {
                Text("Layer keys").font(.subheadline.weight(.semibold))
                Text("while \(triggerLabel) is held").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    rule.mappings.append(.init(from: KeyCombo(key: ""), to: KeyAction()))
                } label: { Label("Add Key", systemImage: "plus") }
                .controlSize(.small)
            }
            if rule.mappings.isEmpty {
                Text("No layer keys. Add one to turn a key into another key or shortcut while \(triggerLabel) is held.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($rule.mappings) { $mapping in
                HStack(spacing: 6) {
                    KeyCapture(module: module, value: $mapping.from.asKeyAction, options: [.mods])
                        .frame(width: 150)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    KeyCapture(module: module, value: $mapping.to, options: [.mods, .apps], placeholder: "Record or choose…")
                        .frame(width: 150)
                    if mapping.to.app == nil { ModifierToggles(mods: $mapping.to.mods) }
                    Spacer(minLength: 0)
                    Button { rule.mappings.removeAll { $0.id == mapping.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove").accessibilityLabel("Remove layer key")
                }
            }
            if !rule.mappings.isEmpty {
                Text("The output is sent exactly as written, plus any other modifiers you hold.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Field(label: "Tap threshold") {
                Slider(value: Binding(get: { Double(rule.thresholdMs) }, set: { rule.thresholdMs = Int($0 / 10) * 10 }),
                       in: 100...1000)
                    .frame(width: 180)
                Text("\(rule.thresholdMs) ms").monospacedDigit().font(.callout)
            }
            Field(label: "") {
                Toggle("Wait for the threshold before holding (for keys you type)", isOn: $rule.holdAfterThreshold)
                    .toggleStyle(.checkbox)
                    .disabled(triggerIsModifier)
            }
            Hint(rule.holdAfterThreshold && !triggerIsModifier
                 ? "A press shorter than the threshold always counts as a tap, even if you roll onto the next key. Holding starts after the threshold."
                 : "Holding takes effect at once. Released alone within the threshold, it counts as pressed alone.")
            AppFilterEditor(filter: $rule.apps)
        }
    }
}

// MARK: Apps

struct AppFilterEditor: View {
    @Binding var filter: AppFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Field(label: "Applies") {
                Picker("Applies", selection: $filter.mode) {
                    Text("In all apps").tag(AppFilter.Mode.all)
                    Text("Only in…").tag(AppFilter.Mode.only)
                    Text("Except in…").tag(AppFilter.Mode.except)
                }
                .labelsHidden().fixedSize()
                if filter.mode != .all {
                    AppMenu(title: "Add App") { app in
                        if !filter.apps.contains(where: { $0.bundleID == app.bundleID }) { filter.apps.append(app) }
                    }
                }
            }
            if filter.mode != .all {
                ForEach(filter.apps) { app in
                    HStack(spacing: 6) {
                        Text(app.name)
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Button { filter.apps.removeAll { $0.bundleID == app.bundleID } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove").accessibilityLabel("Remove \(app.name)")
                    }
                    .font(.callout)
                    .padding(.leading, 128)
                }
                if filter.apps.isEmpty {
                    Hint(filter.mode == .only ? "No apps yet, so this rule never applies." : "No apps yet, so this rule applies everywhere.")
                }
            }
        }
    }
}
