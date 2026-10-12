import AppKit
import Foundation

@available(macOS 14.0, *)
extension MeetingPromptDetector {
    // Members here that drop `private` do so only because another
    // MeetingPromptDetector file uses them; treat them as private to the type.

    // MARK: - Browser call evidence

    /// What the window titles said during one browser session (a browser mic
    /// session, or a camera-only browser call).
    struct BrowserTitleSession {
        var families: Set<String>
        let startedAt: Date
        /// The latest read's verdict; `nil` until the first read lands.
        var latest: BrowserCallTitleVerdict?
        var readAt: Date?
        /// The latest read returned any titles. False without Accessibility,
        /// when a real call and ChatGPT voice look the same.
        var titlesReadable = false
        /// A call-only title was seen. Sticky: switching away from the Meet
        /// tab mid-call must not demote it.
        var namedCall: MeetingPromptProvider?
        /// When a read last saw that title. A call joined muted has no mic to
        /// end it, so it only counts while this is recent.
        var namedCallSeenAt: Date?
        /// A known non-call site was focused. Sticky too, so ChatGPT voice
        /// does not prompt when the user clicks to another tab; only a
        /// call-only title can still win.
        var sawNonCallSite = false
        var readTask: Task<Void, Never>?
        var readToken = 0
        /// Browser kinds the user said Not now to in this session.
        var declinedKinds: [String: Date] = [:]

        var verdict: BrowserCallTitleVerdict? {
            if let namedCall { return .call(provider: namedCall) }
            if sawNonCallSite { return .notCall }
            return latest
        }
    }

    /// Turns one ad-hoc signal into a candidate. Native apps pass straight
    /// through. A browser has to show it is in a call first (see
    /// `BrowserCallEvidence`); until then this returns `nil`, schedules a
    /// re-check, and reports why the prompt is held back.
    func adHocCandidate(
        for signal: (provider: MeetingPromptProvider, reason: MeetingPromptReason),
        frontmostBundleID: String?,
        now: Date
    ) -> ScoredCandidate? {
        // `.googleMeet` from the signal mapping always means "some browser";
        // native apps never map to it.
        guard signal.provider == .googleMeet else {
            return micInputCandidate(for: signal.provider, reason: signal.reason, evidence: .nativeApp, now: now)
        }

        let families = browserFamiliesForEvidence(reason: signal.reason, frontmostBundleID: frontmostBundleID)
        let since = browserEvidenceStart(reason: signal.reason, families: families, now: now)
        let playingAudio = browserIsPlayingAudio(families: families)

        guard let verdict = currentBrowserTitleVerdict(families: families, now: now) else {
            // The first title read of this session is still running (well
            // under a second); it re-evaluates when it lands. Too brief to be
            // worth a suppression event.
            browserFirstTitleReadPending = true
            return nil
        }

        switch verdict {
        case .call(let provider):
            detectedCallSession?.sawBrowserCallTitle = true
            detectedCallSession?.namedBrowserProvider = provider
            if signal.reason == .micInput {
                // Holding the mic is the call going on; the mic path stops
                // reading once named, so keep it current for a mute that
                // hands it to the listen path.
                browserTitles?.namedCallSeenAt = now
            }
        case .notCall:
            detectedCallSession?.sawBrowserNonCallSite = true
        case .callSite, .unknown:
            break
        }

        let decision = BrowserCallEvidence.decide(
            verdict: verdict,
            cameraInUse: cameraInUse,
            browserPlayingAudio: playingAudio,
            micSince: since,
            now: now,
            timing: browserEvidenceTiming
        )

        switch decision {
        case .prompt(let provider, let evidence):
            return micInputCandidate(
                for: provider ?? .googleMeet,
                reason: signal.reason,
                evidence: evidence,
                now: now
            )
        case .wait(let recheckAt):
            // Keep looking: the user may switch to the Meet tab, or the wait
            // may run out.
            scheduleBrowserEvidenceRecheck(at: recheckAt, now: now)
            recordSuppression(
                candidate: micInputCandidate(
                    for: .googleMeet,
                    reason: signal.reason,
                    evidence: pendingBrowserEvidence(verdict: verdict, playingAudio: playingAudio),
                    now: now
                ).candidate,
                reason: .awaitingCallEvidence,
                now: now
            )
            return nil
        case .notACall:
            // Only a call-only title can still change this, so look again
            // now and then rather than on the fast cadence.
            scheduleBrowserEvidenceRecheck(
                at: now.addingTimeInterval(browserEvidenceTiming.nonCallSiteRecheckInterval),
                now: now
            )
            recordSuppression(
                candidate: micInputCandidate(for: .googleMeet, reason: signal.reason, evidence: .nonCallSite, now: now).candidate,
                reason: .notACall,
                now: now
            )
            return nil
        }
    }

    /// The evidence a held-back browser prompt would carry, for telemetry.
    private func pendingBrowserEvidence(
        verdict: BrowserCallTitleVerdict,
        playingAudio: Bool
    ) -> MeetingPromptCallEvidence {
        if case .callSite = verdict { return .callSite }
        if playingAudio { return .micAndOutput }
        if cameraInUse { return .camera }
        return .micOnly
    }

    /// Browser families whose windows can name the call: the ones holding the
    /// mic, or for a camera-only signal the frontmost browser.
    /// Keyed by the app whose windows show the tab, so Safari's mic
    /// (`com.apple.WebKit`) and Safari in front (`com.apple.Safari`) are the
    /// same browser.
    private func browserFamiliesForEvidence(reason: MeetingPromptReason, frontmostBundleID: String?) -> Set<String> {
        if reason == .cameraInput {
            return Self.browserAppFamilies(for: [frontmostBundleID].compactMap { $0 })
        }
        if reason == .audioOutput {
            return browserListenFamilies
        }
        return Self.browserAppFamilies(for: micActiveBundleIDs)
    }

    private static func browserAppFamilies<S: Sequence>(for bundleIDs: S) -> Set<String> where S.Element == String {
        Set(bundleIDs
            .compactMap(MeetingPromptProvider.browserFamily(forBundleID:))
            .map(MeetingPromptProvider.browserAppFamily(forBundleFamily:)))
    }

    /// When the wait for this browser signal started. For the mic, when a
    /// browser first held it. For the camera, the later of the camera coming
    /// on and this browser being the one in front, so a camera already on
    /// for another app does not let a browser skip the wait.
    private func browserEvidenceStart(reason: MeetingPromptReason, families: Set<String>, now: Date) -> Date {
        guard reason == .cameraInput else {
            return browserMicSince ?? now
        }
        if cameraEvidenceSince == nil || cameraEvidenceFamilies != families {
            cameraEvidenceFamilies = families
            cameraEvidenceSince = now
        }
        return max(cameraOnSince ?? now, cameraEvidenceSince ?? now)
    }

    private func browserIsPlayingAudio(families: Set<String>) -> Bool {
        !families.isDisjoint(with: Self.browserAppFamilies(for: browserOutputActiveBundleIDs))
    }

    /// What the window titles say for this browser session, with the sticky
    /// rules applied, or `nil` while the session's first read is running.
    /// Starts a background read when the last one is old enough; its result
    /// re-evaluates.
    private func currentBrowserTitleVerdict(families: Set<String>, now: Date) -> BrowserCallTitleVerdict? {
        guard !families.isEmpty else { return .unknown }
        if var session = browserTitles, !session.families.isDisjoint(with: families) {
            // Same browser (another one may have joined or left): keep what
            // its titles already said.
            session.families = families
            browserTitles = session
        } else {
            // A different browser: its own titles, its own verdict.
            browserTitles?.readTask?.cancel()
            browserTitles = BrowserTitleSession(families: families, startedAt: now)
        }
        guard let session = browserTitles else { return nil }
        let readIsStale = session.readAt.map { now.timeIntervalSince($0) >= browserEvidenceTiming.titleReadSpacing } ?? true
        if session.namedCall == nil, session.readTask == nil, readIsStale {
            startBrowserTitleRead(families: families)
        }
        return session.verdict
    }

    private func startBrowserTitleRead(families: Set<String>) {
        browserTitleReadCounter += 1
        let token = browserTitleReadCounter
        let provider = browserWindowTitlesProvider
        browserTitles?.readToken = token
        evaluationsInFlight += 1
        browserTitles?.readTask = Task { @MainActor [weak self] in
            let titles = await provider(families)
            guard let self else { return }
            defer { self.finishEvaluation() }
            guard !Task.isCancelled, self.browserTitles?.readToken == token else { return }
            self.applyBrowserTitles(titles, now: Date())
            await self.evaluate()
        }
    }

    private func applyBrowserTitles(_ titles: [BrowserWindowTitle], now: Date) {
        guard var session = browserTitles else { return }
        let verdict = BrowserCallEvidence.classify(titles)
        logBrowserTitleVerdict(verdict, windows: titles.count, previous: session.latest)
        session.readTask = nil
        session.readAt = now
        session.latest = verdict
        session.titlesReadable = !titles.isEmpty
        switch verdict {
        case .call(let provider):
            session.namedCall = provider
            session.namedCallSeenAt = now
        case .notCall:
            // Only for the mic or camera use it explains, counted from when
            // that began: a session a playing video opened earlier must not
            // let ChatGPT in front then silence a call that starts later.
            let anchor = max(session.startedAt, browserMicSince ?? session.startedAt)
            if browserMicSince != nil || cameraInUse,
               now.timeIntervalSince(anchor) <= browserEvidenceTiming.nonCallSiteStickyWindow {
                session.sawNonCallSite = true
            }
        case .callSite, .unknown:
            break
        }
        browserTitles = session
    }

    private func scheduleBrowserEvidenceRecheck(at date: Date, now: Date) {
        if let pending = browserEvidenceRecheckAt, pending > now, pending <= date {
            return
        }
        browserEvidenceRecheckTask?.cancel()
        browserEvidenceRecheckAt = date
        let delay = max(0.05, date.timeIntervalSince(now))
        browserEvidenceRecheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.browserEvidenceRecheckAt = nil
            self.browserEvidenceRecheckTask = nil
            self.evaluationsInFlight += 1
            await self.evaluate()
            self.finishEvaluation()
        }
    }

    func cancelBrowserEvidenceRecheck() {
        browserEvidenceRecheckTask?.cancel()
        browserEvidenceRecheckTask = nil
        browserEvidenceRecheckAt = nil
    }

    /// No browser holds the mic (or a muted call's audio stopped). Keep the
    /// session for `micReleaseGrace` in case it comes straight back (Safari
    /// lets go of the mic while muted).
    func scheduleBrowserMicSessionEnd() {
        let grace = browserEvidenceTiming.micReleaseGrace
        guard grace > 0 else {
            endBrowserMicSession()
            return
        }
        browserMicEndTask?.cancel()
        browserMicEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.browserMicEndTask = nil
            guard !self.micActiveBundleIDs.contains(where: MeetingPromptProvider.isBrowserBundleID) else { return }
            self.endBrowserMicSession()
        }
    }

    /// The browser mic session is over: the next browser mic use starts its
    /// own wait. The title verdict goes too, unless a browser is still
    /// playing audio: a call the user muted (Safari lets go of the mic) or
    /// joined muted is still on, and its title already said so.
    func endBrowserMicSession() {
        browserMicSince = nil
        browserMicEndTask?.cancel()
        browserMicEndTask = nil
        cancelBrowserEvidenceRecheck()
        guard browserOutputActiveBundleIDs.isEmpty else { return }
        browserTitles?.readTask?.cancel()
        browserTitles = nil
    }

    /// A browser mic session starts while the title session lives on from
    /// playback (`endBrowserMicSession` keeps it while audio plays). What it
    /// stuck to was about earlier use (a call that has ended into a video, a
    /// non-call site in front back then), so this mic use gets a fresh read,
    /// as a new session would. Unmuting a muted call still names it at once:
    /// its room title is in the window the user unmutes in. Not nows given
    /// in this session stay.
    func startBrowserMicSessionTitles(now: Date) {
        guard var session = browserTitles else { return }
        session.readTask?.cancel()
        session.readTask = nil
        session.sawNonCallSite = false
        session.namedCall = nil
        session.namedCallSeenAt = nil
        session.latest = nil
        session.readAt = nil
        browserTitles = session
    }

    // MARK: - A call joined muted

    /// Browsers playing audio while no browser holds the mic: a call joined
    /// muted, or just a video. Only their titles can tell which.
    var browserListenFamilies: Set<String> {
        guard !micActiveBundleIDs.contains(where: MeetingPromptProvider.isBrowserBundleID) else { return [] }
        return Self.browserAppFamilies(for: browserOutputActiveBundleIDs)
    }

    /// The provider whose call-only title a playing browser showed within
    /// `listenNamedCallGrace`, or nil. That is the whole signal for a call
    /// joined muted: no mic, so the title has to keep showing up, and a tab
    /// switch longer than the grace (or the call ending into a video) lets
    /// it go.
    func browserListenNamedCall(now: Date) -> MeetingPromptProvider? {
        let families = browserListenFamilies
        guard !families.isEmpty,
              let session = browserTitles,
              !session.families.isDisjoint(with: families),
              let named = session.namedCall,
              let seenAt = session.namedCallSeenAt,
              now.timeIntervalSince(seenAt) <= browserEvidenceTiming.listenNamedCallGrace else { return nil }
        return named
    }

    /// Each evaluate pass: while a browser plays audio with nothing on the
    /// mic, read its window titles every `listenRecheckInterval`, named call
    /// or not, so a call joined muted is noticed and its end is too. Reads
    /// never log or keep the titles, and nothing here records a suppression:
    /// a video playing is not a held-back prompt.
    func refreshBrowserListenTitles(now: Date) {
        let families = browserListenFamilies
        guard !families.isEmpty else {
            cancelBrowserListenRecheck()
            return
        }
        if var session = browserTitles, !session.families.isDisjoint(with: families) {
            session.families.formUnion(families)
            browserTitles = session
        } else if browserTitles != nil, cameraInUse {
            // The camera path is reading another browser (camera on, that
            // one in front). Taking its session would make the two paths
            // swap it back and forth, rereading titles without end.
            cancelBrowserListenRecheck()
            return
        } else {
            browserTitles?.readTask?.cancel()
            browserTitles = BrowserTitleSession(families: families, startedAt: now)
        }
        guard let session = browserTitles else { return }
        let interval = browserEvidenceTiming.listenRecheckInterval
        // A tenth of slack: the last read landed a little after the pass that
        // scheduled this one, and must not push every read a whole period.
        let readIsDue = session.readAt.map { now.timeIntervalSince($0) >= interval * 0.9 } ?? true
        if session.readTask == nil, readIsDue {
            startBrowserTitleRead(families: families)
        }
        scheduleBrowserListenRecheck(at: now.addingTimeInterval(interval), now: now)
    }

    private func scheduleBrowserListenRecheck(at date: Date, now: Date) {
        if let pending = browserListenRecheckAt, pending > now, pending <= date {
            return
        }
        browserListenRecheckTask?.cancel()
        browserListenRecheckAt = date
        let delay = max(0.05, date.timeIntervalSince(now))
        browserListenRecheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.browserListenRecheckAt = nil
            self.browserListenRecheckTask = nil
            self.evaluationsInFlight += 1
            await self.evaluate()
            self.finishEvaluation()
        }
    }

    func cancelBrowserListenRecheck() {
        browserListenRecheckTask?.cancel()
        browserListenRecheckTask = nil
        browserListenRecheckAt = nil
    }

    /// Providers a browser tab can be named after (see
    /// `BrowserCallEvidence.inCallProvider`).
    private static let browserNamedProviders: [MeetingPromptProvider] = [.googleMeet, .teams, .zoom, .ktalk, .telemost]

    func browserCandidateIDs(besides id: String) -> [String] {
        (Self.browserNamedProviders.map { micCandidateID(for: $0) }
            + [Self.unverifiedBrowserCandidateID, Self.browserCallSiteCandidateID])
            .filter { $0 != id }
    }
}
