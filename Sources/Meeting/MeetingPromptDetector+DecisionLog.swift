import ApplicationServices
import Foundation

/// The detector's local decision trace (`decisionLog`). Every value is an enum
/// raw value or a candidate id (`mic:ktalk`, `calendar:<event id>` is not
/// logged), so the trace can say why a call did not prompt without carrying
/// anything the user typed or opened.
@available(macOS 14.0, *)
extension MeetingPromptDetector {
    static func decisionContext(_ candidate: Candidate) -> [String: String] {
        [
            "candidate": candidate.source == .calendarEvent ? "calendar" : candidate.id,
            "provider": candidate.provider.rawValue,
            "reason": candidate.reason.rawValue,
            "evidence": candidate.callEvidence.rawValue,
        ]
    }

    /// One line whenever the set of call signals changes (a call app takes
    /// the mic, a muted call is named, the camera goes off...).
    func logCallSignalsIfChanged(_ signals: [(provider: MeetingPromptProvider, reason: MeetingPromptReason)]) {
        // A browser signal carries `.googleMeet` as "some browser" until its
        // titles name it; say browser.
        let summary = signals.isEmpty
            ? "none"
            : signals.map { signal in
                let source = MeetingPromptProvider.browserSignalProvider == signal.provider ? "browser" : signal.provider.rawValue
                return "\(source):\(signal.reason.rawValue)"
            }.sorted().joined(separator: ",")
        // A chat app on the mic without its playback is not a call yet: say
        // so, or "why didn't Telegram prompt?" has no answer.
        let waiting = chatAppsOnMicWithoutPlayback().map { "\($0.rawValue):mic_without_playback" }
        let line = waiting.isEmpty ? summary : summary + "; waiting " + waiting.joined(separator: ",")
        guard line != lastLoggedCallSignals else { return }
        lastLoggedCallSignals = line
        decisionLog?("Call signals changed", ["signals": line])
    }

    /// What one read of the browser window titles concluded, by kind only.
    /// `via` says which signal asked: a browser on the mic, the camera, or a
    /// browser playing audio with nothing on the mic.
    func logBrowserTitleVerdict(_ verdict: BrowserCallTitleVerdict, windows: Int, previous: BrowserCallTitleVerdict?) {
        let kind: String
        switch verdict {
        case .call(let provider): kind = "call:\(provider.rawValue)"
        case .callSite(let provider): kind = "call_site:\(provider?.rawValue ?? "other")"
        case .notCall: kind = "not_call"
        // No titles has two causes the trace must tell apart: no Accessibility
        // (titles never come) or no browser window visible right now.
        case .unknown where windows == 0: kind = AXIsProcessTrusted() ? "no_titles" : "no_accessibility"
        case .unknown: kind = "unknown"
        }
        // Same verdict, different kind (no windows, then unreadable ones) is
        // still news; a repeat of both is not.
        guard verdict != previous || kind != lastLoggedBrowserTitleKind else { return }
        lastLoggedBrowserTitleKind = kind
        let via: String
        if micActiveBundleIDs.contains(where: MeetingPromptProvider.isBrowserBundleID) {
            via = "mic"
        } else if !browserListenFamilies.isEmpty {
            via = "playback"
        } else {
            via = "camera"
        }
        decisionLog?("Browser titles read", ["verdict": kind, "windows": String(windows), "via": via])
    }
}
