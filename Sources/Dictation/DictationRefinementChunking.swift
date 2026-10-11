import Foundation

/// Fork: splits a long dictation for the transcript LLM pass, the way a
/// meeting goes one utterance at a time.
///
/// One request for a whole long take is where the small local model goes
/// wrong: it can stop early or summarize, and the length check
/// (`DictationTextRefinementPolicy`) then has to throw the whole answer away
/// or let a shortened one through; past about 40 minutes of speech the
/// request doesn't fit the slot's context at all. In pieces of a minute or
/// two of speech each answer is checked on its own, a bad one keeps just its
/// piece, and the system prompt stays in llama-server's prompt cache between
/// them. Takes up to `singleRequestCharacters` (about five minutes of speech)
/// still go in one request, as before.
enum DictationRefinementChunking {
    struct Chunk: Equatable {
        /// The piece without surrounding whitespace, as sent to the model.
        let text: String
        /// The whitespace that followed it in the dictation, put back
        /// between the refined pieces ("" after the last).
        let separator: String
    }

    static let singleRequestCharacters = 3000
    static let targetChunkCharacters = 1500

    static func chunks(
        of text: String,
        singleRequestCharacters: Int = singleRequestCharacters,
        targetChunkCharacters: Int = targetChunkCharacters
    ) -> [Chunk] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > singleRequestCharacters else {
            return trimmed.isEmpty ? [] : [Chunk(text: trimmed, separator: "")]
        }
        // Even pieces: a 3,300-character take becomes three of ~1,100, not
        // two full ones and a stub.
        let pieceCount = Int((Double(trimmed.count) / Double(targetChunkCharacters)).rounded(.up))
        let target = max(1, trimmed.count / pieceCount)

        var runs: [String] = []
        var current = ""
        for unit in units(of: trimmed, maxCharacters: targetChunkCharacters) {
            // A piece closes once it reaches the even share, or before the
            // next sentence would take it past the target.
            if !current.isEmpty, current.count >= target || current.count + unit.count > targetChunkCharacters {
                runs.append(current)
                current = ""
            }
            current += unit
        }
        if !current.isEmpty { runs.append(current) }
        return chunks(fromRuns: runs)
    }

    /// The refined pieces put back together with the original separators.
    static func join(_ pieces: [String], of chunks: [Chunk]) -> String {
        zip(pieces, chunks).map { $0 + $1.separator }.joined()
    }

    // MARK: - Private

    /// Sentences with their trailing whitespace, covering the whole text. A
    /// sentence longer than `maxCharacters` (no punctuation came back) is cut
    /// at spaces.
    private static func units(of text: String, maxCharacters: Int) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .substringNotRequired]) { _, _, enclosing, _ in
            sentences.append(String(text[enclosing]))
        }
        // Sentence enumeration skips nothing in practice, but never lose
        // text if it does.
        guard sentences.joined() == text else { return wordRuns(of: text, maxCharacters: maxCharacters) }
        return sentences.flatMap { $0.count > maxCharacters ? wordRuns(of: $0, maxCharacters: maxCharacters) : [$0] }
    }

    private static func wordRuns(of text: String, maxCharacters: Int) -> [String] {
        var runs: [String] = []
        var current = ""
        var word = ""
        func flushWord() {
            if !current.isEmpty, current.count + word.count > maxCharacters {
                runs.append(current)
                current = ""
            }
            current += word
            word = ""
        }
        for character in text {
            word.append(character)
            if character.isWhitespace { flushWord() }
        }
        if !word.isEmpty { flushWord() }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Whitespace at either end of a run becomes the separator before or
    /// after it (a paragraph break can open the next sentence).
    private static func chunks(fromRuns runs: [String]) -> [Chunk] {
        var texts: [String] = []
        var separators: [String] = []
        for run in runs {
            let leading = String(run.prefix { $0.isWhitespace })
            let trailing = String(run.reversed().prefix { $0.isWhitespace }.reversed())
            let text = run.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                if !separators.isEmpty { separators[separators.count - 1] += run }
                continue
            }
            if !separators.isEmpty { separators[separators.count - 1] += leading }
            texts.append(text)
            separators.append(trailing)
        }
        return zip(texts, separators).map { Chunk(text: $0, separator: $1) }
    }
}
