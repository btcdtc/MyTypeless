import Foundation

enum CorrectionValidationError: LocalizedError {
    case parseFailed(String)
    case emptyText
    case textTooLong(actual: Int, cap: Int)
    case containsMarkupOrJSON

    var errorDescription: String? {
        switch self {
        case .parseFailed(let why):             return "Parse failed: \(why)"
        case .emptyText:                        return "Empty text on commit"
        case .textTooLong(let a, let c):        return "Output too long (\(a) > \(c))"
        case .containsMarkupOrJSON:             return "Output contains markup or JSON"
        }
    }
}

/// Per spec §18.
enum CorrectionValidator {
    static func parseAndValidate(rawOutput: String, for request: CorrectionRequest) throws -> CorrectionResult {
        let cleaned = ModelOutputCleaner.clean(rawOutput)
        guard let jsonString = ModelOutputCleaner.extractFirstJSONObject(cleaned) else {
            throw CorrectionValidationError.parseFailed("no JSON object found")
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw CorrectionValidationError.parseFailed("not utf-8")
        }
        let payload: CorrectionPayload
        do {
            payload = try JSONDecoder().decode(CorrectionPayload.self, from: data)
        } catch {
            throw CorrectionValidationError.parseFailed(error.localizedDescription)
        }
        let result = CorrectionResult(
            action: payload.action ?? .commit,
            text: payload.text,
            risk: payload.risk ?? .low
        )
        try validate(result, for: request)
        return result
    }

    static func validate(_ result: CorrectionResult, for request: CorrectionRequest) throws {
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            throw CorrectionValidationError.emptyText
        }

        // Keep a guardrail against hallucinated essays, but allow normal
        // expansion from punctuation, mixed-language spacing, and structured
        // correction modes.
        let cap = maxOutputCharacters(for: request)
        if result.text.count > cap {
            throw CorrectionValidationError.textTooLong(actual: result.text.count, cap: cap)
        }

        if containsMarkupOrJSON(result.text) {
            throw CorrectionValidationError.containsMarkupOrJSON
        }
    }

    private static func containsMarkupOrJSON(_ s: String) -> Bool {
        if s.contains("```") { return true }
        if s.contains("<think>") || s.contains("</think>") { return true }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") { return true }
        return false
    }

    private static func maxOutputCharacters(for request: CorrectionRequest) -> Int {
        let baseline = request.rawTranscript.count
        switch request.correctionMode {
        case .clean:
            return max(80, baseline * 3)
        case .polish:
            return max(100, baseline * 3)
        case .polishPlus, .formalPlus:
            return max(140, baseline * 4)
        case .structurePlus:
            return max(180, baseline * 6)
        }
    }

    private struct CorrectionPayload: Decodable {
        var action: CorrectionAction?
        var text: String
        var risk: CorrectionRisk?
    }
}
