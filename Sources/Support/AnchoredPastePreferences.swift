import Foundation

/// Fork: Anchored paste (`AnchoredPastePolicy`). Off by default, so the
/// regular paste-into-the-front-app stays the behavior until it's turned on.
enum AnchoredPastePreferences {
    static let enabledKey = "dictationAnchoredPasteEnabled"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }
}
