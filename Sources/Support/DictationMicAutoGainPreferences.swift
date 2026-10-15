import Foundation

/// "Automatic mic level" for dictation: lifts a quiet mic toward a steady
/// speech level and caps every peak so nothing clips (`DictationMicAutoGain`).
/// On until the user turns it off: it only ever raises quiet speech, so a mic
/// that's already loud is left alone. Read at each dictation start. Meetings
/// keep their own Mic processing setting (`MicrophoneProcessingPreferences`),
/// and dictation that borrows a meeting's mic gets the meeting's processing.
enum DictationMicAutoGainPreferences {
    static let enabledKey = "dictationMicAutoGainEnabled"
    static let shipsOnByDefault = true

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.object(forKey: enabledKey) as? Bool ?? shipsOnByDefault
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }
}
