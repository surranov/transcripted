// NotchIslandController+LiveTranscript.swift
// The recording drop-down's live transcript: keeps one
// NotchIslandLiveTranscriptView alive for each surface of the island, feeds
// them from LiveMeetingCaptions, and copies the whole transcript on Copy all.

import AppKit
import Combine

extension NotchIslandController {
    /// The meeting's live transcript changed. The views live as long as the
    /// island so their scroll position survives the drop-down being rebuilt;
    /// they are updated in place, never by re-rendering the island.
    func updateLiveTranscript(_ log: LiveMeetingCaptionLog, status: LiveMeetingCaptions.Status) {
        // Nothing to show yet: don't build the panel for it.
        if surfaces.isEmpty, log.isEmpty, status == .off { return }
        if Self.showsLiveTranscript(meeting) {
            ensureLiveTranscriptViews().forEach { $0.apply(log, status: status) }
        } else {
            // Never builds one back: once the recording ends the views are
            // released, and a hidden one only keeps the latest state.
            releaseLiveTranscriptViewIfRecordingEnded()
            islandViews.forEach { $0.liveTranscriptView?.apply(log, status: status) }
        }
        // The setting was flipped mid-meeting: swap lanes and transcript.
        if var meeting, meeting.showsLiveTranscript != Self.showsLiveTranscript(meeting) {
            meeting.showsLiveTranscript = Self.showsLiveTranscript(meeting)
            self.meeting = meeting
            render()
        }
    }

    @discardableResult
    func ensureLiveTranscriptViews() -> [NotchIslandLiveTranscriptView] {
        ensureSurfaces().map { surface in
            if let view = surface.view.liveTranscriptView { return view }
            let view = NotchIslandLiveTranscriptView(width: NotchIslandDropView.contentWidth)
            surface.view.liveTranscriptView = view
            let captions = LiveMeetingCaptions.shared
            view.apply(captions.log, status: captions.status)
            return view
        }
    }

    /// The recording is over, so the drop-down can't show the transcript
    /// again this meeting: free the views and their text storage. Copy all
    /// reads `LiveMeetingCaptions`, not a view, and the next meeting
    /// builds fresh views before its first drop-down.
    func releaseLiveTranscriptViewIfRecordingEnded() {
        guard meeting?.isRecording != true else { return }
        islandViews.forEach { $0.liveTranscriptView = nil }
    }

    static func showsLiveTranscript(_ meeting: NotchIslandMeetingContent?) -> Bool {
        meeting?.isRecording == true && NotchIslandPreferences.showsLiveTranscript()
    }

    func watchLiveTranscript() {
        let captions = LiveMeetingCaptions.shared
        liveTranscriptWatch = captions.$log.combineLatest(captions.$status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] log, status in
                MainActor.assumeIsolated { self?.updateLiveTranscript(log, status: status) }
            }
    }

    /// Copy all: the whole transcript so far, words still being heard included.
    func copyLiveTranscript() {
        let text = LiveMeetingCaptions.shared.log.plainText()
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
