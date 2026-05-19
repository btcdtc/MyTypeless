import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingPairing = false
    @State private var showingMacSettings = false
    @State private var showingKeyboardGuide = false
    @State private var rawTranscriptExpanded = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Typeforme")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Task { await state.refreshRoute(force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(state.isBusy)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showingPairing = true
                            } label: {
                                Label("Pairing", systemImage: "qrcode.viewfinder")
                            }
                            Button {
                                showingMacSettings = true
                            } label: {
                                Label("Server Settings", systemImage: "desktopcomputer")
                            }
                            .disabled(!state.isConfigured)
                            Button {
                                showingKeyboardGuide = true
                            } label: {
                                Label("Keyboard Guide", systemImage: "questionmark.circle")
                            }
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showingPairing) {
                    PairingView(config: state.config, routeStatus: state.routeStatus) { newConfig in
                        state.saveConfig(newConfig)
                    }
                }
                .sheet(isPresented: $showingMacSettings) {
                    NavigationStack {
                        MacSettingsView()
                            .environmentObject(state)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showingMacSettings = false }
                                }
                            }
                    }
                }
                .sheet(isPresented: $showingKeyboardGuide) {
                    NavigationStack {
                        KeyboardGuideView()
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showingKeyboardGuide = false }
                                }
                            }
                    }
                }
                .overlay(alignment: .top) {
                    ToastView(message: state.transientMessage)
                        .padding(.top, 8)
                        .animation(.snappy(duration: 0.22), value: state.transientMessage)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !state.isConfigured {
            UnpairedHero { showingPairing = true }
        } else {
            VStack(spacing: 16) {
                RouteStatusBar()
                HeroRecordCard()
                ModeChipsRow()
                Divider()
                ScrollView {
                    VStack(spacing: 14) {
                        LanguagesRow()
                        HostAudioSessionRow()
                        if let error = state.errorMessage, !error.isEmpty {
                            ErrorBanner(message: error) {
                                state.errorMessage = nil
                            }
                        }
                        if !state.resultText.isEmpty {
                            ResultCard()
                        }
                        if !state.rawTranscript.isEmpty {
                            RawTranscriptCard(expanded: $rawTranscriptExpanded)
                        }
                        KeyboardSetupHint {
                            showingKeyboardGuide = true
                        }
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - Unpaired empty state

private struct UnpairedHero: View {
    let onTapPair: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 8) {
                Text("Pair your Mac")
                    .font(.title2.weight(.semibold))
                Text("Typeforme uses your Mac's local ASR + LLM to clean up dictation. Pair the Mac Bridge URL and token to get started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button(action: onTapPair) {
                Label("Pair Mac Bridge", systemImage: "link")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            Spacer()
            Text("Or copy the pairing JSON from the Mac app.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 24)
        }
    }
}

// MARK: - Route status bar

private struct RouteStatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 9, height: 9)
                Text(state.routeStatus.activeKind.rawValue)
                    .font(.subheadline.weight(.semibold))
                if let detail = latencyDetail {
                    Text("· \(detail)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let installing = state.activeModelInstallText {
                Text(installing)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if let timing = state.latestServerTiming?.displayText {
                Text(timing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
    }

    private var dotColor: Color {
        switch state.routeStatus.activeKind {
        case .local: return .green
        case .cloud: return .blue
        case .unavailable: return .orange
        }
    }

    private var latencyDetail: String? {
        switch state.routeStatus.activeKind {
        case .local:
            return state.routeStatus.localLatencyMs.map { "\($0)ms" }
        case .cloud:
            return state.routeStatus.cloudLatencyMs.map { "\($0)ms" }
        case .unavailable:
            return nil
        }
    }
}

// MARK: - Hero record orb

/// Mirror of the keyboard's UIKit orb: 200pt circle with vertical gradient,
/// soft inner highlight, state-tinted shadow, and concentric pulse rings during
/// recording. The mic icon swaps out for a voiceprint when recording.
private struct HeroRecordCard: View {
    @EnvironmentObject private var state: AppState
    @State private var isPressed = false

    private let orbDiameter: CGFloat = 200

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(.horizontal, 24)

            ZStack {
                if isRecording {
                    PulseRingsHalo(tint: pulseTint, diameter: orbDiameter)
                        .allowsHitTesting(false)
                }
                orb
                    .scaleEffect(isPressed ? 0.92 : 1)
                    .animation(.spring(response: 0.32, dampingFraction: 0.55), value: isPressed)
                    .animation(.snappy(duration: 0.22), value: state.phase)
                    .gesture(pressGesture)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isButton)
            }
            .frame(height: orbDiameter + 40)
            .opacity(state.canInteractWithHostDictation ? 1 : 0.5)

            Picker("Input mode", selection: inputModeBinding) {
                ForEach(VoiceInputMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 210)
            .disabled(isRecording || state.isBusy)
            .opacity((isRecording || state.isBusy) ? 0.55 : 1)
        }
        .padding(.horizontal, 16)
    }

    private var orb: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: gradientStops,
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .overlay(
                    Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.75)
                )
                .shadow(color: shadowTint.opacity(0.42), radius: 28, x: 0, y: 14)

            // Specular highlight, upper-left
            Ellipse()
                .fill(.white.opacity(0.22))
                .frame(width: orbDiameter * 0.55, height: orbDiameter * 0.32)
                .blur(radius: 10)
                .offset(x: -orbDiameter * 0.16, y: -orbDiameter * 0.22)
                .blendMode(.plusLighter)

            // Center content: voiceprint while recording, spinner while sending,
            // mic icon otherwise.
            Group {
                if isRecording {
                    VoicePrintBars(level: state.hostRecordingLevel, isActive: true, tint: .white)
                        .frame(width: orbDiameter * 0.62, height: 64)
                } else if state.isHostRecordStarting || state.phase == .sending || state.phase == .restyling {
                    ProgressView()
                        .controlSize(.extraLarge)
                        .tint(.white)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 72, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: orbDiameter, height: orbDiameter)
        .compositingGroup()
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                guard state.canInteractWithHostDictation else { return }
                isPressed = true
                if state.inputMode == .hold {
                    Task { await state.beginHostHoldRecording() }
                }
            }
            .onEnded { _ in
                guard isPressed else { return }
                isPressed = false
                switch state.inputMode {
                case .hold:
                    Task { await state.endHostHoldRecording() }
                case .tap:
                    Task { await state.toggleHostTapRecording() }
                }
            }
    }

    private var inputModeBinding: Binding<VoiceInputMode> {
        Binding(
            get: { state.inputMode },
            set: { state.setInputMode($0) }
        )
    }

    private var isRecording: Bool {
        state.recorder.isRecording || state.phase == .recording
    }

    /// The orb is a single-purpose action: hold to speak, release to send.
    /// Title only ever reflects that contract or the in-flight verb of a
    /// user-initiated action — never a retry CTA, never a success/error
    /// status. Status goes to `detail`, errors go to `ErrorBanner`.
    private var title: String {
        if state.isHostRecordStarting { return "Preparing…" }
        if isRecording { return state.inputMode.recordingTitle }
        switch state.phase {
        case .sending: return "Sending…"
        case .restyling: return "Restyling…"
        default: return state.inputMode.idleTitle
        }
    }

    private var detail: String {
        if !state.isConfigured {
            return "Pair the Mac Bridge first."
        }
        if isRecording {
            return state.inputMode == .tap ? "Tap again when you're done." : "Keep holding while you speak."
        }
        if state.routeStatus.activeURL == nil {
            return "Mac Bridge is offline. Start it, then tap refresh."
        }
        if let installing = state.activeModelInstallText,
           state.phase == .sending || state.phase == .restyling {
            return installing
        }
        switch state.phase {
        case .sending: return "Transcribing…"
        case .restyling: return "Re-styling with the new mode."
        case .success(.copied), .success(.inserted): return "Result copied to the clipboard."
        case .failure, .idle, .preparing, .recording:
            return state.inputMode.idleDetail
        }
    }

    private var iconName: String {
        switch state.phase {
        case .success: return "checkmark"
        default: return "mic.fill"
        }
    }

    /// Gradient only shifts color for states the user actively triggered. A
    /// background-task `.failure` (route probe died, audio session hiccup)
    /// doesn't repaint the orb orange — it lives in the error banner.
    private var gradientStops: [Color] {
        if isPressed || isRecording {
            return [Color(red: 1.0, green: 0.42, blue: 0.42), Color(red: 0.86, green: 0.18, blue: 0.20)]
        }
        switch state.phase {
        case .sending, .restyling:
            return [Color(red: 0.60, green: 0.50, blue: 0.96), Color(red: 0.36, green: 0.28, blue: 0.80)]
        case .success:
            return [Color(red: 0.36, green: 0.84, blue: 0.50), Color(red: 0.15, green: 0.62, blue: 0.30)]
        default:
            return [Color(red: 0.34, green: 0.66, blue: 1.00), Color(red: 0.10, green: 0.40, blue: 0.92)]
        }
    }

    private var shadowTint: Color { gradientStops.last ?? .blue }
    private var pulseTint: Color { gradientStops.last ?? .blue }
}

/// Concentric pulse rings that bloom outward from the orb during recording.
/// Three rings, phase-offset by 0.6s each, scale 1.0 → 1.55, alpha 0 → 0.5 → 0.
private struct PulseRingsHalo: View {
    let tint: Color
    let diameter: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let localPhase = ((phase - Double(i) * 0.55).truncatingRemainder(dividingBy: 1.65)) / 1.65
                    let lp = max(0, localPhase)
                    let scale = 1.0 + lp * 0.55
                    let alpha = lp < 0.18
                        ? (lp / 0.18) * 0.5
                        : max(0, (1 - (lp - 0.18) / 0.82) * 0.5)
                    Circle()
                        .stroke(tint.opacity(alpha), lineWidth: 1.6)
                        .frame(width: diameter * scale, height: diameter * scale)
                }
            }
        }
        .frame(width: diameter + 80, height: diameter + 80)
    }
}

// MARK: - Voiceprint visualization (SwiftUI)

/// Mirrors the keyboard extension's UIKit `VoicePrintView`. Drives 9 bars from
/// an audio level (0...1) plus phase-shifted sines for organic motion. The
/// `TimelineView(.animation)` is only mounted when `isActive` is true so it
/// doesn't burn 60fps cycles when the hero card is idle.
private struct VoicePrintBars: View {
    let level: Float
    let isActive: Bool
    let tint: Color

    private let barCount = 9

    var body: some View {
        GeometryReader { geo in
            if isActive {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                    Canvas { context, _ in
                        let phase = timeline.date.timeIntervalSinceReferenceDate
                        drawBars(context: context, size: geo.size, phase: phase)
                    }
                }
            } else {
                // Static at min-height; mounted but cheap.
                Canvas { context, _ in
                    drawBars(context: context, size: geo.size, phase: 0, forceMinimum: true)
                }
            }
        }
        .frame(height: 64)
    }

    private func drawBars(
        context: GraphicsContext,
        size: CGSize,
        phase: CFTimeInterval,
        forceMinimum: Bool = false
    ) {
        let centerY = size.height / 2
        let minH = max(6, size.height * 0.12)
        let maxH = size.height * 0.95
        let barW: CGFloat = 5
        let total = CGFloat(barCount)
        let gap = (size.width - total * barW) / (total + 1)

        // Baseline 0.30 gives clearly visible motion even at silence; speech
        // amplifies on top via `voiceBoost`. With `level = 0` the bars still
        // breathe between ~30% and full-wave-modulated 30%; with `level = 0.5`
        // (speech) envelope hits 1.0 and bars span the full range.
        let baseline: CGFloat = 0.30
        let voiceBoost = CGFloat(level) * 2.2
        let envelope = min(1.0, baseline + voiceBoost)

        for i in 0..<barCount {
            let barH: CGFloat
            if forceMinimum {
                barH = minH
            } else {
                let centerBias = abs(Double(i) - Double(barCount - 1) / 2.0) / (Double(barCount - 1) / 2.0)
                let centerBoost = 1.0 - centerBias * 0.30
                let bandPhase = Double(i) * 0.55
                let s = sin(phase * 5.4 + bandPhase) * 0.55 + sin(phase * 11.1 + bandPhase * 2.3) * 0.45
                let waveform = CGFloat((s + 1) / 2)
                let modulation = envelope * CGFloat(centerBoost) * (0.35 + 0.65 * waveform)
                barH = max(minH, min(maxH, minH + (maxH - minH) * modulation))
            }
            let x = gap + CGFloat(i) * (barW + gap)
            let rect = CGRect(x: x, y: centerY - barH / 2, width: barW, height: barH)
            context.fill(
                Path(roundedRect: rect, cornerRadius: 2.5),
                with: .color(tint)
            )
        }
    }
}

// MARK: - Mode chips

private struct ModeChipsRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CorrectionModeID.allCases) { mode in
                    ModeChip(
                        mode: mode,
                        isSelected: state.correctionMode == mode,
                        isDisabled: state.isBusy
                    ) {
                        Task { await state.applyCorrectionMode(mode) }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollClipDisabled()
    }
}

private struct ModeChip: View {
    let mode: CorrectionModeID
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(isSelected ? Color.clear : Color(.separator), lineWidth: 0.5)
                )
        }
        .disabled(isDisabled)
        .opacity(isDisabled && !isSelected ? 0.5 : 1)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var label: String {
        mode.title
    }
}

// MARK: - Languages row

private struct LanguagesRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationLink {
            LanguageSelectionView(
                selection: $state.selectedLanguageIDs,
                options: state.config.supportedLanguageOptions
            )
            .onChange(of: state.selectedLanguageIDs) { _, _ in
                state.persistLanguageSelection()
            }
        } label: {
            HStack {
                Image(systemName: "globe")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Text("Languages")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(LanguageDisplay.summary(
                    for: state.selectedLanguageIDs,
                    options: state.config.supportedLanguageOptions
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Host audio session

private struct HostAudioSessionRow: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Host audio session")
                    .font(.subheadline.weight(.medium))
                Text("How long the host app keeps keyboard audio ready after wake.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Picker("Host audio session", selection: hostAudioSessionLengthBinding) {
                ForEach(HostAudioSessionLength.allCases) { length in
                    Text(length.title).tag(length)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(state.isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var hostAudioSessionLengthBinding: Binding<HostAudioSessionLength> {
        Binding {
            state.hostAudioSessionLength
        } set: { length in
            state.setHostAudioSessionLength(length)
        }
    }
}

// MARK: - Result card

private struct ResultCard: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Result", systemImage: "text.alignleft")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if state.phase == .restyling {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            TextEditor(text: $state.resultText)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.systemBackground))
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack(spacing: 10) {
                Button {
                    state.copyResult()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button(role: .destructive) {
                    state.clearResult()
                } label: {
                    Label("Clear", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

// MARK: - Raw transcript card

private struct RawTranscriptCard: View {
    @EnvironmentObject private var state: AppState
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack {
                    Label("Raw transcript", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                Text(state.rawTranscript)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

// MARK: - Error banner

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.32), lineWidth: 0.5)
        )
    }
}

// MARK: - Keyboard setup hint

private struct KeyboardSetupHint: View {
    let onOpenGuide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Keyboard", systemImage: "keyboard")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Enable Typeforme in iOS Settings > General > Keyboard > Keyboards, then turn on Allow Full Access.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(action: onOpenGuide) {
                    Label("Guide", systemImage: "questionmark.circle")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "arrow.up.right.square")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground).opacity(0.6))
        )
    }
}

// MARK: - Keyboard guide

private struct KeyboardGuideView: View {
    var body: some View {
        List {
            Section("Setup") {
                GuideStepRow(
                    icon: "desktopcomputer",
                    title: "Pair the Mac Server",
                    detail: "Paste the pairing JSON from the Mac app, then refresh Server Settings so iOS has the current languages and default mode."
                )
                GuideStepRow(
                    icon: "keyboard",
                    title: "Enable the keyboard",
                    detail: "In iOS Settings, add Typeforme and allow Full Access. The keyboard needs that to talk to the host app."
                )
            }

            Section("In Any App") {
                GuideStepRow(
                    icon: "mic.fill",
                    title: "Dictate",
                    detail: "Use Hold to Speak or Tap to Speak. Without a text selection, Typeforme inserts the new result at the cursor."
                )
                GuideStepRow(
                    icon: "text.cursor",
                    title: "Fix selected text",
                    detail: "Select the wrong span first, then press the mic and say the intended replacement. Only that selected span is replaced."
                )
                GuideStepRow(
                    icon: "wand.and.stars",
                    title: "Command edit",
                    detail: "Press the wand and speak an instruction like make this shorter, translate this, or turn it into bullets. With no selection, it targets the current input text."
                )
            }

            Section("Style Buttons") {
                GuideStepRow(
                    icon: "sparkles",
                    title: "Restyle existing text",
                    detail: "In the keyboard, Clean, Polish, Polish+, Structure+, and Formal+ use the selected text first, then the current input. In the host app, mode changes reuse the original recording transcript when available."
                )
                GuideStepRow(
                    icon: "exclamationmark.triangle",
                    title: "Selection changed",
                    detail: "If iOS no longer reports the same selection when the result returns, Typeforme copies the result instead of guessing where to paste it."
                )
            }
        }
        .navigationTitle("Keyboard Guide")
    }
}

private struct GuideStepRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Toast

private struct ToastView: View {
    let message: String?

    var body: some View {
        if let message {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Server Settings (unchanged behavior, lightly polished)

private struct MacSettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var draft: BridgeMacSettingsPayload?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    var body: some View {
        List {
            if let draft {
                Section("Speech") {
                    Picker("ASR Engine", selection: asrProviderBinding) {
                        ForEach(draft.asrProviderOptions) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Stepper(value: asrTimeoutBinding, in: 10...300, step: 5) {
                        HStack {
                            Text("ASR Timeout")
                            Spacer()
                            Text("\(draft.asrTimeoutSec)s")
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        LanguageSelectionView(
                            selection: languageBinding,
                            options: draft.supportedLanguageOptions(for: draft.asrProvider)
                        )
                    } label: {
                        HStack {
                            Text("Languages")
                            Spacer()
                            Text(LanguageDisplay.summary(
                                for: Set(draft.languageIDs),
                                options: draft.supportedLanguageOptions(for: draft.asrProvider)
                            ))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                }

                Section("Correction") {
                    Picker("Engine", selection: correctionBackendBinding) {
                        ForEach(draft.correctionBackendOptions) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Stepper(value: correctionTimeoutBinding, in: 100...30_000, step: 100) {
                        HStack {
                            Text("Correction Timeout")
                            Spacer()
                            Text("\(draft.correctionTimeoutMs)ms")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Stepper(value: correctionColdTimeoutBinding, in: 1_000...60_000, step: 1_000) {
                        HStack {
                            Text("Model Startup Timeout")
                            Spacer()
                            Text("\(draft.correctionColdTimeoutMs)ms")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Picker("Mode", selection: correctionModeBinding) {
                        ForEach(CorrectionModeID.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Numbers", selection: numberOutputPreferenceBinding) {
                        ForEach(NumberOutputPreferenceID.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Punctuation", selection: punctuationPreferenceBinding) {
                        ForEach(PunctuationPreferenceID.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle("Auto Commit", isOn: autoCommitBinding)
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        Label(isSaving ? "Saving…" : "Save to Server", systemImage: "arrow.up.circle")
                    }
                    .disabled(isSaving)

                    Button {
                        Task { await load(force: true) }
                    } label: {
                        Label("Reload from Server", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading || isSaving)
                }
            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text("Loading server settings")
                    }
                }
            }

            if let savedMessage {
                Section {
                    Text(savedMessage)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Server Settings")
        .task {
            await load(force: false)
        }
    }

    private var asrProviderBinding: Binding<String> {
        Binding {
            draft?.asrProvider ?? "whisperkit"
        } set: { value in
            draft?.asrProvider = value
            normalizeDraft()
        }
    }

    private var correctionBackendBinding: Binding<String> {
        Binding {
            draft?.correctionBackend ?? ""
        } set: { value in
            draft?.correctionBackend = value
        }
    }

    private var asrTimeoutBinding: Binding<Int> {
        Binding {
            draft?.asrTimeoutSec ?? 120
        } set: { value in
            draft?.asrTimeoutSec = min(max(value, 10), 300)
        }
    }

    private var correctionTimeoutBinding: Binding<Int> {
        Binding {
            draft?.correctionTimeoutMs ?? 1500
        } set: { value in
            draft?.correctionTimeoutMs = min(max(value, 100), 30_000)
        }
    }

    private var correctionColdTimeoutBinding: Binding<Int> {
        Binding {
            draft?.correctionColdTimeoutMs ?? 8000
        } set: { value in
            draft?.correctionColdTimeoutMs = min(max(value, 1_000), 60_000)
        }
    }

    private var correctionModeBinding: Binding<CorrectionModeID> {
        Binding {
            draft?.correctionMode ?? .polish
        } set: { value in
            draft?.correctionMode = value
        }
    }

    private var numberOutputPreferenceBinding: Binding<NumberOutputPreferenceID> {
        Binding {
            draft?.numberOutputPreference ?? .automatic
        } set: { value in
            draft?.numberOutputPreference = value
        }
    }

    private var punctuationPreferenceBinding: Binding<PunctuationPreferenceID> {
        Binding {
            draft?.punctuationPreference ?? .normal
        } set: { value in
            draft?.punctuationPreference = value
        }
    }

    private var autoCommitBinding: Binding<Bool> {
        Binding {
            draft?.autoCommit ?? true
        } set: { value in
            draft?.autoCommit = value
        }
    }

    private var languageBinding: Binding<Set<String>> {
        Binding {
            Set(draft?.languageIDs ?? [])
        } set: { value in
            guard var current = draft else { return }
            current.languageIDs = ASRLanguageSelection.validatedIDs(
                Array(value),
                supportedOptions: current.supportedLanguageOptions(for: current.asrProvider)
            )
            draft = current
        }
    }

    private func normalizeDraft() {
        guard var current = draft else { return }
        current.normalize()
        draft = current
    }

    private func load(force: Bool) async {
        guard force || draft == nil else { return }
        isLoading = true
        errorMessage = nil
        savedMessage = nil
        do {
            draft = try await state.refreshMacSettings()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        guard let draft else { return }
        isSaving = true
        errorMessage = nil
        savedMessage = nil
        do {
            self.draft = try await state.updateMacSettings(draft)
            savedMessage = "Saved to server."
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
