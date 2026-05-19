import SwiftUI

@main
struct TypeformeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        CommandLineHandler.exitIfHandled()
    }

    var body: some Scene {
        // Native SwiftUI menu-bar item (macOS 13+). Replaces the AppKit
        // NSStatusItem + NSMenu boilerplate; the label re-renders when
        // coordinator state changes thanks to @ObservedObject, the
        // "Always show HUD" toggle is bound via @AppStorage and stays in
        // sync with Settings → Recording.
        MenuBarExtra {
            MenuBarMenu(onOpenSettings: { appDelegate.openSettings() })
        } label: {
            MenuBarLabel(coordinator: appDelegate.coordinator)
        }
    }
}
