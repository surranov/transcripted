import Foundation

// A long dictation goes to the transcript LLM in pieces (DictationRefinementChunking):
// even pieces cut at sentence ends, nothing lost or reordered when the
// refined pieces are joined back, short takes still one request.

func testDictationRefinementChunking() {
    let sentence = "Это предложение диктовки примерно на сто символов, чтобы набрать длину для нарезки текста. "

    runSuite("DictationRefinementChunking keeps a short take whole") {
        assertEqual(DictationRefinementChunking.chunks(of: "  привет мир  "), [.init(text: "привет мир", separator: "")], "one request, trimmed")
        assertEqual(DictationRefinementChunking.chunks(of: " \n "), [], "nothing to send")
        let fiveMinutes = String(repeating: sentence, count: 30)
        assertEqual(DictationRefinementChunking.chunks(of: fiveMinutes).count, 1, "up to about five minutes of speech: one request, as before")
    }

    runSuite("DictationRefinementChunking cuts a long take into even pieces at sentence ends") {
        let text = String(repeating: sentence, count: 45).trimmingCharacters(in: .whitespaces)
        let chunks = DictationRefinementChunking.chunks(of: text)
        assertEqual(chunks.count, 3, "about 4,100 characters: three pieces")
        assertTrue(chunks.allSatisfy { $0.text.hasSuffix(".") && $0.text.hasPrefix("Это") }, "each piece is whole sentences")
        assertTrue(chunks.allSatisfy { $0.text.count <= DictationRefinementChunking.targetChunkCharacters }, "no piece over the target")
        assertEqual(DictationRefinementChunking.join(chunks.map(\.text), of: chunks), text, "joined back, the take is unchanged")
    }

    runSuite("DictationRefinementChunking keeps paragraphs and punctuation-less speech") {
        let paragraphs = (0..<6).map { _ in String(repeating: sentence, count: 6).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n\n")
        let chunks = DictationRefinementChunking.chunks(of: paragraphs)
        assertEqual(DictationRefinementChunking.join(chunks.map(\.text), of: chunks), paragraphs, "line breaks between pieces come back")
        assertTrue(chunks.dropLast().allSatisfy { !$0.separator.isEmpty }, "every piece but the last keeps what followed it")

        let words = String(repeating: "слово ", count: 900).trimmingCharacters(in: .whitespaces)
        let wordChunks = DictationRefinementChunking.chunks(of: words)
        assertTrue(wordChunks.count >= 3, "no sentence ends: cut at spaces")
        assertEqual(DictationRefinementChunking.join(wordChunks.map(\.text), of: wordChunks), words, "nothing lost")
    }

    runSuite("DictationRefinementChunking puts refined pieces back in order") {
        let chunks: [DictationRefinementChunking.Chunk] = [.init(text: "a", separator: " "), .init(text: "b", separator: "\n\n"), .init(text: "c", separator: "")]
        assertEqual(DictationRefinementChunking.join(["A.", "B.", "C."], of: chunks), "A. B.\n\nC.", "each piece keeps its separator")
    }
}
