// Support/CallPromptAutoRecordPreferences.swift
// How long the detected-call prompt waits before it records by itself.
//
// Off by default. When set, a prompt for a call that is live right now counts
// down this many seconds on its Record button and then records, unless the
// person skips it or asks to be reminded. Which prompts qualify is
// MeetingPromptHeuristics.autoRecordDelaySeconds; the rest still only ask.
// docs/auto-call-detection-spec.md ("Deliberately not built: default
// auto-record") is why this stays opt-in: no file is written without a human
// signal unless the person chose this.

import Foundation

enum CallPromptAutoRecordPreferences {

    static let delayKey = "call-prompt-auto-record-delay-seconds"

    /// The delays Settings offers, in seconds.
    static let delayChoices = [5, 10, 15, 30]

    /// Seconds before the prompt records by itself; nil means off (the
    /// default). A stored value that is not one of `delayChoices` (a
    /// hand-edited 0 would record at once) also reads as off.
    static func delaySeconds(userDefaults: UserDefaults = .standard) -> Int? {
        guard let seconds = userDefaults.object(forKey: delayKey) as? Int,
              delayChoices.contains(seconds) else { return nil }
        return seconds
    }

    /// nil, or a value outside `delayChoices`, turns it off.
    static func setDelaySeconds(_ seconds: Int?, userDefaults: UserDefaults = .standard) {
        guard let seconds, delayChoices.contains(seconds) else {
            userDefaults.removeObject(forKey: delayKey)
            return
        }
        userDefaults.set(seconds, forKey: delayKey)
    }
}
