// DictationCardPresentation.swift
// Plain decisions behind the Dictations page cards: the metadata line and
// whether Transcribe again is offered. No SwiftUI, so tests call it directly.

import Foundation

enum DictationCardFormatting {
    enum MetadataKind: Equatable {
        case time
        case length
        case words
        case app
        /// A delivery problem, shown in amber.
        case problem
    }

    struct MetadataItem: Equatable, Identifiable {
        let kind: MetadataKind
        let text: String
        var id: String { "\(kind)" }

        /// Length and app step aside while the player is open; the time,
        /// words, and any problem stay.
        var collapsesWhilePlaying: Bool {
            kind == .length || kind == .app
        }
    }

    /// The bar's metadata, in order: time, length, words, app, problem.
    /// Length is left out until it's known; the app is left out when the
    /// entry doesn't name one.
    static func metadata(
        time: String,
        length: TimeInterval?,
        wordCount: Int,
        appName: String,
        delivery: DictationDelivery
    ) -> [MetadataItem] {
        var items = [MetadataItem(kind: .time, text: time)]
        if let length, length > 0 {
            items.append(MetadataItem(kind: .length, text: lengthText(seconds: length)))
        }
        items.append(MetadataItem(kind: .words, text: wordsText(wordCount)))
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !app.isEmpty, app != "Unknown" {
            items.append(MetadataItem(kind: .app, text: app))
        }
        if let problem = deliveryProblem(delivery) {
            items.append(MetadataItem(kind: .problem, text: problem))
        }
        return items
    }

    /// VoiceOver reads the bar as one sentence.
    static func accessibilitySummary(_ items: [MetadataItem]) -> String {
        items.map(\.text).joined(separator: ", ")
    }

    /// "16 sec", "1 min 24 sec", "32 min", "1 hr 5 min". Minutes and seconds
    /// both show under five minutes; past that, whole minutes.
    static func lengthText(seconds: TimeInterval) -> String {
        let total = max(1, Int(seconds.rounded()))
        if total < 60 {
            return "\(total) sec"
        }
        if total < 300 {
            let minutes = total / 60
            let rest = total % 60
            return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) sec"
        }
        let minutes = Int((Double(total) / 60).rounded())
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    /// Player clock: "0:07", "1:24", "1:02:03".
    static func clockText(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let rest = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, rest)
        }
        return String(format: "%d:%02d", minutes, rest)
    }

    static func wordsText(_ count: Int) -> String {
        count == 1 ? "1 word" : "\(count) words"
    }

    static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// The amber note for a take that didn't land in the app. Never claims a
    /// destination: a copied take is on the clipboard, a failed or capped
    /// take was only saved here.
    static func deliveryProblem(_ delivery: DictationDelivery) -> String? {
        switch delivery {
        case .pasted, .sentToThread:
            return nil
        case .copied:
            return "copied, not pasted"
        case .failed, .savedWithoutPaste:
            return "saved only"
        }
    }
}

/// Whether a card's ⋯ menu offers Transcribe again, and how it's labeled.
/// The busy rules are the saved-meeting Re-transcribe rules
/// (`SavedMeetingRetranscriptionAvailabilityPolicy`): not while dictating,
/// recording, loading models, or finishing a meeting. One dictation is
/// transcribed again at a time.
enum DictationTranscribeAgainPolicy {
    enum Availability: Equatable {
        /// No kept audio: the item isn't shown.
        case hidden
        case available
        /// This entry is being transcribed again now.
        case running
        case unavailable(reason: String)
    }

    static let anotherRunningReason = "Wait for the other dictation to finish transcribing again."

    static func availability(
        entryID: String,
        hasAudio: Bool,
        runningEntryID: String?,
        globalUnavailableReason: String?
    ) -> Availability {
        guard hasAudio else { return .hidden }
        if runningEntryID == entryID { return .running }
        if let globalUnavailableReason { return .unavailable(reason: globalUnavailableReason) }
        if runningEntryID != nil { return .unavailable(reason: anotherRunningReason) }
        return .available
    }

    /// The menu title, or nil when the item is hidden. A greyed-out menu item
    /// can't show a tooltip, so it says when it'll work again.
    static func menuTitle(for availability: Availability) -> String? {
        switch availability {
        case .hidden:
            return nil
        case .available:
            return "Transcribe again"
        case .running:
            return "Transcribing again\u{2026}"
        case .unavailable(let reason):
            let hint = reason == anotherRunningReason
                ? "after the current one"
                : SavedMeetingRetranscriptionAvailabilityPolicy.menuHint(for: reason)
            return "Transcribe again (\(hint))"
        }
    }

    static func isEnabled(_ availability: Availability) -> Bool {
        availability == .available
    }
}

/// Automation ids for the Dictations card's ⋯ menu. The page picks the
/// shell's reveal item by this id, not by its title.
enum DictationRowMenuIdentifier {
    static let reveal = "transcripted.dictations.row.reveal"
    static let transcribeAgain = "transcripted.dictations.row.transcribeAgain"
}

/// The version tabs an expanded Dictations card shows (fork): the original
/// recognized text and each model's version of it, labeled with the model.
/// Collapsed cards show the saved text only.
enum DictationVersionTabs {
    struct Tab: Equatable, Identifiable {
        let id: Int
        let title: String
        let text: String
    }

    struct Layout: Equatable {
        let tabs: [Tab]
        /// The tab holding the entry's saved text, selected when the card opens.
        let savedTabID: Int
    }

    /// The saved text when no version matches it (the day file was edited
    /// by hand).
    static let savedTitle = "Saved"
    /// A version from before versions were kept (`.earlier`).
    static let earlierTitle = "Earlier"

    /// Tabs in the order the texts were made, or nil when there's nothing to
    /// choose between (fewer than two texts). A title that repeats (two runs
    /// on one model) gets a number: "Gemma 4 E2B", "Gemma 4 E2B 2".
    static func layout(versions: [DictationTextVersion], savedText: String) -> Layout? {
        var tabs: [Tab] = []
        var seenTitles: [String: Int] = [:]
        for version in versions {
            let base = title(for: version)
            let count = (seenTitles[base] ?? 0) + 1
            seenTitles[base] = count
            tabs.append(Tab(id: tabs.count, title: count == 1 ? base : "\(base) \(count)", text: version.text))
        }
        let saved = savedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedTabID: Int
        if let match = tabs.last(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == saved }) {
            savedTabID = match.id
        } else if !saved.isEmpty {
            tabs.append(Tab(id: tabs.count, title: savedTitle, text: saved))
            savedTabID = tabs.count - 1
        } else {
            return nil
        }
        guard tabs.count >= 2 else { return nil }
        return Layout(tabs: tabs, savedTabID: savedTabID)
    }

    /// "Original · Parakeet V3" for what recognition heard, the LLM's name
    /// for its answer. A model the app no longer offers shows its raw id.
    static func title(for version: DictationTextVersion) -> String {
        switch version.stage {
        case .recognized:
            guard let model = version.model else { return "Original" }
            return "Original · \(TranscriptionModelChoice(rawValue: model)?.shortTitle ?? model)"
        case .refined:
            guard let model = version.model else { return "Processed" }
            return TranscriptLLMModelChoice(rawValue: model)?.title ?? model
        case .earlier:
            return earlierTitle
        }
    }
}
