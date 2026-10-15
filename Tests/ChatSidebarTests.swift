import ApplicationServices

// Which sidebar row is the open thread's (ChatSidebar.currentRow).

func testChatSidebar() {
    let element = AXUIElementCreateApplication(getpid())
    func row(_ label: String, current: Bool, underProject: Bool) -> ChatSidebar.Row {
        .init(element: element, label: label, frame: .zero, isCurrent: current, isUnderProject: underProject)
    }

    runSuite("A Codex thread just started, marked current twice, keeps to its row under the project") {
        // Recent rows are read first: they sit higher in the tree.
        let sidebar = ChatSidebar(rows: [
            row("Подтвердить проверку Transcripted", current: true, underProject: false),
            row("Исследовать баг CD-273310\ndailyrent-search-frontend", current: false, underProject: true),
            row("Подтвердить проверку Transcripted\ndailyrent-search-frontend", current: true, underProject: true),
        ], visible: .zero, rowBadgeWidth: 33)
        assertEqual(sidebar.currentRow?.label, "Подтвердить проверку Transcripted\ndailyrent-search-frontend", "the project's row")
    }

    runSuite("The one row marked current is the open thread's, wherever it's listed") {
        let fromRecent = ChatSidebar(rows: [
            row("Реализовать пагинацию мультипинов", current: true, underProject: false),
            row("Реализовать пагинацию мультипинов\ndailyrent-search-frontend", current: false, underProject: true),
        ], visible: .zero, rowBadgeWidth: 33)
        assertEqual(fromRecent.currentRow?.label, "Реализовать пагинацию мультипинов", "opened from Recent: the Recent row")
        let t3 = ChatSidebar(rows: [
            row("GVR\ndailyrent-search-frontend", current: false, underProject: false),
            row("🚨 Алерты\nNo project", current: true, underProject: false),
        ], visible: .zero, rowBadgeWidth: 26)
        assertEqual(t3.currentRow?.label, "🚨 Алерты\nNo project", "T3 Code marks one row")
        let none = ChatSidebar(rows: [row("Найти причину сбоев macOS", current: false, underProject: false)], visible: .zero, rowBadgeWidth: 33)
        assertNil(none.currentRow, "opened by search: no row to learn")
    }
}
