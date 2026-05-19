import Foundation

struct LocalLlamaModelSpec: Identifiable {
    let label: String
    let pathKey: String
    let urlKey: String
    let defaultPath: String
    let backendKind: CorrectionBackendKind
    let note: String

    var id: String { pathKey }
}

let localLlamaModels: [LocalLlamaModelSpec] = [
    LocalLlamaModelSpec(
        label: "Qwen3.5 2B (good)",
        pathKey: AppSettings.Keys.llama2BPath,
        urlKey: AppSettings.Keys.llama2BDownloadURL,
        defaultPath: AppPaths.llama2BFile.path,
        backendKind: .qwen35_2B,
        note: "Good local correction model"
    ),
    LocalLlamaModelSpec(
        label: "Qwen3.5 4B (better)",
        pathKey: AppSettings.Keys.llama4BPath,
        urlKey: AppSettings.Keys.llama4BDownloadURL,
        defaultPath: AppPaths.llama4BFile.path,
        backendKind: .qwen35_4B,
        note: "Better local correction model"
    ),
    LocalLlamaModelSpec(
        label: "Qwen3.5 9B (best)",
        pathKey: AppSettings.Keys.llama9BPath,
        urlKey: AppSettings.Keys.llama9BDownloadURL,
        defaultPath: AppPaths.llama9BFile.path,
        backendKind: .qwen35_9B,
        note: "Best local correction model"
    ),
]
