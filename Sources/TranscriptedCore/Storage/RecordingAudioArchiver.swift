import Foundation

struct RetainedRecordingAudio: Equatable {
    let directory: URL
    let micURL: URL?
    let systemURL: URL?
}

enum RecordingAudioArchiver {
    /// Copies the capture into `<transcript>_audio/` under `archiveRoot`. Each
    /// copy is flushed to the drive before it counts as archived, and so are
    /// the new directory entries, because the caller deletes the scratch
    /// original once the copy is reported. A copy that can't be made durable
    /// is reported as not archived, so its scratch original is kept.
    static func archive(
        micURL: URL?,
        systemURL: URL?,
        transcriptURL: URL,
        archiveRoot: URL,
        fileManager: FileManager = .default,
        durability: any FileDurability = SavedFileDurability.current
    ) throws -> RetainedRecordingAudio {
        guard micURL != nil || systemURL != nil else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directory = archiveRoot.appendingPathComponent(
            "\(transcriptURL.deletingPathExtension().lastPathComponent)_audio",
            isDirectory: true
        )
        let directoryAlreadyExisted = fileManager.fileExists(atPath: directory.path)
        try createPrivateDirectory(at: directory, fileManager: fileManager)

        var firstCopyError: Error?
        let archivedMicURL: URL?
        if let micURL {
            // The silent placeholder keeps its identity through the archive:
            // renamed to `microphone.*` it would read as a real recording and
            // keep a system-less row retryable forever.
            let micStem = FailedTranscription.isMicrophonePlaceholder(micURL) ? "microphone_placeholder" : "microphone"
            do {
                archivedMicURL = try copyAudioFile(
                    from: micURL,
                    to: directory.appendingPathComponent(micStem).appendingPathExtension(fileExtension(for: micURL)),
                    fileManager: fileManager,
                    durability: durability
                )
            } catch {
                firstCopyError = error
                archivedMicURL = nil
            }
        } else {
            archivedMicURL = nil
        }

        let systemStem = micURL == nil ? "recording" : "system_audio"
        let archivedSystemURL: URL?
        if let systemURL {
            do {
                archivedSystemURL = try copyAudioFile(
                    from: systemURL,
                    to: directory.appendingPathComponent(systemStem).appendingPathExtension(fileExtension(for: systemURL)),
                    fileManager: fileManager,
                    durability: durability
                )
            } catch {
                firstCopyError = firstCopyError ?? error
                archivedSystemURL = nil
            }
        } else {
            archivedSystemURL = nil
        }

        // A damaged local track must not prevent the valid remote track from
        // becoming durable (or vice versa). Report failure only when none of the
        // supplied sources could be retained; callers can compare supplied and
        // returned URLs to avoid deleting a source that was not copied.
        guard archivedMicURL != nil || archivedSystemURL != nil else {
            // Do not leave an empty archive folder after a total copy failure.
            // Never remove a pre-existing folder: it may contain audio retained
            // by an earlier run with the same transcript stem.
            if !directoryAlreadyExisted {
                try? fileManager.removeItem(at: directory)
            }
            throw firstCopyError ?? CocoaError(.fileNoSuchFile)
        }

        // The copies are durable; make the entries that name them durable too.
        // A directory that can't be flushed is not fatal for a copy that was:
        // the data is safe and the entry is journaled by the filesystem.
        for entry in [directory, archiveRoot]
        where !durability.syncDirectory(at: entry).isSafeToRelyOn {
            AppLogger.pipeline.warning("Could not flush the retained audio folder entry to disk")
        }

        return RetainedRecordingAudio(
            directory: directory,
            micURL: archivedMicURL,
            systemURL: archivedSystemURL
        )
    }

    private static func copyAudioFile(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager,
        durability: any FileDurability
    ) throws -> URL {
        let finalURL = uniqueURL(for: destinationURL, fileManager: fileManager)
        try fileManager.copyItem(at: sourceURL, to: finalURL)
        fileManager.restrictToOwnerOnly(atPath: finalURL.path)
        // `copyItem` only hands the bytes to the OS. The caller deletes the
        // scratch original once this copy is reported, so the copy must be on
        // the drive first; otherwise a power cut leaves neither.
        guard durability.syncFile(at: finalURL).isSafeToRelyOn else {
            throw CocoaError(.fileWriteUnknown)
        }
        return finalURL
    }

    private static func createPrivateDirectory(at url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        fileManager.restrictDirectoryToOwnerOnly(atPath: url.path)
    }

    private static func fileExtension(for url: URL) -> String {
        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return ext.isEmpty ? "wav" : ext
    }

    private static func uniqueURL(for url: URL, fileManager: FileManager) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var suffix = 2

        while true {
            let candidate = directory
                .appendingPathComponent("\(stem)-\(suffix)")
                .appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }
}
