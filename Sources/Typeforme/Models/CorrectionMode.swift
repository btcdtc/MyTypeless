import Foundation

enum CorrectionMode: String, Codable, CaseIterable, Sendable {
    case clean = "clean"
    case polish = "polish"
    case polishPlus = "polish_plus"
    case structurePlus = "structure_plus"
    case formalPlus = "formal_plus"

    var displayName: String {
        switch self {
        case .clean:             return "Clean"
        case .polish:            return "Polish"
        case .polishPlus:        return "Polish+"
        case .structurePlus:     return "Structure+"
        case .formalPlus:        return "Formal+"
        }
    }

    var helpText: String {
        switch self {
        case .clean:
            return "Fix punctuation, ASR mistakes, repeated words, and meaningless speech noise without rewriting."
        case .polish:
            return "Improve readability with limited wording changes while keeping the original structure and voice."
        case .polishPlus:
            return "Resolve the full transcript into polished, natural, logically clear text."
        case .structurePlus:
            return "Resolve the full transcript into an actionable note, request, or list."
        case .formalPlus:
            return "Resolve the full transcript into polished professional prose."
        }
    }
}
