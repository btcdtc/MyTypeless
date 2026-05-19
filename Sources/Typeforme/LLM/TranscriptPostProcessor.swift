import Foundation

enum TranscriptPostProcessor {
    static func clean(
        _ text: String,
        languageIDs: [String],
        preserveLineBreaks: Bool = false,
        appendTerminalPunctuation: Bool = true,
        numberPreference: NumberOutputPreference = .automatic,
        punctuationPreference: PunctuationOutputPreference = .normal
    ) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return out }

        let preferChinesePunctuation = containsCJK(out)

        out = normalizeLineBreaks(out)
        out = removeMandarinSentenceParticles(out)
        out = normalizeWhitespace(out, preserveLineBreaks: preserveLineBreaks)
        out = collapseRepeatedMandarinFillers(out)
        out = repairDictatedCommaWord(out)
        out = normalizeRepeatedPunctuation(out, preferChinesePunctuation: preferChinesePunctuation)
        out = normalizePunctuationSpacing(
            out,
            preferChinesePunctuation: preferChinesePunctuation,
            preserveLineBreaks: preserveLineBreaks
        )
        out = normalizeWhitespace(out, preserveLineBreaks: preserveLineBreaks)
        out = applyNumberPreference(out, numberPreference: numberPreference)
        out = insertChineseQuestionBreaks(out, preferChinesePunctuation: preferChinesePunctuation)
        if appendTerminalPunctuation && punctuationPreference != .spaces {
            out = appendMissingTerminalPunctuation(out, preferChinesePunctuation: preferChinesePunctuation)
        }
        out = normalizePunctuationSpacing(
            out,
            preferChinesePunctuation: preferChinesePunctuation,
            preserveLineBreaks: preserveLineBreaks
        )
        if preserveLineBreaks {
            out = normalizeStructuredLayout(out)
        }
        out = applyPunctuationPreference(
            out,
            punctuationPreference: punctuationPreference,
            preserveLineBreaks: preserveLineBreaks
        )
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func applyNumberPreference(_ text: String, numberPreference: NumberOutputPreference) -> String {
        guard numberPreference == .digits else { return text }
        var out = replaceChineseNumberWordsWithDigits(text)
        out = replaceEnglishNumberWordsWithDigits(out)
        return out
    }

    private static func replaceChineseNumberWordsWithDigits(_ text: String) -> String {
        replaceRegexMatches(
            text,
            pattern: #"([零〇一二两三四五六七八九十百千万]{1,12})(?=(?:个月|小时|分钟|毫秒|秒钟|美元|人民币|公里|千米|厘米|毫米|公斤|千克|毫升|GB|MB|KB|个|只|条|次|件|块|元|秒|天|周|年|月|日|号|岁|点|分|%|％))"#
        ) { groups in
            guard let raw = groups.first,
                  let value = parseChineseNumber(raw)
            else { return nil }
            return String(value)
        }
    }

    private static func replaceEnglishNumberWordsWithDigits(_ text: String) -> String {
        let unitWords = [
            "tests?", "items?", "times?", "minutes?", "seconds?", "hours?", "days?", "weeks?", "months?", "years?",
            "dollars?", "percent", "files?", "tokens?", "eggs?", "models?", "people", "users?", "bugs?", "issues?", "points?"
        ].joined(separator: "|")
        let ones = "zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen"
        let tens = "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety"
        let numberPattern = "(?:\(ones)|(?:\(tens))(?:[- ](?:one|two|three|four|five|six|seven|eight|nine))?)"
        return replaceRegexMatches(
            text,
            pattern: #"(?i)\b(\#(numberPattern))\b(?=\s+(?:\#(unitWords))\b)"#
        ) { groups in
            guard let raw = groups.first,
                  let value = parseEnglishNumber(raw)
            else { return nil }
            return String(value)
        }
    }

    private static func parseChineseNumber(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }

        if text.allSatisfy({ chineseDigitValue($0) != nil }),
           text.count > 1 {
            let digits = text.compactMap(chineseDigitValue).map(String.init).joined()
            return Int(digits)
        }

        var total = 0
        var section = 0
        var number = 0
        var sawToken = false

        for char in text {
            if let digit = chineseDigitValue(char) {
                number = digit
                sawToken = true
                continue
            }
            guard let unit = chineseUnitValue(char) else { return nil }
            sawToken = true
            if unit == 10_000 {
                section += number
                if section == 0 { section = 1 }
                total += section * unit
                section = 0
            } else {
                if number == 0 { number = 1 }
                section += number * unit
            }
            number = 0
        }

        guard sawToken else { return nil }
        return total + section + number
    }

    private static func chineseDigitValue(_ char: Character) -> Int? {
        switch char {
        case "零", "〇": return 0
        case "一": return 1
        case "二", "两": return 2
        case "三": return 3
        case "四": return 4
        case "五": return 5
        case "六": return 6
        case "七": return 7
        case "八": return 8
        case "九": return 9
        default: return nil
        }
    }

    private static func chineseUnitValue(_ char: Character) -> Int? {
        switch char {
        case "十": return 10
        case "百": return 100
        case "千": return 1_000
        case "万": return 10_000
        default: return nil
        }
    }

    private static func parseEnglishNumber(_ text: String) -> Int? {
        let normalized = text.lowercased().replacingOccurrences(of: "-", with: " ")
        var total = 0
        for token in normalized.split(separator: " ") {
            switch token {
            case "zero": total += 0
            case "one": total += 1
            case "two": total += 2
            case "three": total += 3
            case "four": total += 4
            case "five": total += 5
            case "six": total += 6
            case "seven": total += 7
            case "eight": total += 8
            case "nine": total += 9
            case "ten": total += 10
            case "eleven": total += 11
            case "twelve": total += 12
            case "thirteen": total += 13
            case "fourteen": total += 14
            case "fifteen": total += 15
            case "sixteen": total += 16
            case "seventeen": total += 17
            case "eighteen": total += 18
            case "nineteen": total += 19
            case "twenty": total += 20
            case "thirty": total += 30
            case "forty": total += 40
            case "fifty": total += 50
            case "sixty": total += 60
            case "seventy": total += 70
            case "eighty": total += 80
            case "ninety": total += 90
            default: return nil
            }
        }
        return total
    }

    private static func removeMandarinSentenceParticles(_ text: String) -> String {
        // Remove spoken tail particles when ASR leaves them before punctuation
        // or at sentence end: "好不好用哦,," -> "好不好用,,".
        regexReplace(
            text,
            pattern: #"(?<=\p{Han})\s*(哦|噢|喔)(?=\s*($|[,，。.!?！？]))"#,
            with: ""
        )
    }

    private static func repairDictatedCommaWord(_ text: String) -> String {
        // Common mixed ASR artifact when the user says "逗号": "好几个,号".
        regexReplace(
            text,
            pattern: #"(好?几个|很多|好多|多个|一个|这个|那个)[,，]\s*号"#,
            with: "$1逗号"
        )
    }

    private static func collapseRepeatedMandarinFillers(_ text: String) -> String {
        regexReplace(
            text,
            pattern: #"(这个|那个|就是|嗯|呃|啊)(?:\s*[，,]?\s*)\1+"#,
            with: "$1"
        )
    }

    private static func normalizeRepeatedPunctuation(_ text: String, preferChinesePunctuation: Bool) -> String {
        let comma = preferChinesePunctuation ? "，" : ", "
        var out = regexReplace(text, pattern: #"[,，](?:\s*[,，])+"#, with: comma)
        out = regexReplace(out, pattern: #"[,，]\s*([。.!?！？])"#, with: "$1")
        out = regexReplace(out, pattern: #"([。.!?！？])(?:\s*[。.!?！？])+"#, with: "$1")
        return out
    }

    private static func normalizePunctuationSpacing(
        _ text: String,
        preferChinesePunctuation: Bool,
        preserveLineBreaks: Bool
    ) -> String {
        let whitespace = preserveLineBreaks ? #"[ \t]+"# : #"\s+"#
        var out = regexReplace(text, pattern: "\(whitespace)([,，。.!?！？])", with: "$1")
        if preferChinesePunctuation {
            out = regexReplace(out, pattern: #"(?<=\p{Han})\s*,\s*"#, with: "，")
            out = regexReplace(out, pattern: #",\s*(?=\p{Han})"#, with: "，")
            out = regexReplace(out, pattern: "([，。！？])\(whitespace)", with: "$1")
        } else {
            out = regexReplace(out, pattern: #",\s*"#, with: ", ")
        }
        return out
    }

    private static func normalizeWhitespace(_ text: String, preserveLineBreaks: Bool) -> String {
        guard preserveLineBreaks else {
            return regexReplace(text, pattern: #"\s+"#, with: " ")
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                regexReplace(String(line), pattern: #"[ \t]+"#, with: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
    }

    private static func normalizeLineBreaks(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func normalizeStructuredLayout(_ text: String) -> String {
        var out = text
        if !out.contains("\n") {
            out = regexReplace(
                out,
                pattern: #"^(.+?https?://\S+)[，,]\s*然后(.+)$"#,
                with: "- 操作：$1\n- 下一步：$2"
            )
        }
        if !out.contains("\n") {
            out = regexReplace(
                out,
                pattern: #"^(.+?\bprod\b)[，,]\s*但是\s*(.+?)[，,]\s*先(不要\s+.+)$"#,
                with: "- 动作：$1\n- 状态：$2\n- 指令：先$3"
            )
        }
        if !out.contains("\n") {
            out = regexReplace(out, pattern: #"(?<!^)\s+-\s+"#, with: "\n- ")
            out = regexReplace(
                out,
                pattern: #"(?<!^)\s+(?=(要买|时间|地点|对象|事件|动作|状态|约束|问题|下一步|URL|Path)[：:])"#,
                with: "\n"
            )
        }
        out = regexReplace(out, pattern: #"\n{3,}"#, with: "\n\n")
        return out
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    private static func applyPunctuationPreference(
        _ text: String,
        punctuationPreference: PunctuationOutputPreference,
        preserveLineBreaks: Bool
    ) -> String {
        switch punctuationPreference {
        case .normal:
            return text
        case .english:
            return normalizeEnglishPunctuation(text, preserveLineBreaks: preserveLineBreaks)
        case .spaces:
            let replaced = replaceSentencePunctuationWithSpaces(text)
            return normalizeWhitespace(replaced, preserveLineBreaks: preserveLineBreaks)
        }
    }

    private static func normalizeEnglishPunctuation(_ text: String, preserveLineBreaks: Bool) -> String {
        var out = text
        let replacements: [(String, String)] = [
            ("，", ", "), ("。", "."), ("！", "!"), ("？", "?"),
            ("：", ":"), ("；", ";"), ("、", ", "),
            ("“", "\""), ("”", "\""), ("‘", "'"), ("’", "'"),
            ("（", "("), ("）", ")"), ("【", "["), ("】", "]"),
            ("《", "<"), ("》", ">"), ("…", "..."),
        ]
        for (source, target) in replacements {
            out = out.replacingOccurrences(of: source, with: target)
        }
        out = normalizeWhitespace(out, preserveLineBreaks: preserveLineBreaks)
        out = regexReplace(out, pattern: #"\s+([,.;:!?])"#, with: "$1")
        out = regexReplace(out, pattern: #"([,;!?])(?=\S)"#, with: "$1 ")
        return out
    }

    private static func replaceSentencePunctuationWithSpaces(_ text: String) -> String {
        let chars = Array(text)
        var output = ""
        output.reserveCapacity(text.count)
        for index in chars.indices {
            let char = chars[index]
            if shouldReplaceWithSpace(char, previous: previousNonWhitespace(in: chars, before: index), next: nextNonWhitespace(in: chars, after: index)) {
                output.append(" ")
            } else {
                output.append(char)
            }
        }
        return output
    }

    private static func shouldReplaceWithSpace(_ char: Character, previous: Character?, next: Character?) -> Bool {
        if ["，", "。", "！", "？", "：", "；", "、"].contains(char) {
            return true
        }
        switch char {
        case ",", ";", "!", "?":
            if char == ",",
               previous.map(isASCIIDigit) == true,
               next.map(isASCIIDigit) == true {
                return false
            }
            return true
        case ":":
            return next != "/"
        case ".":
            guard let previous, let next else { return true }
            return !(isASCIIAlphaNumeric(previous) && isASCIIAlphaNumeric(next))
        default:
            return false
        }
    }

    private static func previousNonWhitespace(in chars: [Character], before index: Int) -> Character? {
        guard index > chars.startIndex else { return nil }
        var cursor = index - 1
        while cursor >= chars.startIndex {
            let char = chars[cursor]
            if !isWhitespace(char) { return char }
            if cursor == chars.startIndex { break }
            cursor -= 1
        }
        return nil
    }

    private static func nextNonWhitespace(in chars: [Character], after index: Int) -> Character? {
        guard index < chars.index(before: chars.endIndex) else { return nil }
        var cursor = index + 1
        while cursor < chars.endIndex {
            let char = chars[cursor]
            if !isWhitespace(char) { return char }
            cursor += 1
        }
        return nil
    }

    private static func insertChineseQuestionBreaks(_ text: String, preferChinesePunctuation: Bool) -> String {
        guard preferChinesePunctuation else { return text }
        var out = text
        for phrase in ["咋样", "怎么样", "如何"] {
            out = out.replacingOccurrences(of: phrase + phrase, with: phrase + "？" + phrase)
        }
        out = regexReplace(
            out,
            pattern: #"(咋样|怎么样|如何)(?=(快|赶紧|麻烦|帮|给|说|讲|告诉|看看|看一下|查|算))"#,
            with: "$1？"
        )
        return out
    }

    private static func appendMissingTerminalPunctuation(_ text: String, preferChinesePunctuation: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, preferChinesePunctuation || containsCJK(trimmed) else { return trimmed }
        guard !hasTerminalPunctuation(trimmed) else { return trimmed }
        return trimmed + (isQuestionLike(trimmed) ? "？" : "。")
    }

    private static func hasTerminalPunctuation(_ text: String) -> Bool {
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            let ch = text[previous]
            if trailingClosers.contains(ch) || isWhitespace(ch) {
                index = previous
                continue
            }
            return terminalPunctuation.contains(ch)
        }
        return false
    }

    private static func isQuestionLike(_ text: String) -> Bool {
        let zhMarkers = [
            "吗", "呢", "什么", "怎么", "为什么", "为啥", "哪", "谁",
            "多少", "多大", "多长", "多高", "多远", "多久",
            "是不是", "能不能", "可不可以", "可以吗", "行吗", "对吗",
            "咋样", "怎么样", "如何",
        ]
        for marker in zhMarkers where text.contains(marker) { return true }

        let lower = text.lowercased()
        let enMarkers = [
            "what ", "how ", "why ", "where ", "when ", "who ", "which ",
            "can you", "could you", "would you", "is it", "are you", "do you",
        ]
        for marker in enMarkers where lower.contains(marker) { return true }
        return false
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func isASCIIAlphaNumeric(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && character.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
        }
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && character.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
        }
    }

    private static func regexReplace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func replaceRegexMatches(
        _ text: String,
        pattern: String,
        transform: ([String]) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        var out = text
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: out) else { continue }
            var groups: [String] = []
            for index in 1..<match.numberOfRanges {
                let nsRange = match.range(at: index)
                guard nsRange.location != NSNotFound,
                      let range = Range(nsRange, in: out)
                else { continue }
                groups.append(String(out[range]))
            }
            guard let replacement = transform(groups) else { continue }
            out.replaceSubrange(matchRange, with: replacement)
        }
        return out
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
            (0x3400...0x4DBF).contains(Int(scalar.value)) ||
            (0x20000...0x2A6DF).contains(Int(scalar.value))
        }
    }

    private static let terminalPunctuation: Set<Character> = [".", "!", "?", "。", "！", "？", "…", ":", "："]
    private static let trailingClosers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "）", "】", "》", "」", "』"]
}
