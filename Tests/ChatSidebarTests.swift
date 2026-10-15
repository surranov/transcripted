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

    runSuite("A Claude Code session's row, which nothing marks, is the one named as the open page") {
        // Claude 2.42304.0's Code sessions, read 2026-10-15.
        let labels = ["CD-290518 Просмотренность", "Отключение атрибуции в настройках", "Второй экземпляр приложения"]
        let unmarked = [false, false, false]
        assertEqual(
            ChatSidebar.currentRows(marked: unmarked, labels: labels, openThreadName: "Отключение атрибуции в настройках"),
            [false, true, false],
            "the one row with the open session's name"
        )
        assertEqual(
            ChatSidebar.currentRows(marked: unmarked + [false], labels: labels + ["Второй экземпляр приложения"], openThreadName: "Второй экземпляр приложения"),
            [false, false, false, false],
            "two sessions share the name: neither is taken for it"
        )
        assertEqual(ChatSidebar.currentRows(marked: unmarked, labels: labels, openThreadName: "Без названия"), unmarked, "not listed (scrolled out, or under Show more)")
        assertEqual(ChatSidebar.currentRows(marked: unmarked, labels: labels, openThreadName: nil), unmarked, "no name to go by: Code's start page")
        assertEqual(
            ChatSidebar.currentRows(marked: [false, false, true], labels: labels, openThreadName: "Отключение атрибуции в настройках"),
            [false, false, true],
            "a row the app marks (a chat's) wins over a name"
        )
    }
}
