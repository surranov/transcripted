// NotchIslandActivityStack.swift
// Fork: the dictation queue's pyramid. The island shows the newest thing
// going on; everything older sits behind it as layers that peek out below,
// each a step narrower and a shade lighter, newest first, a recording meeting
// always deepest. A back layer shows only a small animation, never text. The
// hover lists every one of them as a card with its own buttons. Foundation
// and CoreGraphics only, so the fast tests cover it.

import CoreGraphics
import Foundation

/// A take finishing behind the one on the island (handed off, see
/// `DictationSessionController+HandOff.swift`).
struct NotchIslandBackgroundTake: Equatable {
    enum Stage: Equatable {
        /// Waiting for the voice model, being transcribed, or refined.
        case processing
        /// Done; waits for an earlier take to paste first.
        case queued
        /// Its words are going in right now.
        case pasting
    }

    var id: UUID
    var stage: Stage
    var appName: String?
    /// Its words once transcribed, for its hover card. Memory only.
    var text: String?
    /// Esc or Don't paste reached it: it is saved, not pasted.
    var declined = false
}

/// One layer behind the island.
struct NotchIslandBackLayer: Equatable {
    enum Glyph: Equatable {
        /// A red dot and small level bars.
        case meeting
        /// Rippling dots and a small wave.
        case processing
        /// A small ring: done, waiting its turn.
        case queued
    }

    /// Stable across renders, so a layer moves instead of appearing anew.
    var key: String
    var glyph: Glyph
}

/// One card in the hover list of everything going on, newest first.
struct NotchIslandActivityCard: Equatable {
    enum Kind: Equatable {
        /// The take being spoken: Cancel and Insert.
        case listening(appName: String?)
        /// The take on the island, released and being written: Don't paste.
        case writing(appName: String?)
        /// A take finishing behind the island: Don't paste until it pastes.
        case background(NotchIslandBackgroundTake)
        /// The recording meeting: Stop. Esc never reaches it.
        case meeting
    }

    var kind: Kind
    /// What Esc acts on right now (`NotchIslandActivityStack.escapeTarget`).
    var isEscapeTarget = false
}

enum NotchIslandActivityStack {
    /// More than this many layers would only push the island's edge down.
    static let maxBackLayers = 3
    /// Each layer is this much narrower on each side than the one above it.
    static let insetPerDepth: CGFloat = 10
    /// Each layer shows this much more below the one above it.
    static let peekPerDepth: CGFloat = 9
    /// A layer never gets narrower than this, so its glyph still fits.
    static let minimumWidth: CGFloat = 60

    static func glyph(for stage: NotchIslandBackgroundTake.Stage) -> NotchIslandBackLayer.Glyph {
        switch stage {
        case .processing: return .processing
        case .queued, .pasting: return .queued
        }
    }

    /// The take the island shows when no take of its own is on it: the
    /// newest one still finishing. Nil while a take is on the island.
    static func topTake(
        dictationOnIsland: Bool,
        takes: [NotchIslandBackgroundTake]
    ) -> NotchIslandBackgroundTake? {
        dictationOnIsland ? nil : takes.last
    }

    /// What sits behind the island, top-most first: the earlier takes,
    /// newest first, then a recording meeting, always deepest. `takes` come
    /// oldest first (take order). The take shown on the island itself is not
    /// repeated. At most `maxBackLayers`; the meeting keeps its place.
    static func backLayers(
        takes: [NotchIslandBackgroundTake],
        topTakeID: UUID?,
        meetingBehind: Bool
    ) -> [NotchIslandBackLayer] {
        let room = meetingBehind ? maxBackLayers - 1 : maxBackLayers
        var layers = takes.reversed()
            .filter { $0.id != topTakeID }
            .prefix(room)
            .map { NotchIslandBackLayer(key: $0.id.uuidString, glyph: glyph(for: $0.stage)) }
        if meetingBehind {
            layers.append(NotchIslandBackLayer(key: "meeting", glyph: .meeting))
        }
        return layers
    }

    /// A back layer's rect for an island at `island` (top-left origin, y
    /// down): centered under it, `insetPerDepth` narrower per side and
    /// `peekPerDepth` taller per depth. Depth 1 sits right under the island.
    static func frame(island: CGRect, depth: Int) -> CGRect {
        let inset = insetPerDepth * CGFloat(depth)
        let width = max(min(minimumWidth, island.width), island.width - 2 * inset)
        return CGRect(
            x: island.midX - width / 2,
            y: island.minY,
            width: width,
            height: island.height + peekPerDepth * CGFloat(depth)
        )
    }

    /// Fill per depth, from the island's black outward (0...1 sRGB).
    static func fill(depth: Int) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        switch depth {
        case ...0: return (0, 0, 0)
        case 1: return (0x20 / 255, 0x20 / 255, 0x25 / 255)
        case 2: return (0x2D / 255, 0x2D / 255, 0x34 / 255)
        default: return (0x3A / 255, 0x3A / 255, 0x42 / 255)
        }
    }

    struct Shadow: Equatable {
        var radius: CGFloat
        var offsetY: CGFloat
        var opacity: Float
    }

    /// Material-style elevation, counted from the bottom layer: the bottom
    /// one casts no shadow, the one above it a sharp one, higher ones softer
    /// and wider. `depth` 0 is the island itself; `layerCount` counts it too.
    /// A lone island casts none.
    static func shadow(depth: Int, layerCount: Int) -> Shadow? {
        switch layerCount - 1 - depth {
        case ...0: return nil
        case 1: return Shadow(radius: 0.75, offsetY: 1, opacity: 0.65)
        case 2: return Shadow(radius: 3.5, offsetY: 3, opacity: 0.55)
        default: return Shadow(radius: 8, offsetY: 7, opacity: 0.5)
        }
    }

    /// Every activity as a card, newest first: the take on the island, the
    /// takes behind it (newest first), then a recording meeting. The card Esc
    /// acts on is marked.
    static func cards(
        dictation: NotchIslandDictationContent?,
        takes: [NotchIslandBackgroundTake],
        meetingRecording: Bool
    ) -> [NotchIslandActivityCard] {
        var cards: [NotchIslandActivityCard] = []
        if let dictation, let kind = cardKind(for: dictation) {
            cards.append(NotchIslandActivityCard(kind: kind))
        }
        cards += takes.reversed().map { NotchIslandActivityCard(kind: .background($0)) }
        if meetingRecording {
            cards.append(NotchIslandActivityCard(kind: .meeting))
        }
        if let target = escapeTarget(in: cards) {
            cards[target].isEscapeTarget = true
        }
        return cards
    }

    /// Esc acts on the newest take still being spoken or finishing: the take
    /// on the island first, else the newest take behind it that hasn't
    /// started pasting or been declined. Never the meeting.
    static func escapeTarget(in cards: [NotchIslandActivityCard]) -> Int? {
        cards.firstIndex { card in
            switch card.kind {
            case .listening, .writing:
                return true
            case .background(let take):
                return !take.declined && take.stage != .pasting
            case .meeting:
                return false
            }
        }
    }

    /// The take on the island as a card, while it is spoken or finishing.
    /// A take showing its result (Pasted, a message) is past both.
    private static func cardKind(for dictation: NotchIslandDictationContent) -> NotchIslandActivityCard.Kind? {
        switch dictation.phase {
        case .starting, .loading, .listening:
            return .listening(appName: dictation.targetAppName)
        case .writing:
            return .writing(appName: dictation.targetAppName)
        case .success, .message:
            return nil
        }
    }
}
