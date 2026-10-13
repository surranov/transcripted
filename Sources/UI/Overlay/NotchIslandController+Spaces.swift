// NotchIslandController+Spaces.swift
// Keeps the island on whichever desktop is in front. macOS can leave the
// panel on one desktop although it asks for all of them (see
// NotchIslandPanel.rejoinAllSpacesIfLeftBehind()), so the controller checks
// when the island shows, when the desktop changes and when displays change.

import AppKit

extension NotchIslandController {
    func watchSpaces() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rejoinAllSpacesIfLeftBehind("desktop_switch")
            }
        }
    }

    /// `moment` says what prompted the check, for the local event log.
    func rejoinAllSpacesIfLeftBehind(_ moment: String) {
        guard let panel, panel.rejoinAllSpacesIfLeftBehind() else { return }
        // Local events.jsonl only: the check runs on every show and desktop
        // switch, and a hit is the evidence that macOS dropped the panel.
        EventReporter.shared.capture(
            level: .info,
            engine: "overlay",
            event: "island_rejoined_all_desktops",
            message: "The island was left on one desktop and rejoined every desktop",
            context: ["moment": moment],
            forwardToSentry: false
        )
    }
}
