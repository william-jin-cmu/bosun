import SwiftUI
import UniformTypeIdentifiers

/// The glyph shown in the menu bar: a system symbol (the default), the built-in
/// ship's wheel, or an image the user picked.
enum MenuBarIconChoice: Equatable {
    case symbol(String)
    case wheel
    case custom

    static let fallback = MenuBarIconChoice.symbol("circle.grid.2x2")

    init(stored: String?) {
        switch stored {
        case "wheel": self = .wheel
        case "custom": self = .custom
        case let value? where value.hasPrefix("symbol:"): self = .symbol(String(value.dropFirst(7)))
        default: self = .fallback
        }
    }

    var stored: String {
        switch self {
        case let .symbol(name): "symbol:\(name)"
        case .wheel: "wheel"
        case .custom: "custom"
        }
    }
}

@MainActor
final class MenuBarIcon: ObservableObject {
    static let shared = MenuBarIcon()

    /// Menu bar glyphs are drawn in an 18 pt tall box.
    nonisolated static let height: CGFloat = 18
    nonisolated static let maxCustomWidth: CGFloat = 30

    /// Symbols offered in the picker. Any other SF Symbol name can be typed in.
    static let gallery = [
        "circle.grid.2x2", "circle.grid.2x2.fill", "square.grid.2x2", "square.grid.2x2.fill",
        "circle.hexagongrid", "circle.hexagongrid.fill", "hexagon", "square.stack.3d.up",
        "slider.vertical.3", "slider.horizontal.3", "switch.2", "togglepower",
        "dial.low", "dial.medium", "gauge.with.dots.needle.33percent", "gauge.with.needle",
        "command", "command.circle", "wrench.and.screwdriver", "gearshape.2",
        "sailboat.fill", "ferry.fill", "lifepreserver", "safari",
        "water.waves", "wind", "binoculars.fill", "scope",
        "sparkle", "seal", "staroflife", "atom",
        "target", "circle.circle", "smallcircle.filled.circle", "fish.fill",
    ]

    @Published private(set) var choice: MenuBarIconChoice
    /// Whether a custom image is tinted like other menu bar items (on) or keeps its own colors (off).
    @Published private(set) var tintCustom: Bool
    @Published private(set) var image: NSImage
    @Published private(set) var hasCustomImage: Bool
    @Published var lastError: String?

    private let defaults = UserDefaults.standard

    private init() {
        let choice = MenuBarIconChoice(stored: defaults.string(forKey: "menubar.icon"))
        let tint = defaults.object(forKey: "menubar.icon.tint") == nil ? true : defaults.bool(forKey: "menubar.icon.tint")
        self.choice = choice
        self.tintCustom = tint
        self.hasCustomImage = Self.customFile() != nil
        self.image = Self.render(choice, tintCustom: tint)
    }

    func select(_ choice: MenuBarIconChoice) {
        if case let .symbol(name) = choice, NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
            lastError = "“\(name)” is not a system symbol on this Mac."
            return
        }
        if choice == .custom, Self.customFile() == nil { return }
        lastError = nil
        self.choice = choice
        defaults.set(choice.stored, forKey: "menubar.icon")
        image = Self.render(choice, tintCustom: tintCustom)
    }

    func setTintCustom(_ on: Bool) {
        tintCustom = on
        defaults.set(on, forKey: "menubar.icon.tint")
        image = Self.render(choice, tintCustom: on)
    }

    /// Copies the picked file into Application Support and switches to it.
    func importCustom(from url: URL) {
        guard NSImage(contentsOf: url)?.isValid == true else {
            lastError = "That file could not be read as an image."
            return
        }
        do {
            let folder = Self.supportFolder()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for old in Self.customFiles() { try? FileManager.default.removeItem(at: old) }
            let target = folder.appendingPathComponent("menubar-icon.\(url.pathExtension.lowercased())")
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            lastError = "Could not save the image: \(error.localizedDescription)"
            return
        }
        hasCustomImage = true
        select(.custom)
    }

    func chooseCustomImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .pdf, .svg, .tiff, .jpeg, .icns]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a menu bar icon. A black shape on a transparent background, about 36 pixels tall, works best."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { importCustom(from: url) }
    }

    // MARK: Rendering

    static func supportFolder() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bosun")
    }

    private static func customFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: supportFolder(), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.deletingPathExtension().lastPathComponent == "menubar-icon" }
    }

    private static func customFile() -> URL? { customFiles().first }

    static func render(_ choice: MenuBarIconChoice, tintCustom: Bool) -> NSImage {
        let image: NSImage
        switch choice {
        case let .symbol(name):
            image = symbolImage(name) ?? symbolImage("circle.grid.2x2") ?? WheelGlyph.menuBarImage
        case .wheel:
            image = WheelGlyph.menuBarImage
        case .custom:
            guard let file = customFile(), let source = NSImage(contentsOf: file), source.isValid else {
                return render(.fallback, tintCustom: tintCustom)
            }
            image = fitted(source, template: tintCustom)
        }
        image.accessibilityDescription = "Bosun"
        return image
    }

    static func symbolImage(_ name: String, pointSize: CGFloat = 15) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        symbol.isTemplate = true
        return symbol
    }

    /// Scales any image to the menu bar's height, keeping its proportions.
    static func fitted(_ source: NSImage, template: Bool) -> NSImage {
        let size = fittedSize(source.size)
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = template
        return image
    }

    nonisolated static func fittedSize(_ source: NSSize) -> NSSize {
        guard source.width > 0, source.height > 0 else { return NSSize(width: height, height: height) }
        let scale = min(height / source.height, maxCustomWidth / source.width)
        return NSSize(width: max(1, (source.width * scale).rounded()), height: max(1, (source.height * scale).rounded()))
    }

    /// Draws the current glyph centred in `rect` (used when it sits next to status widgets).
    func draw(in rect: CGRect) {
        let size = image.size
        let scale = min(rect.width / size.width, rect.height / size.height, 1)
        let target = CGRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2,
                            width: size.width * scale, height: size.height * scale)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// The picker shown in General settings.
struct MenuBarIconPicker: View {
    @ObservedObject var icon: MenuBarIcon
    @State private var symbolName = ""

    private let columns = Array(repeating: GridItem(.fixed(38), spacing: 6), count: 12)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(MenuBarIcon.gallery, id: \.self) { name in
                    tile(selected: icon.choice == .symbol(name), label: name) {
                        Image(systemName: name).font(.system(size: 16, weight: .medium))
                    } action: { icon.select(.symbol(name)) }
                }
                tile(selected: icon.choice == .wheel, label: "Ship's wheel") {
                    Image(nsImage: WheelGlyph.menuBarImage)
                } action: { icon.select(.wheel) }
            }
            Divider()
            HStack(spacing: 8) {
                Text("Any SF Symbol")
                TextField("Symbol name, e.g. moon.stars", text: $symbolName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applySymbol)
                Button("Use", action: applySymbol).disabled(symbolName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Divider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your own image")
                    Text("PNG, PDF or SVG. A black shape on a transparent background works best.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if icon.hasCustomImage {
                    tile(selected: icon.choice == .custom, label: "Your image") {
                        Image(nsImage: MenuBarIcon.render(.custom, tintCustom: icon.tintCustom))
                    } action: { icon.select(.custom) }
                }
                Button(icon.hasCustomImage ? "Replace…" : "Choose Image…") { icon.chooseCustomImage() }
            }
            if icon.choice == .custom {
                Toggle("Tint it to match the menu bar", isOn: Binding(get: { icon.tintCustom }, set: { icon.setTintCustom($0) }))
                    .toggleStyle(.checkbox)
            }
            if let error = icon.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func applySymbol() {
        let name = symbolName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        icon.select(.symbol(name))
    }

    private func tile<Content: View>(selected: Bool, label: String, @ViewBuilder content: () -> Content,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content()
                .frame(width: 38, height: 32)
                .background(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
