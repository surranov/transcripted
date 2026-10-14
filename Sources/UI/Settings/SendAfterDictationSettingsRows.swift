import SwiftUI

/// Fork: Settings → Send after dictation (`DictationSendSettings`). One
/// select, Default, says what a dictation does once its words land, in every
/// app. The rows its choice needs sit indented under it: the send key while
/// anything sends, the Dictate & send key and the confirm key and wait while
/// anything uses them. Below, an app may pick its own behavior instead.
struct SendAfterDictationSettingsRows: View {
    struct App: Identifiable, Equatable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// Running apps, offered so one can get its own behavior with one pick.
    let runningApps: [App]
    let displayName: (String) -> String
    let dictationShortcutsEnabled: Bool
    @ObservedObject var recorder: ShortcutRecorderModel
    let onRefreshApps: () -> Void
    /// Opens the app picker; the chosen app's bundle id, nil if cancelled.
    let onChooseApp: () -> String?
    let onTrackAction: (String) -> Void

    @State private var defaultBehavior = DictationSendSettings.defaultBehavior()
    @State private var overrides = DictationSendSettings.overrides()
    /// Apps added with Add… that are still on Default, so they stay listed.
    @State private var addedApps: Set<String> = []
    @State private var sendKey = DictationAutoSendPreferences.sendKey()
    @State private var confirmKey = DictationAutoSendPreferences.confirmKey()
    @State private var confirmSeconds = DictationAutoSendPreferences.confirmSeconds()
    @AppStorage(AnchoredPastePreferences.enabledKey)
    private var anchoredPasteEnabled = false

    /// How far the rows that belong to Default sit in from the card's edge.
    private static let nestedIndent: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            defaultRow
            VStack(alignment: .leading, spacing: 0) {
                nestedRows
            }
            .padding(.leading, Self.nestedIndent)
            overridesHeader
            appRows
        }
        .onChange(of: inUse.contains(.withDictateAndSendKey)) { _, used in
            // Its key row just hid; don't keep listening for that key.
            if !used, recorder.recordingTarget == .dictateAndSend {
                recorder.stopRecording()
            }
        }
    }

    // MARK: - Default

    private var defaultRow: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                GeneralTitleLabel(
                    title: "Default",
                    info: GeneralInfo(
                        title: "Default",
                        message: "What every dictation does once its words are pasted, in every app that doesn't have its own choice under Per-app overrides. Send: presses the send key. With Dictate & send key: only a dictation you start with that key sends; the dictation key just pastes. After I confirm: the island asks, and the confirm key from any app, or Send on the island, presses send in the box the words went into. With Anchored paste on, send is only ever pressed in the box the dictation started in, even in a window in the background; if you've moved to another box the island says it wasn't sent."
                    )
                )
                Text(defaultBehavior.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            Picker("Default", selection: Binding(
                get: { defaultBehavior },
                set: { behavior in
                    defaultBehavior = behavior
                    DictationSendSettings.setDefaultBehavior(behavior)
                    onTrackAction("change_send_default_\(behavior.rawValue)")
                }
            )) {
                ForEach(DictationSendBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.settings.general.auto-send")
    }

    /// The behaviors Default and the apps use right now.
    private var inUse: Set<DictationSendBehavior> {
        Set(overrides.values).union([defaultBehavior])
    }

    @ViewBuilder
    private var nestedRows: some View {
        if inUse.contains(where: { $0 != .dontSend }) {
            SettingsControlRow(
                title: "Send key",
                info: GeneralInfo(
                    title: "Send key",
                    message: "The key pressed to send, in every app that sends. Most chats send with Enter; pick ⌘ Enter for apps where Enter starts a new line."
                ),
                automationIdentifier: "transcripted.settings.general.send-key"
            ) {
                Picker("Send key", selection: Binding(
                    get: { sendKey },
                    set: { key in
                        sendKey = key
                        DictationAutoSendPreferences.setSendKey(key)
                        onTrackAction("change_auto_send_key")
                    }
                )) {
                    ForEach(DictationAutoSendKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }

        if inUse.contains(.withDictateAndSendKey) {
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

        if inUse.contains(.afterConfirm) {
            confirmRows
        }
    }

    /// Confirm key and wait, plus why confirming can't work without Anchored paste.
    @ViewBuilder
    private var confirmRows: some View {
        if !anchoredPasteEnabled {
            HStack(alignment: .top, spacing: 8) {
                warning("After I confirm needs Anchored paste, so send knows which box the words went into. Until then nothing is sent.")
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

    // MARK: - Per-app overrides

    private var overridesHeader: some View {
        SettingsControlRow(
            title: "Per-app overrides",
            info: GeneralInfo(
                title: "Per-app overrides",
                message: "An app here does what you pick for it instead of Default. Running apps are listed so you can pick one quickly; use Add for an app that isn't open."
            ),
            automationIdentifier: "transcripted.settings.general.send-overrides",
            showsDivider: !listedApps.isEmpty
        ) {
            HStack(spacing: 8) {
                SettingsInlineActionButton(title: "Refresh") {
                    onTrackAction("refresh_auto_send_apps")
                    onRefreshApps()
                }
                SettingsInlineActionButton(title: "Add…", symbolName: "plus") {
                    onTrackAction("add_auto_send_app")
                    if let bundleID = onChooseApp() {
                        addedApps.insert(bundleID)
                    }
                }
            }
        }
    }

    /// Apps with their own behavior first, then the running ones and any
    /// just added, each group by name.
    private var listedApps: [App] {
        var ids = Set(overrides.keys).union(addedApps)
        ids.formUnion(runningApps.map(\.bundleID))
        let names = Dictionary(runningApps.map { ($0.bundleID, $0.name) }, uniquingKeysWith: { first, _ in first })
        return ids
            .map { App(bundleID: $0, name: names[$0] ?? displayName($0)) }
            .sorted { lhs, rhs in
                let lhsOwn = overrides[lhs.bundleID] != nil, rhsOwn = overrides[rhs.bundleID] != nil
                if lhsOwn != rhsOwn { return lhsOwn }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    @ViewBuilder
    private var appRows: some View {
        let apps = listedApps
        ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
            SettingsControlRow(title: app.name, showsDivider: index < apps.count - 1) {
                Picker(app.name, selection: Binding<DictationSendBehavior?>(
                    get: { overrides[app.bundleID] },
                    set: { behavior in
                        overrides[app.bundleID] = behavior
                        DictationSendSettings.setOverride(behavior, for: app.bundleID)
                        onTrackAction("change_send_app_behavior_\(behavior?.rawValue ?? "default")")
                    }
                )) {
                    Text("Default (\(defaultBehavior.title))").tag(DictationSendBehavior?.none)
                    Divider()
                    ForEach(DictationSendBehavior.allCases) { behavior in
                        Text(behavior.title).tag(DictationSendBehavior?.some(behavior))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
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
