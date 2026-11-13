import Foundation

/// Ready-made rules, so an empty editor is not the starting point.
struct KeyPreset: Identifiable {
    let id: String
    let title: String
    let detail: String
    let rules: [KeyRule]

    /// Fresh copies, so adding a preset twice gives independent rules.
    func instantiate() -> [KeyRule] {
        rules.map { rule in
            var copy = rule
            copy.id = UUID().uuidString
            if case .hold(var hold) = copy.body {
                hold.mappings = hold.mappings.map { .init(from: $0.from, to: $0.to) }
                copy.body = .hold(hold)
            }
            return copy
        }
    }
}

enum KeyPresets {
    private static func layer(_ trigger: String, _ keys: [(String, String, Mods)], alone: HoldRule.Alone = .normal,
                              tap: KeyAction = KeyAction(), holdMods: Mods = []) -> HoldRule {
        HoldRule(trigger: trigger, alone: alone, tap: tap, holdMods: holdMods,
                 mappings: keys.map { .init(from: KeyCombo(key: $0.0), to: .key($0.1, $0.2)) })
    }

    static let rightControlToFn = KeyRule(name: "Right Control → fn", .remap(RemapRule(from: "right_control", to: "fn")))

    static let capsControlWASD = KeyRule(name: "Caps Lock + W A S D → ⌃ arrows", .hold(layer("caps_lock", [
        ("w", "up_arrow", .control), ("a", "left_arrow", .control),
        ("s", "down_arrow", .control), ("d", "right_arrow", .control),
    ])))

    static let all: [KeyPreset] = [
        KeyPreset(id: "caps-spaces", title: "Caps Lock + W A S D → Control+Arrows",
                  detail: "Switch Spaces and open Mission Control from the home row. Caps Lock alone still works.",
                  rules: [capsControlWASD]),
        KeyPreset(id: "caps-vim", title: "Caps Lock + H J K L → Arrows",
                  detail: "Vim-style arrows while Caps Lock is held; other modifiers pass through.",
                  rules: [KeyRule(name: "Caps Lock + H J K L → arrows", .hold(layer("caps_lock", [
                      ("h", "left_arrow", []), ("j", "down_arrow", []), ("k", "up_arrow", []), ("l", "right_arrow", []),
                  ])))]),
        KeyPreset(id: "caps-esc-ctrl", title: "Caps Lock: tap Escape, hold Control",
                  detail: "The classic dual-role key.",
                  rules: [KeyRule(name: "Caps Lock: tap Escape, hold ⌃", .hold(
                      HoldRule(trigger: "caps_lock", alone: .send, tap: .key("escape"), holdMods: .control)))]),
        KeyPreset(id: "caps-hyper", title: "Caps Lock → Hyper Key",
                  detail: "Hold for ⌃⌥⇧⌘ to build shortcuts nothing else uses; tap for Escape.",
                  rules: [KeyRule(name: "Caps Lock → Hyper", .hold(
                      HoldRule(trigger: "caps_lock", alone: .send, tap: .key("escape"), holdMods: .hyper)))]),
        KeyPreset(id: "caps-control", title: "Caps Lock → Control",
                  detail: "A plain key remap: Caps Lock is a Control key everywhere, password fields included.",
                  rules: [KeyRule(.remap(RemapRule(from: "caps_lock", to: "left_control")))]),
        KeyPreset(id: "caps-escape", title: "Caps Lock → Escape",
                  detail: "A plain key remap.",
                  rules: [KeyRule(.remap(RemapRule(from: "caps_lock", to: "escape")))]),
        KeyPreset(id: "rctrl-fn", title: "Right Control → fn (Globe)",
                  detail: "For keyboards without a Globe key: dictation, input switching, fn shortcuts.",
                  rules: [rightControlToFn]),
        KeyPreset(id: "swap-cmd-opt", title: "Swap Option and Command",
                  detail: "For PC-layout keyboards. Edit the rules afterwards to limit them to one keyboard.",
                  rules: [KeyRule(.remap(RemapRule(from: "left_option", to: "left_command"))),
                          KeyRule(.remap(RemapRule(from: "left_command", to: "left_option"))),
                          KeyRule(.remap(RemapRule(from: "right_option", to: "right_command"))),
                          KeyRule(.remap(RemapRule(from: "right_command", to: "right_option")))]),
        KeyPreset(id: "home-end", title: "Home / End move within the line",
                  detail: "Like on Windows: Home and End go to the start and end of the line; Shift selects.",
                  rules: [KeyRule(name: "Home → ⌘←", .shortcut(ShortcutRule(from: KeyCombo(key: "home"), anyModifiers: true, to: .key("left_arrow", .command)))),
                          KeyRule(name: "End → ⌘→", .shortcut(ShortcutRule(from: KeyCombo(key: "end"), anyModifiers: true, to: .key("right_arrow", .command))))]),
        KeyPreset(id: "iso-section", title: "§ → ` on ISO keyboards",
                  detail: "Puts backtick/tilde where ANSI keyboards have it.",
                  rules: [KeyRule(.remap(RemapRule(from: "non_us_backslash", to: "grave_accent_and_tilde")))]),
        KeyPreset(id: "hyper-terminal", title: "Hyper + T → open Terminal",
                  detail: "An example of opening an app from a shortcut; pair it with a Hyper key.",
                  rules: [KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "t", mods: .hyper),
                                                         to: .openApp("com.apple.Terminal", name: "Terminal"))))]),
        KeyPreset(id: "f-media", title: "F13 / F14 / F15 → volume keys",
                  detail: "Mute, volume down and volume up on the keys above the arrow cluster.",
                  rules: [KeyRule(.remap(RemapRule(from: "f13", to: "mute"))),
                          KeyRule(.remap(RemapRule(from: "f14", to: "volume_decrement"))),
                          KeyRule(.remap(RemapRule(from: "f15", to: "volume_increment")))]),
    ]
}
