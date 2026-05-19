import Foundation

enum LocaleTextNormalizer {
    static func normalize(_ text: String, languageIDs: [String]) -> String {
        switch ASRLanguageSelection.scriptPreference(for: languageIDs) {
        case .simplified:
            return transformHanRuns(text, using: "Hant-Hans")
        case .traditional:
            return transformHanRuns(text, using: "Hans-Hant")
        case .preserve:
            return text
        }
    }

    static func normalize(_ text: String, locale: String) -> String {
        normalize(text, languageIDs: ASRLanguageSelection.parse(locale))
    }

    static func promptInstruction(for languageIDs: [String]) -> String {
        let languageNames = ASRLanguageSelection.displayNames(for: languageIDs).joined(separator: ", ")
        let languageScope = "Expected languages: \(languageNames). Preserve natural code-switching among these languages. Preserve each selected-language segment in its original language and script; do not translate between selected languages. Treat unrelated languages as ASR errors only when the local context makes that clear; otherwise preserve the user's words."
        switch ASRLanguageSelection.scriptPreference(for: languageIDs) {
        case .simplified:
            return languageScope + " When output contains Chinese, use Simplified Chinese. " + languageStyleGuidance(for: languageIDs)
        case .traditional:
            return languageScope + " When output contains Chinese, use Traditional Chinese. " + languageStyleGuidance(for: languageIDs)
        case .preserve:
            return languageScope + " Preserve the detected script for Chinese unless the selected languages imply a clear user preference. " + languageStyleGuidance(for: languageIDs)
        }
    }

    static func promptInstruction(for locale: String) -> String {
        promptInstruction(for: ASRLanguageSelection.parse(locale))
    }

    static func languageStyleGuidance(for languageIDs: [String]) -> String {
        let names = ASRLanguageSelection.displayNames(for: languageIDs).joined(separator: ", ")
        return "Language style guidance: for \(names), use natural contemporary wording for each detected language; preserve language-specific diacritics, accents, native scripts, casing, acronyms, product names, code, and proper nouns; avoid archaic, literary, or word-for-word calques unless the surrounding text clearly requires that style."
    }

    private static func transform(_ text: String, using transformName: String) -> String {
        let transform = StringTransform(rawValue: transformName)
        return (text as NSString).applyingTransform(transform, reverse: false) ?? text
    }

    private static func transformHanRuns(_ text: String, using transformName: String) -> String {
        var output = ""
        var run = ""
        var runContainsKana = false

        func flushRun() {
            guard !run.isEmpty else { return }
            output += runContainsKana ? run : transform(run, using: transformName)
            run = ""
            runContainsKana = false
        }

        for character in text {
            let scalars = character.unicodeScalars
            if scalars.contains(where: { isHan($0) || isKana($0) }) {
                run.append(character)
                if scalars.contains(where: isKana) {
                    runContainsKana = true
                }
            } else {
                flushRun()
                output.append(character)
            }
        }
        flushRun()
        return output
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2A6DF).contains(value)
            || (0x2A700...0x2B73F).contains(value)
            || (0x2B740...0x2B81F).contains(value)
            || (0x2B820...0x2CEAF).contains(value)
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x3040...0x309F).contains(value)
            || (0x30A0...0x30FF).contains(value)
            || (0x31F0...0x31FF).contains(value)
    }
}
