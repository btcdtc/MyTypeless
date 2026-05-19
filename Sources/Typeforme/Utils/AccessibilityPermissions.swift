import AppKit
import ApplicationServices

/// Spec §4: Accessibility permission is required for synthesized Cmd+V paste.
enum AccessibilityPermissions {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Deep-link straight to System Settings → Privacy → Accessibility. More
    /// reliable than `AXIsProcessTrustedWithOptions(prompt: true)`, which
    /// sometimes silently records a "denied" entry the user then has to
    /// reset via tccutil.
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Wipe the Accessibility TCC entry for this bundle id. Useful when an
    /// older signature of the app left a stale "Not granted" record that
    /// won't go away no matter how many times the user toggles the switch.
    /// (Common with adhoc-signed local builds where each rebuild has a
    /// different code-signing hash.)
    ///
    /// IMPORTANT: `tccutil reset` only deletes the record — it does NOT
    /// register the app in the Accessibility list. The list stays empty
    /// for our bundle until the app actually touches an AX API. Callers
    /// should run `requestTrustPrompt()` right after to (re-)register.
    @discardableResult
    static func resetGrant() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.btcdtc.typeforme.mac"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", bundleID]
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Tell TCC to (re-)register this app under Accessibility. macOS shows
    /// its standard "Typeforme would like to control this computer using
    /// accessibility features" dialog with an "Open System Settings" button,
    /// and the app appears in Privacy → Accessibility (unchecked) so the
    /// user has something to toggle.
    static func requestTrustPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
