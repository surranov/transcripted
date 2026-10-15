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
/// fresh state. Pastes, and their sends, stay in take order (`awaitDeliveryTurn`).
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
    /// Set once its detached audio is transcribed: the take's own empty
    /// reason and held-back text (the router's belong to the newest take).
    var detachedTranscript: DetachedDictationTranscript?
    /// Where it is, for the island's layers and hover cards.
    var stage: NotchIslandBackgroundTake.Stage = .processing {
        didSet { if stage != oldValue { onChange?() } }
    }
    /// Its words once written, for its hover card. Memory only.
    var cardText: String?
    /// Set at hand-off: the island follows its stage.
    var onChange: (() -> Void)?

    // The per-take controller state, copied at hand-off.
    var sessionStartTime: CFAbsoluteTime = 0
    var sourceApp: NSRunningApplication?
    var pasteTarget: DictationPasteTarget?
    var trigger: DictationTrigger = .unknown
    var shortcutMode: DictationShortcutMode?
    var startedWithDictateAndSendKey = false
    var stoppedAudioRecovery: DictationStoppedAudioRecovery?
    var stoppedAudioRecoveryPreservationSessionID: UUID?
    var transcriptRefinementTask: Task<DictationTextRefinement, Never>?
    var pasteAnchor: DictationPasteAnchor?
    var pasteAnchorTask: Task<Void, Never>?
    var anchoredSend: (route: AnchoredPasteRoute, anchor: DictationPasteAnchor)?
    var autoSendRequestDecision = DictationAutoSendRequestDecision.notEvaluated
    var chatThreadCapture: Task<ChatThread?, Never>?
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

/// Who answers Esc while takes finish in the background.
enum DictationHandedOffEscapePolicy {
    /// The take on the island has Esc first (the overlay's monitor); only
    /// with none there does Esc reach the takes behind it.
    static func handlesEscape(isDictating: Bool, overlayOwnsEscape: Bool) -> Bool {
        !isDictating && !overlayOwnsEscape
    }
}

/// A handed-off take that didn't paste, shown once the island is free.
struct HandedOffTakeNotice {
    enum Kind {
        case notPasted(unconfirmed: Bool, hint: String?)
        case clipboardBusy
        case error
        /// An empty take's message, with its button when it has one (Paste
        /// Anyway, Transcribe It).
        case message(actionTitle: String?, action: (() -> Void)?)
    }
    let text: String
    let message: String
    let kind: Kind
}

extension DictationSessionController {
    /// How long a ready take waits for an earlier take to paste first. Every
    /// take ends its turn however it ends (`takeTaskEnded`), so this only
    /// guards against a take stuck for good; it used to be 60 s, which a long
    /// LLM pass over an earlier take could outlast and paste out of order.
    static let deliveryTurnWaitSeconds: Double = 600

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
              // (Transcribe Again, a take still holding the engine's audio) it
              // keeps waiting, and the island would be left on this take's
              // "Writing". Detached takes being transcribed don't hold it.
              !(appState?.sttRouter.blocksNewDictationStart ?? false) else { return false }
        // Outside any take's scope, these read the controller's own state.
        take.sessionStartTime = sessionStartTime
        take.sourceApp = sessionSourceApp
        take.pasteTarget = sessionPasteTarget
        take.trigger = currentDictationTrigger
        take.shortcutMode = currentDictationShortcutMode
        take.startedWithDictateAndSendKey = currentDictationStartedWithDictateAndSendKey
        take.stoppedAudioRecovery = stoppedAudioRecovery
        take.stoppedAudioRecoveryPreservationSessionID = stoppedAudioRecoveryPreservationSessionID
        take.transcriptRefinementTask = transcriptRefinementTask
        take.pasteAnchor = pasteAnchor
        take.pasteAnchorTask = pasteAnchorTask
        take.anchoredSend = anchoredSend
        take.autoSendRequestDecision = autoSendRequestDecision
        take.chatThreadCapture = chatThreadCapture
        take.processingTask = streamingTask
        take.markHandedOff()

        // The next take starts clean; the handed-off one keeps its copies.
        streamingTask = nil
        stoppedAudioRecovery = nil
        stoppedAudioRecoveryPreservationSessionID = nil
        transcriptRefinementTask = nil
        anchoredSend = nil
        pasteAnchorTask = nil
        chatThreadCapture = nil
        finishingTake = nil
        handedOffTakes.append(take)
        take.onChange = { [weak self] in self?.handedOffTakesChanged() }
        // Its transcription and LLM pass run on: App Nap must not throttle
        // them once `isDictating` lets go below. Released when it ends.
        DictationProcessActivity.shared.acquire(reason: "Finishing a dictation in the background")
        handedOffTakesChanged()
        appState?.logger.log("DICTATION | take handed off to finish in the background (\(handedOffTakes.count) finishing)")
        isDictating = false
        return true
    }

    /// The take's stop task ended, however it ended (an early return too):
    /// its paste turn passes on, and a handed-off take leaves the list.
    func takeTaskEnded(_ take: DictationFinishingTake) {
        // A take that ended without its words landing (an error, no speech)
        // takes its flag along; a landed or waiting one keeps it a while.
        anchorMarker.hideIfInFlight(take.sessionID)
        take.isDelivering = false
        markDelivered(take.sequence)
        pasteDeclinedSessionIDs.remove(take.sessionID)
        if take.isHandedOff {
            finishHandedOffTake(take)
        } else if finishingTake === take {
            finishingTake = nil
        }
    }

    // MARK: - Esc

    /// Esc with no take on the island reaches the newest take still finishing
    /// behind it: it won't paste and is saved to Dictations, like Esc after
    /// a stop. Each Esc takes the next one back. A take already pasting, or
    /// declined, is passed over. False when none is left.
    @discardableResult
    func declineNewestHandedOffTakePaste() -> Bool {
        guard let take = handedOffTakes.last(where: {
            !$0.finished && !$0.isDelivering && !pasteDeclinedSessionIDs.contains($0.sessionID)
        }) else { return false }
        pasteDeclinedSessionIDs.insert(take.sessionID)
        take.transcriptRefinementTask?.cancel()
        appState?.logger.log("DICTATION | Esc: a take finishing in the background won't paste; it is saved")
        handedOffTakesChanged()
        return true
    }

    /// Watches Esc while takes finish in the background. The overlay's own
    /// monitor owns Esc while a take is on the island (cancel, or decline
    /// its paste); this one acts only when none is. Never touches a meeting.
    func updateHandedOffEscapeMonitor() {
        let wanted = handedOffTakes.contains { !$0.finished }
        if wanted, handedOffEscapeMonitor == nil {
            handedOffEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, !event.isARepeat,
                      // Decided now, as the key lands: the overlay's monitor
                      // reacts to this same press on a later turn, and its
                      // cancel would otherwise make this one act on the take
                      // behind as well. Off the main thread it's left alone.
                      Thread.isMainThread,
                      MainActor.assumeIsolated({ [weak self] in
                          guard let self else { return false }
                          return DictationHandedOffEscapePolicy.handlesEscape(
                              isDictating: self.isDictating,
                              overlayOwnsEscape: self.overlayController?.ownsEscapeForTake ?? false
                          )
                      }) else { return }
                Task { @MainActor [weak self] in
                    self?.declineNewestHandedOffTakePaste()
                }
            }
        } else if !wanted, let monitor = handedOffEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            handedOffEscapeMonitor = nil
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
        DictationProcessActivity.shared.release()
        markDelivered(take.sequence)
        handedOffTakes.removeAll { $0 === take }
        handedOffTakesChanged()
        presentHandedOffNoticeIfIdle()
    }

    /// The takes finishing behind the island changed (one joined, left, or
    /// moved on a stage): the island's layers and the background Esc follow.
    func handedOffTakesChanged() {
        overlayController?.island?.updateBackgroundTakes(backgroundTakeSnapshots())
        updateHandedOffEscapeMonitor()
    }

    /// The takes finishing behind the island, oldest first, as the island
    /// draws them.
    func backgroundTakeSnapshots() -> [NotchIslandBackgroundTake] {
        handedOffTakes.filter { !$0.finished }.map { take in
            NotchIslandBackgroundTake(
                id: take.sessionID,
                stage: take.stage,
                appName: take.sourceApp?.localizedName,
                text: take.cardText,
                declined: pasteDeclinedSessionIDs.contains(take.sessionID)
            )
        }
    }

    /// The hover cards' Don't paste: the take on the island (as Esc after its
    /// stop), or one finishing behind it.
    func handleTakeQueueAction(_ action: NotchIslandAction) {
        switch action {
        case .dictationDeclinePaste:
            _ = keepStoppedTakeWithoutPasting()
        case .backgroundTakeDeclinePaste(let id):
            guard let take = handedOffTakes.first(where: { $0.sessionID == id }),
                  !take.finished, !take.isDelivering else { return }
            pasteDeclinedSessionIDs.insert(id)
            take.transcriptRefinementTask?.cancel()
            appState?.logger.log("DICTATION | Don't paste: a take finishing in the background is saved instead")
            handedOffTakesChanged()
        default:
            break
        }
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
        case .notPasted(let unconfirmed, let hint):
            showNotPasted(notice.text, message: notice.message, unconfirmed: unconfirmed, hint: hint, overlayController: overlayController)
        case .clipboardBusy:
            showClipboardBusy(notice.text, message: notice.message, overlayController: overlayController)
        case .error:
            overlayController.showError(notice.message)
        case .message(let actionTitle, let action):
            overlayController.showError(notice.message, actionTitle: actionTitle, action: action)
        }
    }
}

extension FloatingOverlayController {
    /// A take is on the island in a state the overlay's own Esc monitor
    /// answers (cancel, confirm, decline its paste, dismiss its message).
    var ownsEscapeForTake: Bool {
        switch state {
        case .starting, .loading, .listening, .drafting: return true
        case .idle, .success: return false
        }
    }
}
