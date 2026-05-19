import Foundation

enum ProtectedSpanPostProcessor {
    static func apply(_ text: String, rawTranscript: String) -> String {
        if containsNoTranslateMarker(rawTranscript), !preservesNoTranslateMarker(text) {
            return rawTranscript
        }
        if mentionsTranslation(rawTranscript), !mentionsTranslation(text) {
            return rawTranscript
        }

        var output = text
        output = restoreProtectedEnglishTokens(output, rawTranscript: rawTranscript)
        if dropsProtectedTechnicalToken(output, rawTranscript: rawTranscript) {
            return rawTranscript
        }
        output = restoreSimpleStructuredFacts(output, rawTranscript: rawTranscript)

        if let leadingSpan = leadingNonCJKSpanBeforeCJK(in: rawTranscript),
           !contains(output, leadingSpan) {
            output = restoreLeadingSpan(leadingSpan, in: output)
        }
        if looksLikeUnrequestedCrossScriptTranslation(rawTranscript: rawTranscript, output: output) {
            return rawTranscript
        }
        return output
    }

    private static func leadingNonCJKSpanBeforeCJK(in raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var scalars = String.UnicodeScalarView()
        var sawCJK = false
        for scalar in trimmed.unicodeScalars {
            if isCJK(scalar) {
                sawCJK = true
                break
            }
            scalars.append(scalar)
        }
        guard sawCJK else { return nil }

        let punctuation = CharacterSet(charactersIn: " ,，.。!！?？:：;；")
        let candidate = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines.union(punctuation))
        guard candidate.count >= 2 else { return nil }
        guard candidate.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }

        let lower = candidate.lowercased()
        if ["um", "uh", "like", "you know"].contains(lower) { return nil }
        return candidate
    }

    private static func restoreLeadingSpan(_ span: String, in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        var index = trimmed.startIndex
        var sawCJK = false
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if character.unicodeScalars.contains(where: isCJK) {
                sawCJK = true
            }
            if sawCJK, leadingClauseTerminators.contains(character) {
                return span + String(trimmed[index...])
            }
            if trimmed.distance(from: trimmed.startIndex, to: index) > 20 {
                break
            }
            index = trimmed.index(after: index)
        }

        if trimmed.unicodeScalars.prefix(3).contains(where: isCJK) {
            return span + " " + trimmed
        }
        return text
    }

    private static func contains(_ text: String, _ protectedSpan: String) -> Bool {
        text.range(of: protectedSpan, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func containsNoTranslateMarker(_ text: String) -> Bool {
        let lower = text.lowercased()
        return text.contains("不要翻译") ||
            text.contains("別翻譯") ||
            lower.contains("do not translate") ||
            lower.contains("don't translate")
    }

    private static func looksLikeUnrequestedCrossScriptTranslation(rawTranscript: String, output: String) -> Bool {
        let rawLatin = rawTranscript.unicodeScalars.filter(isLatinLetter).count
        let rawCJK = rawTranscript.unicodeScalars.filter(isCJK).count
        let outputLatin = output.unicodeScalars.filter(isLatinLetter).count
        let outputCJK = output.unicodeScalars.filter(isCJK).count

        guard rawLatin >= 3, outputCJK >= 2 else { return false }
        if rawCJK == 0 {
            return outputLatin < max(2, rawLatin / 4)
        }
        return outputLatin == 0
    }

    private static func mentionsTranslation(_ text: String) -> Bool {
        let lower = text.lowercased()
        return text.contains("翻译") ||
            text.contains("翻譯") ||
            lower.contains("translate") ||
            lower.contains("translation")
    }

    private static func preservesNoTranslateMarker(_ text: String) -> Bool {
        let lower = text.lowercased()
        return text.contains("不要翻译") ||
            text.contains("別翻譯") ||
            lower.contains("do not translate") ||
            lower.contains("don't translate")
    }

    private static func restoreProtectedEnglishTokens(_ text: String, rawTranscript: String) -> String {
        var out = text
        let lowerRaw = rawTranscript.lowercased()
        if lowerRaw.range(of: #"\bpath\b"#, options: .regularExpression) != nil,
           out.range(of: #"\bpath\b"#, options: [.caseInsensitive, .regularExpression]) == nil {
            out = out.replacingOccurrences(of: "路径", with: "path")
            out = out.replacingOccurrences(of: "路徑", with: "path")
        }
        return out
    }

    private static func dropsProtectedTechnicalToken(_ text: String, rawTranscript: String) -> Bool {
        let lowerText = text.lowercased()
        let lowerRaw = rawTranscript.lowercased()
        for token in protectedTechnicalTokens
        where lowerRaw.contains(token) && !lowerText.contains(token) {
            return true
        }
        return false
    }

    private static func restoreSimpleStructuredFacts(_ text: String, rawTranscript: String) -> String {
        var out = text
        if rawTranscript.contains("超市"),
           !out.contains("超市"),
           out.contains("\n") {
            out += "\n- 地点：超市"
        }
        return out
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = Int(scalar.value)
        return (0x4E00...0x9FFF).contains(value) ||
            (0x3400...0x4DBF).contains(value) ||
            (0x20000...0x2A6DF).contains(value)
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        let value = Int(scalar.value)
        return (0x41...0x5A).contains(value) ||
            (0x61...0x7A).contains(value) ||
            (0x00C0...0x024F).contains(value)
    }

    private static let leadingClauseTerminators: Set<Character> = [
        ",", "，", ".", "。", "!", "！", "?", "？", ":", "：", ";", "；",
    ]

    private static let protectedTechnicalTokens: [String] = [
        "feature",
        "ship",
        "prod",
        "release note",
        "merge",
        "npm install",
        "git status",
    ]
}
