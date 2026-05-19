import Foundation

@MainActor
final class ASRFactory {
    static let shared = ASRFactory()

    private var whisper: WhisperKitASRService?
    private var qwenLlama: QwenLlamaASRService?
    private var qwenLlamaKey: String?

    var whisperKitCacheDir: URL { AppPaths.whisperKitCacheDir }

    func whisperKitCachedModelInfo(modelName: String) -> WhisperKitModelCacheInfo? {
        WhisperKitASRService.cachedModelInfo(for: modelName)
    }

    func get() -> ASRService {
        switch AppSettings.asrProvider.lowercased() {
        case "qwen3-asr-llama":
            return AutoInstallingQwenLlamaASRService()
        default:
            return whisperService(for: AppSettings.asrModel)
        }
    }

    func prepareWhisperKitModel(
        modelName: String,
        progress: (@MainActor @Sendable (WhisperKitPreparationProgress) -> Void)? = nil,
        stage: (@MainActor @Sendable (WhisperKitPreparationStage) -> Void)? = nil
    ) async throws -> URL {
        try await whisperService(for: modelName).prepareModel(progress: progress, stage: stage)
    }

    func deleteWhisperKitModel(modelName: String) throws {
        if whisper?.modelName == modelName {
            whisper = nil
        }
        guard let cached = whisperKitCachedModelInfo(modelName: modelName) else { return }
        try FileManager.default.removeItem(at: cached.modelFolder)
    }

    func preloadCachedActiveModel() async {
        let provider = AppSettings.asrProvider.lowercased()
        if provider == "qwen3-asr-llama" {
            await preloadQwenLlama()
            return
        }

        guard provider == "whisperkit" || provider.isEmpty else {
            Log.asr.info("ASR preload skipped for external provider: \(provider, privacy: .public)")
            return
        }

        let modelName = AppSettings.asrModel
        guard whisperKitCachedModelInfo(modelName: modelName) != nil else {
            Log.asr.notice("WhisperKit preload skipped; model not cached: \(modelName, privacy: .public)")
            return
        }
        do {
            _ = try await whisperService(for: modelName).prepareModel()
            Log.asr.info("WhisperKit preloaded: \(modelName, privacy: .public)")
        } catch {
            Log.asr.error("WhisperKit preload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func warmQwenLlama() async throws {
        try await ensureQwenLlamaInstalled()
        guard let service = qwenLlamaServiceAfterInstall() else {
            throw LlamaServerError.launchFailed("Bundled llama-server binary not found")
        }
        try await service.preload()
    }

    func ensureQwenLlamaInstalled() async throws {
        try AppPaths.ensureDirectories()
        try await ModelAutoInstaller.shared.ensureFile(
            atPath: AppSettings.asrQwenLlamaModelPath,
            downloadURLString: AppSettings.asrQwenLlamaModelDownloadURL,
            label: "Qwen3-ASR model"
        )
        try await ModelAutoInstaller.shared.ensureFile(
            atPath: AppSettings.asrQwenLlamaMMProjPath,
            downloadURLString: AppSettings.asrQwenLlamaMMProjDownloadURL,
            label: "Qwen3-ASR mmproj"
        )
    }

    func preloadQwenLlama() async {
        guard FileManager.default.fileExists(atPath: AppSettings.asrQwenLlamaModelPath),
              FileManager.default.fileExists(atPath: AppSettings.asrQwenLlamaMMProjPath)
        else {
            Log.asr.notice("Qwen3-ASR preload skipped; model files not installed")
            return
        }
        do {
            try await warmQwenLlama()
            Log.asr.info("Qwen3-ASR GGUF preloaded")
        } catch {
            Log.asr.error("Qwen3-ASR GGUF preload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopQwenLlama() async {
        await qwenLlama?.stop()
        qwenLlama = nil
        qwenLlamaKey = nil
    }

    private func whisperService(for modelName: String) -> WhisperKitASRService {
        if whisper == nil || whisper?.modelName != modelName {
            whisper = WhisperKitASRService(modelName: modelName)
        }
        return whisper!
    }

    func qwenLlamaServiceAfterInstall() -> QwenLlamaASRService? {
        qwenLlamaService()
    }

    private func qwenLlamaService() -> QwenLlamaASRService? {
        guard let binary = AppPaths.bundledLlamaServer else { return nil }
        let modelPath = AppSettings.asrQwenLlamaModelPath
        let mmprojPath = AppSettings.asrQwenLlamaMMProjPath
        let key = [
            modelPath,
            mmprojPath,
            binary.path,
            "timeout=\(AppSettings.asrQwenLlamaTimeoutSeconds)",
            "maxTokens=\(AppSettings.asrQwenLlamaMaxTokens)",
        ].joined(separator: "|")
        if qwenLlama == nil || qwenLlamaKey != key {
            let server = LlamaCppServerManager(
                modelPath: modelPath,
                contextSize: 4096,
                useFlashAttn: AppSettings.llamaUseFlashAttn,
                binaryURL: binary,
                pidFile: AppPaths.asrLlamaPidFile,
                requiredFiles: [mmprojPath],
                extraArguments: ["--mmproj", mmprojPath],
                coldTimeoutSec: min(max(AppSettings.asrQwenLlamaTimeoutSeconds, 30), 180)
            )
            qwenLlama = QwenLlamaASRService(server: server)
            qwenLlamaKey = key
        }
        return qwenLlama
    }
}

private struct UnavailableASRService: ASRService {
    let reason: String

    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        throw ASRAudioSupportError.httpStatus(503, reason)
    }
}

private struct AutoInstallingQwenLlamaASRService: ASRService {
    func transcribe(audioFileURL: URL, languageIDs: [String]) async throws -> String {
        try await ASRFactory.shared.ensureQwenLlamaInstalled()
        guard let service = await ASRFactory.shared.qwenLlamaServiceAfterInstall() else {
            throw ASRAudioSupportError.httpStatus(503, "Bundled llama-server binary not found")
        }
        return try await service.transcribe(audioFileURL: audioFileURL, languageIDs: languageIDs)
    }
}
