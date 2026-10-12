// MeetingPromptProvider.swift
// The call services the meeting prompt knows, and everything that ties a
// signal to one: native app bundle IDs, meeting-link hosts, browser
// families. Browser tab titles are matched in `BrowserCallEvidence`.

import Foundation

enum MeetingPromptProvider: String, CaseIterable, Hashable {
    case zoom
    case googleMeet
    case teams
    case webex
    case facetime
    /// Kontur.Talk (ktalk.ru): web rooms and the "Толк" desktop app.
    case ktalk
    /// Yandex Telemost: web calls and the desktop app.
    case telemost

    var browserHosted: Bool {
        switch self {
        case .googleMeet, .teams, .webex, .ktalk, .telemost:
            return true
        case .zoom, .facetime:
            return false
        }
    }

    var activeBundleIdentifiers: Set<String> {
        switch self {
        case .zoom:
            return ["us.zoom.xos"]
        case .googleMeet:
            return []
        case .teams:
            return ["com.microsoft.teams", "com.microsoft.teams2"]
        case .webex:
            return ["com.cisco.webexmeetingsapp", "com.webex.meetingmanager"]
        case .facetime:
            return ["com.apple.FaceTime"]
        case .ktalk:
            // Electron: the call's audio runs in `kontur.talk.helper*`,
            // matched as a family.
            return ["kontur.talk"]
        case .telemost:
            return ["ru.yandex.desktop.telemost"]
        }
    }

    var supportsNativeRuntimePrompt: Bool {
        !activeBundleIdentifiers.isEmpty
    }

    var supportsRuntimeOnlyPrompt: Bool {
        switch self {
        // Open all day between calls (Telemost and Talk are also chat apps),
        // so being open says nothing about a call.
        case .zoom, .teams, .googleMeet, .ktalk, .telemost:
            return false
        case .webex, .facetime:
            return supportsNativeRuntimePrompt
        }
    }

    var displayName: String {
        switch self {
        case .zoom:
            return "Zoom"
        case .googleMeet:
            return "Google Meet"
        case .teams:
            return "Teams"
        case .webex:
            return "Webex"
        case .facetime:
            return "FaceTime"
        case .ktalk:
            return "Kontur.Talk"
        case .telemost:
            return "Telemost"
        }
    }

    static func provider(forMeetingHost host: String) -> MeetingPromptProvider? {
        let normalizedHost = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()

        if hostMatches(normalizedHost, domain: "zoom.us") {
            return .zoom
        }
        if normalizedHost == "meet.google.com" {
            return .googleMeet
        }
        if hostMatches(normalizedHost, domain: "teams.microsoft.com") {
            return .teams
        }
        if hostMatches(normalizedHost, domain: "webex.com") {
            return .webex
        }
        if hostMatches(normalizedHost, domain: "facetime.apple.com") {
            return .facetime
        }
        // Rooms live on the organization's own subdomain
        // (`cian.ktalk.ru/<room>`).
        if hostMatches(normalizedHost, domain: "ktalk.ru") {
            return .ktalk
        }
        if hostMatches(normalizedHost, domain: "telemost.yandex.ru")
            || hostMatches(normalizedHost, domain: "telemost.360.yandex.ru")
            || hostMatches(normalizedHost, domain: "telemost.yandex.com") {
            return .telemost
        }

        return nil
    }

    private static func hostMatches(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }

    // MARK: - Mic-activity attribution (ad-hoc call detection)

    /// Bundle-ID prefixes for browser families that can host a web call.
    ///
    /// Matching is by *family prefix*, not exact bundle ID, because browsers
    /// spread audio across helper/service processes. This was confirmed against a
    /// live Google Meet call: the only process holding the mic input was
    /// `com.google.Chrome.helper` (Chrome's Audio Service), not the main
    /// `com.google.Chrome`. Safari/WKWebView audio likewise runs in
    /// `com.apple.WebKit.GPU`, which is not prefixed by `com.apple.Safari`.
    static let browserBundleIDPrefixes: [String] = [
        "com.google.Chrome",          // Chrome, Chrome.canary, and *.helper children
        "com.microsoft.edgemac",      // Edge + helpers
        "com.brave.Browser",          // Brave + helpers
        "company.thebrowser.Browser", // Arc + helpers
        "org.mozilla.firefox",        // Firefox + plugin-container children
        "com.apple.Safari",           // Safari main process
        "com.apple.WebKit",           // Safari / WKWebView service processes (GPU, Networking, WebContent)
    ]

    /// The provider a browser signal carries before its titles name the call
    /// (`micInputProvider` maps every browser to it).
    static let browserSignalProvider: MeetingPromptProvider = .googleMeet

    /// Whether `bundleID` belongs to a known browser family (main app or any of
    /// its helper/service processes). Prefix-aware: a prefix matches the exact id
    /// or any dotted child (`com.google.Chrome` matches `com.google.Chrome.helper`).
    static func isBrowserBundleID(_ bundleID: String) -> Bool {
        browserBundleIDPrefixes.contains { bundleID.matchesBundleFamily($0) }
    }

    /// The browser family prefix `bundleID` belongs to (`com.google.Chrome`
    /// for `com.google.Chrome.helper`), or `nil` when it is not a browser.
    /// Used to line a browser's mic process up with its audio-output process
    /// and with the app whose windows name the call.
    static func browserFamily(forBundleID bundleID: String) -> String? {
        browserBundleIDPrefixes.first { bundleID.matchesBundleFamily($0) }
    }

    /// The family of the app whose windows show the tab for a browser family.
    /// Safari's audio runs in `com.apple.WebKit.GPU`, which is not prefixed by
    /// `com.apple.Safari`, so WebKit maps to Safari. Every other family is its
    /// own app.
    static func browserAppFamily(forBundleFamily family: String) -> String {
        family == "com.apple.WebKit" ? "com.apple.Safari" : family
    }

    /// Maps a process bundle ID that is *currently holding the mic input* to a
    /// meeting provider, or `nil` if it is not a recognized call source.
    ///
    /// - Native conferencing apps (Zoom, Teams, Webex, FaceTime) map to their own
    ///   provider, matched by family prefix so a helper process still attributes
    ///   to the parent app.
    /// - Any browser-family process maps to `.googleMeet` — the representative
    ///   "browser call" (Meet / Zoom-web / Teams-web). This is the branch that
    ///   closes the spontaneous-Google-Meet gap.
    /// - Everything else (QuickTime, Voice Memos, Photo Booth, …) returns `nil`,
    ///   so it never produces a prompt.
    ///
    /// Because `.googleMeet` carries no `activeBundleIdentifiers`, it is never a
    /// native match — so a `.googleMeet` result unambiguously means "browser call".
    static func micInputProvider(forBundleID bundleID: String) -> MeetingPromptProvider? {
        if let native = allCases.first(where: { provider in
            provider.activeBundleIdentifiers.contains { bundleID.matchesBundleFamily($0) }
        }) {
            return native
        }
        if isBrowserBundleID(bundleID) {
            return .googleMeet
        }
        return nil
    }

    /// Maps a process bundle ID that is *currently playing audio output* to a
    /// meeting provider, or `nil` if it is not a recognized call source.
    ///
    /// Deliberately narrower than the mic-input mapping: only native conferencing
    /// app families count. Browsers are excluded because browser output is
    /// dominated by non-call playback (YouTube, music, videos), while a native
    /// conferencing app emitting sustained output is almost always a live call.
    /// This is the signal that catches the listen-only or hard-muted join the mic
    /// and camera both miss: remote participants are talking, so the app plays
    /// output, but nothing on this Mac holds the mic.
    static func audioOutputProvider(forBundleID bundleID: String) -> MeetingPromptProvider? {
        allCases.first { provider in
            provider.activeBundleIdentifiers.contains { bundleID.matchesBundleFamily($0) }
        }
    }

    /// Attributes a "camera is on, nothing is holding the mic" signal to a meeting
    /// provider using only the *frontmost* app, or `nil` if the frontmost app is
    /// not a known call surface.
    ///
    /// The camera boolean carries no process attribution (CoreMediaIO exposes no
    /// per-process camera API), so this is the conservative sanity gate that
    /// distinguishes a camera-on call from a Photo Booth selfie: we attribute a
    /// camera-only signal only when the user is actually looking at a browser or a
    /// native conferencing app. A frontmost browser → `.googleMeet` (the generic
    /// browser call); a frontmost native conferencing app → that provider; a
    /// frontmost Photo Booth / QuickTime / anything else → `nil` (no prompt).
    static func cameraCallProvider(forFrontmostBundleID frontmostBundleID: String?) -> MeetingPromptProvider? {
        guard let frontmostBundleID else { return nil }
        if let native = allCases.first(where: { provider in
            provider.activeBundleIdentifiers.contains { frontmostBundleID.matchesBundleFamily($0) }
        }) {
            return native
        }
        if isBrowserBundleID(frontmostBundleID) {
            return .googleMeet
        }
        return nil
    }
}

extension String {
    /// True when the receiver is `family` exactly or a dotted child of it
    /// (`com.google.Chrome.helper`.matchesBundleFamily(`com.google.Chrome`)).
    /// Guards against false matches like `com.google.ChromeEvil`.
    func matchesBundleFamily(_ family: String) -> Bool {
        self == family || hasPrefix(family + ".")
    }
}
