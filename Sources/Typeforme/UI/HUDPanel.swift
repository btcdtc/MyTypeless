import AppKit

/// Frameless, non-activating panel per spec §9. Showing this panel must not
/// steal focus from the user's current app.
final class HUDPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Drag the capsule by its empty areas (padding around icon, between
        // chips, etc.). SwiftUI Buttons inside still receive their own clicks
        // — AppKit only initiates the drag when the click lands on the
        // panel's chrome, not on a hit-tested control.
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        // Defensive: macOS will silently refuse `setFrame` calls that go
        // below these floors. SwiftUI hosting views sometimes nudge them up.
        contentMinSize = .zero
        minSize = .zero
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
