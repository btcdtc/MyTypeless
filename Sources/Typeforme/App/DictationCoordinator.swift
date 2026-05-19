import Foundation
import Combine

/// Owns the full dictation state machine and orchestrates services.
/// Per spec §7: `idle→recording→transcribing→correcting→(inserting|preview)→success→idle`;
/// any state can fall to `error→idle`.
@MainActor
final class DictationCoordinator: ObservableObject {
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var lastCorrected: String = ""
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var frontmostSnapshot: FrontmostAppSnapshot?
    @Published private(set) var previewCorrectionMode: CorrectionMode?

    private let recorder = AudioRecorder()
    /// Resolved per-request so provider/model setting changes take effect immediately.
    private var asr: ASRService { ASRFactory.shared.get() }
    private var corrector: CorrectorService { CorrectorFactory.shared.make() }
    private let committer = PasteboardTextCommitter()
    private let textEditService: TextEditService
    private let dictionary: UserDictionaryStore

    private var autoStopTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var activeCancelToken: CommitCancellationToken?
    private var remoteBridgeSessionID: String?
    private var activeTextEditTarget: TextEditTargetSnapshot?
    private var activeTextEditIntent: TextEditIntent?
    private var activeDictationContextBefore = ""
    private var activeDictationContextAfter = ""
    private var startInProgress = false
    private var stopAfterStart = false
    private var recordingStartedAt: Date?

    private static let errorResetDelay: TimeInterval = 4.0
    private static let previewResetDelay: TimeInterval = 12.0
    private static let minimumToggleStopInterval: TimeInterval = 0.6

    init(dictionary: UserDictionaryStore) {
        self.dictionary = dictionary
        self.textEditService = TextEditService(dictionary: dictionary)
        recorder.onLevel = { [weak self] level in self?.audioLevel = level }
        recorder.onConfigurationChanged = { [weak self] in
            self?.reportError("Audio device changed mid-recording")
        }
    }

    // MARK: - Public API used by AppDelegate / hotkey

    func toggleDictation() async {
        if startInProgress {
            Log.coordinator.debug("toggle ignored while dictation start is in progress")
            return
        }

        switch state {
        case .idle:
            await startDictation()
        case .recording:
            guard !shouldIgnoreEarlyToggleStop() else { return }
            await stopDictation()
        case .preview, .success, .error:
            // Terminal visible states stay on screen briefly for feedback. A
            // toggle press during that window should start the next dictation,
            // not merely clear the HUD and force a second press.
            reset()
            await startDictation()
        default:
            await cancelDictation()
        }
    }

    func startDictation(intent: TextEditIntent? = nil) async {
        guard state == .idle, !startInProgress else { return }
        if AppSettings.autoCommit && !AccessibilityPermissions.isTrusted {
            AccessibilityPermissions.requestTrustPrompt()
        }

        let sessionID = UUID()
        let cancelToken = CommitCancellationToken()
        activeSessionID = sessionID
        activeCancelToken = cancelToken
        previewCorrectionMode = nil
        startInProgress = true
        stopAfterStart = false
        resetTask?.cancel(); resetTask = nil
        captureFrontmost()
        let focusedTextContext = TextEditTargetCapture.focusedTextContext(in: frontmostSnapshot)
        activeDictationContextBefore = focusedTextContext.before
        activeDictationContextAfter = focusedTextContext.after
        activeTextEditIntent = intent
        if let intent {
            activeTextEditTarget = TextEditTargetCapture.snapshot(
                in: frontmostSnapshot,
                allowFocusedValue: intent == .command
            )
            guard activeTextEditTarget != nil else {
                startInProgress = false
                activeSessionID = nil
                activeCancelToken = nil
                activeTextEditIntent = nil
                reportError("Select text or focus a text field first")
                scheduleAutoReset(after: Self.errorResetDelay)
                return
            }
        } else {
            activeTextEditTarget = TextEditTargetCapture.snapshot(
                in: frontmostSnapshot,
                allowFocusedValue: false
            )
            activeTextEditIntent = activeTextEditTarget == nil ? nil : .repairSelection
        }

        do {
            let startedURL = try await recorder.start()
            startInProgress = false
            guard await isActive(sessionID: sessionID, token: cancelToken) else {
                if let stoppedURL = recorder.stop() {
                    try? FileManager.default.removeItem(at: stoppedURL)
                } else {
                    try? FileManager.default.removeItem(at: startedURL)
                }
                return
            }
            transition(to: .recording)
            scheduleAutoStop(after: AppSettings.maxRecordingDuration)
            if stopAfterStart {
                stopAfterStart = false
                await stopDictation()
            }
        } catch {
            startInProgress = false
            stopAfterStart = false
            guard activeSessionID == sessionID else { return }
            activeSessionID = nil
            activeCancelToken = nil
            reportError(error.localizedDescription)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    func toggleCommandTextEdit() async {
        if startInProgress {
            Log.coordinator.debug("command edit toggle ignored while dictation start is in progress")
            return
        }

        switch state {
        case .idle:
            await startDictation(intent: .command)
        case .recording:
            guard !shouldIgnoreEarlyToggleStop() else { return }
            await stopDictation()
        case .preview, .success, .error:
            reset()
            await startDictation(intent: .command)
        default:
            await cancelDictation()
        }
    }

    func stopDictation() async {
        if startInProgress {
            stopAfterStart = true
            return
        }
        autoStopTask?.cancel(); autoStopTask = nil
        guard state == .recording else { return }
        guard let sessionID = activeSessionID, let cancelToken = activeCancelToken else {
            reportError("Internal state error: missing dictation session")
            scheduleAutoReset(after: Self.errorResetDelay)
            return
        }
        let url = recorder.stop()
        audioLevel = 0
        transition(to: .transcribing)

        guard let url else {
            reportError("No audio captured")
            scheduleAutoReset(after: Self.errorResetDelay)
            return
        }

        let snapshot = frontmostSnapshot
        let selectedCorrectionMode = AppSettings.correctionMode
        let debugLog = DebugLogStore.begin(
            source: AppSettings.processingMode == .client ? "mac-client" : "mac",
            audioURL: url,
            selectedCorrectionMode: selectedCorrectionMode,
            languageIDs: AppSettings.activeLanguageIDs,
            appName: snapshot?.localizedName,
            bundleID: snapshot?.bundleID,
            appCategory: AppCategory.from(bundleID: snapshot?.bundleID)
        )

        if AppSettings.processingMode == .client {
            await processWithRemoteBridge(
                audioURL: url,
                debugLog: debugLog,
                sessionID: sessionID,
                cancelToken: cancelToken,
                snapshot: snapshot,
                selectedCorrectionMode: selectedCorrectionMode
            )
            return
        }

        remoteBridgeSessionID = nil
        var didRecordASR = false
        let asrStarted = Date()
        do {
            let raw = try await asr.transcribe(audioFileURL: url, languageIDs: AppSettings.asrLanguageIDs)
            DebugLogStore.recordASR(
                debugLog,
                text: raw,
                status: "ok",
                latencyMs: elapsedMs(since: asrStarted)
            )
            didRecordASR = true
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            lastTranscript = raw
            try? FileManager.default.removeItem(at: url)

            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                Log.asr.notice("empty transcript — returning to idle without commit")
                activeSessionID = nil
                activeCancelToken = nil
                activeDictationContextBefore = ""
                activeDictationContextAfter = ""
                activeTextEditTarget = nil
                activeTextEditIntent = nil
                transition(to: .idle)
                return
            }

            if let editTarget = activeTextEditTarget,
               let editIntent = activeTextEditIntent {
                transition(to: .correcting)
                do {
                    let editStarted = Date()
                    let result = try await textEditService.edit(
                        intent: editIntent,
                        contextBefore: editTarget.contextBefore,
                        targetText: editTarget.targetText,
                        contextAfter: editTarget.contextAfter,
                        spokenInstruction: trimmed,
                        languageIDs: AppSettings.asrLanguageIDs,
                        appName: snapshot?.localizedName,
                        bundleID: snapshot?.bundleID,
                        appCategory: AppCategory.from(bundleID: snapshot?.bundleID)
                    )
                    try await ensureActive(sessionID: sessionID, token: cancelToken)
                    DebugLogStore.recordCorrection(
                        debugLog,
                        mode: selectedCorrectionMode,
                        text: result.text,
                        status: "text_edit_\(editIntent.rawValue)",
                        latencyMs: elapsedMs(since: editStarted),
                        timeoutMs: AppSettings.correctionTimeoutMs
                    )
                    previewCorrectionMode = selectedCorrectionMode
                    lastCorrected = result.text
                    await finishTextEdit(
                        result,
                        target: editTarget,
                        appSnapshot: snapshot,
                        sessionID: sessionID,
                        cancelToken: cancelToken
                    )
                } catch {
                    try await ensureActive(sessionID: sessionID, token: cancelToken)
                    reportError("Text edit failed: \(error.localizedDescription)")
                    scheduleAutoReset(after: Self.errorResetDelay)
                }
                return
            }

            transition(to: .correcting)
            let request = buildCorrectionRequest(rawTranscript: trimmed)
            let correctionStarted = Date()
            do {
                let result = try await corrector.correct(request, timeoutMs: AppSettings.correctionTimeoutMs)
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                let normalizedResult = normalizeResult(result, correctionMode: request.correctionMode)
                DebugLogStore.recordCorrection(
                    debugLog,
                    mode: request.correctionMode,
                    text: normalizedResult.text,
                    status: "ok",
                    latencyMs: elapsedMs(since: correctionStarted),
                    request: request,
                    timeoutMs: AppSettings.correctionTimeoutMs
                )
                previewCorrectionMode = request.correctionMode
                lastCorrected = normalizedResult.text
                await finish(with: normalizedResult, sessionID: sessionID, cancelToken: cancelToken)
            } catch CorrectorError.empty {
                DebugLogStore.recordCorrection(
                    debugLog,
                    mode: request.correctionMode,
                    text: nil,
                    status: "empty",
                    error: CorrectorError.empty.localizedDescription,
                    request: request,
                    timeoutMs: AppSettings.correctionTimeoutMs
                )
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                Log.coordinator.notice("corrector returned empty — back to idle")
                activeSessionID = nil
                activeCancelToken = nil
                activeTextEditTarget = nil
                activeTextEditIntent = nil
                activeDictationContextBefore = ""
                activeDictationContextAfter = ""
                transition(to: .idle)
            } catch CorrectorError.timeout {
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                let timeoutResult = normalizeResult(
                    CorrectionResult(action: .commit, text: trimmed, risk: .medium),
                    correctionMode: request.correctionMode
                )
                DebugLogStore.recordCorrection(
                    debugLog,
                    mode: request.correctionMode,
                    text: timeoutResult.text,
                    status: "timeout",
                    error: CorrectorError.timeout.localizedDescription,
                    latencyMs: elapsedMs(since: correctionStarted),
                    request: request,
                    timeoutMs: AppSettings.correctionTimeoutMs
                )
                previewCorrectionMode = request.correctionMode
                lastCorrected = timeoutResult.text
                await finish(with: timeoutResult, sessionID: sessionID, cancelToken: cancelToken)
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: url)
            return
        } catch TextCommitterError.cancelled {
            transition(to: .idle)
        } catch {
            if !didRecordASR {
                DebugLogStore.recordASR(
                    debugLog,
                    text: nil,
                    status: "error",
                    error: error.localizedDescription,
                    latencyMs: elapsedMs(since: asrStarted)
                )
            }
            try? FileManager.default.removeItem(at: url)
            guard await isActive(sessionID: sessionID, token: cancelToken) else { return }
            reportError(error.localizedDescription)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    // MARK: - State helpers

    func transition(to next: DictationState) {
        guard state != next else { return }
        Log.coordinator.debug("state: \(self.state.rawValue) → \(next.rawValue)")
        recordingStartedAt = next == .recording ? Date() : nil
        state = next
    }

    private func shouldIgnoreEarlyToggleStop() -> Bool {
        guard let recordingStartedAt else { return false }
        let elapsed = Date().timeIntervalSince(recordingStartedAt)
        guard elapsed < Self.minimumToggleStopInterval else { return false }
        Log.coordinator.debug("toggle stop ignored during recording warmup")
        return true
    }

    func reportError(_ message: String) {
        if let token = activeCancelToken {
            Task { await token.cancel() }
        }
        activeSessionID = nil
        activeCancelToken = nil
        activeTextEditTarget = nil
        activeTextEditIntent = nil
        activeDictationContextBefore = ""
        activeDictationContextAfter = ""
        previewCorrectionMode = nil
        startInProgress = false
        stopAfterStart = false
        recordingStartedAt = nil
        lastError = message
        Log.coordinator.error("\(message, privacy: .public)")
        state = .error
    }

    func reset() {
        autoStopTask?.cancel()
        autoStopTask = nil
        resetTask?.cancel()
        resetTask = nil
        if let token = activeCancelToken {
            Task { await token.cancel() }
        }
        activeSessionID = nil
        activeCancelToken = nil
        startInProgress = false
        stopAfterStart = false
        recordingStartedAt = nil
        lastError = nil
        lastTranscript = ""
        lastCorrected = ""
        previewCorrectionMode = nil
        frontmostSnapshot = nil
        remoteBridgeSessionID = nil
        activeTextEditTarget = nil
        activeTextEditIntent = nil
        activeDictationContextBefore = ""
        activeDictationContextAfter = ""
        audioLevel = 0
        state = .idle
    }

    /// Spec §8: Esc cancels any phase. Tears down the recorder if needed,
    /// cancels pending timers, and goes straight back to idle without
    /// inserting text.
    func cancelDictation() async {
        autoStopTask?.cancel(); autoStopTask = nil
        resetTask?.cancel();     resetTask = nil
        await activeCancelToken?.cancel()
        activeSessionID = nil
        activeCancelToken = nil
        activeTextEditTarget = nil
        activeTextEditIntent = nil
        activeDictationContextBefore = ""
        activeDictationContextAfter = ""
        previewCorrectionMode = nil
        startInProgress = false
        stopAfterStart = false
        recordingStartedAt = nil
        if state == .recording {
            if let url = recorder.stop() {
                try? FileManager.default.removeItem(at: url)
            }
        } else {
            _ = recorder.stop()
        }
        audioLevel = 0
        reset()
    }

    func captureFrontmost() {
        frontmostSnapshot = FrontmostAppCapture.snapshot()
    }

    func setAudioLevel(_ level: Float) {
        audioLevel = max(0, min(1, level))
    }

    func shutdown() {
        autoStopTask?.cancel()
        resetTask?.cancel()
        Task { await activeCancelToken?.cancel() }
        activeSessionID = nil
        activeCancelToken = nil
        activeTextEditTarget = nil
        activeTextEditIntent = nil
        activeDictationContextBefore = ""
        activeDictationContextAfter = ""
        previewCorrectionMode = nil
        recordingStartedAt = nil
        _ = recorder.stop()
    }

    // MARK: - Mode switching (spec §16, allowed only in preview)

    func requestCorrectionModeChange(to newMode: CorrectionMode) async {
        guard state == .preview else { return }
        let raw = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        let previousPreviewMode = previewCorrectionMode
        previewCorrectionMode = newMode

        let sessionID = UUID()
        let cancelToken = CommitCancellationToken()
        activeSessionID = sessionID
        activeCancelToken = cancelToken
        resetTask?.cancel(); resetTask = nil
        transition(to: .correcting)

        if AppSettings.processingMode == .client {
            let didRestyle = await requestRemoteCorrectionModeChange(
                rawTranscript: raw,
                newMode: newMode,
                sessionID: sessionID,
                cancelToken: cancelToken
            )
            if !didRestyle {
                previewCorrectionMode = previousPreviewMode
            }
            return
        }

        let request = buildCorrectionRequest(rawTranscript: raw, correctionModeOverride: newMode)
        do {
            let result = try await corrector.correct(request, timeoutMs: AppSettings.correctionTimeoutMs)
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            let normalizedResult = normalizeResult(result, correctionMode: request.correctionMode)
            lastCorrected = normalizedResult.text
            copyPreviewToPasteboard(normalizedResult)
            transition(to: .preview)
            scheduleAutoReset(after: Self.previewResetDelay)
        } catch is CancellationError {
            previewCorrectionMode = previousPreviewMode
            transition(to: .idle)
        } catch CorrectorError.empty {
            previewCorrectionMode = previousPreviewMode
            transition(to: .idle)
        } catch {
            previewCorrectionMode = previousPreviewMode
            reportError("Re-correction failed: \(error.localizedDescription)")
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    /// Insert the previewed text at the current cursor. Used when autoCommit
    /// is off and the user confirms with Enter (or the Insert button) from
    /// the HUD. Mirrors the autoCommit branch of `finish(with:_:_)` but
    /// re-captures the frontmost app — the user has had time to review and
    /// may have switched apps.
    func commitPreview() async {
        guard state == .preview else { return }
        let text = lastCorrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let snapshot = FrontmostAppCapture.snapshot()
        let sessionID = UUID()
        let cancelToken = CommitCancellationToken()
        activeSessionID = sessionID
        activeCancelToken = cancelToken
        resetTask?.cancel(); resetTask = nil
        transition(to: .inserting)

        do {
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            try await committer.commit(text, to: snapshot, cancelToken: cancelToken)
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            transition(to: .success)
            scheduleAutoReset(after: 0.8)
        } catch is CancellationError {
            transition(to: .idle)
        } catch TextCommitterError.cancelled {
            transition(to: .idle)
        } catch {
            reportError(error.localizedDescription)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    // MARK: - Request building

    private func buildCorrectionRequest(
        rawTranscript: String,
        correctionModeOverride: CorrectionMode? = nil
    ) -> CorrectionRequest {
        let snapshot = frontmostSnapshot
        let category = AppCategory.from(bundleID: snapshot?.bundleID)
        let correctionMode = correctionModeOverride ?? AppSettings.correctionMode
        return CorrectionRequest(
            correctionMode: correctionMode,
            frontmostAppName:  snapshot?.localizedName,
            frontmostBundleID: snapshot?.bundleID,
            appCategory: category,
            languageIDs: AppSettings.activeLanguageIDs,
            rawTranscript: rawTranscript,
            contextBefore: activeDictationContextBefore,
            contextAfter: activeDictationContextAfter,
            numberOutputPreference: AppSettings.numberOutputPreference,
            punctuationPreference: AppSettings.punctuationPreference,
            userDictionary: dictionary.sortedSnapshot()
        )
    }

    private func normalizeResult(_ result: CorrectionResult, correctionMode: CorrectionMode) -> CorrectionResult {
        var normalized = result
        normalized.text = LocaleTextNormalizer.normalize(result.text, languageIDs: AppSettings.activeLanguageIDs)
        normalized.text = TranscriptPostProcessor.clean(
            normalized.text,
            languageIDs: AppSettings.activeLanguageIDs,
            preserveLineBreaks: correctionMode == .structurePlus,
            numberPreference: AppSettings.numberOutputPreference,
            punctuationPreference: AppSettings.punctuationPreference
        )
        return normalized
    }

    private func processWithRemoteBridge(
        audioURL: URL,
        debugLog: DebugLogHandle?,
        sessionID: UUID,
        cancelToken: CommitCancellationToken,
        snapshot: FrontmostAppSnapshot?,
        selectedCorrectionMode: CorrectionMode
    ) async {
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let started = Date()
        do {
            let appCategory = AppCategory.from(bundleID: snapshot?.bundleID)
            let resolved = try await RemoteBridgeClient.resolvedFromSettings(probeAllEndpoints: false)
            let client = resolved.client
            let response = try await client.dictate(
                audioURL: audioURL,
                languageIDs: AppSettings.clientLanguageIDs,
                correctionMode: selectedCorrectionMode,
                appSnapshot: snapshot,
                appCategory: appCategory,
                contextBefore: activeDictationContextBefore,
                contextAfter: activeDictationContextAfter,
                includeRawTranscript: true
            )
            try await ensureActive(sessionID: sessionID, token: cancelToken)

            let raw = response.rawTranscript?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DebugLogStore.recordASR(
                debugLog,
                text: raw.isEmpty ? nil : raw,
                status: raw.isEmpty ? "remote_no_raw" : "remote_ok",
                latencyMs: response.transcriptionLatencyMs ?? elapsedMs(since: started)
            )
            lastTranscript = raw.isEmpty ? response.text : raw
            remoteBridgeSessionID = response.sessionID

            if let editTarget = activeTextEditTarget,
               let editIntent = activeTextEditIntent {
                let spoken = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !spoken.isEmpty else {
                    reportError("Remote transcript was empty")
                    scheduleAutoReset(after: Self.errorResetDelay)
                    return
                }
                transition(to: .correcting)
                let editResponse = try await client.editText(
                    intent: editIntent,
                    contextBefore: editTarget.contextBefore,
                    targetText: editTarget.targetText,
                    contextAfter: editTarget.contextAfter,
                    spokenInstruction: spoken,
                    languageIDs: AppSettings.clientLanguageIDs,
                    appSnapshot: snapshot,
                    appCategory: AppCategory.from(bundleID: snapshot?.bundleID)
                )
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                DebugLogStore.recordCorrection(
                    debugLog,
                    mode: selectedCorrectionMode,
                    text: editResponse.text,
                    status: "remote_text_edit_\(editIntent.rawValue)",
                    error: editResponse.editError,
                    latencyMs: editResponse.editLatencyMs ?? editResponse.latencyMs,
                    timeoutMs: AppSettings.correctionTimeoutMs
                )
                previewCorrectionMode = selectedCorrectionMode
                lastCorrected = editResponse.text
                await finishTextEdit(
                    TextEditResult(action: .replaceTarget, text: editResponse.text),
                    target: editTarget,
                    appSnapshot: snapshot,
                    sessionID: sessionID,
                    cancelToken: cancelToken
                )
                return
            }

            transition(to: .correcting)
            let result = normalizeResult(
                CorrectionResult(action: .commit, text: response.text, risk: .low),
                correctionMode: selectedCorrectionMode
            )
            DebugLogStore.recordCorrection(
                debugLog,
                mode: selectedCorrectionMode,
                text: result.text,
                status: response.correctionStatus,
                error: response.correctionError,
                latencyMs: response.correctionLatencyMs ?? response.latencyMs,
                timeoutMs: AppSettings.correctionTimeoutMs
            )
            previewCorrectionMode = selectedCorrectionMode
            lastCorrected = result.text
            await finish(with: result, sessionID: sessionID, cancelToken: cancelToken)
        } catch is CancellationError {
            transition(to: .idle)
        } catch TextCommitterError.cancelled {
            transition(to: .idle)
        } catch {
            DebugLogStore.recordASR(
                debugLog,
                text: nil,
                status: "remote_error",
                error: error.localizedDescription,
                latencyMs: elapsedMs(since: started)
            )
            guard await isActive(sessionID: sessionID, token: cancelToken) else { return }
            reportError(error.localizedDescription)
            scheduleAutoReset(after: Self.errorResetDelay)
        }
    }

    private func requestRemoteCorrectionModeChange(
        rawTranscript: String,
        newMode: CorrectionMode,
        sessionID: UUID,
        cancelToken: CommitCancellationToken
    ) async -> Bool {
        do {
            let snapshot = frontmostSnapshot
            let resolved = try await RemoteBridgeClient.resolvedFromSettings(probeAllEndpoints: false)
            let response = try await resolved.client.restyle(
                sessionID: remoteBridgeSessionID,
                rawTranscript: rawTranscript,
                languageIDs: AppSettings.clientLanguageIDs,
                correctionMode: newMode,
                appSnapshot: snapshot,
                appCategory: AppCategory.from(bundleID: snapshot?.bundleID),
                contextBefore: activeDictationContextBefore,
                contextAfter: activeDictationContextAfter
            )
            try await ensureActive(sessionID: sessionID, token: cancelToken)
            let result = normalizeResult(
                CorrectionResult(action: .commit, text: response.text, risk: .low),
                correctionMode: newMode
            )
            remoteBridgeSessionID = response.sessionID
            previewCorrectionMode = newMode
            lastCorrected = result.text
            copyPreviewToPasteboard(result)
            transition(to: .preview)
            scheduleAutoReset(after: Self.previewResetDelay)
            return true
        } catch is CancellationError {
            transition(to: .idle)
            return false
        } catch {
            reportError("Remote re-correction failed: \(error.localizedDescription)")
            scheduleAutoReset(after: Self.errorResetDelay)
            return false
        }
    }

    // MARK: - Commit

    private func finish(
        with result: CorrectionResult,
        sessionID: UUID,
        cancelToken: CommitCancellationToken
    ) async {
        if AppSettings.autoCommit {
            transition(to: .inserting)
            do {
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                try await committer.commit(result.text, to: frontmostSnapshot, cancelToken: cancelToken)
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                transition(to: .success)
                scheduleAutoReset(after: 0.8)
            } catch is CancellationError {
                transition(to: .idle)
            } catch TextCommitterError.cancelled {
                transition(to: .idle)
            } catch {
                reportError(error.localizedDescription)
                scheduleAutoReset(after: Self.errorResetDelay)
            }
        } else {
            activeSessionID = nil
            activeCancelToken = nil
            copyPreviewToPasteboard(result)
            transition(to: .preview)
            scheduleAutoReset(after: Self.previewResetDelay)
        }
    }

    private func finishTextEdit(
        _ result: TextEditResult,
        target: TextEditTargetSnapshot,
        appSnapshot: FrontmostAppSnapshot?,
        sessionID: UUID,
        cancelToken: CommitCancellationToken
    ) async {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            activeSessionID = nil
            activeCancelToken = nil
            transition(to: .idle)
            return
        }

        if AppSettings.autoCommit {
            transition(to: .inserting)
            do {
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                try await committer.commitTextEdit(
                    text,
                    target: target,
                    appSnapshot: appSnapshot,
                    cancelToken: cancelToken
                )
                try await ensureActive(sessionID: sessionID, token: cancelToken)
                activeTextEditTarget = nil
                activeTextEditIntent = nil
                transition(to: .success)
                scheduleAutoReset(after: 0.8)
            } catch is CancellationError {
                transition(to: .idle)
            } catch TextCommitterError.cancelled {
                transition(to: .idle)
            } catch {
                reportError(error.localizedDescription)
                scheduleAutoReset(after: Self.errorResetDelay)
            }
        } else {
            activeSessionID = nil
            activeCancelToken = nil
            activeTextEditTarget = nil
            activeTextEditIntent = nil
            PasteboardTextCommitter.copyForManualPaste(text)
            transition(to: .preview)
            scheduleAutoReset(after: Self.previewResetDelay)
        }
    }

    // MARK: - Private

    private func scheduleAutoStop(after seconds: TimeInterval) {
        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.stopDictation()
        }
    }

    private func scheduleAutoReset(after seconds: TimeInterval) {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.reset()
        }
    }

    private func ensureActive(sessionID: UUID, token: CommitCancellationToken) async throws {
        guard await isActive(sessionID: sessionID, token: token) else {
            throw CancellationError()
        }
    }

    private func isActive(sessionID: UUID, token: CommitCancellationToken) async -> Bool {
        let cancelled = await token.isCancelled()
        return activeSessionID == sessionID && !cancelled
    }

    private func copyPreviewToPasteboard(_ result: CorrectionResult) {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        PasteboardTextCommitter.copyForManualPaste(text)
    }

    private func elapsedMs(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}
