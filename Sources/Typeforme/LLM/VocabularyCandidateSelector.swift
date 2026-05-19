import Foundation

struct VocabularyCandidatePayload: Codable, Sendable, Equatable {
    let type: String
    let surface: String
}

enum VocabularyCandidateSelector {
    static let defaultLimit = 40

    private struct ContextSignals {
        var person = 0
        var project = 0
        var technical = 0
        var product = 0
        var organization = 0
        var place = 0
    }

    static func select(
        from entries: [DictionaryEntry],
        rawText: String,
        extraContext: [String] = [],
        limit: Int = defaultLimit
    ) -> [DictionaryEntry] {
        let text = normalize(rawText)
        let context = normalize(extraContext.joined(separator: " "))
        let phoneticText = phoneticKey(rawText)
        let loosePhoneticText = loosePinyinKey(rawText)
        let compactText = compactNormalized(rawText)
        let rawSoundexTokens = soundexTokens(in: rawText)
        let signals = contextSignals(for: [text, context].joined(separator: " "))

        let scored = entries.compactMap { entry -> (DictionaryEntry, Int)? in
            let score = score(
                entry,
                text: text,
                context: context,
                phoneticText: phoneticText,
                loosePhoneticText: loosePhoneticText,
                compactText: compactText,
                rawSoundexTokens: rawSoundexTokens,
                signals: signals
            )
            guard score > 0 else { return nil }
            return (entry, score)
        }

        return scored
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                if $0.0.type != $1.0.type { return $0.0.type < $1.0.type }
                return $0.0.surface < $1.0.surface
            }
            .prefix(limit)
            .map(\.0)
    }

    static func promptPayload(
        from entries: [DictionaryEntry],
        rawText: String,
        extraContext: [String] = [],
        limit: Int = defaultLimit
    ) -> [VocabularyCandidatePayload] {
        select(from: entries, rawText: rawText, extraContext: extraContext, limit: limit).map { entry in
            VocabularyCandidatePayload(type: entry.type, surface: entry.surface)
        }
    }

    private static func score(
        _ entry: DictionaryEntry,
        text: String,
        context: String,
        phoneticText: String,
        loosePhoneticText: String,
        compactText: String,
        rawSoundexTokens: Set<String>,
        signals: ContextSignals
    ) -> Int {
        var score = basePriority(for: entry.type)
        var matched = false

        for term in entry.searchTerms {
            let normalizedTerm = normalize(term)
            if !normalizedTerm.isEmpty, text.contains(normalizedTerm) {
                score += 120
                matched = true
            } else if !normalizedTerm.isEmpty, context.contains(normalizedTerm) {
                score += 40
                matched = true
            }
            if scorePartialTokens(in: normalizedTerm, against: text) {
                score += 60
                matched = true
            }

            let termPhonetic = phoneticKey(term)
            if termPhonetic.count >= 3, phoneticText.contains(termPhonetic) {
                score += 90
                matched = true
            } else if approximateChinesePhoneticMatch(
                term: term,
                termPhonetic: termPhonetic,
                rawPhonetic: phoneticText,
                looseRawPhonetic: loosePhoneticText
            ) {
                score += 70
                matched = true
            }

            if englishPhoneticMatch(
                term: term,
                compactText: compactText,
                rawSoundexTokens: rawSoundexTokens
            ) {
                score += 65
                matched = true
            }
        }

        if entry.type == "person", matched {
            score += 20
        }

        if matched {
            score += contextBonus(for: entry.type, signals: signals)
        }

        return matched ? score : 0
    }

    private static func basePriority(for type: String) -> Int {
        switch type {
        case "person": return 75
        case "organization", "product", "project", "technical_term", "acronym": return 65
        case "place": return 60
        default: return 50
        }
    }

    private static func scorePartialTokens(in term: String, against text: String) -> Bool {
        let tokens = term
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 }
        guard tokens.count > 1 else { return false }
        return tokens.contains { text.contains($0) }
    }

    private static func contextBonus(for type: String, signals: ContextSignals) -> Int {
        switch type {
        case "person":
            return signals.person
        case "project":
            return signals.project
        case "technical_term", "acronym":
            return max(signals.technical, signals.project / 2)
        case "product":
            return max(signals.product, signals.technical / 2)
        case "organization":
            return signals.organization
        case "place":
            return signals.place
        default:
            return 0
        }
    }

    private static func contextSignals(for text: String) -> ContextSignals {
        var signals = ContextSignals()
        if containsAny(text, [
            "ask", "tell", "call", "message", "ping", "reply", "meet", "with",
            "teammate", "manager", "coworker", "colleague",
            "找", "问", "跟", "和", "叫", "发给", "回复", "同事", "老板", "经理", "确认",
        ]) {
            signals.person += 55
        }
        if containsAny(text, [
            "project", "repo", "repository", "issue", "ticket", "pr", "pull request",
            "milestone", "roadmap", "release", "sprint", "linear", "github",
            "项目", "仓库", "需求", "工单", "版本", "迭代", "发布", "里程碑",
        ]) {
            signals.project += 60
        }
        if containsAny(text, [
            "api", "sdk", "server", "client", "latency", "runtime", "deploy", "build",
            "commit", "push", "branch", "debug", "log", "cache", "token", "model",
            "prompt", "asr", "llm", "endpoint", "database", "schema", "json",
            "接口", "服务", "延迟", "部署", "构建", "提交", "分支", "调试", "日志", "模型", "缓存",
        ]) {
            signals.technical += 60
        }
        if containsAny(text, [
            "product", "app", "platform", "feature", "plan", "pricing", "subscription",
            "产品", "应用", "平台", "功能", "定价", "套餐",
        ]) {
            signals.product += 45
        }
        if containsAny(text, [
            "company", "team", "org", "organization", "vendor", "customer", "client",
            "公司", "团队", "组织", "供应商", "客户",
        ]) {
            signals.organization += 45
        }
        if containsAny(text, [
            "at", "in", "from", "to", "office", "room", "meeting room", "address", "city",
            "在", "去", "从", "到", "会议室", "办公室", "地址", "城市",
        ]) {
            signals.place += 45
        }
        return signals
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compactNormalized(_ text: String) -> String {
        normalize(text)
            .filter { $0.isLetter || $0.isNumber }
            .map(String.init)
            .joined()
    }

    private static func phoneticKey(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains(Int($0.value)) }) else {
            return compactNormalized(text)
        }
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        return compactNormalized(mutable as String)
    }

    private static func loosePinyinKey(_ text: String) -> String {
        guard containsCJK(text) else { return compactNormalized(text) }
        return loosenPinyin(phoneticKey(text))
    }

    private static func loosenPinyin(_ key: String) -> String {
        var output = key
        for (from, to) in [
            ("zh", "z"),
            ("ch", "c"),
            ("sh", "s"),
            ("iang", "ian"),
            ("uang", "uan"),
            ("ang", "an"),
            ("eng", "en"),
            ("ing", "in"),
            ("ong", "on"),
        ] {
            output = output.replacingOccurrences(of: from, with: to)
        }
        return output
    }

    private static func approximateChinesePhoneticMatch(
        term: String,
        termPhonetic: String,
        rawPhonetic: String,
        looseRawPhonetic: String
    ) -> Bool {
        guard cjkCount(in: term) >= 2, termPhonetic.count >= 4 else { return false }
        let looseTerm = loosenPinyin(termPhonetic)
        if looseTerm.count >= 4, looseRawPhonetic.contains(looseTerm) {
            return true
        }
        return containsApproximate(termPhonetic, in: rawPhonetic)
    }

    private static func containsApproximate(_ needle: String, in haystack: String) -> Bool {
        let needleChars = Array(needle)
        let haystackChars = Array(haystack)
        guard needleChars.count >= 4, haystackChars.count >= needleChars.count - 1 else { return false }
        let threshold = needleChars.count <= 5 ? 1 : (needleChars.count <= 9 ? 2 : 3)
        let minLength = max(3, needleChars.count - 1)
        let maxLength = min(haystackChars.count, needleChars.count + 1)
        guard minLength <= maxLength else { return false }
        for length in minLength...maxLength {
            guard haystackChars.count >= length else { continue }
            for start in 0...(haystackChars.count - length) {
                let window = Array(haystackChars[start..<(start + length)])
                if levenshtein(needleChars, window, maxDistance: threshold) <= threshold {
                    return true
                }
            }
        }
        return false
    }

    private static func levenshtein(_ left: [Character], _ right: [Character], maxDistance: Int) -> Int {
        if abs(left.count - right.count) > maxDistance { return maxDistance + 1 }
        var previous = Array(0...right.count)
        for (i, leftChar) in left.enumerated() {
            var current = [i + 1]
            var rowMin = current[0]
            for (j, rightChar) in right.enumerated() {
                let substitution = previous[j] + (leftChar == rightChar ? 0 : 1)
                let insertion = current[j] + 1
                let deletion = previous[j + 1] + 1
                let value = min(substitution, insertion, deletion)
                current.append(value)
                rowMin = min(rowMin, value)
            }
            if rowMin > maxDistance { return maxDistance + 1 }
            previous = current
        }
        return previous[right.count]
    }

    private static func englishPhoneticMatch(
        term: String,
        compactText: String,
        rawSoundexTokens: Set<String>
    ) -> Bool {
        guard containsLatinLetter(term) else { return false }
        for variant in acronymSpokenVariants(for: term) where variant.count >= 3 {
            if compactText.contains(variant) { return true }
        }
        for token in latinTokens(in: term) where token.count >= 4 {
            if let code = soundex(token), rawSoundexTokens.contains(code) {
                return true
            }
        }
        return false
    }

    private static func acronymSpokenVariants(for term: String) -> [String] {
        let runs = uppercaseRuns(in: term)
        guard !runs.isEmpty else { return [] }
        var variants = Set<String>()
        for run in runs {
            let before = String(term[..<run.range.lowerBound])
            let after = String(term[run.range.upperBound...])
            for spoken in spokenLetterCombinations(for: run.text) {
                variants.insert(compactNormalized(before + spoken + after))
            }
        }
        return Array(variants)
    }

    private static func uppercaseRuns(in term: String) -> [(range: Range<String.Index>, text: String)] {
        var runs: [(Range<String.Index>, String)] = []
        var start: String.Index?
        var current = term.startIndex
        while current < term.endIndex {
            let character = term[current]
            let isUpper = isASCIIUppercase(character)
            if isUpper {
                if start == nil { start = current }
            } else if let runStart = start {
                let runText = String(term[runStart..<current])
                if runText.count >= 2 { runs.append((runStart..<current, runText)) }
                start = nil
            }
            current = term.index(after: current)
        }
        if let runStart = start {
            let runText = String(term[runStart..<term.endIndex])
            if runText.count >= 2 { runs.append((runStart..<term.endIndex, runText)) }
        }
        return runs
    }

    private static func spokenLetterCombinations(for acronym: String) -> [String] {
        var variants = [""]
        for character in acronym.lowercased() {
            let options = letterNameOptions(for: character)
            variants = variants.flatMap { prefix in
                options.map { prefix + " " + $0 }
            }
            if variants.count > 24 {
                variants = Array(variants.prefix(24))
            }
        }
        return variants
    }

    private static func letterNameOptions(for character: Character) -> [String] {
        switch character {
        case "a": return ["a", "ay"]
        case "b": return ["bee"]
        case "c": return ["see"]
        case "d": return ["dee"]
        case "e": return ["ee"]
        case "f": return ["eff"]
        case "g": return ["gee"]
        case "h": return ["aitch", "h"]
        case "i": return ["eye"]
        case "j": return ["jay"]
        case "k": return ["kay"]
        case "l": return ["ell"]
        case "m": return ["em"]
        case "n": return ["en"]
        case "o": return ["o", "oh"]
        case "p": return ["pee"]
        case "q": return ["cue", "queue"]
        case "r": return ["are"]
        case "s": return ["ess"]
        case "t": return ["tee"]
        case "u": return ["u", "you"]
        case "v": return ["vee"]
        case "w": return ["double u", "double you"]
        case "x": return ["ex"]
        case "y": return ["why"]
        case "z": return ["zee", "zed"]
        case "0": return ["zero", "oh"]
        case "1": return ["one"]
        case "2": return ["two"]
        case "3": return ["three"]
        case "4": return ["four"]
        case "5": return ["five"]
        case "6": return ["six"]
        case "7": return ["seven"]
        case "8": return ["eight"]
        case "9": return ["nine"]
        default: return [String(character)]
        }
    }

    private static func soundexTokens(in text: String) -> Set<String> {
        Set(latinTokens(in: text).compactMap(soundex))
    }

    private static func soundex(_ token: String) -> String? {
        let letters = token.lowercased().filter(\.isLetter)
        guard let first = letters.first, letters.count >= 4 else { return nil }
        let firstLetter = String(first).uppercased()
        var previous = soundexDigit(first)
        var digits: [Character] = []
        for character in letters.dropFirst() {
            let digit = soundexDigit(character)
            if digit != "0", digit != previous {
                digits.append(digit)
            }
            previous = digit
        }
        let padded = String(digits).padding(toLength: 3, withPad: "0", startingAt: 0)
        return firstLetter + String(padded.prefix(3))
    }

    private static func soundexDigit(_ character: Character) -> Character {
        switch character {
        case "b", "f", "p", "v": return "1"
        case "c", "g", "j", "k", "q", "s", "x", "z": return "2"
        case "d", "t": return "3"
        case "l": return "4"
        case "m", "n": return "5"
        case "r": return "6"
        default: return "0"
        }
    }

    private static func latinTokens(in text: String) -> [String] {
        let normalized = normalize(text)
        var tokens: [String] = []
        var current = ""
        for character in normalized {
            if isASCIILetterOrNumber(character) {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens.filter { $0.contains(where: \.isLetter) }
    }

    private static func containsCJK(_ text: String) -> Bool {
        cjkCount(in: text) > 0
    }

    private static func cjkCount(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value)) ? count + 1 : count
        }
    }

    private static func containsLatinLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
        }
    }

    private static func isASCIIUppercase(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return false
        }
        return (65...90).contains(Int(value))
    }

    private static func isASCIILetterOrNumber(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return false
        }
        return (48...57).contains(Int(value)) ||
            (65...90).contains(Int(value)) ||
            (97...122).contains(Int(value))
    }
}
