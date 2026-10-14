// DictationTextVersions.swift
// Fork: the texts one saved dictation went through, each with its model, so
// the Dictations page can show the original next to each model's version.

import Foundation

/// One text a saved dictation had. The day file keeps only the text that was
/// delivered; these keep the steps before it: what speech recognition heard
/// and what the transcript LLM made of it.
struct DictationTextVersion: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        /// Speech recognition's text after the live take's cleanup: what the
        /// transcript LLM was given.
        case recognized
        /// The transcript LLM's accepted answer.
        case refined
        /// The entry's text from before its versions were kept (Transcribe
        /// again on an older dictation). Its model isn't known.
        case earlier
    }

    let stage: Stage
    /// `TranscriptionModelChoice.rawValue` for `.recognized`,
    /// `TranscriptLLMModelChoice.rawValue` for `.refined`, nil for `.earlier`.
    /// Kept as the raw id so a model the app no longer offers still reads back.
    let model: String?
    let text: String
    let createdAt: Date

    /// What a finished take leaves: the recognized text, and the LLM's answer
    /// when it was accepted. A skipped or rejected pass leaves only the first.
    static func take(
        recognized: String,
        recognitionModel: String?,
        refinement: DictationTextRefinement,
        at date: Date = Date()
    ) -> [DictationTextVersion] {
        var versions = [DictationTextVersion(stage: .recognized, model: recognitionModel, text: recognized, createdAt: date)]
        if case let .refined(text, model) = refinement {
            versions.append(DictationTextVersion(stage: .refined, model: model.rawValue, text: text, createdAt: date))
        }
        return versions
    }
}

/// `<dictations folder>/versions/<entry id>.json`, one file per entry: written
/// when the entry is saved, added to by Transcribe again, deleted with the
/// entry. The day file stays the record of the dictation; a missing or
/// unreadable versions file only means the card shows no version tabs, so
/// nothing here throws past `append`, and the save paths ignore its failure.
enum DictationTextVersionStore {
    static let folderName = "versions"
    /// Transcribe again adds up to two versions a run; the oldest go first.
    static let maximumVersions = 8
    static let formatVersion = 1

    private struct File: Codable {
        var formatVersion: Int
        var entryID: String
        var versions: [DictationTextVersion]
    }

    /// One lock for every entry's file: Transcribe again's read-modify-write
    /// can't interleave with the save that created the file.
    private static let lock = NSLock()

    static func folder(in dictationsFolder: URL) -> URL {
        dictationsFolder.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Nil for an id that isn't a plain file name. Entry IDs are read back
    /// from Markdown the user can edit, so one must never become a path.
    static func fileURL(entryID: String, in dictationsFolder: URL) -> URL? {
        guard isSafeEntryID(entryID) else { return nil }
        return folder(in: dictationsFolder).appendingPathComponent("\(entryID).json", isDirectory: false)
    }

    static func isSafeEntryID(_ entryID: String) -> Bool {
        !entryID.isEmpty && entryID.count <= 200
            && entryID.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")
            }
    }

    /// The entry's versions, oldest first; empty when there are none or the
    /// file can't be read.
    static func load(entryID: String, in dictationsFolder: URL) -> [DictationTextVersion] {
        guard let url = fileURL(entryID: entryID, in: dictationsFolder) else { return [] }
        return lock.withLock { read(url)?.versions ?? [] }
    }

    /// Adds `versions` after the entry's existing ones. A version that repeats
    /// an existing one (same stage, model and text) isn't added again.
    static func append(_ versions: [DictationTextVersion], entryID: String, in dictationsFolder: URL) throws {
        guard !versions.isEmpty else { return }
        guard let url = fileURL(entryID: entryID, in: dictationsFolder) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try lock.withLock {
            var file = read(url) ?? File(formatVersion: formatVersion, entryID: entryID, versions: [])
            file.versions = merged(file.versions, adding: versions)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try encoder.encode(file).write(to: url, options: .atomic)
            FileManager.default.restrictFileToOwnerOnly(at: url)
        }
    }

    /// Saves a new entry's versions. Never throws: the dictation itself is
    /// already saved, and losing its versions only hides the tabs.
    @discardableResult
    static func record(_ versions: [DictationTextVersion], for saved: SavedDictationTranscript) -> Bool {
        do {
            try append(versions, entryID: saved.entryID, in: saved.url.deletingLastPathComponent())
            return true
        } catch {
            return false
        }
    }

    /// Transcribe again's versions. An entry saved before versions were kept
    /// first gets the text being replaced as `.earlier`, so the rewrite
    /// doesn't lose it. Never throws, like `record`: the rewrite already
    /// landed.
    @discardableResult
    static func recordRetranscription(
        _ versions: [DictationTextVersion],
        replacing earlier: DictationTextVersion,
        entryID: String,
        in dictationsFolder: URL
    ) -> Bool {
        let hasVersions = !load(entryID: entryID, in: dictationsFolder).isEmpty
        let keepsEarlier = !hasVersions && !earlier.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        do {
            try append((keepsEarlier ? [earlier] : []) + versions, entryID: entryID, in: dictationsFolder)
            return true
        } catch {
            return false
        }
    }

    static func delete(entryID: String, in dictationsFolder: URL) {
        guard let url = fileURL(entryID: entryID, in: dictationsFolder) else { return }
        lock.withLock { _ = try? FileManager.default.removeItem(at: url) }
    }

    /// A saved entry's versions; empty for an entry without an Entry ID.
    static func load(for entry: SavedDictationEntry) -> [DictationTextVersion] {
        guard let entryID = entry.entryID else { return [] }
        return load(entryID: entryID, in: entry.url.deletingLastPathComponent())
    }

    /// Runs once a deleted entry's undo window closes, next to its kept audio.
    static func delete(for entry: SavedDictationEntry) {
        guard let entryID = entry.entryID else { return }
        delete(entryID: entryID, in: entry.url.deletingLastPathComponent())
    }

    /// `existing` plus the new versions that don't repeat one, capped at
    /// `maximumVersions` by dropping the oldest.
    static func merged(_ existing: [DictationTextVersion], adding new: [DictationTextVersion]) -> [DictationTextVersion] {
        var result = existing
        for version in new where !result.contains(where: {
            $0.stage == version.stage && $0.model == version.model && $0.text == version.text
        }) {
            result.append(version)
        }
        return Array(result.suffix(maximumVersions))
    }

    private static func read(_ url: URL) -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(File.self, from: data)
    }

    // Built per call: coders aren't Sendable, and these files are tiny.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
