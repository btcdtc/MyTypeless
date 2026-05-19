import AppKit
import Combine
import SwiftUI

/// Owns the HUD panel: placement, adaptive width per state, and the
/// show/hide animation.
@MainActor
final class HUDWindowController {
    private let panel: HUDPanel
    private let coordinator: DictationCoordinator
    private var stateSub: AnyCancellable?
    private var moveObserver: NSObjectProtocol?
    /// Locks the panel at preview width across the preview→correcting→preview
    /// round-trip that a chip click triggers — otherwise the HUD shrinks to
    /// "correcting" width and bounces back, which is what made the preview
    /// chip row feel frantic.
    private var holdAtPreviewWidth = false
    /// AppDelegate calls `show()` on every non-idle state change. We must not
    /// re-run the entrance animation each time — that resets the panel frame
    /// and clobbers the in-flight width animation from `applyWidth`. Track
    /// shown-ness explicitly so `show()` becomes a true no-op once visible.
    private var isShown = false
    /// User-anchored bottom-center of the panel. The HUD grows UPWARD from
    /// this point as state changes, so the bottom edge stays put and never
    /// flies off the bottom of the screen when the preview wraps to multiple
    /// lines. `nil` until the user drags — then we use the default position.
    private var anchorBottomCenter: NSPoint?
    /// Set while we're moving the panel ourselves (entrance / width change);
    /// suppresses the user-drag observer so we don't treat it as a manual move.
    private var isProgrammaticallyMoving = false

    private static let compactHeight: CGFloat = 52
    private static let previewMaxHeight: CGFloat = 420
    private static let previewWidth: CGFloat = 620
    private static let bottomMargin: CGFloat = 80
    private static let entranceLift: CGFloat = 14
    private static let edgePadding: CGFloat = 8
    /// Chrome around the preview text inside the panel:
    ///   top padding (14) + bottom padding (6) + VStack spacing (20) + chip row (~28) + small safety buffer (4).
    /// Matches `HUDView.expandedPreviewBody`'s natural height exactly.
    private static let previewChromeHeight: CGFloat = 14 + 6 + 20 + 28 + 4
    /// The anchor `y` is the BOTTOM edge of the panel. Persisted to disk in
    /// this key; older builds wrote the panel center, but bottom-anchoring
    /// stops the HUD from sliding lower whenever the preview grows tall.
    private static let anchorXKey = "hud.anchor.bottomX"
    private static let anchorYKey = "hud.anchor.bottomY"

    /// Cached because we recompute it on every state / lastCorrected change
    /// and the SwiftUI font lookup is non-trivial.
    private static let previewMeasureFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        if let desc = base.fontDescriptor.withDesign(.rounded),
           let rounded = NSFont(descriptor: desc, size: 13.5) {
            return rounded
        }
        return base
    }()

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        self.panel = HUDPanel()
        let hosting = NSHostingView(rootView: HUDView(coordinator: coordinator))
        hosting.autoresizingMask = [.width, .height]
        // Empty sizing options: we explicitly do NOT want SwiftUI's preferred
        // content size to feed back into the hosting view's
        // intrinsicContentSize. Without this, the panel kept growing back to
        // SwiftUI's natural size a moment after our setFrame settled.
        hosting.sizingOptions = []
        // NSHostingView is layer-backed; the four corners outside the capsule
        // would otherwise paint an opaque white square that the system shadow
        // traces, producing a rectangular halo.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        panel.alphaValue = 0

        anchorBottomCenter = Self.loadAnchor()

        // Re-apply the frame whenever state OR the previewed text changes —
        // the latter so a re-correct that produces a longer/shorter result
        // grows or shrinks the panel to fit.
        stateSub = Publishers.CombineLatest(
            coordinator.$state.removeDuplicates(),
            coordinator.$lastCorrected.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] state, _ in
            self?.applyWidth(for: state, animated: true)
        }

        // The user dragged the HUD — persist the new center so it sticks
        // across width changes and across app launches.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleManualMove()
            }
        }
    }

    deinit {
        if let m = moveObserver {
            NotificationCenter.default.removeObserver(m)
        }
    }

    var isVisible: Bool { isShown }

    func show() {
        guard !isShown else { return }
        isShown = true
        let size = self.size(for: coordinator.state)
        let finalOrigin = originForAnchor(anchorOrDefault(), size: size)
        // Slide-up entrance: start a few points below the target and fade in.
        let startOrigin = NSPoint(x: finalOrigin.x, y: finalOrigin.y - Self.entranceLift)
        isProgrammaticallyMoving = true
        panel.setFrame(NSRect(origin: startOrigin, size: size), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(NSRect(origin: finalOrigin, size: size), display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.isProgrammaticallyMoving = false
            }
        })
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        holdAtPreviewWidth = false
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    /// Reset the HUD back to its default bottom-center anchor. Wired up
    /// via the menu bar when the user has dragged it somewhere unreachable.
    func resetAnchor() {
        anchorBottomCenter = nil
        UserDefaults.standard.removeObject(forKey: Self.anchorXKey)
        UserDefaults.standard.removeObject(forKey: Self.anchorYKey)
        if isShown {
            applyWidth(for: coordinator.state, animated: true)
        }
    }

    // MARK: - Adaptive width

    private func applyWidth(for state: DictationState, animated: Bool) {
        guard isShown else { return }

        // Re-correct latch: see the chip-click width-thrash bug for context.
        if state == .preview {
            holdAtPreviewWidth = true
        } else if state == .correcting && holdAtPreviewWidth {
            return
        } else {
            holdAtPreviewWidth = false
        }

        let size = self.size(for: state)
        let frame = NSRect(origin: originForAnchor(anchorOrDefault(), size: size), size: size)
        isProgrammaticallyMoving = true
        let release: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.isProgrammaticallyMoving = false
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: release)
        } else {
            panel.setFrame(frame, display: true)
            release()
        }
    }

    // MARK: - Anchor

    private func anchorOrDefault() -> NSPoint {
        anchorBottomCenter ?? Self.defaultAnchor()
    }

    /// Compute the panel origin so the panel's BOTTOM edge sits on `anchor.y`
    /// and is horizontally centered on `anchor.x`. The bottom is the fixed
    /// point: height changes grow the panel upward only, so the user's chip
    /// row never slides closer to (or below) the screen edge as text wraps.
    private func originForAnchor(_ anchor: NSPoint, size: NSSize) -> NSPoint {
        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let minX = visible.minX + Self.edgePadding
            let maxX = visible.maxX - size.width - Self.edgePadding
            let minY = visible.minY + Self.edgePadding
            let maxY = visible.maxY - size.height - Self.edgePadding
            if minX <= maxX { origin.x = max(minX, min(maxX, origin.x)) }
            if minY <= maxY { origin.y = max(minY, min(maxY, origin.y)) }
        }
        return origin
    }

    private static func defaultAnchor() -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let visible = screen.visibleFrame
        return NSPoint(x: visible.midX, y: visible.minY + bottomMargin)
    }

    private static func loadAnchor() -> NSPoint? {
        let ud = UserDefaults.standard
        guard ud.object(forKey: anchorXKey) != nil,
              ud.object(forKey: anchorYKey) != nil else { return nil }
        let p = NSPoint(x: ud.double(forKey: anchorXKey), y: ud.double(forKey: anchorYKey))
        // Reject anchors that aren't on any current screen (display unplugged
        // or resolution changed). The HUD falls back to default bottom anchor.
        guard NSScreen.screens.contains(where: { $0.frame.contains(p) }) else { return nil }
        return p
    }

    private func handleManualMove() {
        guard !isProgrammaticallyMoving else { return }
        let bottomCenter = NSPoint(x: panel.frame.midX, y: panel.frame.minY)
        anchorBottomCenter = bottomCenter
        let ud = UserDefaults.standard
        ud.set(Double(bottomCenter.x), forKey: Self.anchorXKey)
        ud.set(Double(bottomCenter.y), forKey: Self.anchorYKey)
    }

    /// Per-state target size. Preview height is `measuredTextHeight +
    /// previewChromeHeight` — sized to fit the SwiftUI VStack's natural
    /// height exactly, so no Spacer ends up growing to fill leftover space
    /// inside the HUD. Capped at `previewMaxHeight` so a 5-minute monologue
    /// can't paint over the entire screen.
    private func size(for state: DictationState) -> NSSize {
        switch state {
        case .preview:
            return previewSize()
        case .correcting where !coordinator.lastCorrected.isEmpty:
            return previewSize()
        default:
            return NSSize(width: Self.width(for: state), height: Self.compactHeight)
        }
    }

    private func previewSize() -> NSSize {
        // Trim mirrors HUDView.previewText. The corrector occasionally
        // emits trailing whitespace / newlines that SwiftUI's Text drops
        // visually, but `NSString.boundingRect` would count them as full
        // lines — left untreated, that's how a short preview ends up in
        // a 200pt-tall panel with empty material below the chips.
        let raw = coordinator.lastCorrected.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = raw.isEmpty ? "Preview" : raw
        let textHeight = Self.measuredTextHeight(for: text, inWidth: Self.previewWidth - 36)
        let height = min(textHeight + Self.previewChromeHeight, Self.previewMaxHeight)
        return NSSize(width: Self.previewWidth, height: height)
    }

    private static func measuredTextHeight(for text: String, inWidth width: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: previewMeasureFont]
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return ceil(bounds.height)
    }

    private static func width(for state: DictationState) -> CGFloat {
        switch state {
        case .idle:                          return 320
        case .recording:                     return 380
        case .transcribing, .correcting:     return 320
        case .preview:                       return previewWidth
        case .inserting:                     return 280
        case .success:                       return 220
        case .error:                         return 400
        }
    }
}
