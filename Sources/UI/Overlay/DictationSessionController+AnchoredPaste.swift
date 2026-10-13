import AppKit

/// Fork: Anchored paste in the dictation session (`AnchoredPastePolicy`).
///
/// `startDictation` captures the focused field (`beginPasteAnchor`) and the
/// marker appears next to its caret. At paste time `deliverToPasteAnchor`
/// picks the route: the regular paste when the user is still there, typing
/// into a terminal or an Accessibility insertion in the background, or a
/// deferred paste that runs once the user is back in that window. The words
/// are saved to Dictations on every route. With Anchored Enter on
/// (`AnchoredPastePreferences.pressesEnter`) every route ends with Enter in
/// that field, or a notice on the island saying it couldn't be pressed.
struct DeferredAnchoredPaste {
    let text: String
    let anchor: DictationPasteAnchor
    let autoSend: DictationAutoSendRequestDecision
    let deadline: Date
    /// Set when a background write went unconfirmed
    /// (`AnchoredInsertion.unconfirmed`): the field's value before it, to
    /// tell on return whether the words arrived after all.
    let unconfirmedValueBefore: String?
}

extension DeferredAnchoredPaste {
    func withoutUnconfirmedWrite() -> DeferredAnchoredPaste {
        DeferredAnchoredPaste(text: text, anchor: anchor, autoSend: autoSend, deadline: deadline, unconfirmedValueBefore: nil)
    }
}

extension DictationSessionController {
    enum AnchoredDeliveryResult {
        /// No anchor, or the user is back where it points: paste as usual.
        case notAnchored
        case delivered(DictationPasteOutcome)
        case deferred(appName: String)
    }

    func beginPasteAnchor(sourceApp: NSRunningApplication?) {
        pasteAnchorTask?.cancel()
        pasteAnchor = nil
        anchoredSend = nil
        guard AnchoredPastePreferences.isEnabled(),
              let app = sourceApp ?? NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            if deferredAnchoredPastes.isEmpty { anchorMarker.hide() }
            return
        }
        let sessionID = currentDictationSessionID
        pasteAnchorTask = Task { @MainActor [weak self] in
            let anchor = await AnchoredTextDelivery.captureAnchor(for: app)
            guard let self, !Task.isCancelled, self.currentDictationSessionID == sessionID, self.isDictating else { return }
            self.pasteAnchor = anchor
            if let anchor {
                self.appState?.logger.log(
                    "DICTATION | anchored to \(anchor.appName): field \(anchor.field != nil), window \(anchor.windowID != nil), terminal \(anchor.isTerminal)"
                )
                self.anchorMarker.show(for: anchor, phase: .listening, levels: self.appState?.sttRouter.audioLevels.readings)
            }
        }
    }

    /// The marker's stop button does what the island's does: stops the take
    /// being spoken, and only while it listens.
    func stopFromAnchorMarker() {
        guard isDictating, overlayController?.state == .listening else { return }
        stopDictationAndPaste(trigger: .overlayButton)
    }

    func markPasteAnchorWorking() {
        if pasteAnchor != nil { anchorMarker.update(.working) }
    }

    /// Called when `isDictating` turns false: a take that ended without an
    /// anchored delivery (cancel, no speech, an error) takes its marker along.
    func pasteAnchorSessionEnded() {
        pasteAnchorTask?.cancel()
        pasteAnchorTask = nil
        pasteAnchor = nil
        anchoredSend = nil
        if deferredAnchoredPastes.isEmpty, anchorMarker.phaseIsInFlight {
            anchorMarker.hide()
        }
    }

    /// Delivers `text` to the anchored field when the user is no longer in
    /// it. `.notAnchored` hands the paste back to the regular path.
    func deliverToPasteAnchor(_ text: String) async -> AnchoredDeliveryResult {
        guard AnchoredPastePreferences.isEnabled() else { return .notAnchored }
        if pasteAnchor == nil, let capture = pasteAnchorTask {
            await capture.value
        }
        guard let anchor = pasteAnchor else { return .notAnchored }
        let route = AnchoredTextDelivery.route(for: anchor, text: text)
        appState?.logger.log("DICTATION | anchored paste route: \(route.rawValue)")
        switch route {
        case .normalPaste:
            return .notAnchored
        case .terminalKeystrokes:
            guard await AnchoredTextDelivery.typeIntoTerminal(text, anchor: anchor) else { return deferOrPasteHere(text, anchor) }
            prepareAnchoredSend(route: route, anchor: anchor, text: text)
            updateAnchorMarker(.done)
            return .delivered(.pasted)
        case .accessibilityInsert:
            switch await AnchoredTextDelivery.insertViaAccessibility(text, anchor: anchor) {
            case .landed:
                prepareAnchoredSend(route: route, anchor: anchor, text: text)
                updateAnchorMarker(.done)
                return .delivered(.pasted)
            case let .unconfirmed(valueBefore):
                appState?.logger.log("DICTATION | anchored field took the words off screen, unconfirmed until the user is back")
                return deferOrPasteHere(text, anchor, unconfirmedValueBefore: valueBefore)
            case .notTaken:
                appState?.logger.log("DICTATION | anchored field didn't take the words")
                return deferOrPasteHere(text, anchor)
            }
        case .deferred:
            return deferOrPasteHere(text, anchor)
        }
    }

    /// Presses send for a background delivery; nil when the take wasn't
    /// delivered in the background (the regular Auto Enter runs then).
    func performAnchoredSendIfNeeded() async -> DictationAutoSendOutcome? {
        guard let send = anchoredSend else { return nil }
        anchoredSend = nil
        guard autoSendRequestDecision.expected else { return .disabled }
        // Let the target take the words in (a React form re-renders) first.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let outcome = await AnchoredTextDelivery.pressSend(autoSendRequestDecision.key, route: send.route, anchor: send.anchor)
        appState?.logger.log("DICTATION | anchored send: \(outcome.diagnosticName)")
        return outcome
    }

    /// After the regular paste ran for an anchored take (the user was still
    /// there): the marker confirms, or goes when nothing landed.
    func finishPasteAnchorAfterRegularPaste(_ outcome: DictationPasteOutcome) {
        guard pasteAnchor != nil || anchorMarker.isShowing else { return }
        switch outcome {
        case .pasted, .likelyPasted:
            updateAnchorMarker(.done)
        case .copied, .failed:
            if DictationTakeScope.handedOff == nil { anchorMarker.hide() }
        }
    }

    func cancelDeferredAnchoredPaste(text: String) {
        deferredAnchoredPastes.removeAll { $0.text == text }
        if deferredAnchoredPastes.isEmpty {
            stopDeferredAnchoredPasteWatch()
            anchorMarker.hide()
        }
    }

    /// Anchored Enter: a take with an anchor expects Enter even in an app not
    /// chosen for Press send after pasting (`anchoredEnterDecision`).
    func withAnchoredEnter(_ decision: DictationAutoSendRequestDecision, text: String) -> DictationAutoSendRequestDecision {
        guard pasteAnchor != nil else { return decision }
        return DictationAutoSendPolicy.anchoredEnterDecision(
            perApp: decision,
            pressesEnter: AnchoredPastePreferences.pressesEnter(),
            text: text,
            duration: CFAbsoluteTimeGetCurrent() - sessionStartTime
        )
    }

    /// Why Anchored Enter can't press Enter where the regular paste went:
    /// the anchored field (or, for an anchor without one, its window) no
    /// longer has focus, so Enter would land elsewhere. Nil when it can.
    func anchoredEnterBlocker() -> DictationAutoSendFailure? {
        guard let anchor = pasteAnchor else { return .anchoredFieldLeft }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == anchor.pid else { return .targetChanged }
        if anchor.field != nil { return AnchoredTextDelivery.anchoredFieldIsFocused(anchor) ? nil : .anchoredFieldLeft }
        if anchor.window != nil { return AnchoredTextDelivery.anchoredWindowIsFocused(anchor) ? nil : .anchoredFieldLeft }
        return nil
    }

    /// Whether the anchored field holds `text`: the proof Anchored Enter
    /// takes for a likely paste (Electron apps report nothing better).
    func pasteAnchorHolds(_ text: String) -> Bool {
        guard let anchor = pasteAnchor else { return false }
        return AnchoredTextDelivery.fieldContains(text, anchor: anchor)
    }

    /// The marker belongs to the take on the island: a handed-off take
    /// leaves it alone.
    private func updateAnchorMarker(_ phase: AnchorMarkerController.Phase) {
        guard DictationTakeScope.handedOff == nil else { return }
        anchorMarker.update(phase)
    }

    // MARK: - Private

    private func prepareAnchoredSend(route: AnchoredPasteRoute, anchor: DictationPasteAnchor, text: String) {
        autoSendRequestDecision = autoSendDecision(for: text, bundleID: anchor.bundleID)
        anchoredSend = (route, anchor)
    }

    private func autoSendDecision(for text: String, bundleID: String?) -> DictationAutoSendRequestDecision {
        withAnchoredEnter(DictationAutoSendPolicy.requestDecision(
            isEnabled: DictationAutoSendPreferences.isEnabled(),
            key: DictationAutoSendPreferences.sendKey(),
            text: text,
            duration: CFAbsoluteTimeGetCurrent() - sessionStartTime,
            sourceBundleID: bundleID,
            allowedBundleIDs: DictationAutoSendPreferences.allowedBundleIDs()
        ), text: text)
    }

    /// In the anchored app, the regular paste follows the user; elsewhere the
    /// words wait for them to come back.
    private func deferOrPasteHere(
        _ text: String,
        _ anchor: DictationPasteAnchor,
        unconfirmedValueBefore: String? = nil
    ) -> AnchoredDeliveryResult {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == anchor.pid { return .notAnchored }
        deferredAnchoredPastes.append(DeferredAnchoredPaste(
            text: text,
            anchor: anchor,
            autoSend: autoSendDecision(for: text, bundleID: anchor.bundleID),
            deadline: Date().addingTimeInterval(AnchoredPastePolicy.deferredPasteLifetime),
            unconfirmedValueBefore: unconfirmedValueBefore
        ))
        updateAnchorMarker(.waiting)
        startDeferredAnchoredPasteWatch()
        appState?.logger.log("DICTATION | anchored paste waits for \(anchor.appName)")
        return .deferred(appName: anchor.appName)
    }

    private func startDeferredAnchoredPasteWatch() {
        guard deferredAnchoredPasteTimer == nil else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDeferredAnchoredPastes() }
        }
        RunLoop.main.add(timer, forMode: .common)
        deferredAnchoredPasteTimer = timer
    }

    private func stopDeferredAnchoredPasteWatch() {
        deferredAnchoredPasteTimer?.invalidate()
        deferredAnchoredPasteTimer = nil
    }

    private func checkDeferredAnchoredPastes() {
        let now = Date()
        let expired = deferredAnchoredPastes.filter { $0.deadline <= now }
        if !expired.isEmpty {
            deferredAnchoredPastes.removeAll { $0.deadline <= now }
            appState?.logger.log("DICTATION | \(expired.count) anchored paste(s) expired; the words are in Dictations")
        }
        // The clipboard is borrowed for the paste: never during another take.
        // Any pending paste whose window the user is back in, oldest first: one
        // left behind in a window they never return to doesn't hold up the rest.
        guard !isDictating, !deferredAnchoredPasteSettling,
              let index = deferredAnchoredPastes.firstIndex(where: { AnchoredTextDelivery.userIsBack(at: $0.anchor) }) else {
            if deferredAnchoredPastes.isEmpty {
                stopDeferredAnchoredPasteWatch()
                if !expired.isEmpty { anchorMarker.hide() }
            }
            return
        }
        let next = deferredAnchoredPastes.remove(at: index)
        if deferredAnchoredPastes.isEmpty { stopDeferredAnchoredPasteWatch() }
        guard let valueBefore = next.unconfirmedValueBefore else {
            deliverDeferredAnchoredPaste(next)
            return
        }
        deferredAnchoredPasteSettling = true
        Task { @MainActor [weak self] in
            let landed = await Self.waitForUnconfirmedWrite(next, valueBefore: valueBefore)
            guard let self else { return }
            self.deferredAnchoredPasteSettling = false
            if landed {
                self.finishLandedUnconfirmedWrite(next)
            } else if !self.isDictating {
                self.deliverDeferredAnchoredPaste(next)
            } else {
                // A new take started meanwhile: keep the words for later.
                self.deferredAnchoredPastes.insert(next.withoutUnconfirmedWrite(), at: 0)
                self.startDeferredAnchoredPasteWatch()
            }
        }
    }

    /// Polls the field while the window, back on screen, catches up.
    private static func waitForUnconfirmedWrite(_ pending: DeferredAnchoredPaste, valueBefore: String) async -> Bool {
        let started = Date()
        while Date().timeIntervalSince(started) < AnchoredPastePolicy.unconfirmedWriteSettleTime {
            if AnchoredTextDelivery.insertionLanded(pending.text, since: valueBefore, anchor: pending.anchor) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return AnchoredTextDelivery.insertionLanded(pending.text, since: valueBefore, anchor: pending.anchor)
    }

    /// The unconfirmed write turned out to have landed: nothing is pasted
    /// again; send is pressed if the take asked for it.
    private func finishLandedUnconfirmedWrite(_ pending: DeferredAnchoredPaste) {
        appState?.logger.log("DICTATION | unconfirmed anchored write arrived; not pasting again")
        anchorMarker.update(.done)
        guard pending.autoSend.expected else {
            overlayController?.showSuccessAndDismiss(title: "Pasted")
            return
        }
        Task { @MainActor [weak self] in
            var outcome = await AnchoredTextDelivery.pressSend(pending.autoSend.key, route: .accessibilityInsert, anchor: pending.anchor)
            // No send button: Return, only into the anchored field itself.
            if case .failed = outcome, AnchoredTextDelivery.anchoredFieldIsFocused(pending.anchor) {
                let target = DictationPasteTarget(processIdentifier: pending.anchor.pid, bundleIdentifier: pending.anchor.bundleID)
                outcome = self?.autoSender.send(pending.autoSend.key, target: target) ?? outcome
            }
            self?.appState?.logger.log("DICTATION | deferred anchored send: \(outcome.diagnosticName)")
            self?.showDeferredSendResult(pasteOutcome: .pasted, sendOutcome: outcome)
        }
    }

    /// The island's word on a deferred paste, as for any take
    /// (`DictationDeliveryPresentation`): "Pasted + Enter", or why send wasn't
    /// pressed.
    private func showDeferredSendResult(
        pasteOutcome: DictationPasteOutcome,
        sendOutcome: DictationAutoSendOutcome,
        expected: Bool = true
    ) {
        guard let overlayController else { return }
        switch DictationDeliveryPresentation.resolve(
            outcome: pasteOutcome, saveFailureMessage: nil, autoSend: sendOutcome, autoSendExpected: expected
        ) {
        case .success(let title):
            overlayController.showSuccessAndDismiss(title: title)
        case .clipboardNotice(let message):
            overlayController.showClipboardNotice(message)
        case .error(let message), .notPasted(let message, _), .clipboardBusy(let message):
            overlayController.showError(message)
        }
    }

    private func deliverDeferredAnchoredPaste(_ pending: DeferredAnchoredPaste) {
        let target = DictationPasteTarget(processIdentifier: pending.anchor.pid, bundleIdentifier: pending.anchor.bundleID)
        let outcome = textPaster.paste(pending.text, target: target)
        appState?.logger.log("DICTATION | deferred anchored paste: \(outcome.diagnosticName)")
        switch outcome {
        case .pasted, .likelyPasted:
            anchorMarker.update(.done)
            // Auto Enter needs proof the words landed: a confirmed paste, or
            // the anchored field now holding them (Electron apps only ever
            // report a likely paste).
            guard pending.autoSend.expected,
                  outcome == .pasted || AnchoredTextDelivery.fieldContains(pending.text, anchor: pending.anchor) else {
                showDeferredSendResult(pasteOutcome: outcome, sendOutcome: .disabled, expected: pending.autoSend.expected)
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: TranscriptedConstants.dictationAutoEnterDelay)
                guard let self else { return }
                // Anchored Enter goes only into the anchored field: the user
                // may be back in its window but in another box.
                let sent: DictationAutoSendOutcome
                if pending.autoSend.requiresAnchoredField, pending.anchor.field != nil,
                   !AnchoredTextDelivery.anchoredFieldIsFocused(pending.anchor) {
                    sent = .failed(.anchoredFieldLeft)
                } else {
                    sent = self.autoSender.send(pending.autoSend.key, target: target)
                }
                self.appState?.logger.log("DICTATION | deferred anchored send: \(sent.diagnosticName)")
                self.showDeferredSendResult(pasteOutcome: outcome, sendOutcome: sent)
            }
        case .copied, .failed:
            anchorMarker.hide()
            if let overlayController {
                showNotPasted(
                    pending.text,
                    message: "Couldn't paste in \(pending.anchor.appName). Your words are on the clipboard.",
                    overlayController: overlayController
                )
            }
        }
    }
}
