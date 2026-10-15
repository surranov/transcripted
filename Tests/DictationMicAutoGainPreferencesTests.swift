import Foundation

func testDictationMicAutoGainPreferences() {
    runSuite("Automatic mic level is on until the user turns it off") {
        let (defaults, suiteName) = makeDictationMicAutoGainDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertTrue(DictationMicAutoGainPreferences.isEnabled(userDefaults: defaults), "a fresh install should level a quiet mic")
    }

    runSuite("The automatic mic level setting remembers both off and on") {
        let (defaults, suiteName) = makeDictationMicAutoGainDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DictationMicAutoGainPreferences.setEnabled(false, userDefaults: defaults)
        assertFalse(DictationMicAutoGainPreferences.isEnabled(userDefaults: defaults), "explicit off should read back as off, not the default")

        DictationMicAutoGainPreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(DictationMicAutoGainPreferences.isEnabled(userDefaults: defaults), "turning it back on should stick")
    }

    runSuite("The automatic mic level setting is stored under a stable key") {
        assertEqual(
            DictationMicAutoGainPreferences.enabledKey,
            "dictationMicAutoGainEnabled",
            "storage key should not drift across updates"
        )

        let (defaults, suiteName) = makeDictationMicAutoGainDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "dictationMicAutoGainEnabled")
        assertFalse(
            DictationMicAutoGainPreferences.isEnabled(userDefaults: defaults),
            "an off already saved under the key should be honored"
        )
    }
}

private func makeDictationMicAutoGainDefaults() -> (UserDefaults, String) {
    let suiteName = "DictationMicAutoGainPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
