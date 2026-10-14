// ClipboardRestoringTextPaster+ChatChanged.swift
// Fork: the chat thread guard (`ChatThreadPolicy`) keeps a take out of
// another chat thread; its words go on the clipboard for a manual ⌘V.

import AppKit

extension ClipboardRestoringTextPaster {
    /// Puts `text` on the clipboard instead of pasting it, as when focus
    /// moved before a paste: the user's clipboard is saved first and comes
    /// back when the next paste starts. Every clipboard a paste still borrows
    /// (this paster's or another's, waiting on its restore delay) is put back
    /// before that, so the save is the user's own clipboard and not an
    /// earlier take's words.
    func copyForChangedChat(
        _ text: String,
        message: String,
        pasteboard: any ClipboardPasteboard = NSPasteboard.general
    ) -> TextPasteOutcome {
        cancelPendingClipboardRestore()
        restoreOtherPastersPendingClipboards()
        restoreClipboardSavedBeforeFallback(on: pasteboard)
        guard copyTextForManualPaste(text, to: pasteboard, isCurrentOperation: { true }) else {
            return .failed(
                "You switched chats, and Transcripted couldn't put the text on your clipboard. It's still saved in your dictation history.",
                reason: .chatChangeClipboardWriteFailed
            )
        }
        return .copied(message, reason: .chatChanged)
    }
}
