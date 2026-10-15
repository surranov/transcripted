// NotchIslandDropView+Activities.swift
// Fork: the dictation queue. The hover over an island with more than one
// thing going on lists them all, newest first, one card each with its own
// buttons: the take being spoken (Cancel, Insert), a take being written or
// finishing behind the island (Don't paste), the recording meeting (Stop),
// a meeting still being transcribed behind it (its progress, no buttons).
// The card Esc acts on wears an "esc" key; a meeting never does.

import AppKit

extension NotchIslandDropView {
    func buildActivities(_ cards: [NotchIslandActivityCard], live: NotchIslandLiveValues) {
        for card in cards {
            add(activityCard(card, live: live))
        }
    }

    static let earlierMeetingTitle = "Earlier meeting"

    /// "Transcribing 42%", "Transcribing · 1 more waiting". Text only on
    /// screen; never logged.
    static func earlierMeetingStatus(_ meeting: NotchIslandEarlierMeeting, percent: Int?) -> String {
        MeetingPillFinishPresentation.menuStatus(percent: percent, queuedCount: meeting.moreWaiting)
    }

    static func activityAccessibilityLabel(title: String, detail: String) -> String {
        [title, detail].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    func activityCard(_ card: NotchIslandActivityCard, live: NotchIslandLiveValues) -> NSView {
        var content = Self.activityContent(card.kind)
        if case .earlierMeeting(let meeting) = card.kind {
            content.detail = Self.earlierMeetingStatus(meeting, percent: live.earlierMeetingPercent)
        }
        let title = NotchIslandPalette.label(content.title, font: .systemFont(ofSize: 12.5, weight: .semibold), color: NotchIslandPalette.primaryText)
        title.lineBreakMode = .byTruncatingTail
        var lines: [NSView] = [title]
        if !content.detail.isEmpty {
            let detail = NotchIslandPalette.label(content.detail, font: .systemFont(ofSize: 11.5), color: NotchIslandPalette.secondaryText)
            detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            lines.append(detail)
            readableText.append(detail)
        }
        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setContentHuggingPriority(.init(1), for: .horizontal)

        var views: [NSView] = [Self.activityIcon(card.kind), text]
        if card.isEscapeTarget { views.append(Self.escapeKey()) }
        views += content.buttons.map { button($0.title, $0.style, $0.action, symbol: $0.symbol) }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(srgbRed: 0x15 / 255, green: 0x15 / 255, blue: 0x18 / 255, alpha: 1).cgColor
        box.layer?.cornerRadius = 14
        box.layer?.cornerCurve = .continuous
        if card.isEscapeTarget {
            box.layer?.borderWidth = 1
            box.layer?.borderColor = NotchIslandPalette.accent.withAlphaComponent(0.6).cgColor
        }
        box.addSubview(row)
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel(Self.activityAccessibilityLabel(title: content.title, detail: content.detail))
        if case .earlierMeeting(let meeting) = card.kind, let detail = lines.last as? NSTextField {
            earlierMeetingLine = (detail, box, meeting)
        }
        return box
    }

    struct ActivityButton {
        var title: String
        var style: NotchIslandButton.Style
        var action: NotchIslandAction
        var symbol: String? = nil
    }

    /// A card's words and buttons. Text only on screen; never logged.
    static func activityContent(_ kind: NotchIslandActivityCard.Kind) -> (title: String, detail: String, buttons: [ActivityButton]) {
        func into(_ appName: String?) -> String {
            guard let appName, !appName.isEmpty else { return "" }
            return "Into \(appName)"
        }
        switch kind {
        case .listening(let appName):
            return ("Listening", into(appName), [
                ActivityButton(title: "Cancel", style: .plain, action: .dictationCancel),
                ActivityButton(title: "Insert", style: .accent, action: .dictationStop),
            ])
        case .writing(let appName):
            return ("Writing", into(appName), [
                ActivityButton(title: "Don't paste", style: .plain, action: .dictationDeclinePaste),
            ])
        case .background(let take):
            let detail = take.text.map { "“\($0)”" } ?? into(take.appName)
            if take.declined {
                return ("Won't paste, saving", detail, [])
            }
            switch take.stage {
            case .processing:
                return ("Writing", detail, [
                    ActivityButton(title: "Don't paste", style: .plain, action: .backgroundTakeDeclinePaste(take.id)),
                ])
            case .queued:
                return ("Next in line", detail, [
                    ActivityButton(title: "Don't paste", style: .plain, action: .backgroundTakeDeclinePaste(take.id)),
                ])
            case .pasting:
                return ("Pasting", detail, [])
            }
        case .meeting:
            return ("Meeting", "Recording", [
                ActivityButton(title: "Stop", style: .destructive, action: .meetingStop, symbol: "stop.fill"),
            ])
        case .earlierMeeting(let meeting):
            return (earlierMeetingTitle, earlierMeetingStatus(meeting, percent: nil), [])
        }
    }

    private static func activityIcon(_ kind: NotchIslandActivityCard.Kind) -> NSView {
        let icon: NSView
        switch kind {
        case .listening:
            icon = symbol("mic.fill")
        case .writing:
            icon = NotchIslandDotsView(frame: .zero)
        case .background(let take):
            switch take.stage {
            case .processing, .pasting: icon = NotchIslandDotsView(frame: .zero)
            case .queued: icon = symbol("circle")
            }
        case .meeting:
            icon = NotchIslandDotView(size: 7, color: NotchIslandPalette.recording, glow: false)
        case .earlierMeeting:
            icon = NotchIslandDotsView(frame: .zero)
        }
        // One column wide, so the titles line up.
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(icon)
        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalToConstant: 22),
            holder.heightAnchor.constraint(equalToConstant: 16),
            icon.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return holder
    }

    private static func symbol(_ name: String) -> NSView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        view.contentTintColor = NotchIslandPalette.accent
        return view
    }

    /// The small "esc" key on the card Esc acts on.
    private static func escapeKey() -> NSView {
        let label = NotchIslandPalette.label("esc", font: .systemFont(ofSize: 9.5, weight: .semibold), color: NSColor(white: 1, alpha: 0.75))
        label.alignment = .center
        let key = NSView()
        key.wantsLayer = true
        key.layer?.cornerRadius = 4
        key.layer?.borderWidth = 1
        key.layer?.borderColor = NSColor(white: 1, alpha: 0.38).cgColor
        key.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        key.addSubview(label)
        NSLayoutConstraint.activate([
            key.heightAnchor.constraint(equalToConstant: 15),
            label.centerYAnchor.constraint(equalTo: key.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: key.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: key.trailingAnchor, constant: -4),
        ])
        key.setContentHuggingPriority(.required, for: .horizontal)
        key.setAccessibilityElement(true)
        key.setAccessibilityLabel("Escape acts here")
        return key
    }
}
