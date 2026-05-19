import Foundation

/// Resolves the active corrector chain per spec §11.
@MainActor
final class CorrectorFactory {
    static let shared = CorrectorFactory()

    private var servers: [String: LlamaCppServerManager] = [:]
    private var activeServerKeyByModelPath: [String: String] = [:]

    /// Explicit backend selection. Do not automatically fall back to another
    /// engine: failures should surface as failures so quality issues are visible.
    func make() -> CorrectorService {
        switch AppSettings.correctionBackend {
        case .qwen35_2B:
            return makeLlama(modelPath: AppSettings.llama2BPath, kind: .qwen35_2B)
        case .qwen35_4B:
            return makeLlama(modelPath: AppSettings.llama4BPath, kind: .qwen35_4B)
        case .qwen35_9B:
            return makeLlama(modelPath: AppSettings.llama9BPath, kind: .qwen35_9B)
        case .externalLMStudio:
            return LMStudioCorrectorService()
        }
    }

    @discardableResult
    func preloadActiveModels() async -> CorrectorPreloadResult {
        switch AppSettings.correctionBackend {
        case .externalLMStudio:
            return .ready(kind: .externalLMStudio, message: "LM Studio is reachable.")
        case .qwen35_2B:
            return await preloadLlama(modelPath: AppSettings.llama2BPath, kind: .qwen35_2B)
        case .qwen35_4B:
            return await preloadLlama(modelPath: AppSettings.llama4BPath, kind: .qwen35_4B)
        case .qwen35_9B:
            return await preloadLlama(modelPath: AppSettings.llama9BPath, kind: .qwen35_9B)
        }
    }

    private func makeLlama(modelPath: String, kind: CorrectionBackendKind) -> CorrectorService {
        AutoInstallingLlamaCorrectorService(
            kind: kind,
            modelPath: modelPath,
            downloadURLString: downloadURLString(for: kind)
        )
    }

    func installedLlamaService(modelPath: String, kind: CorrectionBackendKind) -> CorrectorService {
        guard let server = llamaServer(modelPath: modelPath, kind: kind) else {
            Log.llm.notice("bundled llama-server binary not found; \(kind.rawValue, privacy: .public) unavailable")
            return UnavailableCorrectorService(kind: kind, reason: "Bundled llama-server binary not found")
        }
        return EmbeddedLlamaCorrectorService(kind: kind, server: server)
    }

    private func preloadLlama(modelPath: String, kind: CorrectionBackendKind) async -> CorrectorPreloadResult {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            let modelFile = URL(fileURLWithPath: modelPath).lastPathComponent
            Log.llm.notice("LLM preload skipped; model missing: \(modelFile, privacy: .public)")
            return .missing(kind: kind, message: "Model file is missing: \(modelFile)")
        }
        guard let server = llamaServer(modelPath: modelPath, kind: kind) else {
            Log.llm.notice("LLM preload skipped; bundled llama-server missing")
            return .failed(kind: kind, message: "Bundled llama-server binary not found")
        }
        do {
            _ = try await server.ensureRunning()
            Log.llm.info("LLM preloaded: \(kind.rawValue, privacy: .public)")
            return .ready(kind: kind, message: "\(kind.displayName) is loaded.")
        } catch {
            Log.llm.error("LLM preload failed: \(error.localizedDescription, privacy: .public)")
            return .failed(kind: kind, message: error.localizedDescription)
        }
    }

    private func llamaServer(modelPath: String, kind: CorrectionBackendKind) -> LlamaCppServerManager? {
        guard let binary = AppPaths.bundledLlamaServer else { return nil }
        let coldTimeoutSec = TimeInterval(AppSettings.correctionColdTimeoutMs) / 1000.0
        let serverKey = [
            modelPath,
            binary.path,
            "ctx=\(AppSettings.correctionContextSize)",
            "flash=\(AppSettings.llamaUseFlashAttn)",
            "cold=\(coldTimeoutSec)",
        ].joined(separator: "|")

        if let previousKey = activeServerKeyByModelPath[modelPath],
           previousKey != serverKey,
           let previousServer = servers.removeValue(forKey: previousKey) {
            Task { await previousServer.stop() }
        }

        let server = servers[serverKey] ?? LlamaCppServerManager(
            modelPath: modelPath,
            contextSize: AppSettings.correctionContextSize,
            useFlashAttn: AppSettings.llamaUseFlashAttn,
            binaryURL: binary,
            coldTimeoutSec: coldTimeoutSec
        )
        servers[serverKey] = server
        activeServerKeyByModelPath[modelPath] = serverKey
        return server
    }

    private func downloadURLString(for kind: CorrectionBackendKind) -> String {
        switch kind {
        case .qwen35_2B:
            return AppSettings.llama2BDownloadURL
        case .qwen35_4B:
            return AppSettings.llama4BDownloadURL
        case .qwen35_9B:
            return AppSettings.llama9BDownloadURL
        case .externalLMStudio:
            return ""
        }
    }

    func shutdownAll() async {
        for server in servers.values {
            await server.stop()
        }
        servers.removeAll()
        activeServerKeyByModelPath.removeAll()
    }
}

enum CorrectorPreloadResult: Equatable {
    case ready(kind: CorrectionBackendKind, message: String)
    case missing(kind: CorrectionBackendKind, message: String)
    case failed(kind: CorrectionBackendKind, message: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .ready(_, let message),
             .missing(_, let message),
             .failed(_, let message):
            return message
        }
    }
}

private struct UnavailableCorrectorService: CorrectorService {
    let kind: CorrectionBackendKind
    let reason: String

    func correct(_ request: CorrectionRequest, timeoutMs: Int) async throws -> CorrectionResult {
        throw CorrectorError.unavailable(reason)
    }

    func complete(system: String, user: String, timeoutMs: Int) async throws -> String {
        throw CorrectorError.unavailable(reason)
    }
}

private struct AutoInstallingLlamaCorrectorService: CorrectorService {
    let kind: CorrectionBackendKind
    let modelPath: String
    let downloadURLString: String

    func correct(_ request: CorrectionRequest, timeoutMs: Int) async throws -> CorrectionResult {
        try AppPaths.ensureDirectories()
        try await ModelAutoInstaller.shared.ensureFile(
            atPath: modelPath,
            downloadURLString: downloadURLString,
            label: kind.displayName
        )
        let service = await CorrectorFactory.shared.installedLlamaService(modelPath: modelPath, kind: kind)
        return try await service.correct(request, timeoutMs: timeoutMs)
    }

    func complete(system: String, user: String, timeoutMs: Int) async throws -> String {
        try AppPaths.ensureDirectories()
        try await ModelAutoInstaller.shared.ensureFile(
            atPath: modelPath,
            downloadURLString: downloadURLString,
            label: kind.displayName
        )
        let service = await CorrectorFactory.shared.installedLlamaService(modelPath: modelPath, kind: kind)
        return try await service.complete(system: system, user: user, timeoutMs: timeoutMs)
    }
}
