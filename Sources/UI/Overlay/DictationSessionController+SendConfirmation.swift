// DictationSessionController+SendConfirmation.swift
// Fork: send pressed only once the user confirms it
// (`DictationAutoSendMode.confirmAfterPaste`).

import AppKit
import Carbon

/// What the event tap takes while a send waits: one press of `key`, from
/// any app, until `deadline` (`ProcessInfo.systemUptime`). Published by the
/// session controller; `ContextCaptureEngine` arms the tap with it.
struct DictationSendConfirmationArm: Equatable {
    let key: DictationSendConfirmKey
    let deadline: TimeInterval
}

/// A take whose words landed and whose send waits for the user's confirm.
/// It keeps the box the words went into and the words, since the
/// controller's per-take state moves on to the next take.
struct PendingSendConfirmation {
    let id = UUID()
    let key: DictationAutoSendKey
    let anchor: DictationPasteAnchor
    let text: String
    /// The box read the words back when they landed, so reading empty later
    /// means they were sent or cleared, not that the app hides its value.
    let boxWasReadable: Bool
    /// The AI chat the take was dictated into (`ChatThreadPolicy`): a
    /// confirmed send goes only while its app still shows that thread.
    let chatThread: ChatThread?
}

extension DictationSessionController {
    /// The words landed; ask before pressing send. Every take is asked in
    /// turn, in take order (`order`, its `DictationDeliveryOrder` number;
    /// `DictationSendConfirmationQueue`): the island shows one prompt with a
    /// Send button, and the confirm key works from any app until that
    /// prompt's wait runs out. With `takeOwnsIsland` (the take on the island,
    /// or a deferred paste landing while none is) the prompt takes the place
    /// of what the island shows for it; otherwise (a handed-off take) it
    /// waits until no take is on the island. A take with no anchored box
    /// isn't asked: nothing would say where send goes once the user clicks
    /// elsewhere.
    func askToSend(
        key: DictationAutoSendKey,
        anchor: DictationPasteAnchor?,
        text: String,
        chatThread: ChatThread?,
        order: Int,
        takeOwnsIsland: Bool
    ) {
        guard let anchor else {
            appState?.logger.log("DICTATION | send not offered: no box was anchored")
            if takeOwnsIsland { overlayController?.showSuccessAndDismiss(title: "Pasted") }
            return
        }
        sendConfirmations.add(PendingSendConfirmation(
            key: key,
            anchor: anchor,
            text: text,
            boxWasReadable: AnchoredTextDelivery.fieldContains(text, anchor: anchor),
            chatThread: chatThread
        ), order: order)
        guard takeOwnsIsland else {
            showNextSendConfirmationWhenIslandIsFree()
            return
        }
        // The island still shows this take's Writing (or its "Pastes when
        // you're back"): it needs a result.
        if !showNextSendConfirmation() {
            overlayController?.showSuccessAndDismiss(title: "Pasted")
        }
    }

    /// Shows the next send waiting, now. A send whose box reads empty (the
    /// user sent or cleared it meanwhile) is passed over. True when a prompt
    /// is up.
    @discardableResult
    func showNextSendConfirmation() -> Bool {
        guard let overlayController else { return false }
        if sendConfirmations.shown != nil { return true }
        while let next = sendConfirmations.next {
            if next.boxWasReadable, AnchoredTextDelivery.anchoredFieldIsEmpty(next.anchor) {
                sendConfirmations.dropNext()
                appState?.logger.log("DICTATION | send not asked: the box in \(next.anchor.appName) is empty now")
                continue
            }
            let confirmKey = DictationAutoSendPreferences.confirmKey()
            let seconds = DictationAutoSendPreferences.confirmSeconds()
            overlayController.showActionNotice(
                DictationAutoSendPolicy.confirmationPrompt(
                    confirmKey: confirmKey,
                    appName: next.anchor.appName,
                    text: next.text,
                    waitingAfter: sendConfirmations.waiting.count - 1
                ),
                actionTitle: "Send",
                action: { [weak self] in self?.confirmPendingSend(fromKey: false) }
            )
            // A press for the next take may start over it; it is asked again after.
            overlayController.messageCanGiveWayToNextStart = DictationQueuedStartPolicy.messageCanGiveWayToNextStart(.sendConfirmation)
            // Marked shown after the notice: showing it discards the message
            // before it, which would count as this one being dismissed.
            sendConfirmations.showNext()
            sendConfirmationArm = DictationSendConfirmationArm(
                key: confirmKey,
                deadline: ProcessInfo.processInfo.systemUptime + TimeInterval(seconds)
            )
            sendConfirmationTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled, let self, self.sendConfirmations.shown?.id == next.id else { return }
                self.sendConfirmations.takeShown()
                self.disarmSendConfirmation()
                self.appState?.logger.log("DICTATION | send confirmation ended: timed_out")
                self.overlayController?.dismissError()
                self.showNextSendConfirmationWhenIslandIsFree()
            }
            appState?.logger.log("DICTATION | send waits for \(confirmKey.rawValue) for \(seconds)s (\(sendConfirmations.count) waiting)")
            return true
        }
        return false
    }

    /// Shows the next send waiting once no take is on the island and nothing
    /// else is up there; looks again every half second until then.
    func showNextSendConfirmationWhenIslandIsFree() {
        guard sendConfirmations.shown == nil, sendConfirmations.next != nil,
              let overlayController else { return }
        if !isDictating, queuedDictationStart == nil, overlayController.state == .idle {
            showNextSendConfirmation()
            return
        }
        guard sendConfirmationRetry == nil else { return }
        sendConfirmationRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.sendConfirmationRetry = nil
            self.showNextSendConfirmationWhenIslandIsFree()
        }
    }

    /// The confirm key (`fromKey`, taken by the event tap) or the island's
    /// Send, for the send the island shows. A key press that couldn't send
    /// goes back to the app in front, as if nothing had been waiting, so it
    /// isn't lost.
    func confirmPendingSend(fromKey: Bool) {
        let confirmKey = sendConfirmationArm?.key ?? DictationAutoSendPreferences.confirmKey()
        // The key counts only while armed: the prompt may have left the
        // island (or its wait run out) as the tap took the press.
        guard !fromKey || sendConfirmationArm != nil,
              let pending = sendConfirmations.takeShown() else {
            if fromKey { Self.press(confirmKey) }
            return
        }
        disarmSendConfirmation()
        appState?.logger.log("DICTATION | send confirmation ended: \(fromKey ? "confirmed_key" : "confirmed_island")")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.pressConfirmedSend(pending)
            self.appState?.logger.log("DICTATION | confirmed send: \(outcome.diagnosticName)")
            if fromKey, outcome != .sent(pending.key) {
                Self.press(confirmKey)
            }
            defer { self.showNextSendConfirmationWhenIslandIsFree() }
            // A dictation started meanwhile owns the island now.
            guard let overlayController = self.overlayController, !self.isDictating,
                  !overlayController.state.isActiveDictationState else { return }
            switch outcome {
            case .sent:
                overlayController.showSuccessAndDismiss(title: outcome.confirmationTitle ?? "Sent")
            case .failed(let failure):
                overlayController.showError(failure.message)
            case .disabled, .awaitingConfirmation:
                // Not returned by a confirmed send; closes the prompt all the same.
                overlayController.showSuccessAndDismiss(title: "Pasted")
            }
        }
    }

    /// The prompt left the island with no answer from the confirm key or
    /// Send. Dismiss or Esc (`dismissed`) drop that send; anything else
    /// taking the island (a take starting, even one then refused, another
    /// message, a hide) puts it back first in line, asked again once the
    /// island is free. The key stops being taken at once either way.
    func sendPromptLeftIsland(dismissed: Bool) {
        guard sendConfirmations.shown != nil else { return }
        disarmSendConfirmation()
        if dismissed {
            sendConfirmations.takeShown()
            appState?.logger.log("DICTATION | send confirmation ended: dismissed")
        } else {
            sendConfirmations.putShownBack()
            appState?.logger.log("DICTATION | send confirmation waits: the island is taken (\(sendConfirmations.count) waiting)")
        }
        showNextSendConfirmationWhenIslandIsFree()
    }

    /// A new take takes the island: the send it shows is asked again after.
    func holdSendConfirmationForNewTake() {
        guard sendConfirmations.shown != nil else { return }
        disarmSendConfirmation()
        sendConfirmations.putShownBack()
        appState?.logger.log("DICTATION | send confirmation waits for the new take (\(sendConfirmations.count) waiting)")
        showNextSendConfirmationWhenIslandIsFree()
    }

    private func disarmSendConfirmation() {
        sendConfirmationArm = nil
        sendConfirmationTimeout?.cancel()
        sendConfirmationTimeout = nil
    }

    private func pressConfirmedSend(_ pending: PendingSendConfirmation) async -> DictationAutoSendOutcome {
        // A confirm chord (⌘ Enter) may still be held; Return is pressed
        // once it's let go, so the app doesn't read it with the chord.
        for _ in 0..<10 where Self.chordModifiersHeld() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let anchor = pending.anchor
        // Fork: never into another thread of the chat the take was dictated
        // into; the anchored window is where the send goes (`+ChatThreadGuard.swift`).
        if await chatChanged(pending.chatThread, in: anchor.pid, window: anchor.window) {
            return .failed(.chatChanged)
        }
        let path = DictationAutoSendPolicy.confirmedSend(
            anchorAppIsFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == anchor.pid,
            anchorIsFocused: anchor.field != nil
                ? AnchoredTextDelivery.anchoredFieldIsFocused(anchor)
                : AnchoredTextDelivery.anchoredWindowIsFocused(anchor),
            isTerminal: anchor.isTerminal,
            terminalWindowIsCurrent: AnchoredTextDelivery.anchoredWindowIsFocused(anchor),
            appName: anchor.appName
        )
        switch path {
        case .frontmost:
            let target = DictationPasteTarget(processIdentifier: anchor.pid, bundleIdentifier: anchor.bundleID)
            let outcome = autoSender.send(pending.key, target: target)
            if case .sent = outcome { followNewChat(pending.chatThread, afterSendIn: anchor.pid) }
            return outcome
        case .background(let route):
            // Sent unseen, so only the take's own words: the box may hold
            // something else by now (another draft, words edited away).
            if pending.boxWasReadable, !AnchoredTextDelivery.fieldContains(pending.text, anchor: anchor) {
                return .failed(.boxChanged(appName: anchor.appName))
            }
            let outcome = await AnchoredTextDelivery.pressSend(pending.key, route: route, anchor: anchor)
            if case .sent = outcome { followNewChat(pending.chatThread, afterSendIn: anchor.pid) }
            return outcome
        case .unavailable(let failure):
            return .failed(failure)
        }
    }

    private static func chordModifiersHeld() -> Bool {
        let held = CGEventSource.flagsState(.combinedSessionState)
        return !held.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty
    }

    /// Gives a taken confirm press back to the app in front.
    private static func press(_ key: DictationSendConfirmKey) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Return), keyDown: false) else { return }
        down.flags = key.eventFlags
        up.flags = key.eventFlags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
