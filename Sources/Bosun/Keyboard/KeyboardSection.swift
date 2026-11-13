import SwiftUI

/// The compact menu bar panel section: warnings, every rule with its switch,
/// and the way into the editor.
struct KeyboardSection: View {
    @ObservedObject var module: KeyboardModule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            KeyboardStatus(module: module, compact: true)
            if module.rules.isEmpty {
                Text("No rules yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(module.rules) { rule in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rule.title).font(.callout).lineLimit(1)
                        Text(rule.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if rule.enabled, let issue = module.issues(rule.id).first(where: \.isError) {
                            Text(issue.text).font(.caption).foregroundStyle(.orange).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 4)
                    Toggle(rule.title, isOn: Binding(get: { rule.enabled }, set: { module.setEnabled(rule.id, $0) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button("Edit Rules…") { SettingsWindow.show(.keyboard) }
                    .controlSize(.small)
            }
        }
    }
}
