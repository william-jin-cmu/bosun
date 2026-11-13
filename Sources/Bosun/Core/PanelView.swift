import SwiftUI

struct PanelView: View {
    @ObservedObject var state: AppState
    @AppStorage("status.style") private var style: StatusStyle = .icon
    @State private var contentHeight: CGFloat = 400
    /// Set by the off-screen snapshot, which wants the whole panel unclipped.
    var unboundedHeight = false

    private var maxListHeight: CGFloat {
        unboundedHeight ? .infinity : max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 80)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    ModuleCard(state: state, module: state.monitor) { MonitorSection(module: state.monitor) }
                    ModuleCard(state: state, module: state.tint) { TintSection(module: state.tint) }
                    ModuleCard(state: state, module: state.displays) { DisplaysSection(module: state.displays) }
                    ModuleCard(state: state, module: state.audio) { AudioSection(module: state.audio) }
                    ModuleCard(state: state, module: state.keyboard) { KeyboardSection(module: state.keyboard) }
                }
                .padding(12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, maxListHeight))
            Divider()
            HStack(spacing: 12) {
                Picker("Menu bar shows", selection: $style) {
                    ForEach(StatusStyle.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("What the menu bar item shows")
                Spacer()
                Toggle("Open at login", isOn: Binding(
                    get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox).fixedSize()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 360)
        .onAppear { state.panelVisibilityChanged(true) }
        .onDisappear { state.panelVisibilityChanged(false) }
    }
}

struct ModuleCard<Content: View>: View {
    @ObservedObject var state: AppState
    let module: any BosunModule
    @ViewBuilder var content: () -> Content

    var body: some View {
        let on = state.isEnabled(module)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(module.title, systemImage: module.symbol).font(.headline)
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { state.setEnabled(module, $0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .accessibilityLabel("\(module.title) enabled")
            }
            if on { content() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A caption/value row used across module sections.
struct StatRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}
