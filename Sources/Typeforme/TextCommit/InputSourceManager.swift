import Foundation
import Carbon

/// Save / restore / switch the active keyboard input source (spec §21).
/// If the user is in a CJK IME at insertion time, Cmd+V would route through
/// the IME and produce garbled output — we switch to ASCII before pasting,
/// then restore.
@MainActor
enum InputSourceManager {
    static func current() -> TISInputSource? {
        guard let unmanaged = TISCopyCurrentKeyboardInputSource() else { return nil }
        return unmanaged.takeRetainedValue()
    }

    @discardableResult
    static func select(_ source: TISInputSource) -> Bool {
        TISSelectInputSource(source) == noErr
    }

    /// Switches to an ASCII-capable input source if the current one is not.
    /// Returns the previous source so the caller can restore it.
    static func switchToASCIIIfNeeded() -> TISInputSource? {
        guard let current = current() else { return nil }
        if isASCIICapable(current) { return nil }
        guard let ascii = findEnabledASCIISource(preferEnglish: true) else { return nil }
        return select(ascii) ? current : nil
    }

    // MARK: - Properties

    static func isASCIICapable(_ source: TISInputSource) -> Bool {
        cfBool(source, key: kTISPropertyInputSourceIsASCIICapable)
    }

    private static func isEnabled(_ source: TISInputSource) -> Bool {
        cfBool(source, key: kTISPropertyInputSourceIsEnabled)
    }

    private static func languages(_ source: TISInputSource) -> [String] {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        let cf = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue()
        return (cf as? [String]) ?? []
    }

    private static func cfBool(_ source: TISInputSource, key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        let cf = Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()
        return CFBooleanGetValue(cf)
    }

    private static func findEnabledASCIISource(preferEnglish: Bool) -> TISInputSource? {
        let conditions: [CFString: Any] = [
            kTISPropertyInputSourceIsASCIICapable: kCFBooleanTrue!,
        ]
        guard let unmanagedList = TISCreateInputSourceList(conditions as CFDictionary, false) else {
            return nil
        }
        guard let arr = unmanagedList.takeRetainedValue() as? [TISInputSource] else { return nil }

        if preferEnglish {
            for s in arr where isEnabled(s) && languages(s).contains(where: { $0.hasPrefix("en") }) {
                return s
            }
        }
        return arr.first(where: { isEnabled($0) })
    }
}
