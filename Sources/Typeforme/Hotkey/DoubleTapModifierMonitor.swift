import AppKit
import Foundation

/// One of the dedicated modifier keys we let the user pick for double-tap-hold
/// dictation. Maps to a device-specific bit in NSEvent.modifierFlags so we can
/// distinguish Right ⌥ from Left ⌥ etc.
enum HoldModifier: String, CaseIterable, Identifiable, Codable, Sendable {
    case none           = "none"
    case rightOption    = "right-option"
    case rightCommand   = "right-command"
    case rightShift     = "right-shift"
    case rightControl   = "right-control"
    case leftOption     = "left-option"
    case fn             = "fn"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:         return "Off"
        case .rightOption:  return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        case .rightShift:   return "Right ⇧ Shift"
        case .rightControl: return "Right ⌃ Control"
        case .leftOption:   return "Left ⌥ Option"
        case .fn:           return "Fn (Globe)"
        }
    }

    /// Device-private modifier flag bits (NX_DEVICE…KEYMASK). NSEvent's
    /// `.modifierFlags` reports these on top of the public `option/command/
    /// shift/control/function` bits, which is how we tell left from right.
    fileprivate var deviceFlagMask: UInt {
        switch self {
        case .none:         return 0
        case .leftOption:   return 0x20    // NX_DEVICELALTKEYMASK
        case .rightOption:  return 0x40    // NX_DEVICERALTKEYMASK
        case .rightCommand: return 0x10    // NX_DEVICERCMDKEYMASK
        case .rightShift:   return 0x04    // NX_DEVICERSHIFTKEYMASK
        case .rightControl: return 0x2000  // NX_DEVICERCTLKEYMASK
        case .fn:           return 0x800000 // NX_SECONDARYFNMASK / cgEventFlagMaskSecondaryFn
        }
    }
}

/// Watches one modifier key globally and detects "double-tap-and-hold" — the
/// idiom used by macOS Dictation, Wispr Flow, SuperWhisper, etc.: tap once,
/// release, tap again and HOLD. Holding triggers `onHoldStart`; releasing the
/// modifier on the second press fires `onHoldEnd`.
///
/// Coexists with HotkeyManager (combo → toggle); both can be active so the
/// user picks whichever feels natural at the moment.
@MainActor
final class DoubleTapModifierMonitor {
    /// Max gap between the first release and the second press to count as a
    /// double-tap. macOS Dictation uses ~250–300ms.
    private static let doubleTapWindow: TimeInterval = 0.3
    /// Avoid firing on a quick second tap; the second press must be held briefly.
    private static let holdStartDelay: UInt64 = 90_000_000

    private var monitor: Any?
    private var modifier: HoldModifier = .none
    private var lastReleaseAt: Date?
    private var wasPressed = false
    private var isHolding = false
    private var pendingHoldTask: Task<Void, Never>?

    var onHoldStart: (() -> Void)?
    var onHoldEnd:   (() -> Void)?

    func install(modifier: HoldModifier) {
        uninstall()
        self.modifier = modifier
        guard modifier != .none else { return }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Global monitor callbacks aren't main-actor-isolated; bounce back.
            Task { @MainActor in self?.handle(event) }
        }
        Log.hotkey.info("double-tap monitor installed for \(modifier.rawValue, privacy: .public)")
    }

    func uninstall() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        pendingHoldTask?.cancel()
        pendingHoldTask = nil
        if isHolding {
            isHolding = false
            onHoldEnd?()
        }
        wasPressed = false
        lastReleaseAt = nil
    }

    private func handle(_ event: NSEvent) {
        let mask = modifier.deviceFlagMask
        guard mask != 0 else { return }

        let pressedNow = (event.modifierFlags.rawValue & mask) != 0

        if pressedNow && !wasPressed {
            // Key went down.
            let now = Date()
            if let last = lastReleaseAt, now.timeIntervalSince(last) < Self.doubleTapWindow {
                // Second press within the double-tap window. Start only if the
                // user keeps holding for a short moment; this filters accidental
                // double taps that would otherwise create empty recordings.
                lastReleaseAt = nil
                pendingHoldTask?.cancel()
                pendingHoldTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: Self.holdStartDelay)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self, self.wasPressed, !self.isHolding else { return }
                        self.isHolding = true
                        self.onHoldStart?()
                    }
                }
            }
            // First press: do nothing yet; we record the time on release.
        } else if !pressedNow && wasPressed {
            // Key released.
            pendingHoldTask?.cancel()
            pendingHoldTask = nil
            if isHolding {
                isHolding = false
                lastReleaseAt = nil
                onHoldEnd?()
            } else {
                lastReleaseAt = Date()
            }
        }
        wasPressed = pressedNow
    }
}
