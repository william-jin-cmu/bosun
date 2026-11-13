import Foundation

/// The event-tap logic with no tap attached: given one key event and the keys
/// currently held as rewritten, decide what the event should become.
enum KeyRewriter {
    enum Kind { case keyDown, keyUp, flagsChanged }

    struct Config: Equatable {
        var layers: [LayerRule] = []
        /// Strip the hold modifier, so Caps+W is Up rather than Control+Up.
        var plainArrows = false
    }

    /// Physical keys whose key-down was rewritten and that are still down.
    struct State: Equatable {
        struct Held: Equatable {
            var target: UInt16
            var layer: LayerRule
        }
        var held: [UInt16: Held] = [:]
    }

    struct Output: Equatable {
        var keycode: UInt16
        var flags: UInt64
    }

    static func rewrite(kind: Kind, keycode: UInt16, flags: UInt64, isRepeat: Bool = false,
                        config: Config, state: inout State) -> Output {
        let unchanged = Output(keycode: keycode, flags: flags)
        switch kind {
        case .flagsChanged:
            return unchanged

        case .keyDown:
            if isRepeat {
                // A repeat follows whatever its first key-down did, even if the
                // hold key was pressed or released since.
                guard let held = state.held[keycode] else { return unchanged }
                return Output(keycode: held.target, flags: outFlags(flags, held.layer, config))
            }
            // A fresh press decides anew; this also drops an entry left behind
            // by a key-up the tap never saw.
            state.held[keycode] = nil
            for layer in config.layers where flags & layer.holdFlag != 0 {
                guard let key = layer.keys.first(where: { $0.from == keycode }) else { continue }
                state.held[keycode] = State.Held(target: key.to, layer: layer)
                return Output(keycode: key.to, flags: outFlags(flags, layer, config))
            }
            return unchanged

        case .keyUp:
            guard let held = state.held.removeValue(forKey: keycode) else { return unchanged }
            return Output(keycode: held.target, flags: outFlags(flags, held.layer, config))
        }
    }

    private static func outFlags(_ flags: UInt64, _ layer: LayerRule, _ config: Config) -> UInt64 {
        var out = flags | layer.addFlags
        if config.plainArrows {
            out &= ~layer.holdFlag
            if out & layer.holdTwinFlag == 0 { out &= ~layer.holdModifier }
        }
        return out
    }
}
