import Foundation

struct QwenASRModelSpec: Identifiable, Equatable {
    let id: String
    let label: String
    let note: String
    let modelPathKey: String
    let mmprojPathKey: String
    let modelURLKey: String
    let mmprojURLKey: String
    let defaultModelPath: String
    let defaultMMProjPath: String
    let defaultModelURL: String
    let defaultMMProjURL: String
}

enum QwenASRModelCatalog {
    static let defaultID = "qwen3-asr-1.7b-bf16"

    static let all: [QwenASRModelSpec] = [
        QwenASRModelSpec(
            id: "qwen3-asr-0.6b-q8_0",
            label: "Qwen3-ASR 0.6B Q8_0 (compatibility)",
            note: "Smallest local Qwen-ASR; use only when memory or disk space is tight",
            modelPathKey: AppSettings.Keys.asrQwen06Q8ModelPath,
            mmprojPathKey: AppSettings.Keys.asrQwen06Q8MMProjPath,
            modelURLKey: AppSettings.Keys.asrQwen06Q8ModelDownloadURL,
            mmprojURLKey: AppSettings.Keys.asrQwen06Q8MMProjDownloadURL,
            defaultModelPath: AppPaths.qwen3ASRGGUFFile.path,
            defaultMMProjPath: AppPaths.qwen3ASRMMProjFile.path,
            defaultModelURL: "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/main/Qwen3-ASR-0.6B-Q8_0.gguf?download=true",
            defaultMMProjURL: "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/main/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf?download=true"
        ),
        QwenASRModelSpec(
            id: "qwen3-asr-0.6b-bf16",
            label: "Qwen3-ASR 0.6B BF16 (compatibility)",
            note: "Smaller BF16 model; kept for comparison and lower-memory machines",
            modelPathKey: AppSettings.Keys.asrQwen06BF16ModelPath,
            mmprojPathKey: AppSettings.Keys.asrQwen06BF16MMProjPath,
            modelURLKey: AppSettings.Keys.asrQwen06BF16ModelDownloadURL,
            mmprojURLKey: AppSettings.Keys.asrQwen06BF16MMProjDownloadURL,
            defaultModelPath: AppPaths.qwen3ASR06BF16File.path,
            defaultMMProjPath: AppPaths.qwen3ASR06BF16MMProjFile.path,
            defaultModelURL: "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/main/Qwen3-ASR-0.6B-bf16.gguf?download=true",
            defaultMMProjURL: "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/main/mmproj-Qwen3-ASR-0.6B-bf16.gguf?download=true"
        ),
        QwenASRModelSpec(
            id: "qwen3-asr-1.7b-q8_0",
            label: "Qwen3-ASR 1.7B Q8_0 (compatibility)",
            note: "Space-saving 1.7B build; use when BF16 is too large",
            modelPathKey: AppSettings.Keys.asrQwen17Q8ModelPath,
            mmprojPathKey: AppSettings.Keys.asrQwen17Q8MMProjPath,
            modelURLKey: AppSettings.Keys.asrQwen17Q8ModelDownloadURL,
            mmprojURLKey: AppSettings.Keys.asrQwen17Q8MMProjDownloadURL,
            defaultModelPath: AppPaths.qwen3ASR17Q8File.path,
            defaultMMProjPath: AppPaths.qwen3ASR17Q8MMProjFile.path,
            defaultModelURL: "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/main/Qwen3-ASR-1.7B-Q8_0.gguf?download=true",
            defaultMMProjURL: "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/main/mmproj-Qwen3-ASR-1.7B-Q8_0.gguf?download=true"
        ),
        QwenASRModelSpec(
            id: "qwen3-asr-1.7b-bf16",
            label: "Qwen3-ASR 1.7B BF16 (default)",
            note: "Recommended local ASR model for this project",
            modelPathKey: AppSettings.Keys.asrQwen17BF16ModelPath,
            mmprojPathKey: AppSettings.Keys.asrQwen17BF16MMProjPath,
            modelURLKey: AppSettings.Keys.asrQwen17BF16ModelDownloadURL,
            mmprojURLKey: AppSettings.Keys.asrQwen17BF16MMProjDownloadURL,
            defaultModelPath: AppPaths.qwen3ASR17BF16File.path,
            defaultMMProjPath: AppPaths.qwen3ASR17BF16MMProjFile.path,
            defaultModelURL: "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/main/Qwen3-ASR-1.7B-bf16.gguf?download=true",
            defaultMMProjURL: "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/main/mmproj-Qwen3-ASR-1.7B-bf16.gguf?download=true"
        ),
    ]

    static func spec(for id: String) -> QwenASRModelSpec {
        all.first { $0.id == id } ?? all[0]
    }
}
