import Foundation

enum TextEditValidationError: LocalizedError {
    case parseFailed(String)
    case emptyText
    case invalidAction
    case textTooLong(actual: Int, cap: Int)
    case containsMarkupOrJSON

    var errorDescription: String? {
        switch self {
        case .parseFailed(let why): return "Parse failed: \(why)"
        case .emptyText: return "Empty edit result"
        case .invalidAction: return "Invalid edit action"
        case .textTooLong(let actual, let cap): return "Edit result too long (\(actual) > \(cap))"
        case .containsMarkupOrJSON: return "Edit result contains markup or JSON"
        }
    }
}

enum TextEditValidator {
    static func parseAndValidate(rawOutput: String, for request: TextEditRequest) throws -> TextEditResult {
        let cleaned = ModelOutputCleaner.clean(rawOutput)
        guard let jsonString = ModelOutputCleaner.extractFirstJSONObject(cleaned) else {
            throw TextEditValidationError.parseFailed("no JSON object found")
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw TextEditValidationError.parseFailed("not utf-8")
        }
        let payload: TextEditPayload
        do {
            payload = try JSONDecoder().decode(TextEditPayload.self, from: data)
        } catch {
            throw TextEditValidationError.parseFailed(error.localizedDescription)
        }

        let action = payload.action ?? .replaceTarget
        guard action == .replaceTarget else {
            throw TextEditValidationError.invalidAction
        }
        let result = TextEditResult(action: action, text: payload.text)
        try validate(result, for: request)
        return result
    }

    private static func validate(_ result: TextEditResult, for request: TextEditRequest) throws {
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw TextEditValidationError.emptyText
        }
        let cap = maxOutputCharacters(for: request)
        if result.text.count > cap {
            throw TextEditValidationError.textTooLong(actual: result.text.count, cap: cap)
        }
        if containsMarkupOrJSON(result.text) {
            throw TextEditValidationError.containsMarkupOrJSON
        }
    }

    private static func maxOutputCharacters(for request: TextEditRequest) -> Int {
        let baseline = max(request.targetText.count, request.spokenInstruction.count)
        switch request.intent {
        case .repairSelection:
            return max(80, baseline * 4)
        case .command:
            return max(160, baseline * 8)
        }
    }

    private static func containsMarkupOrJSON(_ s: String) -> Bool {
        if s.contains("```") { return true }
        if s.contains("<think>") || s.contains("</think>") { return true }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") { return true }
        return false
    }

    private struct TextEditPayload: Decodable {
        var action: TextEditAction?
        var text: String
    }
}
