import SwiftUI

/// The version switch on an expanded Dictations card (fork): one control with
/// a segment per text (`DictationVersionTabs`), and a selection that slides to
/// the picked segment.
///
/// Not `Picker(.segmented)`: on macOS 26 its NSSegmentedControl jumps between
/// segments without the slide (checked on 26.2, clicked and set in code). It
/// still stands in for this control in the accessibility tree, so VoiceOver
/// reads and changes it like the native one.
struct DictationVersionPicker: View {
    let tabs: [DictationVersionTabs.Tab]
    @Binding var selection: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionSpace

    var body: some View {
        // A long history (several Transcribe again runs) scrolls sideways
        // instead of pushing the card wider.
        ScrollView(.horizontal) {
            segments
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityRepresentation {
            Picker("Version", selection: $selection) {
                ForEach(tabs) { tab in
                    Text(tab.title).tag(tab.id)
                }
            }
            .pickerStyle(.segmented)
        }
        .accessibilityIdentifier("transcripted.dictations.row.versions")
    }

    private var segments: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                segment(tab)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl + 2, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .fixedSize()
    }

    private func segment(_ tab: DictationVersionTabs.Tab) -> some View {
        let isSelected = tab.id == selection
        return Button {
            guard !isSelected else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                selection = tab.id
            }
        } label: {
            Text(tab.title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.primary : LibraryTokens.ink2)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            .matchedGeometryEffect(id: "selection", in: selectionSpace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
