import AppKit
import Foundation

// A take the chat thread guard kept out of another thread
// (ClipboardRestoringTextPaster.copyForChangedChat): its words wait on the
// clipboard for a manual paste, and the user's own clipboard comes back with
// the next paste, never an earlier take's words. Uses private pasteboards.

@MainActor
private func confirmedPaste(
    _ text: String,
    with paster: ClipboardRestoringTextPaster,
    on pasteboardName: NSPasteboard.Name,
    restoreDelay: UInt64
) -> TextPasteOutcome {
    let pasteboard = NSPasteboard(name: pasteboardName)
    return paster.paste(
        text,
        pasteboard: pasteboard,
        accessibilityTrusted: { true },
        requestAccessibilityTrust: {},
        pasteDispatcher: {
            _ = pasteboard.string(forType: .string)
            return true
        },
        pasteConfirmed: { true },
        restoreDelay: restoreDelay,
        fallbackRestoreDelay: restoreDelay
    )
}

@MainActor
private func board(_ name: NSPasteboard.Name, holding text: String) {
    let pasteboard = NSPasteboard(name: name)
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

@MainActor
private func clipboard(_ name: NSPasteboard.Name) -> String? {
    NSPasteboard(name: name).string(forType: .string)
}

/// Long enough that the restore is still waiting when the test goes on.
private let restoreStillWaiting: UInt64 = 30_000_000_000
private let quickRestore: UInt64 = 5_000_000

func testClipboardChatChangedCopy() async {
    await runSuite("A take kept out of another chat waits on the clipboard; the next paste gives the user's clipboard back") {
        let name = NSPasteboard.Name("TranscriptedChatChangedCopy-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }
        let outcome = await MainActor.run { () -> TextPasteOutcome in
            board(name, holding: "synthetic user clipboard")
            return paster.copyForChangedChat("synthetic dictation", message: "synthetic notice", pasteboard: NSPasteboard(name: name))
        }
        assertEqual(outcome, .copied("synthetic notice", reason: .chatChanged), "the take reports it was copied because the chat changed")
        assertEqual(await MainActor.run { clipboard(name) }, "synthetic dictation", "the words are on the clipboard for ⌘V")

        _ = await MainActor.run { confirmedPaste("synthetic next take", with: paster, on: name, restoreDelay: quickRestore) }
        await paster.waitForPendingClipboardRestore()
        assertEqual(await MainActor.run { clipboard(name) }, "synthetic user clipboard", "the user's clipboard comes back, not the words")
    }

    await runSuite("A take kept out of another chat right after a paste saves the user's clipboard, not the earlier take") {
        let name = NSPasteboard.Name("TranscriptedChatChangedAfterPaste-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }
        await MainActor.run {
            board(name, holding: "synthetic user clipboard")
            _ = confirmedPaste("synthetic earlier take", with: paster, on: name, restoreDelay: restoreStillWaiting)
        }
        let outcome = await MainActor.run {
            paster.copyForChangedChat("synthetic dictation", message: "synthetic notice", pasteboard: NSPasteboard(name: name))
        }
        assertEqual(outcome.copyReason, .chatChanged, "copied, not pasted")
        assertEqual(await MainActor.run { clipboard(name) }, "synthetic dictation", "this take's words are on the clipboard")

        _ = await MainActor.run { confirmedPaste("synthetic next take", with: paster, on: name, restoreDelay: quickRestore) }
        await paster.waitForPendingClipboardRestore()
        assertEqual(await MainActor.run { clipboard(name) }, "synthetic user clipboard", "the earlier take's borrowed clipboard never replaces the user's")
    }

    await runSuite("A take kept out of another chat puts back another paster's borrowed clipboard first") {
        let name = NSPasteboard.Name("TranscriptedChatChangedOtherPaster-\(UUID().uuidString)")
        let pasteLast = await MainActor.run { ClipboardRestoringTextPaster() }
        let dictation = await MainActor.run { ClipboardRestoringTextPaster() }
        await MainActor.run {
            board(name, holding: "synthetic user clipboard")
            _ = confirmedPaste("synthetic Paste Last text", with: pasteLast, on: name, restoreDelay: restoreStillWaiting)
            _ = dictation.copyForChangedChat("synthetic dictation", message: "synthetic notice", pasteboard: NSPasteboard(name: name))
        }
        _ = await MainActor.run { confirmedPaste("synthetic next take", with: dictation, on: name, restoreDelay: quickRestore) }
        await dictation.waitForPendingClipboardRestore()
        assertEqual(await MainActor.run { clipboard(name) }, "synthetic user clipboard", "Paste Last's borrowed text never replaces the user's clipboard")
    }
}
