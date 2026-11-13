import SwiftUI
import AVFoundation
import CoreLocation
import UserNotifications

struct GeneralSettings: View {
    @ObservedObject var state: AppState
    @StateObject private var permissions = PermissionCenter()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            GeneralGroup("Modules") {
                ForEach(Array(moduleRows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    ModuleRow(state: state, module: row.module, tab: row.tab, summary: row.summary)
                }
            }
            GeneralGroup("Permissions", footnote: "macOS asks for each of these separately. Bosun only needs the ones for the features you use; everything else keeps working without them.") {
                ForEach(Array(permissions.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    PermissionRow(item: item, center: permissions)
                }
            }
            GeneralGroup("Startup") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Bosun at login")
                        Text("Starts quietly in the menu bar.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Open Bosun at login", isOn: Binding(
                        get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                .padding(.vertical, 2)
            }
        }
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Bosun").font(.title.weight(.semibold))
                Text("One menu bar item for system stats, displays, sound, screen color and keyboard.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var moduleRows: [(module: any BosunModule, tab: SettingsTab, summary: String)] {
        [
            (state.monitor, .system, "CPU, memory, disks, network, sensors and battery"),
            (state.tint, .tint, "Warms the screen through the evening"),
            (state.displays, .displays, "Brightness, contrast and volume of every display"),
            (state.audio, .sound, "Devices and a volume for each app"),
            (state.keyboard, .keyboard, "Key remaps, shortcuts and layers"),
        ]
    }
}

private struct GeneralGroup<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String, footnote: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct IconTile: View {
    let symbol: String
    var tint: Color = .accentColor
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}

private struct ModuleRow: View {
    @ObservedObject var state: AppState
    let module: any BosunModule
    let tab: SettingsTab
    let summary: String

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: module.symbol, tint: state.isEnabled(module) ? .accentColor : .gray)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Settings") { SettingsWindow.show(tab) }
                .controlSize(.small)
                .accessibilityLabel("\(module.title) settings")
            Toggle(module.title, isOn: Binding(
                get: { state.isEnabled(module) }, set: { state.setEnabled(module, $0) }))
                .toggleStyle(.switch).labelsHidden()
        }
    }
}

private struct PermissionRow: View {
    let item: PermissionItem
    let center: PermissionCenter

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: item.symbol, tint: item.status.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.purpose).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Label(item.status.label, systemImage: item.status.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(item.status.color)
                .fixedSize()
            if item.status == .notAsked, item.canRequest {
                Button("Allow…") { center.request(item.kind) }.controlSize(.small)
                    .accessibilityLabel("Allow \(item.title)")
            }
            Button("Open Settings") { center.openSettings(item.kind) }.controlSize(.small)
                .accessibilityLabel("Open \(item.title) in System Settings")
        }
    }
}

enum PermissionKind: String, CaseIterable {
    case accessibility, audioCapture, microphone, location, notifications
}

enum PermissionStatus: Equatable {
    case granted, denied, notAsked, unavailable

    var label: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Not allowed"
        case .notAsked: "Not asked yet"
        case .unavailable: "Unknown"
        }
    }
    var symbol: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notAsked: "questionmark.circle"
        case .unavailable: "minus.circle"
        }
    }
    var color: Color {
        switch self {
        case .granted: .green
        case .denied: .orange
        case .notAsked, .unavailable: .gray
        }
    }
}

struct PermissionItem: Identifiable {
    let kind: PermissionKind
    let title: String
    let symbol: String
    let purpose: String
    var status: PermissionStatus
    var canRequest = true
    var id: String { kind.rawValue }
}

/// Reads every macOS permission Bosun can use, in one place, and keeps the
/// list fresh while the General tab is on screen (grants happen in System
/// Settings, outside the app, so there is nothing to observe).
@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var items: [PermissionItem] = []
    private var timer: Timer?
    private var notificationStatus: PermissionStatus = .unavailable
    private lazy var locationManager = CLLocationManager()

    init() { refresh() }

    func startWatching() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        readNotificationStatus()
        items = [
            PermissionItem(kind: .accessibility, title: "Accessibility", symbol: "accessibility",
                           purpose: "Keyboard layers and shortcuts, and the brightness and volume keys for external displays.",
                           status: Accessibility.isTrusted ? .granted : .denied),
            PermissionItem(kind: .audioCapture, title: "System Audio Recording", symbol: "waveform",
                           purpose: "Changing the volume of individual apps. Nothing is recorded.",
                           status: Self.audioCaptureStatus()),
            PermissionItem(kind: .microphone, title: "Microphone", symbol: "mic",
                           purpose: "The input level meter in Sound settings.",
                           status: Self.microphoneStatus(), canRequest: AudioMicAccess.canRequest),
            PermissionItem(kind: .location, title: "Location", symbol: "location",
                           purpose: "Finding sunrise and sunset for Color Temperature. You can type coordinates instead.",
                           status: locationStatus(), canRequest: false),
            PermissionItem(kind: .notifications, title: "Notifications", symbol: "bell",
                           purpose: "Optional alerts from System, such as high temperature or low disk space.",
                           status: notificationStatus, canRequest: Self.isBundled),
        ]
    }

    func request(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            Accessibility.prompt()
        case .audioCapture:
            AudioCaptureAccess.request { [weak self] _ in self?.refresh() }
        case .microphone:
            AudioMicAccess.request { [weak self] _ in self?.refresh() }
        case .location:
            SettingsWindow.show(.tint)
        case .notifications:
            guard Self.isBundled else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
            }
        }
    }

    func openSettings(_ kind: PermissionKind) {
        if kind == .accessibility, !Accessibility.isTrusted {
            // Adds Bosun to the Accessibility list so there is a switch to flip.
            Accessibility.prompt()
        }
        NSWorkspace.shared.open(Self.settingsURL(kind))
    }

    static func settingsURL(_ kind: PermissionKind) -> URL {
        let privacy = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?"
        switch kind {
        case .accessibility: return URL(string: privacy + "Privacy_Accessibility")!
        case .audioCapture: return AudioCaptureAccess.settingsURL
        case .microphone: return AudioMicAccess.settingsURL
        case .location: return URL(string: privacy + "Privacy_LocationServices")!
        case .notifications:
            let id = Bundle.main.bundleIdentifier ?? ""
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
        }
    }

    // MARK: Readers (none of these prompt)

    /// UserNotifications raises an exception in a process without a bundle (the bare test binary).
    private static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    private static func audioCaptureStatus() -> PermissionStatus {
        switch AudioCaptureAccess.current() {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .notAsked
        case .unknown: .unavailable
        }
    }

    private static func microphoneStatus() -> PermissionStatus {
        switch AudioMicAccess.status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notAsked
        @unknown default: .unavailable
        }
    }

    private func locationStatus() -> PermissionStatus {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse, .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notAsked
        @unknown default: .unavailable
        }
    }

    private func readNotificationStatus() {
        guard Self.isBundled else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: PermissionStatus
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: status = .granted
            case .denied: status = .denied
            case .notDetermined: status = .notAsked
            @unknown default: status = .unavailable
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.notificationStatus != status else { return }
                    self.notificationStatus = status
                    self.refresh()
                }
            }
        }
    }
}
