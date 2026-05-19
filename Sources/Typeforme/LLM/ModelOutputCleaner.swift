import Foundation

/// Per spec §18 pipeline step 1–3:
///   raw model output → strip <think> blocks → strip code fences →
///   extract first JSON object
enum ModelOutputCleaner {
    static func clean(_ raw: String) -> String {
        let noThink = stripThinkBlocks(raw)
        let noFences = stripFences(noThink)
        return noFences.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the first balanced `{ ... }` substring, respecting quoted strings
    /// and backslash escapes. Returns nil if no balanced object exists.
    static func extractFirstJSONObject(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if escape { escape = false; i = s.index(after: i); continue }
            if inString {
                switch c {
                case "\\": escape = true
                case "\"": inString = false
                default: break
                }
                i = s.index(after: i); continue
            }
            switch c {
            case "\"": inString = true
            case "{":  depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    let end = s.index(after: i)
                    return String(s[start..<end])
                }
            default: break
            }
            i = s.index(after: i)
        }
        return nil
    }

    private static func stripThinkBlocks(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>") else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    private static func stripFences(_ s: String) -> String {
        // Strip ``` optionally followed by a language tag and a newline, plus closing ```.
        guard let re = try? NSRegularExpression(pattern: "```[a-zA-Z0-9_+\\-]*\\n?|```") else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
}
