import SwiftUI

/// Settings → Local LLM (fork): the model's status and the two prompts the
/// transcript LLM applies, one to every dictation before it's pasted and one
/// to every utterance of a saved meeting. Clearing a prompt turns that pass
/// off. The runtime is `TranscriptLLMController`; this view only edits the
/// saved prompts and reads the status.
struct TranscriptLLMSettingsEditor: View {
    /// In-memory read of the runtime's state; polled once a second while the
    /// card is on screen (a closed window draws nothing, so it polls nothing).
    let statusLine: () -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsControlRow(
                title: "Model",
                info: GeneralInfo(
                    title: "Local LLM",
                    message: "Gemma 4 E2B runs on this Mac, loaded while Transcripted is open. It downloads once (2.8 GB). Nothing leaves the Mac. If it isn't ready, fails, or answers something that doesn't look like what was said, the recognized text is kept as is."
                ),
                automationIdentifier: "transcripted.settings.general.transcript-llm-status"
            ) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(statusLine())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            TranscriptLLMPromptEditor(
                title: "Dictation prompt",
                info: GeneralInfo(
                    title: "Dictation prompt",
                    message: "Applied to every dictation before it's pasted. The dictated text reaches the model between <TRANSCRIPTION-START> and <TRANSCRIPTION-END>. Clear it to paste dictations as recognized."
                ),
                preference: .dictation,
                automationIdentifier: "transcripted.settings.general.dictation-llm-prompt"
            )
            TranscriptLLMPromptEditor(
                title: "Meeting prompt",
                info: GeneralInfo(
                    title: "Meeting prompt",
                    message: "Applied to each utterance of a meeting after its transcript is saved, in the background, however long the meeting. Timestamps and speakers stay as they are, and the transcript as it was is kept in Transcripted's state folder. Clear it to keep meetings as recognized."
                ),
                preference: .meeting,
                automationIdentifier: "transcripted.settings.general.meeting-llm-prompt",
                showsDivider: false
            )
        }
    }
}

/// One prompt: a text box, its character count against the cap, and Reset.
/// Saves on every keystroke; tells the runtime to re-cache once typing pauses.
private struct TranscriptLLMPromptEditor: View {
    let title: String
    let info: GeneralInfo
    let preference: TranscriptLLMPromptPreference
    let automationIdentifier: String
    var showsDivider = true

    @State private var prompt = ""
    @State private var loaded = false
    @State private var pendingNotify: Task<Void, Never>?

    private var atLimit: Bool { prompt.count >= TranscriptLLMPromptPreference.maxCharacters }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeneralTitleLabel(title: title, info: info)

            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 220)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.12))
                )
                .accessibilityIdentifier(automationIdentifier)
                .onChange(of: prompt) { _, newValue in
                    guard loaded else { return }
                    let clamped = TranscriptLLMPromptPreference.clamped(newValue)
                    guard clamped == newValue else {
                        // Pasted past the cap: keep the first 30,000 characters.
                        prompt = clamped
                        return
                    }
                    if preference.setPrompt(clamped) { scheduleNotify() }
                }

            HStack(spacing: 8) {
                Text("\(prompt.count.formatted()) / \(TranscriptLLMPromptPreference.maxCharacters.formatted()) characters")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(atLimit ? Color.orange : Color.secondary)
                Spacer(minLength: 10)
                SettingsInlineActionButton(
                    title: "Reset to default",
                    automationIdentifier: "\(automationIdentifier).reset"
                ) {
                    prompt = preference.defaultPrompt
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if showsDivider { Divider() }
        }
        .onAppear {
            guard !loaded else { return }
            prompt = preference.prompt()
            loaded = true
        }
        .onDisappear { notifyNow() }
    }

    private func scheduleNotify() {
        pendingNotify?.cancel()
        pendingNotify = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            pendingNotify = nil
            preference.postDidChange()
        }
    }

    private func notifyNow() {
        guard let pending = pendingNotify else { return }
        pending.cancel()
        pendingNotify = nil
        preference.postDidChange()
    }
}
