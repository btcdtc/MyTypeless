import Foundation

enum CorrectionBackendKind: String, Codable, CaseIterable, Sendable {
    case qwen35_2B = "qwen35_2b"
    case qwen35_4B = "qwen35_4b"
    case qwen35_9B = "qwen35_9b"
    case externalLMStudio = "external_lm_studio"

    var displayName: String {
        switch self {
        case .qwen35_2B:        return "Qwen3.5 2B (good)"
        case .qwen35_4B:        return "Qwen3.5 4B (better)"
        case .qwen35_9B:        return "Qwen3.5 9B (best)"
        case .externalLMStudio: return "LM Studio (experimental)"
        }
    }
}
