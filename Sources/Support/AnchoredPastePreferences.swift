import Foundation

/// Fork: Anchored paste (`AnchoredPastePolicy`). Off by default, so the
/// regular paste-into-the-front-app stays the behavior until it's turned on.
enum AnchoredPastePreferences {
    static let enabledKey = "dictationAnchoredPasteEnabled"
    /// Anchored Enter: Enter pressed in the anchored field after its words.
    static let enterEnabledKey = "dictationAnchoredPasteEnterEnabled"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }

    /// Anchored Enter is on, and so is Anchored paste, which it builds on.
    static func pressesEnter(userDefaults: UserDefaults = .standard) -> Bool {
        isEnabled(userDefaults: userDefaults) && userDefaults.bool(forKey: enterEnabledKey)
    }

    static func setPressesEnter(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enterEnabledKey)
    }
}
