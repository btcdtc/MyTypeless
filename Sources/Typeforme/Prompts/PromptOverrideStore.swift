import Foundation

enum PromptOverrideStore {
    static let systemFileName = "system.md"

    static func systemFile(in folder: URL = AppSettings.promptOverrideFolder) -> URL {
        folder.appendingPathComponent(systemFileName)
    }

    static func modePromptFile(
        for mode: CorrectionMode,
        in folder: URL = AppSettings.promptOverrideFolder
    ) -> URL {
        folder.appendingPathComponent("mode-\(mode.rawValue).md")
    }

    static func readSystemPrompt(in folder: URL = AppSettings.promptOverrideFolder) -> String? {
        readNonEmpty(systemFile(in: folder))
    }

    static func readModePrompt(
        for mode: CorrectionMode,
        in folder: URL = AppSettings.promptOverrideFolder
    ) -> String? {
        readNonEmpty(modePromptFile(for: mode, in: folder))
    }

    private static func readNonEmpty(_ file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
