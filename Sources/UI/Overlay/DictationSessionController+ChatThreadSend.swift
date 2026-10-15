import AppKit

/// Fork: how a take goes to the chat thread it was dictated into through
/// the app's own server, instead of being pasted (`ChatThreadSendPolicy`).
struct ChatThreadSendInstead {
    let thread: ChatThread
    let target: ChatThreadSendTarget
    let plan: ChatThreadSendPolicy.Plan
}

/// Fork: a take dictated into a T3 Code or Codex thread goes to that thread
/// (`ChatThreadSender`: T3 Code's server, the Codex thread's queue) when the
/// user isn't looking at it: the app shows another thread, or, with Anchored
/// paste on, another app is in front. Send and With Dictate & send key send
/// it at once; After I confirm asks on the island first. When the app can't
/// take it, the take goes the usual way: the chat thread guard's "Not
/// pasted", or Anchored paste's routes.
extension DictationSessionController {
    /// How the take goes to its thread instead; nil when it is pasted as
    /// usual: no thread its app can be sent to, a take that doesn't send, or
    /// the user is looking at that thread.
    private func chatThreadSendInstead(of text: String) async -> ChatThreadSendInstead? {
        guard let thread = await chatThreadAtStart(), let target = thread.sendTarget,
              let plan = ChatThreadSendPolicy.plan(chatThreadSendDecision(for: text, bundleID: thread.bundleID)) else { return nil }
        let threadAppIsFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == thread.pid
        var showsAnotherThread = false
        if threadAppIsFrontmost {
            // Only another thread read on screen: a page that can't be read
            // keeps the guard's safe "Not pasted", never a send that can't
            // be taken back. (A new chat, which its send moves, has no
            // target, so `chatChanged`'s moves don't apply.)
            guard let current = await ChatThreadReader.currentIdentity(of: thread) else { return nil }
            showsAnotherThread = current != thread.identity
        }
        guard ChatThreadSendPolicy.userIsAway(
            threadAppIsFrontmost: threadAppIsFrontmost,
            showsAnotherThread: showsAnotherThread,
            anchoredPasteEnabled: AnchoredPastePreferences.isEnabled()
        ) else { return nil }
        return ChatThreadSendInstead(thread: thread, target: target, plan: plan)
    }

    /// The take's way to its thread instead of a paste; true when it ended
    /// there. Esc (or the island's Don't paste) that came while the thread
    /// was read or its server asked ends it too: kept, sent nowhere.
    func finishedByChatThreadSend(
        _ text: String,
        take: DictationFinishingTake,
        sessionID: UUID,
        versions: [DictationTextVersion],
        appState: TranscriptedAppState,
        overlayController: FloatingOverlayController
    ) async -> Bool {
        if let send = await chatThreadSendInstead(of: text),
           await deliverByChatThreadSend(
               send, text: text, take: take, sessionID: sessionID, versions: versions,
               appState: appState, overlayController: overlayController
           ) {
            return true
        }
        guard pasteDeclinedSessionIDs.contains(sessionID) else { return false }
        await finalizeWithoutPaste(
            text: text, appState: appState, overlayController: overlayController,
            sessionID: sessionID, reason: .escapeAfterStop, versions: versions
        )
        return true
    }

    /// A confirmed send of a take whose words went nowhere yet
    /// (`PendingSendConfirmation.anchor` nil).
    func sendConfirmedToChatThread(_ pending: PendingSendConfirmation) async -> ChatThreadSendResult {
        guard let target = pending.chatThread?.sendTarget else { return .notSent(reason: "no_thread") }
        return await ChatThreadSender.send(pending.text, to: target)
    }

    /// The island's word on a confirmed send to the thread, in place of its
    /// ask. One that didn't go shows the words with Paste; while a dictation
    /// owns the island, once it's free.
    func showConfirmedChatThreadSend(_ result: ChatThreadSendResult, pending: PendingSendConfirmation) {
        let appName = pending.chatThread?.appName ?? "the app"
        let notice: HandedOffTakeNotice
        switch result {
        case .sent:
            // A dictation started meanwhile owns the island now.
            guard let overlayController, !isDictating, !overlayController.state.isActiveDictationState else { return }
            overlayController.showSuccessAndDismiss(title: ChatThreadSendPolicy.sentTitle)
            return
        case .notSent:
            notice = HandedOffTakeNotice(
                text: pending.text,
                message: ChatThreadSendPolicy.notSentMessage(appName: appName),
                kind: .notPasted(unconfirmed: false, hint: ChatThreadSendPolicy.notSentHint)
            )
        case .unconfirmed:
            notice = HandedOffTakeNotice(
                text: pending.text,
                message: ChatThreadSendPolicy.unconfirmedMessage(appName: appName),
                kind: .notPasted(unconfirmed: false, hint: ChatThreadSendPolicy.unconfirmedHint)
            )
        }
        showOrQueue(notice, islandTaken: isDictating || overlayController?.state.isActiveDictationState != false)
    }

    /// The island's ask to send to the thread ran out unanswered: the words,
    /// which went nowhere, with Paste.
    func showUnconfirmedChatThreadSend(_ pending: PendingSendConfirmation) {
        let appName = pending.chatThread?.appName ?? "the app"
        showOrQueue(HandedOffTakeNotice(
            text: pending.text,
            message: ChatThreadSendPolicy.notConfirmedMessage(appName: appName),
            kind: .notPasted(unconfirmed: false, hint: ChatThreadSendPolicy.notConfirmedHint)
        ), islandTaken: isDictating || overlayController?.state.isActiveDictationState != false)
    }

    // MARK: - Private

    /// Sends the take to its thread, or asks first, then finishes the take;
    /// false when the server can't take it (or Esc came first), so the take
    /// goes on.
    private func deliverByChatThreadSend(
        _ send: ChatThreadSendInstead,
        text: String,
        take: DictationFinishingTake,
        sessionID: UUID,
        versions: [DictationTextVersion],
        appState: TranscriptedAppState,
        overlayController: FloatingOverlayController
    ) async -> Bool {
        let appName = send.thread.appName
        // Superseded or cancelled meanwhile: nothing more, as the paste
        // path's own check.
        func superseded() -> Bool {
            !DictationSessionCompletionPolicy.canPublish(
                sessionID: sessionID, currentSessionID: currentDictationSessionID,
                isDictating: activeTakeIsLive, cancelled: Task.isCancelled
            )
        }
        if superseded() { return true }
        if pasteDeclinedSessionIDs.contains(sessionID) { return false }
        // The clipboard isn't borrowed while the server is asked, so a
        // start press may hand the take off meanwhile; its turn is kept
        // (`markDelivered` comes after).
        setActiveTakeCanHandOff(true)
        let result: ChatThreadSendResult
        switch send.plan {
        case .sendNow:
            result = await ChatThreadSender.send(text, to: send.target)
            appState.logger.log("DICTATION | sent to its thread in \(appName) through its server: \(result.diagnosticName)")
        case .askFirst:
            // Ready before the island asks, so a confirm sends at once.
            result = await ChatThreadSender.prepare(send.target) ? .sent : .notSent(reason: "not_ready")
        }
        setActiveTakeCanHandOff(false)
        if superseded() { return true }
        let end: ChatThreadSendEnd
        switch (send.plan, result) {
        case (_, .notSent(let reason)):
            appState.logger.log("DICTATION | \(appName)'s server can't take it (\(reason)); pasting the usual way")
            return false
        case (.askFirst, _):
            if pasteDeclinedSessionIDs.contains(sessionID) { return false }
            end = .asking(send.thread)
        case (.sendNow, .sent):
            end = .sent
        case (.sendNow, .unconfirmed):
            end = .unconfirmed(textPaster.copyForChangedChat(
                text,
                message: ChatThreadSendPolicy.unconfirmedMessage(appName: appName, onClipboard: true)
            ))
        }
        take.isDelivering = false
        markDelivered(take.sequence)
        await finishChatThreadSendTake(
            text, end: end, appName: appName, take: take, sessionID: sessionID, versions: versions,
            appState: appState, overlayController: overlayController
        )
        return true
    }

    private enum ChatThreadSendEnd {
        case sent
        /// No answer from the server: the words are on the clipboard
        /// (`copied`), shown with "Not pasted".
        case unconfirmed(DictationPasteOutcome)
        /// The island asks before the send goes.
        case asking(ChatThread)

        var delivery: DictationDelivery {
            switch self {
            case .sent: return .sentToThread
            case .unconfirmed(let copied): return copied.delivery
            case .asking: return .savedWithoutPaste
            }
        }

        var autoSendName: String {
            switch self {
            case .sent: return "sent_to_thread"
            case .unconfirmed: return "failed"
            case .asking: return DictationAutoSendOutcome.awaitingConfirmation.diagnosticName
            }
        }
    }

    /// The take's send decision with its thread standing in for the anchored
    /// box: the thread is known however the user moved, so neither Anchored
    /// paste's box nor After I confirm's need of one applies.
    private func chatThreadSendDecision(for text: String, bundleID: String?) -> DictationAutoSendRequestDecision {
        let resolved = DictationSendSettings.behavior(
            for: bundleID,
            defaultBehavior: DictationSendSettings.defaultBehavior(),
            overrides: DictationSendSettings.overrides()
        )
        return DictationSendSettings.decision(
            behavior: resolved.behavior,
            isOverride: resolved.isOverride,
            key: DictationAutoSendPreferences.sendKey(),
            text: text,
            duration: CFAbsoluteTimeGetCurrent() - sessionStartTime,
            hasAnchor: true,
            anchoredPasteEnabled: true,
            startedWithDictateAndSendKey: currentDictationStartedWithDictateAndSendKey
        )
    }

    /// Saves the take to Dictations, reports it, and shows how it went (a
    /// handed-off take once the island is free), as the paste path does.
    private func finishChatThreadSendTake(
        _ text: String,
        end: ChatThreadSendEnd,
        appName: String,
        take: DictationFinishingTake,
        sessionID: UUID,
        versions: [DictationTextVersion],
        appState: TranscriptedAppState,
        overlayController: FloatingOverlayController
    ) async {
        lastCompletedText = text
        let delivery = end.delivery
        let recovery = stoppedAudioRecovery
        let saveContext = dictationSaveContext(text: text)
        let saveResult = await startPersistingDictationTranscript(
            text: text, delivery: delivery, recovery: recovery, versions: versions
        ).value
        publishDictationTranscriptPersistence(saveResult, delivery: delivery, context: saveContext)
        guard DictationSessionCompletionPolicy.canPublish(
            sessionID: sessionID, currentSessionID: currentDictationSessionID,
            isDictating: activeTakeIsLive, cancelled: Task.isCancelled
        ) else { return }
        if saveResult.saved != nil, stoppedAudioRecovery == recovery {
            stoppedAudioRecovery = nil
        }
        let saveFailureMessage = saveResult.failureMessage
        let handedOff = DictationTakeScope.handedOff != nil
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        let durationSeconds = CFAbsoluteTimeGetCurrent() - sessionStartTime
        DiagnosticsTrail.record(
            logger: appState.logger,
            level: saveFailureMessage == nil ? .info : .warning,
            engine: "dictation",
            event: "dictation_delivery_completed",
            message: "Dictation went to its chat thread through the app's server",
            context: dictationContext(extra: [
                "dictation_session_id": sessionID.uuidString,
                "trigger": currentDictationTrigger.rawValue,
                "delivery": delivery.rawValue,
                "auto_send": end.autoSendName,
                "chars": "\(text.count)",
                "words": "\(wordCount)",
                "duration_ms": "\(Int(durationSeconds * 1000))",
            ])
        )
        AnalyticsReporter.track("dictation_completed", properties: dictationAnalyticsProperties(extra: [
            "auto_send": end.autoSendName,
            "delivery": delivery.rawValue,
            "duration_bucket": AnalyticsReporter.durationBucket(seconds: durationSeconds),
            "trigger": currentDictationTrigger.rawValue,
            "word_count_bucket": AnalyticsReporter.wordCountBucket(wordCount),
        ]))
        if case .sent = end {
            anchorMarker.update(.done, for: currentDictationSessionID)
        } else {
            anchorMarker.hide(currentDictationSessionID)
        }
        switch end {
        case .sent:
            if let saveFailureMessage {
                showOrQueue(HandedOffTakeNotice(text: text, message: saveFailureMessage, kind: .error), islandTaken: handedOff)
            } else if !handedOff {
                overlayController.showSuccessAndDismiss(title: ChatThreadSendPolicy.sentTitle)
            }
        case .unconfirmed(.copied(let message, reason: _)):
            showOrQueue(HandedOffTakeNotice(
                text: text,
                message: saveFailureMessage.map { "\(message) \($0)" } ?? message,
                kind: .notPasted(unconfirmed: false, hint: ChatThreadSendPolicy.unconfirmedHint)
            ), islandTaken: handedOff)
        case .unconfirmed:
            // The clipboard couldn't take the words; Dictations has them.
            showOrQueue(HandedOffTakeNotice(
                text: text,
                message: ChatThreadSendPolicy.unconfirmedNotCopiedMessage(appName: appName),
                kind: .error
            ), islandTaken: handedOff)
        case .asking(let thread):
            // A failed save shows first; the send is still asked, after it.
            if let saveFailureMessage {
                showOrQueue(HandedOffTakeNotice(text: text, message: saveFailureMessage, kind: .error), islandTaken: handedOff)
            }
            askToSendToThread(
                text: text,
                chatThread: thread,
                order: take.sequence,
                takeOwnsIsland: !handedOff && saveFailureMessage == nil
            )
        }
        endActiveTake()
        appState.logger.log("DICTATION | completed through its chat thread's server: \(delivery.rawValue)\(handedOff ? " (handed off)" : "")")
        if !handedOff {
            appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "completed")
        }
    }

    /// On the island now, unless it isn't this take's (a handed-off take, a
    /// dictation under way): then once it's free.
    private func showOrQueue(_ notice: HandedOffTakeNotice, islandTaken: Bool) {
        guard !islandTaken, let overlayController else {
            queueHandedOffNotice(notice)
            return
        }
        switch notice.kind {
        case .notPasted(let unconfirmed, let hint):
            showNotPasted(notice.text, message: notice.message, unconfirmed: unconfirmed, hint: hint, overlayController: overlayController)
        case .error, .clipboardBusy, .message:
            overlayController.showError(notice.message)
        }
    }
}
