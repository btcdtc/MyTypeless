import Foundation

/// A speech vocabulary term. Unlike text-expansion dictionaries, these entries
/// are candidates for the correction model, not unconditional replacements.
struct DictionaryEntry: Codable, Hashable, Sendable, Identifiable {
    static let suggestedTypes = [
        "person",
        "organization",
        "product",
        "project",
        "place",
        "technical_term",
        "acronym",
        "phrase",
        "other",
    ]

    var id: UUID
    var type: String
    var surface: String

    init(
        id: UUID = UUID(),
        type: String = "other",
        surface: String
    ) {
        self.id = id
        self.type = DictionaryEntry.normalizedType(type)
        self.surface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        !surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayType: String {
        type.replacingOccurrences(of: "_", with: " ")
    }

    var searchTerms: [String] {
        DictionaryEntry.cleanedList([surface])
    }

    private static func normalizedType(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "other" }
        return trimmed
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }

    static func cleanedList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            output.append(trimmed)
        }
        return output
    }
}
