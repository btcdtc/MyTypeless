import AVFoundation
import Combine
import Darwin
import Foundation
import Network
import ObjectiveC
import OSLog
import UIKit

private let appLog = Logger(subsystem: "com.typeforme.ios", category: "app")

/// Top-level UI phase for the iOS host app. Drives the hero record card,
/// busy/disabled gating, and the keyboard bridge status. Replaces the older
/// stringly-typed `status` field that produced silent breakage whenever a
/// label was reworded (e.g. `isBusy` checking `"Resolving route"`).
enum AppPhase: Equatable {
    case idle
    case preparing
    case recording
    case sending
    case restyling
    case success(SuccessKind)
    case failure(String)

    enum SuccessKind: Equatable {
        case copied
        case inserted
    }

    var isBusy: Bool {
        switch self {
        case .preparing, .recording, .sending, .restyling: return true
        default: return false
        }
    }

    var allowsRecordingStart: Bool {
        switch self {
        case .idle, .success, .failure: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .preparing: return "Preparing"
        case .recording: return "Recording"
        case .sending: return "Sending"
        case .restyling: return "Restyling"
        case .success(.copied): return "Copied"
        case .success(.inserted): return "Inserted"
        case .failure(let msg): return msg
        }
    }
}

enum HostAudioSessionLength: String, CaseIterable, Identifiable {
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case thirtyMinutes = "30m"
    case oneHour = "1h"
    case untilStopped = "until_stopped"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fiveMinutes: return "5 min"
        case .fifteenMinutes: return "15 min"
        case .thirtyMinutes: return "30 min"
        case .oneHour: return "1 hour"
        case .untilStopped: return "Until app stops"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .fiveMinutes: return 5 * 60
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .untilStopped: return nil
        }
    }
}

struct ServerTimingSummary: Equatable {
    var transcriptionLatencyMs: Int?
    var correctionLatencyMs: Int?
    var totalLatencyMs: Int?

    var displayText: String? {
        var parts: [String] = []
        if let transcriptionLatencyMs {
            parts.append("Transcription \(transcriptionLatencyMs)ms")
        }
        if let correctionLatencyMs {
            parts.append("Restyle \(correctionLatencyMs)ms")
        }
        if parts.isEmpty, let totalLatencyMs {
            parts.append("Total \(totalLatencyMs)ms")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var config: PairingConfig
    @Published var correctionMode: CorrectionModeID
    @Published var inputMode: VoiceInputMode
    @Published var selectedLanguageIDs: Set<String>
    @Published var resultText = ""
    @Published var rawTranscript = ""
    @Published var sessionID: String?
    @Published var phase: AppPhase = .idle
    @Published var errorMessage: String?
    @Published var routeStatus = BridgeRouteStatus()
    @Published var keyboardStandbyEnabled = true
    @Published var hostAudioSessionLength: HostAudioSessionLength
    @Published var keyboardBridgeStatus = KeyboardBridgeStatus.idle
    @Published var lastRecordingSummary = ""
    @Published var latestServerTiming: ServerTimingSummary?
    @Published var macSettings: BridgeMacSettingsPayload?
    @Published private(set) var isHostRecordStarting = false
    /// Transient feedback ("Copied!", "Saved!") rendered as a toast.
    @Published var transientMessage: String?

    let recorder = AudioRecorder()

    private let store = PairingStore()
    private let routeResolver = BridgeRouteResolver()
    private let keyboardServer = KeyboardLocalServer()
    private let networkPathMonitor = NWPathMonitor()
    private let networkPathQueue = DispatchQueue(label: "com.typeforme.ios.network-path")
    private static let inputModeKey = "keyboard.inputMode"
    private static let hostAudioSessionLengthKey = "keyboard.hostAudioSessionLength"
    private static let keyboardWakePasteboardName = UIPasteboard.Name("com.typeforme.keyboard.wake")
    private static let keyboardDefaultsPasteboardName = UIPasteboard.Name("com.typeforme.keyboard.defaults")
    private static let keyboardWakeMaxAge: TimeInterval = 12
    private static let returnTraceLogName = "typeforme-return-trace.log"
    /// Keeps an input audio session alive while keyboard standby is on. iOS
    /// keyboard extensions cannot open the microphone, so the host app owns a
    /// persistent AVAudioEngine input tap and the keyboard only toggles file
    /// capture through Darwin notifications.
    private let keyboardAudioSession = StandbyAudioSession()
    private var hostHoldReleasePending = false
    private var hostRecordingUsesKeyboardAudioSession = false
    private var keyboardCaptureStartedFromKeyboard = false
    private var hostAudioSessionExpiryTask: Task<Void, Never>?
    private var routeFetchedAt: Date?
    private var networkPathSignature: String?
    private var lastNetworkPathRefreshAt: Date?
    private var phaseResetTask: Task<Void, Never>?
    private var transientMessageTask: Task<Void, Never>?
    private var initialRenderDelayTask: Task<Void, Never>?
    private var modelStatusPollingTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var keyboardDarwinObservers: [KeyboardDarwinNotificationObserver] = []
    private var idleTimerHolders = 0
    private var lastGeneratedResultText: String?
    private var activeKeyboardTextEditContext: KeyboardTextEditContext?
    private var activeKeyboardDictationContext: KeyboardDictationContext?
    private var lastHandledOpenURL: (value: String, time: TimeInterval)?
    /// Forwards audio level changes to SwiftUI. The host orb can be driven by
    /// either the dedicated recorder or the standby audio session.
    private var recorderCancellable: AnyCancellable?
    private var keyboardAudioSessionCancellable: AnyCancellable?

    /// Force-refresh cloud/unavailable routes if cached probe is older than
    /// this. Local routes get a shorter TTL because stale LAN IPs hurt more
    /// than the extra probe.
    private static let routeCacheTTL: TimeInterval = 30
    private static let localRouteCacheTTL: TimeInterval = 5
    private static let networkPathSameSignatureRefreshInterval: TimeInterval = 2
    /// How long a `.success` / `.failure` phase sticks before reverting to
    /// `.idle`. Long enough to read, short enough not to block the next press.
    private static let phaseAutoResetDelay: TimeInterval = 2.4

    private struct RestyleSource {
        let sessionID: String?
        let rawTranscript: String?
    }

    var isBusy: Bool {
        phase.isBusy
    }

    var isConfigured: Bool {
        !config.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && config.hasAnyBridgeURL
    }

    var isReadyToRecord: Bool {
        isConfigured && !isBusy
    }

    var canInteractWithHostDictation: Bool {
        guard isConfigured else { return false }
        if recorder.isRecording || keyboardAudioSession.isRecording || isHostRecordStarting { return true }
        guard routeStatus.activeURL != nil else { return false }
        return phase.allowsRecordingStart
    }

    var hostRecordingLevel: Float {
        hostRecordingUsesKeyboardAudioSession ? keyboardAudioSession.level : recorder.level
    }

    var activeModelInstallText: String? {
        guard let status = macSettings?.modelStatuses.first(where: { $0.installing }) else {
            return nil
        }
        let prefix = status.kind == "asr" ? "Installing ASR" : "Installing Restyle"
        return "\(prefix): \(status.displayName)"
    }

    private var activeLanguageIDs: [String] {
        ASRLanguageSelection.validatedIDs(
            Array(selectedLanguageIDs),
            supportedOptions: config.supportedLanguageOptions
        )
    }

    init() {
        let saved = store.load()
        self.config = saved
        self.correctionMode = saved.correctionMode
        self.inputMode = UserDefaults.standard.string(forKey: Self.inputModeKey)
            .flatMap(VoiceInputMode.init(rawValue:)) ?? .hold
        self.hostAudioSessionLength = UserDefaults.standard.string(forKey: Self.hostAudioSessionLengthKey)
            .flatMap(HostAudioSessionLength.init(rawValue:)) ?? .thirtyMinutes
        self.selectedLanguageIDs = Set(saved.validatedLanguageIDs)
        self.keyboardStandbyEnabled = true
        configureKeyboardServer()
        configureKeyboardDarwinBridge()
        installLifecycleObservers()
        startNetworkPathMonitor()
        recorderCancellable = recorder.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        keyboardAudioSessionCancellable = keyboardAudioSession.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        publishKeyboardDefaults()
    }

    deinit {
        hostAudioSessionExpiryTask?.cancel()
        modelStatusPollingTask?.cancel()
        networkPathMonitor.cancel()
        for token in lifecycleObservers {
            NotificationCenter.default.removeObserver(token)
        }
        for observer in keyboardDarwinObservers {
            observer.stopObserving()
        }
    }

    func bootstrap() async {
        await waitForInitialRenderOpportunity()
        await setKeyboardStandby(true)
        await handlePendingKeyboardWakeRequest(reason: "bootstrap")
        await refreshRoute(force: true)
        _ = try? await refreshMacSettings()
    }

    func saveConfig(_ newConfig: PairingConfig) {
        var normalized = newConfig
        normalized.normalizeLanguageIDs()
        config = normalized
        correctionMode = normalized.correctionMode
        selectedLanguageIDs = Set(normalized.validatedLanguageIDs)
        store.save(normalized)
        publishKeyboardDefaults()
        routeFetchedAt = nil
        Task {
            await handlePendingKeyboardWakeRequest(reason: "foreground")
            await refreshRoute(force: true)
            _ = try? await refreshMacSettings()
        }
    }

    func persistLanguageSelection() {
        let ordered = ASRLanguageSelection.validatedIDs(
            Array(selectedLanguageIDs),
            supportedOptions: config.supportedLanguageOptions
        )
        selectedLanguageIDs = Set(ordered)
        config.languageIDs = ordered
        store.save(config)
    }

    func setInputMode(_ mode: VoiceInputMode) {
        guard mode != inputMode else { return }
        inputMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.inputModeKey)
    }

    func setHostAudioSessionLength(_ length: HostAudioSessionLength) {
        guard length != hostAudioSessionLength else { return }
        hostAudioSessionLength = length
        UserDefaults.standard.set(length.rawValue, forKey: Self.hostAudioSessionLengthKey)
        scheduleHostAudioSessionExpiry()
    }

    func refreshRoute(force: Bool = false, probeAllEndpoints: Bool = true) async {
        let cacheTTL = routeStatus.activeKind == .local ? Self.localRouteCacheTTL : Self.routeCacheTTL
        if !force, let routeFetchedAt,
           Date().timeIntervalSince(routeFetchedAt) < cacheTTL,
           routeStatus.activeURL != nil,
           routeStatusSatisfiesProbeMode(probeAllEndpoints) {
            return
        }
        routeStatus = await routeResolver.resolve(config: config, probeAllEndpoints: probeAllEndpoints)
        persistActiveLocalRouteIfNeeded(routeStatus)
        routeFetchedAt = Date()
    }

    private func routeStatusSatisfiesProbeMode(_ probeAllEndpoints: Bool) -> Bool {
        guard probeAllEndpoints else { return true }
        let localConfigured = !config.localBridgeURLCandidates.isEmpty
        let cloudConfigured = !config.publicBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (!localConfigured || routeStatus.localChecked) &&
            (!cloudConfigured || routeStatus.cloudChecked)
    }

    func refreshMacSettings() async throws -> BridgeMacSettingsPayload {
        let client = try await activeBridgeClient()
        var settings = try await client.macSettings()
        settings.normalize()
        applyMacSettings(settings)
        return settings
    }

    func updateMacSettings(_ settings: BridgeMacSettingsPayload) async throws -> BridgeMacSettingsPayload {
        var normalized = settings
        normalized.normalize()
        let client = try await activeBridgeClient()
        var updated = try await client.updateMacSettings(normalized)
        updated.normalize()
        applyMacSettings(updated)
        return updated
    }

    private func applyMacSettings(_ settings: BridgeMacSettingsPayload) {
        macSettings = settings
        config.supportedLanguages = settings.supportedLanguages
        config.correctionMode = settings.correctionMode
        config.languageIDs = ASRLanguageSelection.validatedIDs(
            config.languageIDs,
            supportedOptions: config.supportedLanguageOptions
        )
        selectedLanguageIDs = Set(config.validatedLanguageIDs)
        correctionMode = settings.correctionMode
        store.save(config)
        publishKeyboardDefaults()
    }

    private func resetCorrectionModeToDefault() {
        guard correctionMode != config.correctionMode else { return }
        correctionMode = config.correctionMode
    }

    private func publishKeyboardDefaults() {
        let payload: [String: Any] = [
            "version": 1,
            "correction_mode": config.correctionMode.rawValue,
            "updated_at": Date().timeIntervalSince1970,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8),
              let pasteboard = UIPasteboard(name: Self.keyboardDefaultsPasteboardName, create: true)
        else { return }
        pasteboard.string = text
    }

    private func persistActiveLocalRouteIfNeeded(_ status: BridgeRouteStatus) {
        guard status.activeKind == .local,
              let activeURL = status.activeURL?.absoluteString
        else { return }

        let previous = config.localBridgeURLCandidates
        config.promoteLocalBridgeURL(activeURL)
        if config.localBridgeURLCandidates != previous {
            store.save(config)
        }
    }

    private func refreshMacModelStatuses() async throws {
        let client = try await activeBridgeClient()
        var settings = try await client.macSettings(timeout: 3)
        settings.normalize()
        if var current = macSettings {
            current.modelStatuses = settings.modelStatuses
            macSettings = current
        } else {
            macSettings = settings
        }
    }

    private func startModelStatusPolling() {
        modelStatusPollingTask?.cancel()
        modelStatusPollingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            while !Task.isCancelled {
                _ = try? await self?.refreshMacModelStatuses()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopModelStatusPolling() {
        modelStatusPollingTask?.cancel()
        modelStatusPollingTask = nil
    }

    private func activeBridgeClient() async throws -> BridgeClient {
        if routeStatus.activeURL == nil {
            await refreshRoute(force: true, probeAllEndpoints: false)
        }
        guard let baseURL = routeStatus.activeURL else {
            throw BridgeClientError.unauthorizedOrUnavailable
        }
        return BridgeClient(baseURL: baseURL, token: config.token)
    }

    // MARK: - Recording (host UI)

    func toggleRecording() async {
        if recorder.isRecording {
            await stopAndSend()
        } else {
            await startRecording()
        }
    }

    func toggleHostTapRecording() async {
        if recorder.isRecording || phase == .recording {
            await stopAndSend()
        } else {
            await startRecording()
        }
    }

    func beginHostHoldRecording() async {
        guard !recorder.isRecording, !keyboardAudioSession.isRecording else { return }
        guard !isHostRecordStarting else { return }
        guard isConfigured else {
            setFailure("Pair the Mac Bridge first.")
            return
        }
        guard phase.allowsRecordingStart else { return }

        hostHoldReleasePending = false
        isHostRecordStarting = true
        setPhase(.preparing)
        errorMessage = nil

        guard routeStatus.activeURL != nil else {
            hostHoldReleasePending = false
            isHostRecordStarting = false
            setFailure("Mac Bridge is offline. Start the Mac app or Server, then tap refresh.")
            return
        }

        do {
            try await startHostRecordingCapture()
            acquireIdleTimer()
            setPhase(.recording)
        } catch {
            hostRecordingUsesKeyboardAudioSession = false
            setFailure(error.localizedDescription)
            await resumeKeyboardStandbyAfterCommand()
        }

        isHostRecordStarting = false
        if hostHoldReleasePending {
            hostHoldReleasePending = false
            if recorder.isRecording || keyboardAudioSession.isRecording {
                await stopAndSend()
            }
        }
    }

    func endHostHoldRecording() async {
        if isHostRecordStarting {
            hostHoldReleasePending = true
            return
        }
        guard recorder.isRecording || keyboardAudioSession.isRecording else { return }
        await stopAndSend()
    }

    func startRecording() async {
        errorMessage = nil
        setPhase(.preparing)
        guard isConfigured else {
            setFailure("Pair the Mac Bridge first.")
            return
        }
        guard routeStatus.activeURL != nil else {
            setFailure("Mac Bridge is offline. Start the Mac app or Server, then tap refresh.")
            return
        }

        do {
            try await startHostRecordingCapture()
            acquireIdleTimer()
            setPhase(.recording)
        } catch {
            hostRecordingUsesKeyboardAudioSession = false
            setFailure(error.localizedDescription)
            await resumeKeyboardStandbyAfterCommand()
        }
    }

    private func startHostRecordingCapture() async throws {
        keyboardCaptureStartedFromKeyboard = false
        if keyboardAudioSession.isActive, !keyboardAudioSession.isRecording {
            _ = try keyboardAudioSession.beginRecording()
            hostRecordingUsesKeyboardAudioSession = true
            return
        }

        try await recorder.start(reuseActiveSession: keyboardAudioSession.isActive)
        hostRecordingUsesKeyboardAudioSession = false
    }

    func stopAndSend(keyboardCommandID: String? = nil) async {
        let requestedCorrectionMode = correctionMode
        defer { resetCorrectionModeToDefault() }
        let keyboardCaptureWasStartedFromKeyboard = keyboardCaptureStartedFromKeyboard
        keyboardCaptureStartedFromKeyboard = false
        let isHostStandbyCapture = keyboardCommandID == nil
            && hostRecordingUsesKeyboardAudioSession
            && !keyboardCaptureWasStartedFromKeyboard
        let isKeyboardCapture = keyboardAudioSession.isRecording
        let fileURL = isKeyboardCapture
            ? keyboardAudioSession.finishRecording()
            : recorder.stop(deactivateSession: !keyboardStandbyEnabled)
        hostRecordingUsesKeyboardAudioSession = false
        let keyboardTextEditContext = activeKeyboardTextEditContext
        let keyboardDictationContext = activeKeyboardDictationContext
        activeKeyboardTextEditContext = nil
        activeKeyboardDictationContext = nil
        releaseIdleTimer()
        guard let fileURL else {
            setPhase(.idle)
            if let keyboardCommandID {
                publishKeyboardStatus(.standby, commandID: keyboardCommandID, message: "Nothing recorded")
            }
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
            await resumeKeyboardStandbyAfterCommand()
            return
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let recordingInfo = RecordingFileInfo(url: fileURL)
        lastRecordingSummary = recordingInfo.summary
        if recordingInfo.isTooShort {
            setPhase(.idle)
            if let keyboardCommandID {
                publishKeyboardStatus(
                    .standby,
                    commandID: keyboardCommandID,
                    message: "Too short; hold while speaking",
                    audioDurationSeconds: recordingInfo.durationSeconds,
                    audioByteCount: recordingInfo.byteCount
                )
            }
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
            await resumeKeyboardStandbyAfterCommand()
            return
        }

        acquireIdleTimer()
        defer { releaseIdleTimer() }

        setPhase(.sending)
        if let keyboardCommandID {
            publishKeyboardStatus(.sending, commandID: keyboardCommandID, message: "Resolving Bridge")
        }
        await refreshRoute(force: true, probeAllEndpoints: false)
        guard let baseURL = routeStatus.activeURL else {
            setFailure("Bridge unavailable. Check pairing, Local URL, or Cloud URL.")
            if let keyboardCommandID {
                publishKeyboardStatus(.error, commandID: keyboardCommandID, message: errorMessage ?? "Bridge unavailable")
            }
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
            await resumeKeyboardStandbyAfterCommand()
            return
        }

        if let keyboardCommandID {
            publishKeyboardStatus(
                .sending,
                commandID: keyboardCommandID,
                message: "Transcribing \(recordingInfo.durationLabel) audio",
                audioDurationSeconds: recordingInfo.durationSeconds,
                audioByteCount: recordingInfo.byteCount
            )
        }
        do {
            let client = BridgeClient(baseURL: baseURL, token: config.token)
            startModelStatusPolling()
            defer { stopModelStatusPolling() }
            let dictationContext = keyboardTextEditContext == nil ? keyboardDictationContext : nil
            let response = try await client.dictate(
                audioURL: fileURL,
                audioExtension: fileURL.pathExtension.isEmpty ? "m4a" : fileURL.pathExtension,
                languageIDs: activeLanguageIDs,
                correctionMode: requestedCorrectionMode,
                contextBefore: dictationContext?.contextBefore ?? "",
                contextAfter: dictationContext?.contextAfter ?? "",
                includeRawTranscript: true
            )
            _ = try? await refreshMacModelStatuses()
            let spokenTranscript = response.rawTranscript?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var resultMessage = "Inserted \(recordingInfo.durationLabel) audio"
            var correctionLatencyMs = response.correctionLatencyMs
            var totalLatencyMs = response.latencyMs

            if let editContext = keyboardTextEditContext {
                guard !spokenTranscript.isEmpty else {
                    setFailure("Mac returned an empty transcript.")
                    if let keyboardCommandID {
                        publishKeyboardStatus(.error, commandID: keyboardCommandID, message: errorMessage ?? "Empty transcript")
                    }
                    KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                    await resumeKeyboardStandbyAfterCommand()
                    return
                }
                if let keyboardCommandID {
                    publishKeyboardStatus(
                        .sending,
                        commandID: keyboardCommandID,
                        message: editContext.intent == .command ? "Editing selection" : "Repairing selection",
                        audioDurationSeconds: recordingInfo.durationSeconds,
                        audioByteCount: recordingInfo.byteCount
                    )
                }
                let editResponse = try await client.editText(
                    intent: editContext.intent.rawValue,
                    contextBefore: editContext.contextBefore,
                    targetText: editContext.targetText,
                    contextAfter: editContext.contextAfter,
                    spokenInstruction: spokenTranscript,
                    languageIDs: activeLanguageIDs
                )
                text = editResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
                correctionLatencyMs = editResponse.editLatencyMs ?? editResponse.latencyMs
                if let transcriptionLatency = response.transcriptionLatencyMs,
                   let editLatency = editResponse.latencyMs {
                    totalLatencyMs = transcriptionLatency + editLatency
                } else {
                    totalLatencyMs = editResponse.latencyMs ?? response.latencyMs
                }
                resultMessage = editContext.intent == .command ? "Edited selection" : "Repaired selection"
            }
            guard !text.isEmpty else {
                setFailure("Mac returned an empty result.")
                if let keyboardCommandID {
                    publishKeyboardStatus(.error, commandID: keyboardCommandID, message: errorMessage ?? "Empty result")
                }
                KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                await resumeKeyboardStandbyAfterCommand()
                return
            }
            resultText = text
            lastGeneratedResultText = text
            if keyboardTextEditContext == nil {
                rawTranscript = response.rawTranscript ?? rawTranscript
                sessionID = response.sessionID
            } else {
                rawTranscript = ""
                sessionID = nil
            }
            latestServerTiming = ServerTimingSummary(
                transcriptionLatencyMs: response.transcriptionLatencyMs,
                correctionLatencyMs: correctionLatencyMs,
                totalLatencyMs: totalLatencyMs
            )
            errorMessage = nil
            applyCorrectionMetadata(status: response.correctionStatus, error: response.correctionError)

            let shouldPublishKeyboardResult = keyboardCommandID != nil
                || keyboardCaptureWasStartedFromKeyboard
                || (isKeyboardCapture && !isHostStandbyCapture)
            let resultCommandID = keyboardCommandID ?? (shouldPublishKeyboardResult ? "keyboard-\(UUID().uuidString)" : nil)
            if let resultCommandID {
                publishKeyboardStatus(
                    .result,
                    commandID: resultCommandID,
                    message: resultMessage,
                    resultText: text,
                    audioDurationSeconds: recordingInfo.durationSeconds,
                    audioByteCount: recordingInfo.byteCount,
                    rawTranscriptLength: spokenTranscript.count
                )
            }
            publishKeyboardPasteboardResult(text)
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
            if resultCommandID != nil {
                scheduleKeyboardStandbyRefresh()
                return
            }
        } catch {
            Task { @MainActor [weak self] in
                _ = try? await self?.refreshMacModelStatuses()
            }
            if isBenignEmptyTranscript(error) {
                setPhase(.idle)
                if let keyboardCommandID {
                    publishKeyboardStatus(.standby, commandID: keyboardCommandID, message: "Nothing recorded")
                }
                KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                await resumeKeyboardStandbyAfterCommand()
                return
            }
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
            // A stale route is the most common cause of `.unauthorizedOrUnavailable`
            // after the public Bridge URL was unavailable for a while. Force a
            // single re-probe so the next press doesn't need a manual refresh.
            if let bridgeError = error as? BridgeClientError,
               case .unauthorizedOrUnavailable = bridgeError {
                routeFetchedAt = nil
            }
            setFailure(error.localizedDescription)
            if let keyboardCommandID {
                publishKeyboardStatus(.error, commandID: keyboardCommandID, message: error.localizedDescription)
            }
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
        }
        await resumeKeyboardStandbyAfterCommand()
    }

    func applyCorrectionMode(_ newMode: CorrectionModeID) async {
        // Block mode changes while a request is mid-flight to avoid a stale
        // result coming back in the old mode while the UI shows the new one.
        guard !isBusy else { return }
        correctionMode = newMode

        guard let source = currentRestyleSource() else {
            rawTranscript = ""
            sessionID = nil
            lastGeneratedResultText = nil
            return
        }
        defer { resetCorrectionModeToDefault() }
        await refreshRoute(force: true, probeAllEndpoints: false)
        guard let baseURL = routeStatus.activeURL else {
            setFailure("Bridge unavailable. Check pairing, Local URL, or Cloud URL.")
            return
        }
        do {
            setPhase(.restyling)
            let client = BridgeClient(baseURL: baseURL, token: config.token)
            startModelStatusPolling()
            defer { stopModelStatusPolling() }
            let response = try await client.restyle(
                sessionID: source.sessionID,
                rawTranscript: source.rawTranscript,
                languageIDs: activeLanguageIDs,
                correctionMode: newMode
            )
            _ = try? await refreshMacModelStatuses()
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                setFailure("Mac returned an empty result.")
                return
            }
            resultText = text
            lastGeneratedResultText = text
            if let submittedRaw = source.rawTranscript {
                rawTranscript = submittedRaw
            }
            sessionID = response.sessionID
            latestServerTiming = ServerTimingSummary(
                transcriptionLatencyMs: latestServerTiming?.transcriptionLatencyMs,
                correctionLatencyMs: response.correctionLatencyMs ?? response.latencyMs,
                totalLatencyMs: response.latencyMs
            )
            publishKeyboardPasteboardResult(text)
            errorMessage = nil
            applyCorrectionMetadata(status: response.correctionStatus, error: response.correctionError)
        } catch {
            Task { @MainActor [weak self] in
                _ = try? await self?.refreshMacModelStatuses()
            }
            if let bridgeError = error as? BridgeClientError,
               case .unauthorizedOrUnavailable = bridgeError {
                routeFetchedAt = nil
            }
            setFailure(error.localizedDescription)
        }
    }

    func copyResult() {
        guard !resultText.isEmpty else { return }
        UIPasteboard.general.string = resultText
        errorMessage = nil
        setPhase(.success(.copied))
        showTransient("Copied")
    }

    func clearResult() {
        resultText = ""
        rawTranscript = ""
        sessionID = nil
        lastGeneratedResultText = nil
        setPhase(.idle)
    }

    private func currentRestyleSource() -> RestyleSource? {
        let existingSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let validSessionID = existingSessionID?.isEmpty == false ? existingSessionID : nil
        let previousSource = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !previousSource.isEmpty {
            return RestyleSource(sessionID: validSessionID, rawTranscript: previousSource)
        }
        if let validSessionID {
            return RestyleSource(sessionID: validSessionID, rawTranscript: nil)
        }

        let visibleText = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visibleText.isEmpty else { return nil }
        return RestyleSource(sessionID: nil, rawTranscript: visibleText)
    }

    func handleOpenURL(_ url: URL, sourceApplication: String? = nil) async {
        guard url.scheme?.lowercased() == "typeforme" else { return }
        let now = Date().timeIntervalSince1970
        if let lastHandledOpenURL,
           lastHandledOpenURL.value == url.absoluteString,
           now - lastHandledOpenURL.time < 1.0 {
            appLog.notice("handleOpenURL: skipped duplicate \(url.absoluteString, privacy: .public)")
            return
        }
        lastHandledOpenURL = (url.absoluteString, now)
        resetReturnTrace("openURL url=\(url.absoluteString) sourceApplication=\(sourceApplication ?? "nil")")
        appLog.notice("handleOpenURL: received \(url.absoluteString, privacy: .public), sourceApplication=\(sourceApplication ?? "nil", privacy: .public)")
        await waitForInitialRenderOpportunity()
        let action = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var shouldReturnToKeyboard = false
        var returnBundleID: String?
        var returnProcessID: Int32?
        var source: String?
        var urlDebugLines: [String] = []
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let items = components.queryItems ?? []
            applyKeyboardParameters(items, allowCorrectionMode: action == "record")
            shouldReturnToKeyboard = items.contains { item in
                item.name == "return" && item.value == "1"
            }
            returnBundleID = items.first { $0.name == "return_bundle" }?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            returnProcessID = items.first { $0.name == "return_pid" }?
                .value
                .flatMap(Int32.init)
            source = items.first { $0.name == "source" }?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            urlDebugLines = items
                .filter { $0.name == "debug" }
                .compactMap { $0.value }
        }
        let explicitReturnBundleID = returnBundleID
        returnBundleID = resolvedReturnBundleID(
            explicitBundleID: returnBundleID,
            sourceApplication: sourceApplication,
            processID: returnProcessID
        )
        appendReturnTrace("openURL parsed action=\(action) source=\(source ?? "nil") return=\(shouldReturnToKeyboard) explicitBundle=\(explicitReturnBundleID ?? "nil") resolvedBundle=\(returnBundleID ?? "nil") pid=\(returnProcessID.map(String.init) ?? "nil")")
        for line in urlDebugLines.prefix(80) {
            appendReturnTrace("keyboardURLDebug \(line)")
        }
        appLog.notice("handleOpenURL: action=\(action, privacy: .public), source=\(source ?? "nil", privacy: .public), return=\(shouldReturnToKeyboard, privacy: .public), bundle=\(returnBundleID ?? "nil", privacy: .public), pid=\(returnProcessID.map(String.init) ?? "nil", privacy: .public)")
        if source == "keyboard" {
            appendKeyboardWakePasteboardTrace(reason: "openURL")
            clearKeyboardWakeRequest()
        }
        if action == "record" {
            if source == "keyboard" {
                await setKeyboardStandby(true)
                await startKeyboardRecording(commandID: nil, allowSessionStart: true)
            } else {
                await toggleRecording()
            }
            if shouldReturnToKeyboard {
                await returnToPreviousAppSoon(bundleID: returnBundleID)
            }
        } else if action == "standby" {
            if shouldReturnToKeyboard {
                await prepareKeyboardAndReturnToPreviousApp(bundleID: returnBundleID)
            } else {
                await setKeyboardStandby(true)
            }
        }
    }

    private func waitForInitialRenderOpportunity() async {
        if let task = initialRenderDelayTask {
            await task.value
            return
        }

        let task = Task<Void, Never> {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        initialRenderDelayTask = task
        await task.value
    }

    func setKeyboardStandby(_ enabled: Bool) async {
        keyboardStandbyEnabled = enabled
        configureKeyboardServer()

        if enabled {
            do {
                try await keyboardAudioSession.start()
                try keyboardServer.start()
                publishKeyboardStatus(.standby, message: "Ready")
                scheduleHostAudioSessionExpiry()
            } catch {
                errorMessage = "Keyboard standby unavailable: \(error.localizedDescription)"
                publishKeyboardStatus(.error, message: error.localizedDescription)
            }
        } else {
            hostAudioSessionExpiryTask?.cancel()
            hostAudioSessionExpiryTask = nil
            keyboardServer.stop()
            keyboardAudioSession.stop()
            publishKeyboardStatus(.idle)
        }
    }

    private func scheduleHostAudioSessionExpiry() {
        hostAudioSessionExpiryTask?.cancel()
        hostAudioSessionExpiryTask = nil
        guard keyboardStandbyEnabled,
              keyboardAudioSession.isActive,
              let seconds = hostAudioSessionLength.seconds
        else { return }

        hostAudioSessionExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.expireHostAudioSessionIfIdle()
        }
    }

    private func expireHostAudioSessionIfIdle() {
        guard keyboardStandbyEnabled, keyboardAudioSession.isActive else { return }
        guard !keyboardAudioSession.isRecording,
              !recorder.isRecording,
              !isHostRecordStarting,
              !phase.isBusy
        else {
            scheduleHostAudioSessionExpiry()
            return
        }
        keyboardServer.stop()
        keyboardAudioSession.stop()
        publishKeyboardStatus(.idle, message: "Host audio session expired")
    }

    private func applyKeyboardParameters(_ items: [URLQueryItem], allowCorrectionMode: Bool) {
        for item in items {
            switch item.name {
            case "correction_mode":
                if allowCorrectionMode,
                   let value = item.value,
                   let nextMode = CorrectionModeID(rawValue: value) {
                    correctionMode = nextMode
                }
            case "languages":
                let ids = item.value?
                    .split(separator: ",")
                    .map { String($0) } ?? []
                if !ids.isEmpty {
                    selectedLanguageIDs = Set(ASRLanguageSelection.validatedIDs(
                        ids,
                        supportedOptions: config.supportedLanguageOptions
                    ))
                    persistLanguageSelection()
                }
            default:
                break
            }
        }
    }

    private func handlePendingKeyboardWakeRequest(reason: String) async {
        guard let pasteboard = UIPasteboard(name: Self.keyboardWakePasteboardName, create: false),
              let text = pasteboard.string,
              let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            appLog.notice("keyboardWakeRequest: none for \(reason, privacy: .public)")
            return
        }

        let id = payload["id"] as? String ?? "unknown"
        let source = payload["source"] as? String
        let action = payload["action"] as? String ?? "standby"
        let shouldReturn = payload["return"] as? Bool ?? false
        let createdAt = payload["created_at"] as? TimeInterval ?? 0
        let age = Date().timeIntervalSince1970 - createdAt
        let explicitReturnBundleID = (payload["return_bundle"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let returnProcessID = returnProcessID(from: payload["return_pid"])
        let returnBundleID = resolvedReturnBundleID(
            explicitBundleID: explicitReturnBundleID,
            sourceApplication: nil,
            processID: returnProcessID
        )
        let correctionModeValue = payload["correction_mode"] as? String
        resetReturnTrace("wakeRequest id=\(id) reason=\(reason) source=\(source ?? "nil") action=\(action) return=\(shouldReturn) explicitBundle=\(explicitReturnBundleID ?? "nil") resolvedBundle=\(returnBundleID ?? "nil") pid=\(returnProcessID.map(String.init) ?? "nil") age=\(String(format: "%.3f", age))")
        appendKeyboardWakePayloadTrace(payload, reason: reason)

        if source != "keyboard" || createdAt <= 0 || age > Self.keyboardWakeMaxAge {
            appLog.notice("keyboardWakeRequest: clearing stale/invalid id=\(id, privacy: .public), source=\(source ?? "nil", privacy: .public), age=\(age, privacy: .public)")
            appendReturnTrace("wakeRequest staleOrInvalid source=\(source ?? "nil") age=\(String(format: "%.3f", age))")
            clearKeyboardWakeRequest()
            return
        }

        appLog.notice("keyboardWakeRequest: handling id=\(id, privacy: .public), reason=\(reason, privacy: .public), action=\(action, privacy: .public), return=\(shouldReturn, privacy: .public), bundle=\(returnBundleID ?? "nil", privacy: .public), pid=\(returnProcessID.map(String.init) ?? "nil", privacy: .public), age=\(age, privacy: .public)")
        clearKeyboardWakeRequest()

        if action == "record",
           let correctionModeValue,
           let nextMode = CorrectionModeID(rawValue: correctionModeValue) {
            correctionMode = nextMode
        }

        switch action {
        case "record":
            await setKeyboardStandby(true)
            await startKeyboardRecording(commandID: nil, allowSessionStart: true)
            if shouldReturn {
                await returnToPreviousAppSoon(bundleID: returnBundleID)
            }
        case "standby":
            if shouldReturn {
                await prepareKeyboardAndReturnToPreviousApp(bundleID: returnBundleID)
            } else {
                await setKeyboardStandby(true)
            }
        default:
            appLog.notice("keyboardWakeRequest: unsupported action \(action, privacy: .public)")
        }
    }

    private func clearKeyboardWakeRequest() {
        UIPasteboard(name: Self.keyboardWakePasteboardName, create: false)?.string = nil
    }

    private func appendKeyboardWakePasteboardTrace(reason: String) {
        guard let pasteboard = UIPasteboard(name: Self.keyboardWakePasteboardName, create: false),
              let text = pasteboard.string,
              let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            appendReturnTrace("keyboardWakePayload unavailable reason=\(reason)")
            return
        }
        appendKeyboardWakePayloadTrace(payload, reason: reason)
    }

    private func appendKeyboardWakePayloadTrace(_ payload: [String: Any], reason: String) {
        let explicitBundle = (payload["return_bundle"] as? String) ?? "nil"
        let pid = returnProcessID(from: payload["return_pid"]).map(String.init) ?? "nil"
        appendReturnTrace("keyboardWakePayload reason=\(reason) explicitBundle=\(explicitBundle) pid=\(pid)")
    }

    private func returnProcessID(from value: Any?) -> Int32? {
        if let number = value as? NSNumber {
            let pid = number.int32Value
            return pid > 0 ? pid : nil
        }
        if let int = value as? Int {
            let pid = Int32(int)
            return pid > 0 ? pid : nil
        }
        if let string = value as? String,
           let pid = Int32(string.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0 {
            return pid
        }
        return nil
    }

    private func resolvedReturnBundleID(
        explicitBundleID: String?,
        sourceApplication: String?,
        processID: Int32?
    ) -> String? {
        if let explicitBundleID = explicitBundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
           isUsableReturnBundleID(explicitBundleID) {
            appendReturnTrace("resolvedReturnBundleID explicit=\(explicitBundleID)")
            return explicitBundleID
        }

        if let sourceApplication = sourceApplication?.trimmingCharacters(in: .whitespacesAndNewlines),
           isUsableReturnBundleID(sourceApplication) {
            appLog.notice("resolvedReturnBundleID: using sourceApplication \(sourceApplication, privacy: .public)")
            appendReturnTrace("resolvedReturnBundleID sourceApplication=\(sourceApplication)")
            return sourceApplication
        }

        if let processID {
            appendReturnTrace("resolvedReturnBundleID pidLookupSkipped pid=\(processID)")
        }

        appendReturnTrace("resolvedReturnBundleID unresolved explicit=\(explicitBundleID ?? "nil") sourceApplication=\(sourceApplication ?? "nil") pid=\(processID.map(String.init) ?? "nil")")
        return nil
    }

    private func prepareKeyboardAndReturnToPreviousApp(bundleID: String?) async {
        appLog.notice("prepareKeyboardAndReturnToPreviousApp: bundle=\(bundleID ?? "nil", privacy: .public)")
        await setKeyboardStandby(true)
        await returnToPreviousAppSoon(bundleID: bundleID)
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func returnToPreviousAppSoon(bundleID: String?) async {
        appendReturnTrace("returnToPreviousAppSoon start bundle=\(bundleID ?? "nil")")
        appLog.notice("returnToPreviousAppSoon: start bundle=\(bundleID ?? "nil", privacy: .public)")
        guard let bundleID else {
            appLog.notice("returnToPreviousAppSoon: no return bundle available")
            appendReturnTrace("return skipped missingBundle")
            showTransient("Ready. Tap the top-left back arrow to return.")
            return
        }

        let retryDelays: [UInt64] = [
            350_000_000,
            450_000_000,
            650_000_000,
            900_000_000,
        ]

        for (index, delay) in retryDelays.enumerated() {
            try? await Task.sleep(nanoseconds: delay)
            appendReturnTrace("return attempt=\(index + 1) bundle=\(bundleID)")
            appLog.notice("returnToPreviousAppSoon: attempt \(index + 1, privacy: .public), bundle=\(bundleID, privacy: .public)")
            NSLog("Typeforme return-to-keyboard: attempt \(index + 1), bundleID=\(bundleID)")
            if openApplication(bundleID: bundleID) {
                appLog.notice("returnToPreviousAppSoon: returned via LSApplicationWorkspace bundle")
                appendReturnTrace("return success LSApplicationWorkspace attempt=\(index + 1) bundle=\(bundleID)")
                NSLog("Typeforme return-to-keyboard: returned via LSApplicationWorkspace bundle")
                return
            }
        }

        appLog.notice("returnToPreviousAppSoon: all attempts failed")
        appendReturnTrace("return failed allAttempts bundle=\(bundleID)")
        showTransient("Ready. Tap the top-left back arrow to return.")
    }

    private func isUsableReturnBundleID(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "<null>" else { return false }
        guard isBundleIdentifierShape(trimmed) else { return false }
        guard trimmed != Bundle.main.bundleIdentifier else { return false }
        guard !trimmed.hasPrefix("com.typeforme.") else { return false }
        guard !trimmed.hasPrefix("com.btcdtc.typeforme") else { return false }
        return true
    }

    private func isBundleIdentifierShape(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        for part in parts {
            guard !part.isEmpty else { return false }
            guard part.allSatisfy({ character in
                character.isLetter || character.isNumber || character == "-"
            }) else { return false }
        }
        return true
    }

    private func openApplication(bundleID: String) -> Bool {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != Bundle.main.bundleIdentifier else {
            appendReturnTrace("openApplication invalid bundle=\(trimmed)")
            NSLog("Typeforme return-to-keyboard: invalid return bundle \(trimmed)")
            return false
        }
        guard let workspaceClass = objc_getClass("LSApplicationWorkspace") as? AnyObject else {
            appendReturnTrace("openApplication LSApplicationWorkspace unavailable bundle=\(trimmed)")
            NSLog("Typeforme return-to-keyboard: LSApplicationWorkspace unavailable")
            return false
        }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard let workspace = workspaceClass.perform(defaultSelector)?.takeUnretainedValue() as? NSObject else {
            appendReturnTrace("openApplication defaultWorkspace unavailable bundle=\(trimmed)")
            NSLog("Typeforme return-to-keyboard: defaultWorkspace unavailable")
            return false
        }
        let openSelector = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: openSelector),
              let imp = workspace.method(for: openSelector)
        else {
            appendReturnTrace("openApplication openApplicationWithBundleID unavailable bundle=\(trimmed)")
            NSLog("Typeforme return-to-keyboard: openApplicationWithBundleID unavailable")
            return false
        }
        typealias OpenApplication = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let openApplication = unsafeBitCast(imp, to: OpenApplication.self)
        let didOpen = openApplication(workspace, openSelector, trimmed as NSString)
        appLog.notice("openApplication: bundle=\(trimmed, privacy: .public), result=\(didOpen, privacy: .public)")
        appendReturnTrace("openApplication bundle=\(trimmed) result=\(didOpen)")
        NSLog("Typeforme return-to-keyboard: openApplicationWithBundleID \(trimmed) result=\(didOpen)")
        return didOpen
    }

    private func configureKeyboardServer() {
        keyboardServer.statusProvider = { [weak self] in
            guard let self else { return .idle }
            return await MainActor.run {
                let base = self.keyboardBridgeStatus
                guard base.state == .recording else {
                    return base
                }
                let level = self.keyboardAudioSession.isRecording
                    ? self.keyboardAudioSession.level
                    : self.recorder.level
                return base.withAudioLevel(level)
            }
        }
        keyboardServer.onCommand = { [weak self] command in
            guard let self else {
                return KeyboardBridgeStatus(commandID: command.id, state: .error, message: "Typeforme is unavailable")
            }
            return await self.handleKeyboardCommand(command)
        }
    }

    private func configureKeyboardDarwinBridge() {
        keyboardDarwinObservers.forEach { $0.stopObserving() }
        keyboardDarwinObservers = [
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.requestStartDictation) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.keyboardStandbyEnabled || self.keyboardAudioSession.isRecording else { return }
                    self.activeKeyboardTextEditContext = nil
                    self.activeKeyboardDictationContext = nil
                    self.keyboardCaptureStartedFromKeyboard = true
                    await self.startKeyboardRecording(commandID: nil, allowSessionStart: false)
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.requestStopDictation) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.keyboardStandbyEnabled || self.keyboardAudioSession.isRecording else { return }
                    await self.stopAndSend(keyboardCommandID: nil)
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.requestCancelDictation) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activeKeyboardTextEditContext = nil
                    self.activeKeyboardDictationContext = nil
                    self.keyboardCaptureStartedFromKeyboard = false
                    if self.keyboardAudioSession.isRecording {
                        self.keyboardAudioSession.cancelRecording()
                    } else {
                        _ = self.recorder.stop(deactivateSession: false)
                    }
                    self.releaseIdleTimer()
                    await self.resumeKeyboardStandbyAfterCommand()
                    self.publishKeyboardStatus(.standby, message: "Ready")
                    KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                }
            },
            KeyboardDarwinBridge.observe(KeyboardDarwinNotificationName.requestSessionStatus) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.keyboardAudioSession.isActive {
                        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.sessionStarted)
                    }
                    if self.keyboardAudioSession.isRecording {
                        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStarted)
                    }
                }
            },
        ]
    }

    private func handleKeyboardCommand(_ command: KeyboardBridgeCommand) async -> KeyboardBridgeStatus {
        guard keyboardStandbyEnabled || keyboardAudioSession.isRecording else {
            publishKeyboardStatus(.idle, commandID: command.id, message: "Keyboard standby is off")
            return keyboardBridgeStatus
        }
        guard Date().timeIntervalSince1970 - command.createdAt < 60 else {
            publishKeyboardStatus(.error, commandID: command.id, message: "Keyboard command expired")
            return keyboardBridgeStatus
        }
        switch command.action {
        case .start:
            if let nextMode = CorrectionModeID(rawValue: command.correctionMode) {
                correctionMode = nextMode
            }
            activeKeyboardTextEditContext = command.textEditContext
            activeKeyboardDictationContext = command.dictationContext
            keyboardCaptureStartedFromKeyboard = true
            await startKeyboardRecording(commandID: command.id, allowSessionStart: false)
        case .stop:
            await stopAndSend(keyboardCommandID: command.id)
        case .cancel:
            activeKeyboardTextEditContext = nil
            activeKeyboardDictationContext = nil
            keyboardCaptureStartedFromKeyboard = false
            if keyboardAudioSession.isRecording {
                keyboardAudioSession.cancelRecording()
            } else {
                _ = recorder.stop(deactivateSession: false)
            }
            releaseIdleTimer()
            await resumeKeyboardStandbyAfterCommand()
            publishKeyboardStatus(.standby, commandID: command.id, message: "Ready")
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
            resetCorrectionModeToDefault()
        case .configure:
            activeKeyboardTextEditContext = nil
            activeKeyboardDictationContext = nil
            keyboardCaptureStartedFromKeyboard = false
            publishKeyboardStatus(.standby, commandID: command.id, message: "Ready")
        case .restyleText:
            await restyleKeyboardText(command)
        }
        return keyboardBridgeStatus
    }

    private func restyleKeyboardText(_ command: KeyboardBridgeCommand) async {
        guard !isBusy else {
            publishKeyboardStatus(.error, commandID: command.id, message: "Typeforme is busy")
            return
        }
        let requestedCorrectionMode = CorrectionModeID(rawValue: command.correctionMode) ?? config.correctionMode
        guard let source = command.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty
        else {
            publishKeyboardStatus(.error, commandID: command.id, message: "Nothing to rewrite")
            return
        }
        correctionMode = requestedCorrectionMode
        defer { resetCorrectionModeToDefault() }

        publishKeyboardStatus(.sending, commandID: command.id, message: "Rewriting text")
        await refreshRoute(force: true, probeAllEndpoints: false)
        guard let baseURL = routeStatus.activeURL else {
            setFailure("Bridge unavailable. Check pairing, Local URL, or Cloud URL.")
            publishKeyboardStatus(.error, commandID: command.id, message: errorMessage ?? "Bridge unavailable")
            return
        }

        do {
            setPhase(.restyling)
            let client = BridgeClient(baseURL: baseURL, token: config.token)
            let response = try await client.restyle(
                sessionID: nil,
                rawTranscript: source,
                languageIDs: activeLanguageIDs,
                correctionMode: requestedCorrectionMode
            )
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                setFailure("Mac returned an empty result.")
                publishKeyboardStatus(.error, commandID: command.id, message: errorMessage ?? "Empty result")
                return
            }

            resultText = text
            lastGeneratedResultText = text
            rawTranscript = source
            sessionID = response.sessionID
            latestServerTiming = ServerTimingSummary(
                transcriptionLatencyMs: nil,
                correctionLatencyMs: response.correctionLatencyMs ?? response.latencyMs,
                totalLatencyMs: response.latencyMs
            )
            UIPasteboard.general.string = text
            errorMessage = nil
            applyCorrectionMetadata(status: response.correctionStatus, error: response.correctionError)
            setPhase(.success(.copied))
            publishKeyboardStatus(
                .result,
                commandID: command.id,
                message: "Rewritten",
                resultText: text,
                rawTranscriptLength: source.count
            )
        } catch {
            if let bridgeError = error as? BridgeClientError,
               case .unauthorizedOrUnavailable = bridgeError {
                routeFetchedAt = nil
            }
            setFailure(error.localizedDescription)
            publishKeyboardStatus(.error, commandID: command.id, message: error.localizedDescription)
        }
    }

    private func startKeyboardRecording(commandID: String?, allowSessionStart: Bool) async {
        if keyboardAudioSession.isRecording {
            keyboardCaptureStartedFromKeyboard = true
            publishKeyboardStatus(.recording, commandID: commandID, message: "Recording")
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStarted)
            return
        }
        if !keyboardAudioSession.isActive {
            guard allowSessionStart else {
                keyboardCaptureStartedFromKeyboard = false
                resetCorrectionModeToDefault()
                publishKeyboardStatus(.idle, commandID: commandID, message: "Keyboard audio session is not active")
                KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                return
            }
            do {
                try await keyboardAudioSession.start()
                scheduleHostAudioSessionExpiry()
            } catch {
                keyboardCaptureStartedFromKeyboard = false
                resetCorrectionModeToDefault()
                setFailure(error.localizedDescription)
                publishKeyboardStatus(.error, commandID: commandID, message: error.localizedDescription)
                KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
                await resumeKeyboardStandbyAfterCommand()
                return
            }
        }
        do {
            _ = try keyboardAudioSession.beginRecording()
            keyboardCaptureStartedFromKeyboard = true
            acquireIdleTimer()
            setPhase(.recording)
            publishKeyboardStatus(.recording, commandID: commandID, message: "Recording")
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStarted)
        } catch {
            keyboardCaptureStartedFromKeyboard = false
            setFailure(error.localizedDescription)
            publishKeyboardStatus(.error, commandID: commandID, message: error.localizedDescription)
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.dictationStopped)
            await resumeKeyboardStandbyAfterCommand()
        }
    }

    private func resumeKeyboardStandbyAfterCommand() async {
        guard keyboardStandbyEnabled else { return }
        guard !keyboardAudioSession.isRecording else { return }
        guard !isHostRecordStarting, !phase.isBusy else { return }
        do {
            try await keyboardAudioSession.start()
            try keyboardServer.start()
            publishKeyboardStatus(.standby, message: "Ready")
            scheduleHostAudioSessionExpiry()
        } catch {
            // Don't touch `phase` here — this tail runs after every
            // dictation; a transient server error would otherwise clobber
            // the `.success(.copied)` phase the user just earned. Banner +
            // status carry the signal instead.
            errorMessage = "Keyboard standby refresh failed: \(error.localizedDescription)"
            publishKeyboardStatus(.error, message: error.localizedDescription)
        }
    }

    private func scheduleKeyboardStandbyRefresh() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self?.resumeKeyboardStandbyAfterCommand()
        }
    }

    private func publishKeyboardPasteboardResult(_ text: String) {
        UIPasteboard.general.string = text
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.transcriptionReady)
    }

    private func publishKeyboardStatus(
        _ state: KeyboardBridgeState,
        commandID: String? = nil,
        message: String? = nil,
        resultText: String? = nil,
        audioDurationSeconds: Double? = nil,
        audioByteCount: Int? = nil,
            rawTranscriptLength: Int? = nil
    ) {
        let status = KeyboardBridgeStatus(
            commandID: commandID,
            state: state,
            message: message ?? KeyboardBridgeStatus.idle.message,
            resultText: resultText,
            audioDurationSeconds: audioDurationSeconds,
            audioByteCount: audioByteCount,
            rawTranscriptLength: rawTranscriptLength,
            defaultCorrectionMode: config.correctionMode.rawValue
        )
        keyboardBridgeStatus = status
    }

    private func applyCorrectionMetadata(status correctionStatus: String?, error correctionError: String?) {
        if correctionStatus == "error" {
            let message = correctionError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            setFailure(message.isEmpty ? "Mac correction failed." : message)
            return
        }
        if correctionStatus == "timeout" {
            errorMessage = nil
            setPhase(.success(.copied))
            showTransient("Correction timed out; copied transcript")
            return
        }
        errorMessage = nil
        setPhase(.success(.copied))
        showTransient("Copied")
    }

    private func isBenignEmptyTranscript(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("empty transcript")
            || message.contains("audio produced an empty transcript")
            || message.contains("asr return empty")
    }

    // MARK: - Phase / transient state

    private func setPhase(_ next: AppPhase) {
        phase = next
        phaseResetTask?.cancel()
        phaseResetTask = nil
        switch next {
        case .success, .failure:
            phaseResetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.phaseAutoResetDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    if case .success = self.phase {
                        self.phase = .idle
                    } else if case .failure = self.phase {
                        self.phase = .idle
                    }
                }
            }
        default:
            break
        }
    }

    private func setFailure(_ message: String) {
        errorMessage = message
        setPhase(.failure(message))
    }

    private func showTransient(_ message: String) {
        transientMessage = message
        transientMessageTask?.cancel()
        transientMessageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.transientMessage = nil
            }
        }
    }

    private var returnTraceURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.returnTraceLogName)
    }

    private func resetReturnTrace(_ message: String) {
        guard let url = returnTraceURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try returnTraceLine(message).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            appLog.error("return trace reset failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func appendReturnTrace(_ message: String) {
        guard let url = returnTraceURL,
              let data = returnTraceLine(message).data(using: .utf8)
        else { return }
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                resetReturnTrace(message)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            appLog.error("return trace append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func returnTraceLine(_ message: String) -> String {
        "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    }

    // MARK: - Idle timer

    /// Multiple paths can ask the screen to stay on; track holders so we don't
    /// drop it back to default while one path is still recording.
    private func acquireIdleTimer() {
        idleTimerHolders += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func releaseIdleTimer() {
        idleTimerHolders = max(0, idleTimerHolders - 1)
        if idleTimerHolders == 0 {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - App lifecycle

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleEnteredBackground()
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWillEnterForeground()
            }
        })
    }

    private func startNetworkPathMonitor() {
        networkPathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = Self.networkSignature(for: path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.networkPathSignature == nil {
                    self.networkPathSignature = signature
                    return
                }
                let now = Date()
                let signatureChanged = self.networkPathSignature != signature
                let shouldRefreshSameSignature = !signatureChanged
                    && path.status == .satisfied
                    && path.usesInterfaceType(.wifi)
                    && self.routeStatus.activeKind == .local
                    && self.shouldRefreshRouteForSameSignaturePathUpdate(at: now)
                guard signatureChanged || shouldRefreshSameSignature else { return }
                if signatureChanged {
                    self.networkPathSignature = signature
                }
                self.lastNetworkPathRefreshAt = now
                self.routeFetchedAt = nil
                self.routeStatus = BridgeRouteStatus()
                if self.isConfigured {
                    await self.refreshRoute(force: true)
                }
            }
        }
        networkPathMonitor.start(queue: networkPathQueue)
    }

    private func shouldRefreshRouteForSameSignaturePathUpdate(at now: Date) -> Bool {
        guard let lastNetworkPathRefreshAt else { return true }
        return now.timeIntervalSince(lastNetworkPathRefreshAt) >= Self.networkPathSameSignatureRefreshInterval
    }

    nonisolated private static func networkSignature(for path: NWPath) -> String {
        [
            path.status == .satisfied ? "up" : "down",
            path.usesInterfaceType(.wifi) ? "wifi" : "",
            path.usesInterfaceType(.cellular) ? "cellular" : "",
            path.usesInterfaceType(.wiredEthernet) ? "wired" : "",
            path.usesInterfaceType(.loopback) ? "loopback" : "",
            path.isExpensive ? "expensive" : "",
            path.isConstrained ? "constrained" : "",
        ].filter { !$0.isEmpty }.joined(separator: ":")
    }

    private func handleEnteredBackground() {
        // Backgrounding kills the AVAudioSession we're recording on. Cancel
        // the in-flight recording so we don't ship an empty / corrupted file
        // to the Bridge on resume.
        if recorder.isRecording || (hostRecordingUsesKeyboardAudioSession && keyboardAudioSession.isRecording) {
            if hostRecordingUsesKeyboardAudioSession {
                keyboardAudioSession.cancelRecording()
                hostRecordingUsesKeyboardAudioSession = false
                keyboardCaptureStartedFromKeyboard = false
            } else {
                _ = recorder.stop(deactivateSession: true)
            }
            releaseIdleTimer()
            isHostRecordStarting = false
            hostHoldReleasePending = false
            setPhase(.failure("Recording stopped — app went to background."))
        }
    }

    private func handleWillEnterForeground() {
        // Warm route status for the UI. Hot recording/rewrite paths request a
        // fast route separately so Cloud diagnostics never block input.
        routeFetchedAt = nil
        Task {
            await refreshRoute(force: true)
            _ = try? await refreshMacSettings()
        }
    }
}

private struct RecordingFileInfo {
    let durationSeconds: Double?
    let byteCount: Int
    let sampleRate: Double?
    let channelCount: AVAudioChannelCount?
    let fileExtension: String

    init(url: URL) {
        fileExtension = url.pathExtension.isEmpty ? "audio" : url.pathExtension.lowercased()
        if let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 {
            durationSeconds = Double(file.length) / file.fileFormat.sampleRate
            sampleRate = file.fileFormat.sampleRate
            channelCount = file.fileFormat.channelCount
        } else {
            durationSeconds = nil
            sampleRate = nil
            channelCount = nil
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    var isTooShort: Bool {
        if let durationSeconds {
            return durationSeconds < 0.35
        }
        return byteCount <= 44
    }

    var durationLabel: String {
        guard let durationSeconds else { return "unknown-length" }
        return String(format: "%.1fs", durationSeconds)
    }

    var summary: String {
        let kb = Double(byteCount) / 1024
        let format: String
        if let sampleRate, let channelCount {
            format = String(format: ", %@ %.0fkHz %dch", fileExtension, sampleRate / 1000, channelCount)
        } else {
            format = ", \(fileExtension)"
        }
        if let durationSeconds {
            return String(format: "%.2fs, %.0f KB%@", durationSeconds, kb, format)
        }
        return String(format: "unknown duration, %.0f KB%@", kb, format)
    }
}
