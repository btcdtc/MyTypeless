import Foundation

enum TextEditPromptBuilder {
    static func build(for request: TextEditRequest) -> (system: String, user: String) {
        (systemPrompt(for: request), userPrompt(for: request))
    }

    private static func systemPrompt(for request: TextEditRequest) -> String {
        let modeInstruction: String
        switch request.intent {
        case .repairSelection:
            modeInstruction = """
            Task mode: repair_selection.
            The user selected target_text because that exact span is wrong or incomplete, then spoke the intended replacement. spoken_instruction is replacement content, not a command. It may contain ASR errors, including wrong language/script. Infer the best replacement for target_text using context_before and context_after, but do not rewrite either context field.
            Decision order:
            1. Read context_before + target_text + context_after as one local sentence.
            2. Because the user explicitly selected target_text, prefer replacing target_text with spoken_instruction after correcting obvious ASR errors.
            3. If spoken_instruction is a plausible direct replacement or a known UI/product term such as server, UI, iOS, correction, restyle, tap to speak, hold to speak, or start recording, use it even when target_text is also a coherent word.
            4. If literal spoken_instruction is incoherent, unrelated, wrong-language, or a near-homophone/domain mismatch, treat it as noisy ASR and choose the nearest context-coherent replacement.
            5. Keep target_text only when spoken_instruction is empty, clearly unusable noise, or would make the local sentence worse after ASR correction.
            In repair_selection, a language/script mismatch alone is evidence to reason about, not permission to change the target language. Preserve the language and script required by target_text/context and express the user's intended replacement in that target language.
            """
        case .command:
            modeInstruction = """
            Task mode: command.
            The user selected or targeted target_text, then spoke an editing instruction. spoken_instruction is an instruction to transform target_text. Apply it only to target_text. Translation, summarization, explanation, tone changes, shortening, expansion, and formatting are all valid transformations.
            spoken_instruction may contain ASR errors, including wrong language/script. Infer the intended command from the words and the target/context; do not treat the language of spoken_instruction by itself as an instruction to change output language.
            A language-change command is explicit only when spoken_instruction contains an action such as translate, 翻译, dịch, write in, use, 改成, 写成, or 用 plus a target language. Isolated language names or aliases by themselves are ambiguous/noisy; treat them as no-op unless the surrounding words clearly request translation or language change.
            For translation commands, translate target_text faithfully. Use context_before/context_after only to disambiguate meaning, pronouns, tense, terminology, and tone. Do not summarize, embellish, answer, or rewrite the target into a different idea.
            For shortening commands, actually shorten target_text when it contains removable detail; do not return the original unchanged unless no shorter faithful replacement exists.
            Preserve established product and UI terms during command edits when they are part of the user's domain vocabulary, including UI, iOS, host app, Mac app, server latency, voice input app, keyboard, ship, deploy, debug log, tap to speak, and hold to speak.
            When translating or rewriting into any language, use natural contemporary wording in the requested target language. Avoid archaic, literary, or word-for-word calque phrasing unless target_text is legal/official text or the user asks for that style.
            Before returning, verify the text is only the replacement for target_text. If the draft includes exact words from context_before or context_after, remove that read-only context unless those words are naturally part of the replacement itself.
            If the command is ambiguous after considering context, return target_text unchanged.
            """
        }

        return """
        You are Typeforme text edit engine.

        Hard boundary:
        - target_text is the only text you may replace.
        - context_before and context_after are read-only context. Use them to infer meaning, grammar, punctuation, references, casing, and domain terms, but never rewrite or include them unless they are naturally part of the target replacement.
        - If the same words appear multiple times in context, only the selected/targeted span is editable.
        - language_ids and language_instruction are ASR/script-normalization hints, not instructions to translate the output.
        - Follow output_preferences for number formatting and punctuation style unless doing so would corrupt URLs, code, file paths, model names, exact IDs, decimals, or protected technical tokens.

        \(modeInstruction)

        Output language policy:
        - By default, the replacement must stay in the language/script of target_text and its surrounding context, not the language of spoken_instruction.
        - Treat spoken_instruction as noisy ASR. A mismatch between spoken_instruction language and target_text language is evidence to reason about, not a command.
        - Infer the target language from target_text first, then context_before/context_after, then language_ids. Never choose output language from spoken_instruction alone.
        - If spoken_instruction is in a different language but does not explicitly ask for translation or language change, keep the replacement in the target/context language.
        - If an explicit language-change command is present, output in the requested target language using natural contemporary phrasing.
        - Preserve intentional mixed-language spans; do not normalize a mixed target into a single language.

        Context policy:
        - context_before/context_after are semantic anchors, not editable text.
        - Use context to keep the replacement coherent with the surrounding sentence, especially references, subject, tense, negation, and technical terms.
        - Never use context as permission to invent new content, change the target meaning, or produce a looser paraphrase when the command asks for translation.
        - The returned replacement may be a fragment. Do not include context_before or context_after just to make a complete sentence.
        - If the literal spoken_instruction meaning conflicts with context, consider ASR error before changing the target into an incoherent or unrelated idea.

        Editing rules:
        - Preserve the user's intent, target language, speaker perspective, names, numbers, dates, units, product names, code, URLs, and paths.
        - Preserve diacritics, tones, accents, kana/kanji, CJK script choices, and other language-specific spelling marks when they are part of normal writing.
        - Preserve established UI phrases when correcting ASR near-homophones; for microphone labels, prefer "tap to speak" / "hold to speak" when the noisy text sounds like those phrases.
        - Correct obvious ASR errors in spoken_instruction when context makes the intended replacement clear.
        - Prefer the smallest edit that makes target_text fit the local sentence and user intent.
        - Keep output scoped. Return only the new replacement for target_text, not the full surrounding sentence or document.
        - If the spoken instruction is ambiguous, make the smallest valid edit.
        - Use vocabulary_candidates as correction hints only when target/context/spoken input supports the term. Do not replace ordinary words globally just because they sound similar to a vocabulary item.

        Output:
        - Return exactly one JSON object and nothing else: {"action":"replace_target","text":"string"}
        - action must be "replace_target".
        - The JSON must be valid. Escape multiline text inside the string as \\n.
        """
    }

    private static func userPrompt(for request: TextEditRequest) -> String {
        let languageIDs = ASRLanguageSelection.validatedIDs(request.languageIDs)
        let outputPreferences = PromptOutputPreferencesPayload(
            numbers: request.numberOutputPreference.rawValue,
            numberInstruction: request.numberOutputPreference.promptInstruction,
            punctuation: request.punctuationPreference.rawValue,
            punctuationInstruction: request.punctuationPreference.promptInstruction
        )
        let context = TextEditPromptContextPayload(
            appName: request.frontmostAppName ?? "",
            bundleID: request.frontmostBundleID ?? "",
            appCategory: request.appCategory.rawValue,
            languages: ASRLanguageSelection.displayNames(for: languageIDs),
            languageCodes: ASRLanguageSelection.whisperCodes(for: languageIDs),
            languageInstruction: LocaleTextNormalizer.promptInstruction(for: languageIDs),
            targetLanguageHint: targetLanguageHint(for: request),
            outputPreferences: outputPreferences
        )
        let vocabularyCandidates = VocabularyCandidateSelector.promptPayload(
            from: request.userDictionary,
            rawText: [
                request.contextBefore,
                request.targetText,
                request.contextAfter,
                request.spokenInstruction,
            ].joined(separator: " "),
            extraContext: [
                request.frontmostAppName ?? "",
                request.frontmostBundleID ?? "",
                request.appCategory.rawValue,
            ]
        )
        let input = TextEditPromptInputPayload(
            task: "edit_target_text_with_spoken_input",
            intent: request.intent.rawValue,
            context: context,
            vocabularyCandidates: vocabularyCandidates,
            contextBefore: request.contextBefore,
            targetText: request.targetText,
            contextAfter: request.contextAfter,
            spokenInstruction: request.spokenInstruction
        )

        var parts = ["""
        <output_schema>
        {"action":"replace_target","text":"string"}
        </output_schema>
        """, examples(for: request), """
        <actual_task>
        Use the examples only as decision patterns. Now edit the single input_json below.
        </actual_task>
        """]
        if let directive = requestDirective(for: request) {
            parts.append(directive)
        }
        if let json = PromptPayloadEncoder.jsonString(input) {
            parts.append("""
            <input_json>
            \(json)
            </input_json>
            """)
        }
        parts.append("Return only the replacement JSON object described above.")
        return parts.joined(separator: "\n")
    }

    private static func examples(for request: TextEditRequest) -> String {
        switch request.intent {
        case .repairSelection:
            return repairSelectionExamples()
        case .command:
            return commandExamples(for: request)
        }
    }

    private static func repairSelectionExamples() -> String {
        wrapExamples([
            """
            Input:
            {"intent":"repair_selection","context_before":"Please ","target_text":"do not write","context_after":" this section in the final draft.","spoken_instruction":"不写"}
            Output:
            {"action":"replace_target","text":"do not include"}
            """,
            """
            Input:
            {"intent":"repair_selection","context_before":"The button should ","target_text":"start rewarding","context_after":" immediately after touch down.","spoken_instruction":"start rewarding"}
            Output:
            {"action":"replace_target","text":"start recording"}
            """,
            """
            Input:
            {"intent":"repair_selection","context_before":"The button should ","target_text":"start recording","context_after":" immediately after touch down.","spoken_instruction":"start rewarding"}
            Output:
            {"action":"replace_target","text":"start recording"}
            """,
            """
            Input:
            {"intent":"repair_selection","context_before":"左上角显示 ","target_text":"Cloudflare","context_after":" 状态。","spoken_instruction":"server"}
            Output:
            {"action":"replace_target","text":"server"}
            """,
            """
            Input:
            {"intent":"repair_selection","context_before":"The field should show ","target_text":"corrextion","context_after":" latency.","spoken_instruction":"correction"}
            Output:
            {"action":"replace_target","text":"correction"}
            """,
            """
            Input:
            {"intent":"repair_selection","context_before":"Loại vật liệu này là ","target_text":"cây kéo","context_after":" dùng để dán giấy.","spoken_instruction":"keo"}
            Output:
            {"action":"replace_target","text":"keo"}
            """,
            """
            Input:
            {"intent":"repair_selection","context_before":"The microphone button label should read ","target_text":"hold to steak","context_after":" while recording voice.","spoken_instruction":"hold to steak"}
            Output:
            {"action":"replace_target","text":"hold to speak"}
            """,
        ])
    }

    private static func commandExamples(for request: TextEditRequest) -> String {
        let instruction = request.spokenInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerInstruction = instruction.lowercased()
        let lowerTarget = request.targetText.lowercased()
        var examples: [String] = []

        if isExplicitTranslationInstruction(lowerInstruction) {
            if containsProtectedProductTerm(lowerTarget) {
                examples.append(protectedTermsTranslationExample)
            }
            if requestsChinese(lowerInstruction) {
                examples.append(englishToChineseTranslationExample)
                examples.append(scopedHostAppTranslationExample)
            }
            if requestsEnglish(lowerInstruction) {
                examples.append(chineseVoiceInputToEnglishExample)
                examples.append(vietnameseVoiceInputToEnglishExample)
            }
            if requestsVietnamese(lowerInstruction) {
                if lowerInstruction.contains("natural") || instruction.contains("自然") || request.targetText.contains("按住") {
                    examples.append(naturalVietnameseButtonExample)
                }
                if containsCJK(request.targetText) {
                    examples.append(chineseVoiceInputToVietnameseExample)
                } else {
                    examples.append(englishVoiceInputToVietnameseExample)
                }
            }
            if requestsJapanese(lowerInstruction) {
                examples.append(englishKeyboardToJapaneseExample)
            }
        } else if isIsolatedLanguageName(instruction) {
            examples.append(isolatedChineseNoopExample)
            examples.append(isolatedVietnameseNoopExample)
        } else if lowerInstruction.contains("bullet") || instruction.contains("项目符号") || instruction.contains("列表") {
            examples.append(bulletCommandExample)
        } else if lowerInstruction.contains("shorter") || lowerInstruction.contains("shorten") || instruction.contains("简短") {
            examples.append(shortenCommandExample)
        } else if lowerInstruction.contains("professional") || instruction.contains("正式") || instruction.contains("专业") {
            examples.append(professionalToneExample)
        }

        if examples.isEmpty {
            examples.append(scopedHostAppTranslationExample)
            examples.append(shortenCommandExample)
        }
        return wrapExamples(Array(examples.prefix(4)))
    }

    private static func requestDirective(for request: TextEditRequest) -> String? {
        guard case .command = request.intent else { return nil }
        let instruction = request.spokenInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerInstruction = instruction.lowercased()
        if isIsolatedLanguageName(instruction) {
            return """
            <request_directive>
            Isolated language name detected. The spoken_instruction is not an explicit edit command. Return target_text unchanged unless the input contains additional action words requesting a transformation.
            </request_directive>
            """
        }
        guard isExplicitTranslationInstruction(lowerInstruction) else { return nil }

        let targetLanguage: String
        if requestsChinese(lowerInstruction) {
            targetLanguage = "Chinese"
        } else if requestsEnglish(lowerInstruction) {
            targetLanguage = "English"
        } else if requestsVietnamese(lowerInstruction) {
            targetLanguage = "Vietnamese"
        } else if requestsJapanese(lowerInstruction) {
            targetLanguage = "Japanese"
        } else {
            targetLanguage = "the requested target language"
        }

        return """
        <request_directive>
        Explicit translation command detected. Translate target_text into \(targetLanguage). Returning target_text unchanged in its source language is invalid unless source and target languages are already the same.
        </request_directive>
        """
    }

    private static func wrapExamples(_ examples: [String]) -> String {
        let body = examples.map { example in
            """
            <example>
            \(example)
            </example>
            """
        }.joined(separator: "\n")
        return """
        <examples>
        \(body)
        </examples>
        """
    }

    private static func isExplicitTranslationInstruction(_ instruction: String) -> Bool {
        instruction.contains("translate")
            || instruction.contains("翻译")
            || instruction.contains("翻譯")
            || instruction.contains("dịch")
            || instruction.contains("dich")
    }

    private static func requestsChinese(_ instruction: String) -> Bool {
        instruction.contains("chinese") || instruction.contains("中文") || instruction.contains("中国语")
            || instruction.contains("zh")
    }

    private static func requestsEnglish(_ instruction: String) -> Bool {
        instruction.contains("english") || instruction.contains("英文") || instruction.contains("英语")
    }

    private static func requestsVietnamese(_ instruction: String) -> Bool {
        instruction.contains("vietnamese") || instruction.contains("越南语") || instruction.contains("tiếng việt")
            || instruction.contains("tieng viet")
    }

    private static func requestsJapanese(_ instruction: String) -> Bool {
        instruction.contains("japanese") || instruction.contains("日语") || instruction.contains("日文")
            || instruction.contains("日本語")
    }

    private static func isIsolatedLanguageName(_ instruction: String) -> Bool {
        let normalized = instruction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "chinese", "english", "vietnamese", "japanese", "korean",
            "中文", "英文", "英语", "越南语", "日语", "日文", "韩语", "한국어", "日本語",
        ].contains(normalized)
    }

    private static func containsProtectedProductTerm(_ target: String) -> Bool {
        ["ui", "ios", "host app", "mac app", "server latency", "debug log", "ship", "deploy", "keyboard"]
            .contains { target.contains($0) }
    }

    private static let englishToChineseTranslationExample = """
    Input:
    {"intent":"command","context_before":"前半句说明 server latency 很高，","target_text":"the first request blocks the UI for almost a second","context_after":"，所以用户觉得卡。","spoken_instruction":"翻译成中文"}
    Output:
    {"action":"replace_target","text":"第一个请求阻塞 UI 将近一秒"}
    """

    private static let protectedTermsTranslationExample = """
    Input:
    {"intent":"command","context_before":"","target_text":"server latency and debug log are shown in the host app","context_after":"","spoken_instruction":"翻译成中文"}
    Output:
    {"action":"replace_target","text":"host app 中显示 server latency 和 debug log"}
    """

    private static let chineseVoiceInputToEnglishExample = """
    Input:
    {"intent":"command","context_before":"","target_text":"这个语音输入法是我开发的","context_after":"","spoken_instruction":"translate to English"}
    Output:
    {"action":"replace_target","text":"I built this voice input app."}
    """

    private static let vietnameseVoiceInputToEnglishExample = """
    Input:
    {"intent":"command","context_before":"","target_text":"Ứng dụng nhập liệu bằng giọng nói này là do tôi phát triển.","context_after":"","spoken_instruction":"translate to English"}
    Output:
    {"action":"replace_target","text":"I built this voice input app."}
    """

    private static let chineseVoiceInputToVietnameseExample = """
    Input:
    {"intent":"command","context_before":"","target_text":"这个语音输入法是我开发的","context_after":"","spoken_instruction":"翻译成越南语"}
    Output:
    {"action":"replace_target","text":"Ứng dụng nhập liệu bằng giọng nói này là do tôi phát triển."}
    """

    private static let englishVoiceInputToVietnameseExample = """
    Input:
    {"intent":"command","context_before":"","target_text":"I built this voice input app.","context_after":"","spoken_instruction":"dịch sang tiếng Việt"}
    Output:
    {"action":"replace_target","text":"Tôi đã xây dựng ứng dụng nhập liệu bằng giọng nói này."}
    """

    private static let englishKeyboardToJapaneseExample = """
    Input:
    {"intent":"command","context_before":"","target_text":"The keyboard is laggy.","context_after":"","spoken_instruction":"翻译成日语"}
    Output:
    {"action":"replace_target","text":"キーボードの反応が遅い。"}
    """

    private static let isolatedChineseNoopExample = """
    Input:
    {"intent":"command","context_before":"The iOS keyboard is laggy because ","target_text":"the first request blocks the UI for almost a second","context_after":" when the host app wakes.","spoken_instruction":"Chinese"}
    Output:
    {"action":"replace_target","text":"the first request blocks the UI for almost a second"}
    """

    private static let isolatedVietnameseNoopExample = """
    Input:
    {"intent":"command","context_before":"","target_text":"the host app opens slowly","context_after":"","spoken_instruction":"Vietnamese"}
    Output:
    {"action":"replace_target","text":"the host app opens slowly"}
    """

    private static let scopedHostAppTranslationExample = """
    Input:
    {"intent":"command","context_before":"前半句不要动：server latency 很高。","target_text":"the host app opens slowly","context_after":" 后半句也不要动。","spoken_instruction":"translate to Chinese"}
    Output:
    {"action":"replace_target","text":"host app 打开很慢"}
    """

    private static let shortenCommandExample = """
    Input:
    {"intent":"command","context_before":"The keyboard feels slow because ","target_text":"the first request blocks the UI for almost a second","context_after":".","spoken_instruction":"make it shorter"}
    Output:
    {"action":"replace_target","text":"the first request blocks the UI"}
    """

    private static let bulletCommandExample = """
    Input:
    {"intent":"command","context_before":"","target_text":"buy apples then check git status","context_after":"","spoken_instruction":"turn this into bullets"}
    Output:
    {"action":"replace_target","text":"- buy apples\\n- check git status"}
    """

    private static let professionalToneExample = """
    Input:
    {"intent":"command","context_before":"","target_text":"this bug is super annoying but ship it","context_after":"","spoken_instruction":"make it professional"}
    Output:
    {"action":"replace_target","text":"this bug is disruptive, but we should still ship it"}
    """

    private static let naturalVietnameseButtonExample = """
    Input:
    {"intent":"command","context_before":"","target_text":"按住这个按钮后应该马上开始录音","context_after":"","spoken_instruction":"翻译成自然的越南语"}
    Output:
    {"action":"replace_target","text":"Sau khi nhấn giữ nút này, ghi âm sẽ bắt đầu ngay lập tức."}
    """

    private static func targetLanguageHint(for request: TextEditRequest) -> String {
        let target = request.targetText
        let surrounding = [request.contextBefore, request.contextAfter].joined(separator: " ")
        let selectedLanguages = ASRLanguageSelection.displayNames(
            for: ASRLanguageSelection.validatedIDs(request.languageIDs)
        ).joined(separator: ", ")
        let targetHasCJK = containsCJK(target)
        let targetHasLatin = containsLatinLetter(target)
        let targetHasLatinDiacritics = containsLatinDiacritic(target)
        let surroundingHasLatinDiacritics = containsLatinDiacritic(surrounding)
        switch (targetHasCJK, targetHasLatin) {
        case (true, true):
            return "mixed-script target_text; preserve the same local language mix unless explicitly instructed to translate"
        case (true, false):
            return "CJK target_text; preserve the target/context language and configured script unless explicitly instructed to translate"
        case (false, true):
            if targetHasLatinDiacritics || surroundingHasLatinDiacritics {
                return "Latin-script target_text with diacritics; infer the specific language from target/context and selected languages (\(selectedLanguages)); preserve diacritics unless explicitly instructed to translate"
            }
            return "Latin-script target_text; infer the specific language from target/context and selected languages (\(selectedLanguages)); do not assume English solely from Latin script and do not translate unless explicitly instructed"
        case (false, false):
            let surroundingHasCJK = containsCJK(surrounding)
            let surroundingHasLatin = containsLatinLetter(surrounding)
            switch (surroundingHasCJK, surroundingHasLatin) {
            case (true, true):
                return "target_text has no clear script; surrounding context is mixed, so preserve the local language mix"
            case (true, false):
                return "target_text has no clear script; surrounding context is CJK, so preserve the context language/script unless explicitly instructed to translate"
            case (false, true):
                if surroundingHasLatinDiacritics {
                    return "target_text has no clear script; surrounding context is Latin-script with diacritics, so infer the specific language from context and preserve diacritics"
                }
                return "target_text has no clear script; surrounding context is Latin-script, so infer the specific language from context and selected languages (\(selectedLanguages)) unless explicitly instructed to translate"
            case (false, false):
                return "infer from target_text and context; do not choose output language from spoken_instruction alone"
            }
        }
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
                || (0x3400...0x4DBF).contains(Int(scalar.value))
                || (0x3040...0x30FF).contains(Int(scalar.value))
                || (0xAC00...0xD7AF).contains(Int(scalar.value))
        }
    }

    private static func containsLatinLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x41...0x5A).contains(Int(scalar.value))
                || (0x61...0x7A).contains(Int(scalar.value))
                || (0x00C0...0x024F).contains(Int(scalar.value))
        }
    }

    private static func containsLatinDiacritic(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x00C0...0x024F).contains(Int(scalar.value))
        }
    }
}
