import SwiftUI
import KeyboardShortcuts

/// Bottom-centered glass capsule HUD.
///
/// Visual targets:
/// - ultraThinMaterial surface with a thin hairline border (cleaner edge than
///   the old `.thickMaterial` capsule which melted into the background)
/// - state-tinted leading indicator (red while recording, green on success, …)
/// - rich 20-bar waveform during recording, plus a pulsing dot + elapsed timer
/// - inline preview text with readable correction mode chips
struct HUDView: View {
    @ObservedObject var coordinator: DictationCoordinator
    @State private var recordingStartedAt: Date?

    private static let cornerRadius: CGFloat = 24

    /// Preview state lays out as two rows: full-width wrapped text on top so
    /// the user can actually verify what's about to be inserted, then chips
    /// + Insert on the bottom. Other states stay as a single 52pt-tall row.
    private var isExpandedPreview: Bool {
        coordinator.state == .preview ||
            (coordinator.state == .correcting && !coordinator.lastCorrected.isEmpty)
    }

    var body: some View {
        // ZStack so the surface ALWAYS fills the panel — `.background(surface)`
        // on a Group only paints behind the content's natural size, which left
        // the rest of a tall preview panel transparent (desktop showing
        // through).
        ZStack(alignment: .topLeading) {
            surface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isExpandedPreview {
                expandedPreviewBody
            } else {
                compactBody
            }
        }
        .onChange(of: coordinator.state) { _, newState in
            if newState == .recording {
                recordingStartedAt = Date()
            }
        }
    }

    private var compactBody: some View {
        HStack(spacing: 12) {
            leadingArea
            centerArea
            trailingArea
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var expandedPreviewBody: some View {
        // Natural sizing only — no .frame(maxHeight: .infinity) here. With
        // `maxHeight: .infinity`, SwiftUI advertises infinity as its desired
        // height, which NSHostingView then propagated back to the panel as
        // an intrinsic content size, growing the panel a few moments after
        // our setFrame settled.
        VStack(alignment: .leading, spacing: 20) {
            // Top: full preview text — no line limit, no truncation.
            Text(previewText)
                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            // Bottom: tone chips on the left, primary commit on the right.
            HStack(spacing: 8) {
                ModeChipRow(coordinator: coordinator, disabled: coordinator.state == .correcting)
                Spacer(minLength: 8)
                InsertButton {
                    Task { await coordinator.commitPreview() }
                }
                .disabled(coordinator.state == .correcting)
                .opacity(coordinator.state == .correcting ? 0.55 : 1.0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var previewText: String {
        let trimmed = coordinator.lastCorrected.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Preview" : trimmed
    }

    // MARK: - Surface

    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return shape
            .fill(.ultraThinMaterial)
            .overlay(
                // State-coloured glow along the top edge, fades into the body.
                shape
                    .strokeBorder(stateColor.opacity(0.35), lineWidth: 0.8)
                    .mask(
                        LinearGradient(
                            colors: [.black, .black.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .opacity(stateColor == .clear ? 0 : 1)
            )
            .overlay(
                // Hairline border so the capsule has a defined edge in any bg.
                shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
    }

    // MARK: - Leading (icon / waveform / recording dot)

    @ViewBuilder
    private var leadingArea: some View {
        switch coordinator.state {
        case .recording:
            HStack(spacing: 8) {
                RecordingDot()
                WaveformView(level: coordinator.audioLevel, state: .recording)
                    .frame(height: 30)
            }
        case .transcribing, .correcting, .inserting:
            ProcessingIndicator(symbol: iconSymbol, tint: stateColor)
        default:
            Image(systemName: iconSymbol)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(stateColor == .clear ? Color.accentColor : stateColor)
                .frame(width: 22, height: 22)
                .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - Center (status text / preview text)

    private var centerArea: some View {
        Text(statusText)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(coordinator.state == .preview ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.15), value: coordinator.state)
    }

    // MARK: - Trailing (timer / nothing in compact body)
    //
    // Chips live in the expanded preview layout, not here. The compact body
    // is for states without a preview to show (idle / recording / first-time
    // transcribing / inserting / success / error).

    @ViewBuilder
    private var trailingArea: some View {
        if coordinator.state == .recording, let startedAt = recordingStartedAt {
            TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
                Text(elapsedString(from: startedAt, to: context.date))
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - State helpers

    private var iconSymbol: String {
        switch coordinator.state {
        case .idle:         return "mic"
        case .transcribing: return "waveform"
        case .correcting:   return "sparkles"
        case .preview:      return "text.bubble.fill"
        case .inserting:    return "text.cursor"
        case .success:      return "checkmark.circle.fill"
        case .error:        return "exclamationmark.triangle.fill"
        case .recording:    return "mic.fill" // unused; waveform takes over
        }
    }

    private var stateColor: Color {
        switch coordinator.state {
        case .idle:         return .clear
        case .recording:    return .red
        case .transcribing: return .blue
        case .correcting:   return .purple
        case .preview:      return .accentColor
        case .inserting:    return .accentColor
        case .success:      return .green
        case .error:        return .orange
        }
    }

    private var statusText: String {
        switch coordinator.state {
        case .idle:         return "Ready · \(hotkeyDescription)"
        case .recording:    return "Recording"
        case .transcribing: return "Transcribing…"
        case .correcting:
            // Re-correct: keep the prior text on screen so the HUD doesn't
            // flash to "Polishing…" mid-edit. First correction has no prior
            // text, so we still show the spinner copy.
            return coordinator.lastCorrected.isEmpty ? "Polishing…" : coordinator.lastCorrected
        case .preview:      return coordinator.lastCorrected.isEmpty ? "Preview" : coordinator.lastCorrected
        case .inserting:    return "Inserting…"
        case .success:      return "Done"
        case .error:        return coordinator.lastError ?? "Error"
        }
    }

    private var hotkeyDescription: String {
        let combo = KeyboardShortcuts.getShortcut(for: .toggleDictation)?.description ?? "⌘⇧Space"
        let hold = AppSettings.holdModifier
        guard hold != .none else { return combo }
        return "double-tap \(shortHoldName(hold))"
    }

    private func shortHoldName(_ hold: HoldModifier) -> String {
        switch hold {
        case .none:         return ""
        case .rightOption:  return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .rightShift:   return "Right ⇧"
        case .rightControl: return "Right ⌃"
        case .leftOption:   return "Left ⌥"
        case .fn:           return "Fn"
        }
    }

    private func elapsedString(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Recording dot

/// Soft pulsing red dot — the universal "we are listening" cue.
private struct RecordingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .shadow(color: Color.red.opacity(0.65), radius: pulse ? 4 : 2)
            .scaleEffect(pulse ? 1.0 : 0.78)
            .opacity(pulse ? 1.0 : 0.7)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - Processing indicator

/// Soft rotating gradient ring around the state icon, for transcribing /
/// correcting / inserting. Cheaper than ProgressView and matches the visual
/// language of the rest of the HUD.
private struct ProcessingIndicator: View {
    let symbol: String
    let tint: Color
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.0), tint.opacity(0.85)],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                .frame(width: 22, height: 22)
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Mode chips

/// All five correction modes laid out as explicit chips. The active mode is
/// highlighted; the chevron-dropdown variant we tried first hid the + mode
/// variants behind a menu and gave users no signal of which one was in use.
private struct ModeChipRow: View {
    @ObservedObject var coordinator: DictationCoordinator
    let disabled: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CorrectionMode.allCases, id: \.self) { mode in
                ModeChip(
                    label: shortLabel(for: mode),
                    isActive: active == mode
                ) {
                    Task { await coordinator.requestCorrectionModeChange(to: mode) }
                }
                .help(mode.helpText)
                .disabled(disabled)
            }
        }
        .opacity(disabled ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.18), value: disabled)
    }

    private var active: CorrectionMode {
        coordinator.previewCorrectionMode ?? AppSettings.correctionMode
    }

    private func shortLabel(for mode: CorrectionMode) -> String {
        switch mode {
        case .clean:             return "Clean"
        case .polish:            return "Polish"
        case .polishPlus:        return "Polish+"
        case .structurePlus:     return "Structure+"
        case .formalPlus:        return "Formal+"
        }
    }
}

private struct ModeChip: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).modifier(ChipStyle(isActive: isActive))
        }
        .buttonStyle(.plain)
    }
}

private struct ChipStyle: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(isActive ? Color.white : Color.secondary)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.08))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(isActive ? 0.0 : 0.10), lineWidth: 0.5)
            )
    }
}

// MARK: - Insert button

/// Primary action pill: commits the previewed text at the current cursor.
/// The keycap glyph doubles as a hint that Enter does the same thing.
private struct InsertButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .bold))
                Text("Insert")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(Capsule(style: .continuous).fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .help("Insert at current cursor (⏎)")
    }
}
