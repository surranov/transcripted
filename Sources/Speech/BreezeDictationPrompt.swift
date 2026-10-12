import Foundation

/// Fork: the text Breeze (a Whisper model) reads before each piece of audio.
///
/// A Whisper prompt is not an instruction. The model treats it as the
/// transcript that came just before, and continues in its style: punctuation,
/// and technical terms written in Latin letters inside Russian speech. On 132
/// recorded dictations this lifted English terms kept in Latin from 72% to 77%
/// and cut word errors from 18.4% to 17.1% (2026-10-12, against ElevenLabs
/// Scribe on the same audio).
///
/// Order matters: whisper.cpp keeps only the last 223 prompt tokens, so the
/// fixed sample goes first and the text right before this audio goes last.
/// The budgets keep all three inside that: the sample is 80 tokens, 200
/// characters of terms about 72 and 150 of Russian text about 50 (Whisper's
/// multilingual tokenizer, 2026-10-12). At 240 and 200 they came to 232 and
/// the sample's start was cut.
enum BreezeDictationPrompt {
    /// The sample the 2026-10-12 evaluation used, unchanged.
    static let styleSample = "Так, сделай commit и push в main, потом rebase и pull request. Глянь Slack, Jira и Confluence, задеплой на stage. Созвон с тимлидом перенесли. Запусти npm install, проверь frontend и backend, открой CLAUDE.md и worktree в Obsidian."

    static let maximumTermsCharacters = 200
    static let maximumPrecedingCharacters = 150
    /// Longer replacements are phrases or addresses, not terms to spell.
    static let maximumTermLength = 32

    static func make(dictionary: [CustomDictionaryEntry], precedingText: String) -> String {
        var parts = [styleSample]
        let terms = latinTerms(from: dictionary)
        if !terms.isEmpty { parts.append(terms + ".") }
        let preceding = tail(of: precedingText, maximumCharacters: maximumPrecedingCharacters)
        if !preceding.isEmpty { parts.append(preceding) }
        return parts.joined(separator: " ")
    }

    /// The user's own Latin-script spellings (Slack, CLAUDE.md, ...), deduped,
    /// in dictionary order, up to the character budget.
    static func latinTerms(from dictionary: [CustomDictionaryEntry]) -> String {
        var seen = Set<String>()
        var picked: [String] = []
        var length = 0
        for entry in dictionary {
            let term = entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= maximumTermLength,
                  !term.contains("@"),
                  term.unicodeScalars.contains(where: { $0.properties.isAlphabetic && $0.isASCII }),
                  seen.insert(term.lowercased()).inserted else { continue }
            let added = term.count + (picked.isEmpty ? 0 : 2)
            guard length + added <= maximumTermsCharacters else { break }
            picked.append(term)
            length += added
        }
        return picked.joined(separator: ", ")
    }

    /// The end of `text`, cut at a word boundary so the prompt never starts
    /// mid-word.
    static func tail(of text: String, maximumCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumCharacters else { return trimmed }
        let suffix = trimmed.suffix(maximumCharacters)
        guard let firstSpace = suffix.firstIndex(where: \.isWhitespace) else { return String(suffix) }
        return String(suffix[suffix.index(after: firstSpace)...])
    }
}

/// Fork: the language Breeze transcribes a dictation in. Breeze was tuned on
/// Mandarin-English speech, so left to detect on its own it can answer in
/// Chinese; pinning the person's language keeps the text in their script while
/// the English terms inside it stay English.
enum BreezeDictationLanguage {
    /// The meeting language picker wins when it names a language. Otherwise the
    /// one non-English language among the person's languages (Mac languages and
    /// keyboards), since Russian-with-English-terms is transcribed as Russian;
    /// English when English is all there is; nil (Whisper's own detection) when
    /// there are several other languages to choose from.
    static func code(userLanguageCodes: [String], explicitMeetingLanguage: String?) -> String? {
        if let explicitMeetingLanguage, !explicitMeetingLanguage.isEmpty { return explicitMeetingLanguage }
        var base: [String] = []
        for code in userLanguageCodes {
            let language = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? ""
            if !language.isEmpty, !base.contains(language) { base.append(language) }
        }
        let nonEnglish = base.filter { $0 != "en" }
        if nonEnglish.count == 1 { return nonEnglish[0] }
        if nonEnglish.isEmpty, base.contains("en") { return "en" }
        return nil
    }
}
