import AppKit

/// Snapshot of the frontmost app at recording-start, so we can refocus it
/// before inserting text (spec §9, §21).
struct FrontmostAppSnapshot: Sendable, Equatable {
    let pid: pid_t
    let bundleID: String?
    let localizedName: String?
}

enum FrontmostAppCapture {
    @MainActor
    static func snapshot() -> FrontmostAppSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostAppSnapshot(
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            localizedName: app.localizedName
        )
    }

    @MainActor
    static func refocus(_ snapshot: FrontmostAppSnapshot) {
        guard let app = NSRunningApplication(processIdentifier: snapshot.pid) else { return }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
