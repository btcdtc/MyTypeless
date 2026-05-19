import AppKit
import SwiftUI

/// LSUIElement=true (menu bar agent) apps don't get a working SwiftUI
/// `Settings` scene out of the box — the system selector `showSettingsWindow:`
/// fires but no window comes forward because the activation policy is
/// `.accessory`. We own the window directly in AppKit instead, briefly flip
/// activation to `.regular` so it can focus normally, and flip back when the
/// user closes it. The actual UI is still our existing SwiftUI `SettingsView`
/// hosted via `NSHostingView`.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    init(dictionary: UserDictionaryStore) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Typeforme Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("TypeformeSettingsWindow")

        let hosting = NSHostingView(rootView: SettingsView(dictionary: dictionary))
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting

        super.init()
        window.delegate = self
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Defer so the close animation finishes before we drop back to
        // accessory — otherwise the window appears to "snap" away.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
