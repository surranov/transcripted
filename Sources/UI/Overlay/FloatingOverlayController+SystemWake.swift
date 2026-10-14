import AppKit

// MARK: - System Wake Recovery & Periodic AG Refresh

extension FloatingOverlayController {
    func handleSystemWake() {
        // No NSHostingView to recreate. AppKit views survive sleep/wake without corruption.
        // Reset state to idle as a safety measure.
        guard !isVisible else { return }
        state = .idle
    }
}
