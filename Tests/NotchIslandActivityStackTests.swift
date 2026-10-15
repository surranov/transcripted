// NotchIslandActivityStackTests.swift
// Fork: the dictation queue's pyramid. Newest on top, older takes behind it
// newest first, a recording meeting always deepest; each layer narrower and
// lower; shadows by height above the bottom layer; Esc on the newest take,
// never the meeting.

import CoreGraphics
import Foundation

func testNotchIslandActivityStack() {
    runSuite("A meeting still being transcribed sits under the recording one and keeps its place") {
        let takes = (0..<3).map { _ in NotchIslandBackgroundTake(id: UUID(), stage: .processing) }
        let layers = NotchIslandActivityStack.backLayers(takes: takes, topTakeID: nil, meetingBehind: true, transcribingMeetingBehind: true)
        assertEqual(
            layers.map(\.key),
            [takes[2].id.uuidString, "meeting", NotchIslandActivityStack.transcribingMeetingLayer.key],
            "one take fits; the recording, then the meeting being transcribed at the bottom"
        )
        assertEqual(
            NotchIslandActivityStack.backLayers(takes: [], topTakeID: nil, meetingBehind: false, transcribingMeetingBehind: true),
            [NotchIslandActivityStack.transcribingMeetingLayer]
        )
        let cards = NotchIslandActivityStack.cards(
            dictation: nil, takes: [], meetingRecording: true, earlierMeeting: NotchIslandEarlierMeeting(moreWaiting: 0)
        )
        assertEqual(cards.map(\.kind), [.meeting, .earlierMeeting(NotchIslandEarlierMeeting(moreWaiting: 0))])
        assertNil(NotchIslandActivityStack.escapeTarget(in: cards), "Esc never reaches a meeting")
    }

    runSuite("The layers behind the island: newest take first, the meeting deepest, three at most") {
        let takes = (0..<4).map { NotchIslandBackgroundTake(id: UUID(), stage: $0 == 3 ? .queued : .processing) }
        let layers = NotchIslandActivityStack.backLayers(takes: takes, topTakeID: nil, meetingBehind: true)
        assertEqual(
            layers.map(\.key),
            [takes[3].id.uuidString, takes[2].id.uuidString, "meeting"],
            "two takes, newest first, then the meeting keeps its place at the bottom"
        )
        assertEqual(layers.map(\.glyph), [.queued, .processing, .meeting])

        let noMeeting = NotchIslandActivityStack.backLayers(takes: takes, topTakeID: takes[3].id, meetingBehind: false)
        assertEqual(
            noMeeting.map(\.key),
            [takes[2].id.uuidString, takes[1].id.uuidString, takes[0].id.uuidString],
            "the take shown on the island isn't drawn again behind it"
        )
        assertEqual(
            NotchIslandActivityStack.backLayers(takes: [], topTakeID: nil, meetingBehind: false), [],
            "nothing behind, no layers"
        )
    }

    runSuite("Each layer is a step narrower and peeks a step lower than the one above it") {
        let island = CGRect(x: 100, y: 0, width: 400, height: 32)
        let first = NotchIslandActivityStack.frame(island: island, depth: 1)
        let second = NotchIslandActivityStack.frame(island: island, depth: 2)
        assertEqual(first, CGRect(x: 110, y: 0, width: 380, height: 41), "10 pt in on each side, 9 pt lower")
        assertEqual(second, CGRect(x: 120, y: 0, width: 360, height: 50), "the next one smaller again, by the same step")
        assertEqual(first.midX, island.midX, "centered under the island")
        assertEqual(
            NotchIslandActivityStack.frame(island: CGRect(x: 0, y: 0, width: 70, height: 32), depth: 3).width,
            NotchIslandActivityStack.minimumWidth,
            "never so narrow its glyph can't fit"
        )
    }

    runSuite("Shadows follow height above the bottom layer: none at the bottom, softer higher up") {
        assertNil(NotchIslandActivityStack.shadow(depth: 0, layerCount: 1), "a lone island casts no shadow")
        assertNil(NotchIslandActivityStack.shadow(depth: 1, layerCount: 2), "the bottom layer casts none")
        let sharp = NotchIslandActivityStack.shadow(depth: 0, layerCount: 2)
        assertEqual(sharp?.radius, 0.75, "one step above the bottom: a sharp shadow")

        let shadows = (0..<4).map { NotchIslandActivityStack.shadow(depth: $0, layerCount: 4) }
        assertNil(shadows[3], "four layers: still none at the bottom")
        let radii = shadows.compactMap { $0?.radius }
        assertEqual(radii, [8, 3.5, 0.75], "the island on top the softest, down to a sharp one just above the bottom")
    }

    runSuite("Esc acts on the newest take, never on the meeting") {
        let declined = NotchIslandBackgroundTake(id: UUID(), stage: .processing, declined: true)
        let pasting = NotchIslandBackgroundTake(id: UUID(), stage: .pasting)
        let older = NotchIslandBackgroundTake(id: UUID(), stage: .queued)

        let listening = NotchIslandActivityStack.cards(
            dictation: NotchIslandDictationContent(phase: .listening, targetAppName: "Notes"),
            takes: [older],
            meetingRecording: true
        )
        assertEqual(listening.map(\.isEscapeTarget), [true, false, false], "the take being spoken first")

        let behindOnly = NotchIslandActivityStack.cards(dictation: nil, takes: [older, pasting, declined], meetingRecording: true)
        assertEqual(behindOnly.map(\.kind), [.background(declined), .background(pasting), .background(older), .meeting])
        assertEqual(
            behindOnly.map(\.isEscapeTarget), [false, false, true, false],
            "past a declined take and one already pasting, to the newest still finishing"
        )

        let meetingOnly = NotchIslandActivityStack.cards(dictation: nil, takes: [pasting], meetingRecording: true)
        assertEqual(meetingOnly.map(\.isEscapeTarget), [false, false], "with no take left to stop, Esc has nothing here: the meeting is never its target")

        let landed = NotchIslandActivityStack.cards(
            dictation: NotchIslandDictationContent(phase: .success(title: "Pasted")),
            takes: [],
            meetingRecording: true
        )
        assertEqual(landed.map(\.kind), [.meeting], "a take showing its result is past having a card")
    }

    runSuite("With no take on the island, the newest finishing one is shown on top") {
        let older = NotchIslandBackgroundTake(id: UUID(), stage: .queued)
        let newer = NotchIslandBackgroundTake(id: UUID(), stage: .processing)
        assertEqual(NotchIslandActivityStack.topTake(dictationOnIsland: false, takes: [older, newer]), newer)
        assertNil(NotchIslandActivityStack.topTake(dictationOnIsland: true, takes: [older, newer]), "a take on the island keeps it")
    }
}
