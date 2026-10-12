import Foundation

func testCallPromptAutoRecordPreferences() {
    runSuite("CallPromptAutoRecordPreferences is off for new installs") {
        let (defaults, suiteName) = makeCallPromptAutoRecordDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertNil(
            CallPromptAutoRecordPreferences.delaySeconds(userDefaults: defaults),
            "a detected call must never record by itself until the person opts in"
        )
    }

    runSuite("CallPromptAutoRecordPreferences keeps each offered delay and turns back off") {
        let (defaults, suiteName) = makeCallPromptAutoRecordDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for seconds in CallPromptAutoRecordPreferences.delayChoices {
            CallPromptAutoRecordPreferences.setDelaySeconds(seconds, userDefaults: defaults)
            assertEqual(
                CallPromptAutoRecordPreferences.delaySeconds(userDefaults: defaults),
                seconds,
                "the \(seconds)s choice should round-trip"
            )
        }

        CallPromptAutoRecordPreferences.setDelaySeconds(nil, userDefaults: defaults)
        assertNil(
            CallPromptAutoRecordPreferences.delaySeconds(userDefaults: defaults),
            "choosing Off should turn auto-record off again"
        )
    }

    runSuite("CallPromptAutoRecordPreferences reads anything but an offered delay as off") {
        let (defaults, suiteName) = makeCallPromptAutoRecordDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = CallPromptAutoRecordPreferences.delayKey

        for stored: Any in [0, -5, 9_999, 7, "10", true] {
            defaults.set(stored, forKey: key)
            assertNil(
                CallPromptAutoRecordPreferences.delaySeconds(userDefaults: defaults),
                "a stored \(stored) must not record at once or after an odd delay"
            )
        }

        CallPromptAutoRecordPreferences.setDelaySeconds(10, userDefaults: defaults)
        CallPromptAutoRecordPreferences.setDelaySeconds(0, userDefaults: defaults)
        assertNil(
            CallPromptAutoRecordPreferences.delaySeconds(userDefaults: defaults),
            "setting a delay Settings does not offer should turn it off, not keep the old one"
        )
    }

    runSuite("CallPromptAutoRecordPreferences uses a stable storage key") {
        assertEqual(
            CallPromptAutoRecordPreferences.delayKey,
            "call-prompt-auto-record-delay-seconds",
            "storage key must stay stable across releases"
        )
    }
}

private func makeCallPromptAutoRecordDefaults() -> (UserDefaults, String) {
    let suiteName = "CallPromptAutoRecordPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
