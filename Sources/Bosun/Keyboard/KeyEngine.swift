import Foundation

/// The tap-level rules with no event tap attached: one input event in, the
/// events that should exist instead out. Everything stateful about a press
/// (what its key-down turned into, which hold keys are down and since when)
/// lives in `State`, so the whole thing can be checked headlessly.
enum KeyEngine {
    enum Action: Equatable {
        case key(UInt16, Mods)
        case app(String)
        /// What Caps Lock itself does (the tap works out lock vs. input source).
        case capsLock
    }

    struct Shortcut: Equatable {
        var ruleID: String
        var keycode: UInt16
        var mods: Mods
        var anyMods: Bool
        var action: Action
        var apps = AppFilter()
    }

    struct Mapping: Equatable {
        var keycode: UInt16
        var mods: Mods
        var action: Action
    }

    struct Hold: Equatable {
        var ruleID: String
        var trigger: UInt16
        /// Set when the trigger is a modifier key: it arrives as `flagsChanged`,
        /// is never swallowed, and keeps being that modifier.
        var modifier: KeyCatalog.ModifierKey?
        /// Modifiers added to events while held (beyond a modifier trigger's own).
        var injected: Mods = []
        var tap: Action?
        var mappings: [Mapping] = []
        var holdAfterThreshold = false
        var thresholdMs: UInt64 = 300
        var apps = AppFilter()
    }

    struct Config: Equatable {
        var shortcuts: [Shortcut] = []
        var holds: [Hold] = []
        var isEmpty: Bool { shortcuts.isEmpty && holds.isEmpty }
    }

    struct Input {
        enum Kind { case keyDown, keyUp, flagsChanged, mouseDown, mouseUp }
        var kind: Kind
        var keycode: UInt16 = 0
        var flags: UInt64
        var isRepeat = false
        var timeMs: UInt64
        var app: String?
    }

    enum Output: Equatable {
        /// Let the input event through, with these flags.
        case original(flags: UInt64)
        case key(down: Bool, keycode: UInt16, isRepeat: Bool, flags: UInt64)
        case launch(String)
        /// Caps Lock's own function; `long` when the key was held alone past the threshold.
        case capsLock(long: Bool)
    }

    struct State: Equatable {
        /// What the key-down of a physical key that is still down turned into.
        enum Press: Equatable {
            case swallowed
            case key(target: UInt16, remove: Mods, add: Mods)
        }
        enum Phase: Equatable {
            case pending    // hold-after-threshold key, not yet decided
            case hold
            case tapped     // already resolved as a tap; waiting for its key-up
        }
        struct Active: Equatable {
            var index: Int          // into Config.holds
            var downAt: UInt64
            var used = false        // another key or click happened while held
            var phase: Phase
        }
        var pressed: [UInt16: Press] = [:]
        var holds: [Active] = []

        var isIdle: Bool { pressed.isEmpty && holds.isEmpty }
    }

    // MARK: Entry points

    static func process(_ event: Input, config: Config, state: inout State) -> [Output] {
        // A hold-after-threshold key that has been down long enough is a hold.
        for index in state.holds.indices where state.holds[index].phase == .pending {
            let hold = config.holds[state.holds[index].index]
            if event.timeMs &- state.holds[index].downAt >= hold.thresholdMs { state.holds[index].phase = .hold }
        }
        switch event.kind {
        case .flagsChanged: return flagsChanged(event, config, &state)
        case .keyDown: return event.isRepeat ? keyRepeat(event, config, &state) : keyDown(event, config, &state)
        case .keyUp: return keyUp(event, config, &state)
        case .mouseDown:
            for index in state.holds.indices where state.holds[index].phase == .hold { state.holds[index].used = true }
            return [.original(flags: passFlags(event.flags, config, state))]
        case .mouseUp:
            return [.original(flags: passFlags(event.flags, config, state))]
        }
    }

    /// Regular-key triggers currently held, for the tap to cross-check against
    /// the real keyboard state.
    static func heldTriggers(config: Config, state: State) -> [UInt16] {
        state.holds.compactMap { config.holds[$0.index].modifier == nil ? config.holds[$0.index].trigger : nil }
    }

    /// Drops a hold whose key-up never arrived, without firing its tap action.
    static func forget(trigger: UInt16, config: Config, state: inout State) {
        state.holds.removeAll { config.holds[$0.index].modifier == nil && config.holds[$0.index].trigger == trigger }
        state.pressed[trigger] = nil
    }

    // MARK: Key events

    private static func keyDown(_ event: Input, _ config: Config, _ state: inout State) -> [Output] {
        let key = event.keycode, flags = event.flags
        dropStaleModifierHolds(flags, config, &state)
        // A fresh press decides anew; this also clears whatever a key-up the
        // tap never saw left behind.
        state.pressed[key] = nil
        state.holds.removeAll { config.holds[$0.index].modifier == nil && config.holds[$0.index].trigger == key }

        var out: [Output] = []
        // Rollover: another key before the threshold means the pending key was typed.
        for index in state.holds.indices where state.holds[index].phase == .pending {
            state.holds[index].phase = .tapped
            out += tapOutputs(config.holds[state.holds[index].index], flags, source: key, config, state)
        }
        for index in state.holds.indices where state.holds[index].phase == .hold { state.holds[index].used = true }

        // 1. Layers, the most recently pressed hold key first.
        let current = Mods(flags: flags).union(injected(config, state))
        for active in state.holds.reversed() where active.phase == .hold {
            let hold = config.holds[active.index]
            let own = ownMods(hold, flags)
            let visible = current.subtracting(own)
            let hit = hold.mappings
                .filter { $0.keycode == key && visible.isSuperset(of: $0.mods) }
                .max { $0.mods.count < $1.mods.count }
            guard let hit else { continue }
            let remove = hit.mods.union(own)
            return out + perform(hit.action, key: key, flags: flags, remove: remove, config, &state)
        }

        // 2. Hold keys.
        if let index = config.holds.firstIndex(where: { $0.modifier == nil && $0.trigger == key && $0.apps.allows(event.app) }) {
            state.holds.append(.init(index: index, downAt: event.timeMs,
                                     phase: config.holds[index].holdAfterThreshold ? .pending : .hold))
            state.pressed[key] = .swallowed
            return out
        }

        // 3. Shortcuts, in the user's order.
        for shortcut in config.shortcuts where shortcut.keycode == key {
            guard shortcut.anyMods ? current.isSuperset(of: shortcut.mods) : current == shortcut.mods,
                  shortcut.apps.allows(event.app) else { continue }
            return out + perform(shortcut.action, key: key, flags: flags, remove: shortcut.mods, config, &state)
        }

        return out + [.original(flags: passFlags(flags, config, state))]
    }

    private static func keyRepeat(_ event: Input, _ config: Config, _ state: inout State) -> [Output] {
        dropStaleModifierHolds(event.flags, config, &state)
        // A repeat follows whatever its first key-down did, whatever changed since.
        switch state.pressed[event.keycode] {
        case .swallowed:
            return []
        case .key(let target, let remove, let add):
            return [.key(down: true, keycode: target, isRepeat: true,
                         flags: keyFlags(event.flags, from: event.keycode, to: target, remove: remove, add: add, config, state))]
        case nil:
            return [.original(flags: passFlags(event.flags, config, state))]
        }
    }

    private static func keyUp(_ event: Input, _ config: Config, _ state: inout State) -> [Output] {
        let key = event.keycode
        dropStaleModifierHolds(event.flags, config, &state)
        if let position = state.holds.firstIndex(where: {
            config.holds[$0.index].modifier == nil && config.holds[$0.index].trigger == key
        }) {
            let active = state.holds.remove(at: position)
            let hold = config.holds[active.index]
            state.pressed[key] = nil
            switch active.phase {
            case .pending:
                return tapOutputs(hold, event.flags, source: key, config, state)
            case .hold:
                guard !hold.holdAfterThreshold, !active.used else { return [] }
                if event.timeMs &- active.downAt <= hold.thresholdMs {
                    return tapOutputs(hold, event.flags, source: key, config, state)
                }
                return hold.tap == .capsLock ? [.capsLock(long: true)] : []
            case .tapped:
                return []
            }
        }
        switch state.pressed.removeValue(forKey: key) {
        case .swallowed:
            return []
        case .key(let target, let remove, let add):
            return [.key(down: false, keycode: target, isRepeat: false,
                         flags: keyFlags(event.flags, from: key, to: target, remove: remove, add: add, config, state))]
        case nil:
            return [.original(flags: passFlags(event.flags, config, state))]
        }
    }

    private static func flagsChanged(_ event: Input, _ config: Config, _ state: inout State) -> [Output] {
        let flags = event.flags
        var tap: [Output] = []
        // Releases: a modifier hold whose own bit is gone has ended, whether or
        // not this is the event that says so.
        var kept: [State.Active] = []
        var released: [State.Active] = []
        for active in state.holds {
            let hold = config.holds[active.index]
            if let modifier = hold.modifier, flags & modifier.downBit == 0,
               !modifier.mod.isEmpty || hold.trigger == event.keycode {
                released.append(active)
            } else {
                kept.append(active)
            }
        }
        state.holds = kept
        for active in released {
            let hold = config.holds[active.index]
            if hold.trigger == event.keycode, !active.used, event.timeMs &- active.downAt <= hold.thresholdMs {
                tap += tapOutputs(hold, flags, source: nil, config, state)
            }
        }
        // Press of a modifier key.
        if let modifier = KeyCatalog.modifierKey(keycode: event.keycode), flags & modifier.downBit != 0,
           !state.holds.contains(where: { config.holds[$0.index].modifier != nil && config.holds[$0.index].trigger == event.keycode }) {
            for index in state.holds.indices where state.holds[index].phase == .hold { state.holds[index].used = true }
            if let index = config.holds.firstIndex(where: {
                $0.modifier != nil && $0.trigger == event.keycode && $0.apps.allows(event.app)
            }) {
                state.holds.append(.init(index: index, downAt: event.timeMs, phase: .hold))
            }
        }
        return [.original(flags: passFlags(flags, config, state))] + tap
    }

    // MARK: Pieces

    private static func perform(_ action: Action, key: UInt16, flags: UInt64, remove: Mods,
                                _ config: Config, _ state: inout State) -> [Output] {
        switch action {
        case .app(let bundleID):
            state.pressed[key] = .swallowed
            return [.launch(bundleID)]
        case .capsLock:
            state.pressed[key] = .swallowed
            return [.capsLock(long: false)]
        case .key(let target, let add):
            state.pressed[key] = .key(target: target, remove: remove, add: add)
            return [.key(down: true, keycode: target, isRepeat: false,
                         flags: keyFlags(flags, from: key, to: target, remove: remove, add: add, config, state))]
        }
    }

    /// Modifiers currently injected by held keys.
    private static func injected(_ config: Config, _ state: State) -> Mods {
        state.holds.reduce(into: Mods()) { mods, active in
            if active.phase == .hold { mods.formUnion(config.holds[active.index].injected) }
        }
    }

    /// The modifiers a hold contributes itself. Its layer disregards them when
    /// matching and leaves them off its output (a layer's output modifiers are
    /// spelled out in the rule) — unless the user really holds them as well.
    private static func ownMods(_ hold: Hold, _ flags: UInt64) -> Mods {
        var own = hold.injected.subtracting(Mods(flags: flags))
        if let modifier = hold.modifier, let info = Mods.all.first(where: { $0.mod == modifier.mod }) {
            let twin = (info.leftBit | info.rightBit) & ~modifier.downBit
            if flags & twin == 0 { own.insert(modifier.mod) }
        }
        return own
    }

    private static func passFlags(_ flags: UInt64, _ config: Config, _ state: State) -> UInt64 {
        let add = injected(config, state)
        let have = Mods(flags: flags)
        return have.isSuperset(of: add) ? flags : have.union(add).applied(to: flags)
    }

    private static func keyFlags(_ flags: UInt64, from source: UInt16?, to target: UInt16, remove: Mods, add: Mods,
                                 _ config: Config, _ state: State) -> UInt64 {
        let mods = Mods(flags: flags).union(injected(config, state)).subtracting(remove).union(add)
        let sourceFlags = source.map(KeyCatalog.intrinsicFlags(keycode:)) ?? 0
        return mods.applied(to: (flags & ~sourceFlags) | KeyCatalog.intrinsicFlags(keycode: target))
    }

    private static func tapOutputs(_ hold: Hold, _ flags: UInt64, source: UInt16?,
                                   _ config: Config, _ state: State) -> [Output] {
        switch hold.tap {
        case nil:
            return []
        case .app(let bundleID):
            return [.launch(bundleID)]
        case .capsLock:
            return [.capsLock(long: false)]
        case .key(let target, let add):
            let out = keyFlags(flags, from: source, to: target, remove: [], add: add, config, state)
            return [.key(down: true, keycode: target, isRepeat: false, flags: out),
                    .key(down: false, keycode: target, isRepeat: false, flags: out)]
        }
    }

    /// A modifier hold whose bit is missing from a key event lost its release.
    private static func dropStaleModifierHolds(_ flags: UInt64, _ config: Config, _ state: inout State) {
        state.holds.removeAll {
            guard let modifier = config.holds[$0.index].modifier, !modifier.mod.isEmpty else { return false }
            return flags & modifier.downBit == 0
        }
    }
}
