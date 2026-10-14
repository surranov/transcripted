import SwiftUI

/// Settings → Models and prompts (fork): for each pass of the transcript LLM,
/// its model and its prompt, one applied to every dictation before it's
/// pasted and one to every utterance of a saved meeting. Clearing a prompt
/// turns that pass off. Switching a pass away from a model no pass runs
/// anymore offers to delete it. The runtime is `TranscriptLLMController`;
/// this view edits the saved choices and prompts, reads the status, and asks
/// the runtime to delete.
struct TranscriptLLMSettingsEditor: View {
    /// In-memory read of the runtime's state; polled once a second while the
    /// card is on screen (a closed window draws nothing, so it polls nothing).
    let statusLine: (TranscriptLLMPass) -> String
    let modelBytesOnDisk: (TranscriptLLMModelChoice) -> Int64
    let deleteUnusedModel: @MainActor (TranscriptLLMModelChoice) async -> TranscriptLLMModelDeletion

    private struct DeletionOffer: Identifiable {
        let model: TranscriptLLMModelChoice
        let bytes: Int64
        var id: String { model.rawValue }
        var size: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    }

    @State private var deletionOffer: DeletionOffer?
    @State private var failedDeletion: TranscriptLLMModelChoice?

    private static let modelInfo = "Runs on this Mac while Transcripted is open; nothing leaves the Mac. Gemma 4 E2B is faster; Gemma 4 E4B keeps colloquial wording better and takes about twice as long. A model downloads the first time a pass picks it, and both passes on one model share it in memory. When no pass uses a model anymore, Transcripted offers to delete it. If the model isn't ready, fails, or answers something that doesn't look like what was said, the recognized text is kept as is."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                TranscriptLLMModelRow(
                    pass: .dictation,
                    title: "Dictation LLM",
                    info: GeneralInfo(title: "Dictation LLM", message: Self.modelInfo),
                    statusLine: { statusLine(.dictation) },
                    automationIdentifier: "transcripted.settings.general.dictation-llm-model",
                    onSwitch: offerDeletion
                )
                TranscriptLLMPromptEditor(
                    title: "Dictation prompt",
                    info: GeneralInfo(
                        title: "Dictation prompt",
                        message: "Applied to every dictation before it's pasted. The dictated text reaches the model between <TRANSCRIPTION-START> and <TRANSCRIPTION-END>. Clear it to paste dictations as recognized."
                    ),
                    preference: .dictation,
                    automationIdentifier: "transcripted.settings.general.dictation-llm-prompt"
                )
                TranscriptLLMModelRow(
                    pass: .meeting,
                    title: "Meeting LLM",
                    info: GeneralInfo(
                        title: "Meeting LLM",
                        message: "Meetings are rewritten in the background after they're saved, so a slower model costs no waiting. " + Self.modelInfo
                    ),
                    statusLine: { statusLine(.meeting) },
                    automationIdentifier: "transcripted.settings.general.meeting-llm-model",
                    onSwitch: offerDeletion
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
            // One presentation per view: the failure alert sits on the inner
            // stack, the deletion question on the outer one.
            .alert(
                "Couldn't delete \(failedDeletion?.title ?? "the model")",
                isPresented: Binding(
                    get: { failedDeletion != nil },
                    set: { if !$0 { failedDeletion = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Its files are still in Transcripted's models folder. Switching a pass to it again uses them.")
            }
        }
        .confirmationDialog(
            "Delete \(deletionOffer?.model.title ?? "the model") from this Mac?",
            isPresented: Binding(
                get: { deletionOffer != nil },
                set: { if !$0 { deletionOffer = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletionOffer
        ) { offer in
            Button("Delete \(offer.size)", role: .destructive) { delete(offer.model) }
                .accessibilityIdentifier("transcripted.settings.general.transcript-llm-delete.confirm")
            Button("Keep", role: .cancel) {}
        } message: { offer in
            Text("Neither dictation nor meetings use it now. It takes \(offer.size); picking it again downloads it again.")
        }
    }

    /// Asks only when no pass runs the old model anymore and it has files on
    /// disk (a model never downloaded has nothing to delete).
    private func offerDeletion(of previous: TranscriptLLMModelChoice) {
        guard !TranscriptLLMModelPreference.modelsInUse().contains(previous) else { return }
        let bytes = modelBytesOnDisk(previous)
        guard bytes > 0 else { return }
        deletionOffer = DeletionOffer(model: previous, bytes: bytes)
    }

    private func delete(_ model: TranscriptLLMModelChoice) {
        Task { @MainActor in
            if await deleteUnusedModel(model) == .failed { failedDeletion = model }
        }
    }
}

/// One pass's model: its status and a picker. Saves and tells the runtime on
/// every pick, then hands the model it replaced to `onSwitch`.
private struct TranscriptLLMModelRow: View {
    let pass: TranscriptLLMPass
    let title: String
    let info: GeneralInfo
    let statusLine: () -> String
    let automationIdentifier: String
    let onSwitch: (TranscriptLLMModelChoice) -> Void

    @State private var choice = TranscriptLLMModelChoice.gemma4E2B
    @State private var loaded = false

    var body: some View {
        SettingsControlRow(title: title, info: info, automationIdentifier: automationIdentifier, showsDivider: false) {
            HStack(spacing: 10) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(statusLine())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Picker(title, selection: $choice) {
                    ForEach(TranscriptLLMModelChoice.allCases) { model in
                        Text("\(model.title) · \(model.downloadSize)").tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("\(automationIdentifier).picker")
            }
        }
        .onAppear {
            guard !loaded else { return }
            choice = pass.model.choice()
            loaded = true
        }
        .onChange(of: choice) { previous, picked in
            guard loaded, pass.model.setChoice(picked) else { return }
            TranscriptLLMModelPreference.postDidChange()
            onSwitch(previous)
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
