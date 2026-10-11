import ApplicationServices
import Foundation

/// Fork: keyboard events addressed to one process, without focusing it, for
/// Anchored paste into terminals (`AnchoredPastePolicy.terminalBundleIDs`).
///
/// A port of cua-driver's SkyLight keyboard route (MIT, Cua AI, Inc.,
/// https://github.com/trycua/cua, `libs/cua-driver/rust/crates/platform-macos/src/input`):
/// `SLEventPostToPid` instead of the public `CGEvent.postToPid`, which skips
/// WindowServer's activity bookkeeping, plus an `SLSEventAuthenticationMessage`
/// attached to each event (macOS 15+; skipped where the factory is missing).
/// Private SkyLight symbols are resolved once with `dlsym`; when they are
/// missing the public `postToPid` is used, and the caller sees nothing
/// different.
///
/// Text goes as Unicode payloads on key code 0, up to 20 UTF-16 units per
/// event, with empty modifier flags so a held Shift can't leak in.
enum BackgroundKeystrokes {
    private typealias PostToPid = @convention(c) (pid_t, CGEvent) -> Void
    private typealias SetAuthMessage = @convention(c) (CGEvent, AnyObject) -> Void
    private typealias AuthMessageFactory = @convention(c) (AnyClass, Selector, UnsafeMutableRawPointer, Int32, UInt32) -> AnyObject?

    private struct Symbols {
        let postToPid: PostToPid?
        let setAuthMessage: SetAuthMessage?
        let messageSend: UnsafeMutableRawPointer?
    }

    private static let symbols: Symbols = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_GLOBAL)
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        return Symbols(
            postToPid: dlsym(defaultHandle, "SLEventPostToPid").map { unsafeBitCast($0, to: PostToPid.self) },
            setAuthMessage: dlsym(defaultHandle, "SLEventSetAuthenticationMessage").map { unsafeBitCast($0, to: SetAuthMessage.self) },
            messageSend: dlsym(defaultHandle, "objc_msgSend")
        )
    }()

    /// Pause between events. Terminals drop nothing at 4 ms; it keeps a
    /// 500-character dictation well under a second.
    private static let eventGapMicroseconds: useconds_t = 4_000

    /// Types `text` into `pid`; line breaks are Return presses. Blocks for
    /// the duration, so call it off the main thread.
    static func type(_ text: String, pid: pid_t) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        for chunk in AnchoredPastePolicy.keystrokeChunks(text) {
            switch chunk {
            case .text(let run):
                let units = Array(run.utf16)
                for keyDown in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { return false }
                    units.withUnsafeBufferPointer {
                        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress)
                    }
                    event.flags = []
                    post(event, to: pid)
                    usleep(eventGapMicroseconds)
                }
            case .returnKey:
                guard press(keyCode: 36, flags: [], pid: pid, source: source) else { return false }
            }
        }
        return true
    }

    /// Presses one key (Return is 36) with `flags` in `pid`.
    @discardableResult
    static func press(keyCode: CGKeyCode, flags: CGEventFlags, pid: pid_t, source: CGEventSource? = nil) -> Bool {
        let source = source ?? CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { return false }
            event.flags = flags
            post(event, to: pid)
            usleep(eventGapMicroseconds)
        }
        return true
    }

    private static func post(_ event: CGEvent, to pid: pid_t) {
        guard let postToPid = symbols.postToPid else {
            event.postToPid(pid)
            return
        }
        attachAuthenticationMessage(to: event, pid: pid)
        postToPid(pid, event)
    }

    /// macOS 15 added `+[SLSEventAuthenticationMessage messageWithEventRecord:pid:version:]`;
    /// macOS 14 has the class without it, so the selector is checked first.
    private static func attachAuthenticationMessage(to event: CGEvent, pid: pid_t) {
        guard let setAuthMessage = symbols.setAuthMessage,
              let messageSend = symbols.messageSend,
              let messageClass = NSClassFromString("SLSEventAuthenticationMessage"),
              let record = eventRecord(of: event) else { return }
        let selector = NSSelectorFromString("messageWithEventRecord:pid:version:")
        guard (messageClass as AnyObject).responds(to: selector) else { return }
        let factory = unsafeBitCast(messageSend, to: AuthMessageFactory.self)
        if let message = factory(messageClass, selector, record, pid, 0) {
            setAuthMessage(event, message)
        }
    }

    /// The `SLSEventRecord *` inside a `CGEvent` (`{CFRuntimeBase, uint32_t,
    /// SLSEventRecord *}`), probed at the offsets cua-driver uses across macOS
    /// versions.
    private static func eventRecord(of event: CGEvent) -> UnsafeMutableRawPointer? {
        let base = Unmanaged.passUnretained(event).toOpaque()
        for offset in [24, 32, 16] {
            if let record = base.load(fromByteOffset: offset, as: UnsafeMutableRawPointer?.self) { return record }
        }
        return nil
    }
}
