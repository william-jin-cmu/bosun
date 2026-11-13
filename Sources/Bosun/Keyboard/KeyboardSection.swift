import SwiftUI

struct KeyboardSection: View {
    @ObservedObject var module: KeyboardModule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if module.karabinerRunning {
                Notice(symbol: "exclamationmark.triangle.fill", tint: .orange,
                       text: "Karabiner-Elements is still active, so both will remap. Quit it to switch over.")
            }
            if let error = module.mappingError {
                Notice(symbol: "xmark.octagon.fill", tint: .red, text: "Key remaps failed: \(error)")
            }

            ForEach(module.rules.remaps) { rule in
                RuleRow(title: rule.title, detail: rule.detail, isOn: Binding(
                    get: { rule.enabled }, set: { module.setRemap(rule.id, enabled: $0) }))
            }
            ForEach(module.rules.layers) { layer in
                let usable = module.rules.isUsable(layer)
                RuleRow(title: layer.title,
                        detail: usable ? layerDetail(layer) : "Needs the Caps Lock rule above",
                        isOn: Binding(get: { layer.enabled && usable },
                                      set: { module.setLayer(layer.id, enabled: $0) }))
                    .disabled(!usable)
            }

            if module.needsTap {
                Toggle("Send plain arrows (without Control)", isOn: Binding(
                    get: { module.plainArrows }, set: { module.setPlainArrows($0) }))
                    .toggleStyle(.checkbox)
                    .font(.callout)
                Divider()
                tapStatus
            }
        }
    }

    private func layerDetail(_ layer: LayerRule) -> String {
        module.plainArrows ? "Sent as plain arrows" : layer.detail
    }

    @ViewBuilder private var tapStatus: some View {
        if module.tapRunning {
            StatRow(label: "Accessibility", value: "Granted")
        } else if !module.accessibilityGranted {
            HStack(alignment: .firstTextBaseline) {
                Notice(symbol: "hand.raised.fill", tint: .orange,
                       text: "W A S D arrows are waiting for Accessibility permission. The key remaps already work.")
                Spacer(minLength: 4)
                Button("Grant…") { module.requestAccessibility() }
                    .controlSize(.small)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Notice(symbol: "exclamationmark.triangle.fill", tint: .orange,
                       text: "Key event tap could not start. Remove Bosun from Accessibility, then add it again.")
                Spacer(minLength: 4)
                Button("Open…") { module.requestAccessibility() }
                    .controlSize(.small)
            }
        }
    }
}

private struct RuleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }
}

private struct Notice: View {
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
