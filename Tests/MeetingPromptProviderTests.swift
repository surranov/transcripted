// MeetingPromptProviderTests.swift
// Which call service a signal belongs to: native app processes, meeting-link
// hosts in calendar events.

import Foundation

func testMeetingPromptProvider() {
    guard #available(macOS 14.0, *) else { return }

    runSuite("MeetingPromptProvider — Kontur.Talk and Telemost links in calendar events") {
        let links: [(String, MeetingPromptProvider?)] = [
            ("cian.ktalk.ru", .ktalk),
            ("ktalk.ru", .ktalk),
            ("energo-cis.ktalk.ru", .ktalk),
            ("telemost.yandex.ru", .telemost),
            ("telemost.360.yandex.ru", .telemost),
            ("notktalk.ru", nil),
            ("ktalk.ru.evil.example", nil),
            ("yandex.ru", nil),
        ]
        for (host, provider) in links {
            assertEqual(
                MeetingPromptProvider.provider(forMeetingHost: host),
                provider,
                "\(host) should map to \(provider?.rawValue ?? "no provider")"
            )
        }

        let start = Date(timeIntervalSince1970: 10_000)
        let event = MeetingPromptCalendarEventSnapshot(
            id: "talk-sync",
            title: "Sync",
            startDate: start,
            endDate: start.addingTimeInterval(1_800),
            isAllDay: false,
            url: nil,
            location: nil,
            notes: "Подключиться: https://cian.ktalk.ru/xqgcr0ebnj64"
        )
        assertEqual(event.provider, .ktalk, "a Talk room link in the notes makes the event a Talk meeting")
    }

    runSuite("MeetingPromptProvider — the Talk and Telemost apps and their helpers are native call apps") {
        let apps: [(String, MeetingPromptProvider?)] = [
            ("kontur.talk", .ktalk),
            ("kontur.talk.helper", .ktalk),
            ("kontur.talk.helper.Renderer", .ktalk),
            ("ru.yandex.desktop.telemost", .telemost),
            ("ru.yandex.desktop.telemost.helper", .telemost),
            ("kontur.talkative", nil),
            ("ru.yandex.desktop.disk", nil),
        ]
        for (bundleID, provider) in apps {
            assertEqual(
                MeetingPromptProvider.micInputProvider(forBundleID: bundleID),
                provider,
                "\(bundleID) on the mic"
            )
            assertEqual(
                MeetingPromptProvider.audioOutputProvider(forBundleID: bundleID),
                provider,
                "\(bundleID) playing call audio (a muted join in the app)"
            )
        }
    }

    runSuite("MeetingPromptProvider — an open Talk or Telemost app is not a call by itself") {
        for provider in [MeetingPromptProvider.ktalk, .telemost] {
            assertFalse(
                provider.supportsRuntimeOnlyPrompt,
                "\(provider.displayName) is also a chat app, open all day"
            )
            assertTrue(provider.browserHosted, "\(provider.displayName) also runs in a browser tab")
        }
    }
}
