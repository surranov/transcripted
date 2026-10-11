import Foundation

/// One utterance's text inside a saved meeting transcript, located by line so
/// the transcript LLM pass (fork) can rewrite it in place and touch nothing
/// else: not the timestamp, not the speaker label, not the frontmatter or any
/// other section.
struct MeetingTranscriptUtterance: Equatable, Sendable {
    /// Position among the transcript's utterances; the key results are stored
    /// under.
    let index: Int
    let headerLine: Int
    /// Styled form: the text lines after the header. Raw form: the header line
    /// itself, with the text inline after `inlinePrefix`.
    let textLines: Range<Int>
    let inlinePrefix: String?
    let text: String
}

/// Reads and rewrites utterance text in a saved meeting transcript, in both
/// body forms from `docs/capture-format.md`: styled (`**00:04**  [System/Sarah]`
/// then the text on the next lines) and raw (`[00:04] [System/Sarah] text`).
/// Foundation-only and line-based: every line it doesn't rewrite comes back
/// byte for byte.
enum MeetingTranscriptLLMDocument {
    /// Frontmatter key written once the pass has rewritten the transcript; its
    /// value is the model that did it. A transcript carrying it is not queued
    /// again.
    static let markerKey = "transcript_llm"

    // `[Mic/You]`, `[System/Speaker 2]`, legacy `[System/[[Sarah]]]`.
    private static let label = #"\[(?:Mic|System)/(?:\[\[[^\]]*\]\]|[^\]]*)\]"#
    private static let styledHeader = try? NSRegularExpression(
        pattern: #"^\*\*[0-9:]+\*\*\s+"# + label + #"\s*$"#
    )
    private static let styledInline = try? NSRegularExpression(
        pattern: #"^(\*\*[0-9:]+\*\*\s+"# + label + #"\s+)(\S.*)$"#
    )
    private static let rawInline = try? NSRegularExpression(
        pattern: #"^(\[[0-9:]+\]\s+"# + label + #"\s+)(\S.*)$"#
    )

    static func utterances(in markdown: String) -> [MeetingTranscriptUtterance] {
        utterances(inLines: markdown.components(separatedBy: "\n"))
    }

    static func isProcessed(_ markdown: String) -> Bool {
        frontmatterRange(in: markdown.components(separatedBy: "\n")).map { range in
            markdown.components(separatedBy: "\n")[range].contains { $0.hasPrefix("\(markerKey):") }
        } ?? false
    }

    /// The frontmatter's `capture_id`, the identity a job keeps across renames.
    static func captureID(in markdown: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")
        guard let range = frontmatterRange(in: lines) else { return nil }
        for line in lines[range] where line.hasPrefix("capture_id:") {
            let value = line.dropFirst("capture_id:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    struct Rewrite: Equatable {
        let markdown: String
        /// Utterances actually replaced.
        let applied: Int
    }

    /// Replaces the text of utterances by index, but only where the transcript
    /// still holds the text the replacement was made from (`originals`), so an
    /// edit made while the pass ran (a user fix, a re-transcription) is never
    /// overwritten. Adds the frontmatter marker. Newlines in a replacement are
    /// folded to spaces: an utterance stays one paragraph.
    static func applying(
        _ replacements: [Int: String],
        originals: [Int: String],
        to markdown: String,
        marker: String
    ) -> Rewrite {
        var lines = markdown.components(separatedBy: "\n")
        var applied = 0
        // Bottom to top, so a rewrite that changes a line count can't shift
        // the lines still to come.
        for utterance in utterances(inLines: lines).reversed() {
            guard let replacement = replacements[utterance.index],
                  let original = originals[utterance.index],
                  original == utterance.text else { continue }
            let text = replacement
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty, text != utterance.text else { continue }
            if let prefix = utterance.inlinePrefix {
                lines[utterance.headerLine] = prefix + text
            } else {
                lines.replaceSubrange(utterance.textLines, with: [text])
            }
            applied += 1
        }
        lines = withMarker(marker, in: lines)
        return Rewrite(markdown: lines.joined(separator: "\n"), applied: applied)
    }

    // MARK: - Parsing

    private static func utterances(inLines lines: [String]) -> [MeetingTranscriptUtterance] {
        guard let section = transcriptSection(in: lines) else { return [] }
        var result: [MeetingTranscriptUtterance] = []
        var line = section.lowerBound
        while line < section.upperBound {
            let current = lines[line]
            if let (prefix, text) = inlineMatch(rawInline, in: current) ?? inlineMatch(styledInline, in: current) {
                result.append(MeetingTranscriptUtterance(
                    index: result.count, headerLine: line, textLines: line..<(line + 1),
                    inlinePrefix: prefix, text: text.trimmingCharacters(in: .whitespaces)
                ))
                line += 1
                continue
            }
            if matches(styledHeader, current) {
                var end = line + 1
                while end < section.upperBound,
                      !lines[end].trimmingCharacters(in: .whitespaces).isEmpty,
                      !matches(styledHeader, lines[end]),
                      inlineMatch(styledInline, in: lines[end]) == nil {
                    end += 1
                }
                let textLines = (line + 1)..<end
                let text = lines[textLines]
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n")
                if !text.isEmpty {
                    result.append(MeetingTranscriptUtterance(
                        index: result.count, headerLine: line, textLines: textLines,
                        inlinePrefix: nil, text: text
                    ))
                }
                line = max(end, line + 1)
                continue
            }
            line += 1
        }
        return result
    }

    /// Lines after `## Transcript` / `## Full Transcript` up to the next
    /// section, rule or generated footer.
    private static func transcriptSection(in lines: [String]) -> Range<Int>? {
        guard let heading = lines.firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed == "## Transcript" || trimmed == "## Full Transcript"
        }) else { return nil }
        let start = heading + 1
        var end = lines.count
        for index in start..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") || trimmed == "---" || trimmed.hasPrefix("*Generated by ") {
                end = index
                break
            }
        }
        return start..<end
    }

    private static func frontmatterRange(in lines: [String]) -> Range<Int>? {
        guard lines.first == "---",
              let close = lines.dropFirst().firstIndex(of: "---") else { return nil }
        return 1..<close
    }

    private static func withMarker(_ marker: String, in lines: [String]) -> [String] {
        guard let range = frontmatterRange(in: lines) else { return lines }
        var lines = lines
        let entry = "\(markerKey): \"\(marker.replacingOccurrences(of: "\"", with: "'"))\""
        if let existing = lines[range].firstIndex(where: { $0.hasPrefix("\(markerKey):") }) {
            lines[existing] = entry
        } else {
            lines.insert(entry, at: range.upperBound)
        }
        return lines
    }

    private static func matches(_ regex: NSRegularExpression?, _ line: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func inlineMatch(_ regex: NSRegularExpression?, in line: String) -> (String, String)? {
        guard let regex,
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges >= 3,
              let prefix = Range(match.range(at: 1), in: line),
              let text = Range(match.range(at: 2), in: line) else { return nil }
        return (String(line[prefix]), String(line[text]))
    }
}
