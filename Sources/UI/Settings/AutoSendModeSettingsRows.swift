import SwiftUI

/// Fork: when send is pressed after a dictation (`DictationAutoSendMode`),
/// for Press send after pasting and Press Enter there (Anchored Enter) alike.
/// Their toggles and the app list say where; these rows say when.
struct AutoSendModeSettingsRows: View {
    /// Press send after pasting is on; the settings view owns that state.
    let pressSendAfterPastingEnabled: Bool
    let dictationShortcutsEnabled: Bool
    @ObservedObject var recorder: ShortcutRecorderModel
    let onTrackAction: (String) -> Void

    @State private var mode = DictationAutoSendPreferences.mode()
    @State private var confirmKey = DictationAutoSendPreferences.confirmKey()
    @State private var confirmSeconds = DictationAutoSendPreferences.confirmSeconds()
    @AppStorage(AnchoredPastePreferences.enabledKey)
    private var anchoredPasteEnabled = false
    @AppStorage(AnchoredPastePreferences.enterEnabledKey)
    private var anchoredEnterEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modeRow

            if mode == .dictateAndSendKey {
                ShortcutKeyRow(
                    target: .dictateAndSend,
                    info: GeneralInfo(
                        title: "Dictate & send key",
                        message: "Starts dictation just like the dictation key, with the same Behavior, and that dictation presses send after pasting. Hold ⇧ first, then the dictation key. Until you record your own, it's the dictation key plus ⇧ and follows that key."
                    ),
                    automationIdentifier: "transcripted.settings.general.dictate-and-send-key",
                    recorder: recorder
                ) {
                    if !dictationShortcutsEnabled {
                        warning("Turn on Keyboard shortcuts under Dictation for this key to work.")
                    }
                }
            }

            if mode == .confirmAfterPaste {
                confirmRows
            }
        }
        // Nothing presses send while both features are off.
        .disabled(!(pressSendAfterPastingEnabled || (anchoredPasteEnabled && anchoredEnterEnabled)))
        .onChange(of: mode) { _, newMode in
            // The key row just hid; don't keep listening for its key.
            if newMode != .dictateAndSendKey, recorder.recordingTarget == .dictateAndSend {
                recorder.stopRecording()
            }
        }
    }

    private var modeRow: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                GeneralTitleLabel(
                    title: "When to send",
                    info: GeneralInfo(
                        title: "When to send",
                        message: "For Press send after pasting and for Press Enter there. Always: every dictation that can send does. With Dictate & send key: only a dictation you start with that key sends; the dictation key just pastes. After I confirm: the words paste, then the island asks; press the confirm key in any app, or Send on the island, and send is pressed in the box the words went into. Dismiss, Esc, a new dictation or the wait running out send nothing."
                    )
                )
                Text(mode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            Picker("When to send", selection: Binding(
                get: { mode },
                set: { newMode in
                    mode = newMode
                    DictationAutoSendPreferences.setMode(newMode)
                    onTrackAction("change_auto_send_mode_\(newMode.rawValue)")
                }
            )) {
                ForEach(DictationAutoSendMode.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("transcripted.settings.general.auto-send-mode")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    /// Confirm key and wait, plus why it can't work without Anchored paste.
    @ViewBuilder
    private var confirmRows: some View {
        if !anchoredPasteEnabled {
            HStack(alignment: .top, spacing: 8) {
                warning("Needs Anchored paste, so send knows which box the words went into. Until then nothing is sent.")
                Spacer(minLength: 10)
                SettingsInlineActionButton(title: "Turn On") {
                    onTrackAction("enable_anchored_paste_for_confirm")
                    AnchoredPastePreferences.setEnabled(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transcripted.settings.general.confirm-send-needs-anchored-paste")
        }

        SettingsControlRow(
            title: "Confirm key",
            info: GeneralInfo(
                title: "Confirm key",
                message: "While a dictation waits to be sent, this key sends it from any app, without switching back. Transcripted takes that one press, so the app in front doesn't get it. Plain Enter is the quickest; pick ⌘ Enter or another one if you'd rather keep Enter for typing. If your dictation key is Right ⌥, use Left ⌥ for ⌥ Enter, or Right ⌥ starts a dictation instead."
            ),
            automationIdentifier: "transcripted.settings.general.confirm-send-key"
        ) {
            Picker("Confirm key", selection: Binding(
                get: { confirmKey },
                set: { key in
                    confirmKey = key
                    DictationAutoSendPreferences.setConfirmKey(key)
                    onTrackAction("change_confirm_send_key_\(key.rawValue)")
                }
            )) {
                ForEach(DictationSendConfirmKey.allCases) { key in
                    Text(key.title).tag(key)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }

        SettingsControlRow(
            title: "Wait",
            info: GeneralInfo(
                title: "Wait",
                message: "How long a pasted dictation waits for you to confirm. After that it stays pasted and isn't sent."
            ),
            automationIdentifier: "transcripted.settings.general.confirm-send-wait"
        ) {
            Picker("Wait", selection: Binding(
                get: { confirmSeconds },
                set: { seconds in
                    confirmSeconds = seconds
                    DictationAutoSendPreferences.setConfirmSeconds(seconds)
                    onTrackAction("change_confirm_send_wait_\(seconds)")
                }
            )) {
                ForEach(DictationAutoSendPreferences.confirmSecondsChoices, id: \.self) { seconds in
                    Text("\(seconds) s").tag(seconds)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }
}
