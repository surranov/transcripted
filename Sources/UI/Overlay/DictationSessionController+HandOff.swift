import AppKit
import Combine

/// Fork: the dictation queue. A start press while the last take is still
/// being refined or pasted no longer waits for it: that take hands the
/// controller to the next one and finishes on its own.
///
/// A take is handed off only between its transcription and its paste, or
/// after the paste (Auto Enter and the save): the speech engine is done with
/// it by then, and the clipboard isn't in use. A press during the stop
/// checkpoint, the model wait, transcription or the paste itself waits in the
/// queued start (`DictationQueuedStartPolicy`) until the take gets there.
///
/// The take's stop task runs inside `DictationTakeScope.$take`. Once it is
/// handed off, the controller's per-take state (session id, start time,
/// source app, paste target, anchor, Auto Enter decision, stopped audio...)
/// reads and writes the copy kept in `DictationFinishingTake` from inside
/// that task, so the code after the stop is unchanged and the next take gets
/// fresh state. Pastes stay in take order (`awaitDeliveryTurn`).
@MainActor
final class DictationFinishingTake {
    let sessionID: UUID
    /// Paste order: a take pastes after every earlier one has.
    let sequence: Int
    /// Between transcription and paste, or after the paste.
    var canHandOff = false
    private(set) var isHandedOff = false
    /// The take ended; stands in for `isDictating` once handed off.
    var finished = false
    /// Delivering its words (paste or anchored insert) right now.
    var isDelivering = false

    // The per-take controller state, copied at hand-off.
    var sessionStartTime: CFAbsoluteTime = 0
    var sourceApp: NSRunningApplication?
    var pasteTarget: DictationPasteTarget?
    var trigger: DictationTrigger = .unknown
    var shortcutMode: DictationShortcutMode?
    var stoppedAudioRecovery: DictationStoppedAudioRecovery?
    var stoppedAudioRecoveryPreservationSessionID: UUID?
    var transcriptRefinementTask: Task<DictationTextRefinement, Never>?
    var pasteAnchor: DictationPasteAnchor?
    var pasteAnchorTask: Task<Void, Never>?
    var anchoredSend: (route: AnchoredPasteRoute, anchor: DictationPasteAnchor)?
    var autoSendRequestDecision = DictationAutoSendRequestDecision.notEvaluated
    var processingTask: Task<Void, Never>?

    init(sessionID: UUID, sequence: Int) {
        self.sessionID = sessionID
        self.sequence = sequence
    }

    func markHandedOff() { isHandedOff = true }
}

/// The finishing take whose stop task is running, for the controller's
/// per-take properties.
enum DictationTakeScope {
    @TaskLocal static var take: DictationFinishingTake?

    /// The take, once it has handed the controller on. Before that, the
    /// controller's own state is the take's.
    @MainActor static var handedOff: DictationFinishingTake? {
        guard let take, take.isHandedOff else { return nil }
        return take
    }
}

/// A handed-off take that didn't paste, shown once the island is free.
struct HandedOffTakeNotice {
    enum Kind {
        case notPasted(unconfirmed: Bool)
        case clipboardBusy
        case error
    }
    let text: String
    let message: String
    let kind: Kind
}

extension DictationSessionController {
    /// How long a ready take waits for an earlier take to paste first.
    static let deliveryTurnWaitSeconds: Double = 60

    /// Whether the take running this code is still live: `isDictating` for
    /// the current take, its own flag once handed off.
    var activeTakeIsLive: Bool {
        if let take = DictationTakeScope.handedOff { return !take.finished }
        return isDictating
    }

    /// Ends the take running this code: `isDictating = false` for the
    /// current take; a handed-off take leaves the next take's state alone.
    func endActiveTake() {
        if let take = DictationTakeScope.handedOff {
            finishHandedOffTake(take)
        } else {
            finishingTake = nil
            isDictating = false
        }
    }

    /// Marks the take running this code as safe (or not) to hand off, and
    /// wakes a waiting start press.
    func setActiveTakeCanHandOff(_ canHandOff: Bool) {
        guard let take = DictationTakeScope.take, !take.isHandedOff else { return }
        take.canHandOff = canHandOff
        if canHandOff { handOffReadiness.send(()) }
    }

    /// Hands the finishing take off so the next take can start now. Called
    /// by a waiting start press; false when there's nothing to hand off.
    @discardableResult
    func handOffFinishingTakeIfReady() -> Bool {
        guard isDictating, DictationTakeScope.take == nil,
              let take = finishingTake, take.canHandOff, !take.isHandedOff,
              take.sessionID == currentDictationSessionID,
              // The waiting press must start right away: with the engine busy
              // (Transcribe Again, launch recovery) it keeps waiting, and the
              // island would be left on this take's "Writing".
              !(appState?.sttRouter.isTranscribing ?? false) else { return false }
        // Outside any take's scope, these read the controller's own state.
        take.sessionStartTime = sessionStartTime
        take.sourceApp = sessionSourceApp
        take.pasteTarget = sessionPasteTarget
        take.trigger = currentDictationTrigger
        take.shortcutMode = currentDictationShortcutMode
        take.stoppedAudioRecovery = stoppedAudioRecovery
        take.stoppedAudioRecoveryPreservationSessionID = stoppedAudioRecoveryPreservationSessionID
        take.transcriptRefinementTask = transcriptRefinementTask
        take.pasteAnchor = pasteAnchor
        take.pasteAnchorTask = pasteAnchorTask
        take.anchoredSend = anchoredSend
        take.autoSendRequestDecision = autoSendRequestDecision
        take.processingTask = streamingTask
        take.markHandedOff()

        // The next take starts clean; the handed-off one keeps its copies.
        streamingTask = nil
        stoppedAudioRecovery = nil
        stoppedAudioRecoveryPreservationSessionID = nil
        transcriptRefinementTask = nil
        anchoredSend = nil
        pasteAnchorTask = nil
        finishingTake = nil
        handedOffTakes.append(take)
        overlayController?.finishingInBackground = handedOffTakes.count
        appState?.logger.log("DICTATION | take handed off to finish in the background (\(handedOffTakes.count) finishing)")
        isDictating = false
        return true
    }

    /// The take's stop task ended, however it ended (an early return too):
    /// its paste turn passes on, and a handed-off take leaves the list.
    func takeTaskEnded(_ take: DictationFinishingTake) {
        take.isDelivering = false
        markDelivered(take.sequence)
        if take.isHandedOff {
            finishHandedOffTake(take)
        } else if finishingTake === take {
            finishingTake = nil
        }
    }

    /// Whether a handed-off take is pasting now: the clipboard is borrowed.
    var handedOffTakeIsDelivering: Bool {
        handedOffTakes.contains { $0.isDelivering }
    }

    /// A handed-off take ended (pasted, saved, or failed).
    private func finishHandedOffTake(_ take: DictationFinishingTake) {
        guard !take.finished else { return }
        take.finished = true
        take.isDelivering = false
        markDelivered(take.sequence)
        handedOffTakes.removeAll { $0 === take }
        overlayController?.finishingInBackground = handedOffTakes.count
        presentHandedOffNoticeIfIdle()
    }

    // MARK: - Paste order

    func nextTakeSequence() -> Int {
        deliveryOrder.assign()
    }

    /// Waits until every earlier take has pasted (or given up), so words
    /// land in the order they were spoken. Bounded: a stuck earlier take
    /// doesn't hold this one forever.
    func awaitDeliveryTurn(_ sequence: Int) async {
        let started = ProcessInfo.processInfo.systemUptime
        while !deliveryOrder.isTurn(of: sequence),
              ProcessInfo.processInfo.systemUptime - started < Self.deliveryTurnWaitSeconds,
              !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func markDelivered(_ sequence: Int) {
        deliveryOrder.markDelivered(sequence)
    }

    // MARK: - Notices from handed-off takes

    /// A handed-off take that didn't land keeps its notice until no take is
    /// on the island, so it never replaces the take being spoken.
    func queueHandedOffNotice(_ notice: HandedOffTakeNotice) {
        appState?.logger.log("DICTATION | handed-off take didn't paste; notice waits for the island")
        pendingHandedOffNotices.append(notice)
        presentHandedOffNoticeIfIdle()
    }

    func presentHandedOffNoticeIfIdle() {
        guard !pendingHandedOffNotices.isEmpty, let overlayController else { return }
        guard !isDictating, overlayController.state == .idle else {
            // Try again once the current take's own result has had its turn.
            guard handedOffNoticeRetry == nil else { return }
            handedOffNoticeRetry = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.handedOffNoticeRetry = nil
                self?.presentHandedOffNoticeIfIdle()
            }
            return
        }
        let notice = pendingHandedOffNotices.removeFirst()
        switch notice.kind {
        case .notPasted(let unconfirmed):
            showNotPasted(notice.text, message: notice.message, unconfirmed: unconfirmed, overlayController: overlayController)
        case .clipboardBusy:
            showClipboardBusy(notice.text, message: notice.message, overlayController: overlayController)
        case .error:
            overlayController.showError(notice.message)
        }
    }
}
