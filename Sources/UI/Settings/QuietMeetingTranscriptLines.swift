import SwiftUI

// Transcript rows of an expanded Home meeting (`QuietMeetingExpansion`).
//
// A long meeting has thousands of lines, so the rows sit in a LazyVStack and
// only the ones near the visible part of the page get built. The eager VStack
// this replaced built every row on "Show all" (each is two buttons, a popover,
// a context menu, a tooltip and selectable text): 3,000 lines took ~1.2 GB and
// froze the window for 3 s, or 2 min while an accessibility client was
// reading the app. Now it's ~30 MB and no visible pause at any length.

/// The rows themselves. `lineLimit` nil shows every line.
struct QuietMeetingTranscriptLines: View {
    let lines: [HomeMeetingTranscriptLine]
    let lineLimit: Int?
    let audio: MeetingAudioAttachment?
    let knownPeople: [SpeakerNameChoice]
    let savedSpeakerIDs: Set<UUID>
    let onAssignSpeakers: (
        [HomeMeetingSpeakerAssignment],
        @escaping (Bool) -> Void
    ) -> Void

    var body: some View {
        // Same spacing the rows had as direct children of the expansion's
        // transcript VStack.
        LazyVStack(alignment: .leading, spacing: 9) {
            ForEach(visibleIndices, id: \.self) { index in
                transcriptLine(lines[index], index: index)
            }
        }
    }

    private var visibleIndices: Range<Int> {
        guard let lineLimit else { return lines.indices }
        return lines.indices.prefix(lineLimit)
    }

    private func transcriptLine(_ line: HomeMeetingTranscriptLine, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if !line.time.isEmpty {
                if let audio, let startSeconds = line.startSeconds {
                    QuietTranscriptTimestamp(time: line.time, index: index) {
                        MeetingAudioPlayback.shared.play(
                            audio,
                            from: startSeconds,
                            rowSourceStem: line.identity.channel.map(Self.retainedAudioStem(for:))
                        )
                    }
                } else {
                    Text(line.time)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LibraryTokens.ink3)
                        .frame(width: 52, alignment: .leading)
                }
            }
            if !line.speaker.isEmpty {
                QuietMeetingSpeakerLabel(
                    identity: line.identity,
                    knownPeople: knownPeople,
                    isSavedPerson: identityIsSaved(line.identity),
                    onAssign: { assignment, completion in
                        onAssignSpeakers([assignment], completion)
                    }
                )
            }
            Text(line.text)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.9))
                .textSelection(.enabled)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
    }

    /// Retained-audio file stem that holds a channel's speech.
    private static func retainedAudioStem(for channel: HomeMeetingSpeakerChannel) -> String {
        switch channel {
        case .mic: return "microphone"
        case .system: return "system_audio"
        }
    }

    private func identityIsSaved(_ identity: HomeMeetingSpeakerIdentity) -> Bool {
        identity.persistentSpeakerID.map(savedSpeakerIDs.contains) ?? false
    }
}

/// A transcript row's clock time, shown only when the meeting kept its audio.
/// Clicking it plays the meeting from that moment.
private struct QuietTranscriptTimestamp: View {
    let time: String
    let index: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(time)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isHovering ? LibraryTokens.accent : LibraryTokens.ink3)
                .underline(isHovering)
                .frame(width: 52, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Play from \(time)")
        .accessibilityLabel(Text("Play from \(time)"))
        .accessibilityIdentifier("transcripted.home.expansion.timestamp.\(index)")
    }
}

/// Prominent speaker identity used by every transcript line. It is a real
/// single-click button: the popover stages an edit and only writes on Save.
private struct QuietMeetingSpeakerLabel: View {
    let identity: HomeMeetingSpeakerIdentity
    let knownPeople: [SpeakerNameChoice]
    let isSavedPerson: Bool
    let onAssign: (HomeMeetingSpeakerAssignment, @escaping (Bool) -> Void) -> Void

    @State private var showsPicker = false
    @State private var isHovering = false

    private var canRename: Bool {
        !identity.displayName.isEmpty && identity.rawLabel != "Speaker"
    }

    var body: some View {
        Button {
            guard canRename else { return }
            showsPicker = true
        } label: {
            HStack(spacing: 4) {
                Text(identity.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(speakerColor)
                    .underline(isHovering || showsPicker, color: speakerColor.opacity(0.72))
                    .lineLimit(1)
                if canRename {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(speakerColor.opacity(0.75))
                        .opacity((isHovering || showsPicker) ? 1 : 0.34)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canRename)
        .onHover { isHovering = $0 }
        .contextMenu {
            if canRename {
                Button("Rename Speaker…") { showsPicker = true }
            }
        }
        .accessibilityLabel("Speaker: \(identity.displayName)")
        .accessibilityHint(canRename ? "Assign or correct this person" : "")
        .accessibilityAction(named: "Rename speaker") { showsPicker = true }
        .help(canRename ? "Assign or correct \(identity.displayName)" : "")
        .accessibilityIdentifier("transcripted.home.expansion.speaker.\(identity.stableID)")
        .frame(width: 116, alignment: .leading)
        .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
            HomeMeetingSpeakerPicker(
                identity: identity,
                knownPeople: knownPeople.filter { $0.id != identity.persistentSpeakerID },
                isSavedPerson: isSavedPerson,
                onCancel: { showsPicker = false },
                onSave: { assignment, completion in
                    onAssign(assignment) { didSave in
                        if didSave { showsPicker = false }
                        completion(didSave)
                    }
                }
            )
        }
    }

    private var speakerColor: Color {
        if identity.displayName == "You" { return LibraryTokens.accent }
        return HomeMeetingSpeakerColor.color(for: identity.stableID)
    }
}

private struct HomeMeetingSpeakerPicker: View {
    let identity: HomeMeetingSpeakerIdentity
    let knownPeople: [SpeakerNameChoice]
    let isSavedPerson: Bool
    let onCancel: () -> Void
    let onSave: (HomeMeetingSpeakerAssignment, @escaping (Bool) -> Void) -> Void

    @State private var nameDraft: String
    @State private var selectedProfileID: UUID?
    @State private var isSaving = false
    @State private var saveFailed = false

    init(
        identity: HomeMeetingSpeakerIdentity,
        knownPeople: [SpeakerNameChoice],
        isSavedPerson: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping (HomeMeetingSpeakerAssignment, @escaping (Bool) -> Void) -> Void
    ) {
        self.identity = identity
        self.knownPeople = knownPeople
        self.isSavedPerson = isSavedPerson
        self.onCancel = onCancel
        self.onSave = onSave
        _nameDraft = State(initialValue: identity.displayName)
        _selectedProfileID = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Who is this?")
                    .font(.system(size: 15, weight: .semibold))
                Text(scopeMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LibraryTokens.ink2)
            }

            SpeakerNameAutocompleteField(
                text: $nameDraft,
                placeholder: "Type a name",
                options: knownPeople,
                selectedOptionID: $selectedProfileID,
                showAllWhenTextEquals: identity.displayName,
                accessibilityIdentifier: "transcripted.home.speaker-picker.name",
                autoFocus: true,
                onSubmit: save,
                onCancel: onCancel
            )
            .frame(height: 28)

            if saveFailed {
                Text("Couldn’t save that name. Nothing else was changed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LibraryTokens.attention)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("transcripted.home.speaker-picker.cancel")
                Button(isSaving ? "Saving…" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(assignment == nil || isSaving)
                    .accessibilityIdentifier("transcripted.home.speaker-picker.save")
            }
        }
        .padding(16)
        .frame(width: 340)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.home.speaker-picker")
        .onChange(of: nameDraft) { _, _ in saveFailed = false }
    }

    private var assignment: HomeMeetingSpeakerAssignment? {
        HomeMeetingSpeakerNamingPolicy.assignment(from: HomeMeetingSpeakerNamingDraft(
            identity: identity,
            sampleTexts: [],
            name: nameDraft,
            selectedProfileID: selectedProfileID
        ))
    }

    private var scopeMessage: String {
        if isSavedPerson {
            return selectedProfileID == nil
                ? "Renames this saved person in linked meetings."
                : "Uses this saved person in linked meetings."
        }
        return selectedProfileID == nil
            ? "Updates this meeting only."
            : "Links this voice to the saved person."
    }

    private func save() {
        guard let assignment, !isSaving else { return }
        isSaving = true
        saveFailed = false
        onSave(assignment) { didSave in
            isSaving = false
            saveFailed = !didSave
        }
    }
}
