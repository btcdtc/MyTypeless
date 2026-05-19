import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Default combo for the dictation hotkey. Spec §8 prefers Fn / Right-Option
    /// hold; we ship Cmd+Shift+Space as a safe combo default and will add the
    /// modifier-only variant in a later phase via NSEvent monitoring.
    static let toggleDictation = Self(
        "toggleDictation",
        default: .init(.space, modifiers: [.command, .shift])
    )

    static let commandTextEdit = Self(
        "commandTextEdit",
        default: .init(.space, modifiers: [.command, .option])
    )
}

@MainActor
final class HotkeyManager {
    private let name: KeyboardShortcuts.Name
    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?

    init(name: KeyboardShortcuts.Name = .toggleDictation) {
        self.name = name
    }

    func install() {
        KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
            Log.hotkey.debug("dictation hotkey down")
            self?.onPressed?()
        }
        KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
            Log.hotkey.debug("dictation hotkey up")
            self?.onReleased?()
        }
    }
}
