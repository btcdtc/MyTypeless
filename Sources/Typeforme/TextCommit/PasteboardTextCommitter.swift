import AppKit
import Carbon

/// Spec §21 flow:
///   save input source → switch CJK→ASCII if needed → write text to
///   pasteboard → refocus target → Cmd+V → restore input source.
///
/// The corrected text intentionally remains on the pasteboard. If the target
/// app has no focused text field, the synthetic paste may go nowhere; keeping
/// the text on the pasteboard gives the user a reliable manual Cmd+V path.
@MainActor
final class PasteboardTextCommitter: TextCommitter {
    private static let vKeyCode: CGKeyCode = 9  // kVK_ANSI_V

    static func copyForManualPaste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func commit(
        _ text: String,
        to snapshot: FrontmostAppSnapshot?,
        cancelToken: CommitCancellationToken?
    ) async throws {
        try await checkCancelled(cancelToken)

        let savedSource = InputSourceManager.current()
        let switched = InputSourceManager.switchToASCIIIfNeeded()

        defer {
            if switched != nil, let savedSource {
                _ = InputSourceManager.select(savedSource)
            }
        }

        Self.copyForManualPaste(text)
        try await checkCancelled(cancelToken)

        guard AccessibilityPermissions.isTrusted else {
            throw TextCommitterError.accessibilityNotTrusted
        }

        if let snapshot {
            await MainActor.run { FrontmostAppCapture.refocus(snapshot) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try await checkCancelled(cancelToken)

        try sendCommandV()
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    func commitTextEdit(
        _ text: String,
        target: TextEditTargetSnapshot,
        appSnapshot: FrontmostAppSnapshot?,
        cancelToken: CommitCancellationToken?
    ) async throws {
        try await checkCancelled(cancelToken)
        Self.copyForManualPaste(text)

        guard AccessibilityPermissions.isTrusted else {
            throw TextCommitterError.accessibilityNotTrusted
        }

        if let appSnapshot {
            await MainActor.run { FrontmostAppCapture.refocus(appSnapshot) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try await checkCancelled(cancelToken)

        switch target.kind {
        case .selection:
            let current = TextEditTargetCapture.currentSelectedText(in: appSnapshot) ?? ""
            guard current == target.targetText else {
                throw TextCommitterError.selectionChanged
            }
            try sendCommandV()
            try? await Task.sleep(nanoseconds: 120_000_000)
        case .focusedValue:
            let current = TextEditTargetCapture.currentValue(of: target) ?? ""
            guard current == target.targetText else {
                throw TextCommitterError.selectionChanged
            }
            guard TextEditTargetCapture.setFocusedValue(text, target: target) else {
                throw TextCommitterError.eventPostFailed
            }
        }
    }

    // MARK: - Synthetic Cmd+V

    private func sendCommandV() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw TextCommitterError.eventSourceFailed
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false)
        else {
            throw TextCommitterError.eventPostFailed
        }
        down.flags = .maskCommand
        up.flags   = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func checkCancelled(_ token: CommitCancellationToken?) async throws {
        if Task.isCancelled {
            throw TextCommitterError.cancelled
        }
        if let token, await token.isCancelled() {
            throw TextCommitterError.cancelled
        }
    }
}
