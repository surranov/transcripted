import ApplicationServices
import Foundation

/// Fork: makes a window key inside its own app without activating the app or
/// raising the window, so keystrokes addressed to the app's process
/// (`BackgroundKeystrokes`) reach it: a send into the anchored box
/// (`AnchoredSendMethod.keyWindowReturn`). An inactive Chromium or Electron
/// window drops such keystrokes until it is key; a native window takes them
/// either way.
///
/// yabai's recipe (MIT, Åsmund Vikane, https://github.com/koekeishiya/yabai,
/// `window_manager_focus_window_without_raise` and
/// `window_manager_make_key_window`), as cua-driver uses it (MIT, Cua AI,
/// Inc., https://github.com/trycua/cua, `platform-macos/src/input/skylight.rs`):
/// 248-byte event records posted to the window owner's process with
/// `SLPSPostEventRecordTo`, a focus record and then the make-key pair.
/// Nothing is posted to the front app, so it keeps the keyboard, and
/// `SLPSSetFrontProcessWithOptions` is never called, so nothing activates.
///
/// Measured on macOS 26 (2026-10-13): an inactive Electron window took Return
/// after the focus record and the make-key pair (after neither alone), while
/// the front app and WindowServer's key-focus process stayed the same; the
/// resign record fired the page's blur. A native window (TextEdit) took Return
/// with or without them. A minimized window took nothing.
///
/// Private symbols are resolved once with `dlsym`; when one is missing,
/// `makeKey` returns false and the caller reports that Enter couldn't be
/// pressed.
enum BackgroundKeyWindow {
    private typealias PostEventRecordTo = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt8>) -> Int32
    private typealias GetWindowOwner = @convention(c) (UInt32, UInt32, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias GetConnectionPSN = @convention(c) (UInt32, UnsafeMutableRawPointer) -> Int32
    private typealias MainConnectionID = @convention(c) () -> UInt32
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

    private struct Symbols {
        let postEventRecordTo: PostEventRecordTo?
        let getWindowOwner: GetWindowOwner?
        let getConnectionPSN: GetConnectionPSN?
        let mainConnectionID: MainConnectionID?
        let getProcessForPID: GetProcessForPID?
    }

    private static let symbols: Symbols = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_GLOBAL)
        let handle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        func resolve<T>(_ names: [String], as type: T.Type) -> T? {
            for name in names {
                if let symbol = dlsym(handle, name) { return unsafeBitCast(symbol, to: type) }
            }
            return nil
        }
        return Symbols(
            postEventRecordTo: resolve(["SLPSPostEventRecordTo"], as: PostEventRecordTo.self),
            getWindowOwner: resolve(["SLSGetWindowOwner"], as: GetWindowOwner.self),
            getConnectionPSN: resolve(["SLSGetConnectionPSN"], as: GetConnectionPSN.self),
            mainConnectionID: resolve(["SLSMainConnectionID", "CGSMainConnectionID"], as: MainConnectionID.self),
            getProcessForPID: resolve(["GetProcessForPID"], as: GetProcessForPID.self)
        )
    }()

    /// Makes `windowID` (owned by `pid`) its app's key window. True when
    /// every record was posted; whether the app took it shows in its
    /// `AXFocusedWindow`.
    static func makeKey(_ windowID: CGWindowID, pid: pid_t) -> Bool {
        guard let post = symbols.postEventRecordTo, let psn = processSerialNumber(owning: windowID, pid: pid) else { return false }
        var focus = record(windowID: windowID, kind: 0x0D)
        focus[0x8A] = 0x01
        var posted = post(psn, focus) == 0
        for kind: UInt8 in [0x01, 0x02] {
            var makeKey = record(windowID: windowID, kind: kind)
            makeKey[0x3A] = 0x10
            for offset in 0x20..<0x30 { makeKey[offset] = 0xFF }
            posted = post(psn, makeKey) == 0 && posted
        }
        return posted
    }

    /// Takes key status back from `windowID`, so a background app doesn't go
    /// on acting focused (a caret blinking, a chat marking messages read).
    @discardableResult
    static func resignKey(_ windowID: CGWindowID, pid: pid_t) -> Bool {
        guard let post = symbols.postEventRecordTo, let psn = processSerialNumber(owning: windowID, pid: pid) else { return false }
        var defocus = record(windowID: windowID, kind: 0x0D)
        defocus[0x8A] = 0x02
        return post(psn, defocus) == 0
    }

    /// A zeroed 248-byte record for `windowID`: its size at 0x04, its kind
    /// at 0x08, the window id (little-endian) at 0x3C.
    private static func record(windowID: CGWindowID, kind: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x08] = kind
        withUnsafeBytes(of: windowID.littleEndian) { id in
            for (offset, byte) in id.enumerated() { bytes[0x3C + offset] = byte }
        }
        return bytes
    }

    /// The 8-byte process serial number of the window's owner: through its
    /// WindowServer connection, else (older systems) through its pid.
    private static func processSerialNumber(owning windowID: CGWindowID, pid: pid_t) -> [UInt8]? {
        var psn = [UInt8](repeating: 0, count: 8)
        if let owner = symbols.getWindowOwner, let connectionPSN = symbols.getConnectionPSN, let main = symbols.mainConnectionID {
            var ownerConnection: UInt32 = 0
            if owner(main(), windowID, &ownerConnection) == 0, ownerConnection != 0,
               psn.withUnsafeMutableBytes({ connectionPSN(ownerConnection, $0.baseAddress!) }) == 0 {
                return psn
            }
        }
        guard let processForPID = symbols.getProcessForPID,
              psn.withUnsafeMutableBytes({ processForPID(pid, $0.baseAddress!) }) == 0 else { return nil }
        return psn
    }
}
