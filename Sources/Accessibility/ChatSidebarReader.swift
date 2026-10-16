import ApplicationServices

/// Fork: the thread rows of a chat app's sidebar (`ChatThreadPolicy.sidebarBundleIDs`),
/// where an Anchored paste marker sits while another thread is open.
///
/// T3 Code, measured on 2026-10-15 (macOS 26):
/// - The sidebar is a navigation landmark ("Threads").
/// - Its rows are buttons with the DOM class `group/sidebar-row`. No thread
///   id is exposed. A row's accessible label is "Title, Status, Project",
///   and its status changes as the agent works (Working, Done), so a row is
///   told by its title text (its first text) and its project (the first text
///   of the group under it).
/// - The open thread's row has `aria-current="page"`.
/// - The rows scroll inside their parent (class `overflow-auto`).
/// - The list is virtualized: rows far from view aren't in the tree.
/// - The agent's badge sits in a row's bottom-right corner.
///
/// Codex (the ChatGPT app 26.924), measured on 2026-10-15:
/// - The thread list is the second navigation landmark, 15 deep in the
///   window; the first, the app's rail, has no rows.
/// - A thread row is a button with the DOM class
///   `data-[app-action-sidebar-thread-selected=true]:bg-primary-ghost-hover`
///   (a project's own row and New chat lack it). Its accessible label is the
///   thread's name, the open thread's page title too; an unread mark is a
///   hidden text of its own. No thread id is exposed.
/// - A thread shows twice: under its project in Projects (in a group with
///   the class `group/cwd`, titled after the project) and in Recent. A row
///   is told by its name and project, so the two read as different rows.
/// - The open thread's row has `aria-current="page"`: the row it was opened
///   from, both rows of a thread just started, none when it was opened
///   another way (search, back).
/// - The rows scroll inside a group a few levels up (class `overflow-y-auto`).
/// - The list isn't virtualized: rows out of view are in the tree, squeezed
///   to the list's edge (1 pt high, a row half in view cut to its part).
/// - An unread dot or the agent's status sits 10 to 35 pt from a row's
///   right edge, vertically centered; pin and archive buttons show there
///   on hover only.
///
/// Claude (2.42304.0), measured on 2026-10-15, alike for its Code sessions
/// and its chats:
/// - The sidebar is a complementary landmark ("Боковая панель" in Russian),
///   not a navigation one.
/// - A thread row is the button with the class `hit-row-main` inside a group
///   with the class `df-drag-shiftable` (the menu's own rows, New among them,
///   aren't in one). Its accessible label starts with its status ("Inactive")
///   in chats, so a row is told by its name, its first text (in the group
///   with the class `dframe-fade-label`). No thread id is exposed.
/// - A chat's row has `aria-current="page"` while it's open; a Code
///   session's row has nothing to tell it. The open page is titled
///   "<name> - Claude Code" (a chat's "<name> - Claude"), so the open
///   session's row is the one with that name (`ChatThreadPolicy.openThreadName`).
/// - The rows scroll inside a group with the class `overflow-y-auto`.
/// - A status (an alert, a spinner) and, on hover, an options button sit up
///   to 30 pt from a row's right edge.
///
/// Holds Accessibility elements read off the main actor; AX calls are thread-safe.
struct ChatSidebar: @unchecked Sendable {
    struct Row {
        let element: AXUIElement
        /// The title and project, which stay while the thread's status changes.
        let label: String
        /// Screen rectangle, Accessibility coordinates (top-left origin).
        let frame: CGRect
        let isCurrent: Bool
        /// Codex: listed under its project, which its label names.
        let isUnderProject: Bool
    }

    /// Which rows are the open thread's: those the app marks; when it marks
    /// none, the one row labeled `openThreadName` (a Claude Code session,
    /// `ChatThreadPolicy.openThreadName`), if only one is.
    static func currentRows(marked: [Bool], labels: [String], openThreadName: String?) -> [Bool] {
        guard !marked.contains(true), let openThreadName else { return marked }
        let named = labels.indices.filter { labels[$0] == openThreadName }
        return marked.indices.map { named.count == 1 && $0 == named[0] }
    }

    let rows: [Row]
    /// Where rows can be seen: the sidebar's scrolled area, same coordinates.
    let visible: CGRect
    /// What the app draws at a row's right end (T3 Code's agent badge, Codex's
    /// unread dot or status, Claude's status), with its margin: the flags sit
    /// to its left.
    let rowBadgeWidth: CGFloat

    /// The open thread's row. Of two (a Codex thread just started), the one
    /// under its project: its label tells it from same-named threads.
    var currentRow: Row? {
        rows.first { $0.isCurrent && $0.isUnderProject } ?? rows.first(where: \.isCurrent)
    }
}

enum ChatSidebarReader {
    private static let messagingTimeout: Float = 0.3
    /// The landmark sits 5 or 6 deep in T3 Code's window, 12 in Claude's and
    /// 15 in Codex's, under the page; rows up to 6 (T3 Code, Claude) or 11
    /// (Codex, under a project) more inside it. Nothing inside a row (but
    /// Claude's name) or the thread is read.
    private static let landmarkSearchLimit = 400
    private static let landmarkMaxDepth = 17
    private static let rowSearchLimit = 600
    private static let rowMaxDepth = 12

    /// The sidebars read here, told apart by their rows' classes.
    private enum Style {
        case t3Code
        case codex
        case claude

        /// `inThreadItem`: inside a group with the class `df-drag-shiftable`,
        /// where Claude keeps a thread's row.
        init?(classes: [String], inThreadItem: Bool) {
            if classes.contains("group/sidebar-row") {
                self = .t3Code
            } else if classes.contains("data-[app-action-sidebar-thread-selected=true]:bg-primary-ghost-hover") {
                self = .codex
            } else if inThreadItem, classes.contains("hit-row-main") {
                self = .claude
            } else {
                return nil
            }
        }

        /// T3 Code's agent badge: 20 pt wide, 6 pt from the edges. Codex's dot
        /// or status: 25 pt wide, 10 pt from the edge, so 29 past the flags'
        /// corner inset, plus a 4 pt gap. Claude's status and options: 30 pt
        /// from the edge, so 24 past the inset, plus the gap.
        var rowBadgeWidth: CGFloat {
            switch self {
            case .t3Code: 26
            case .codex: 33
            case .claude: 28
            }
        }
    }

    /// The whole read stops here with what it found: a busy app answers
    /// each call only at its timeout.
    private static let readDeadline: TimeInterval = 0.5

    /// Asks app `pid` for its full web accessibility tree, once a window is
    /// watched: what marks the open thread's row (`aria-current`) is only in
    /// it. Without `AXManualAccessibility`, which is off after every launch,
    /// an Electron app serves a partial tree (T3 Code relaunched by its
    /// update, measured 2026-10-16, Electron 44): pages, classes, labels and
    /// the focused field, so the page and composer reads never ask, but no
    /// `AXARIACurrent`, so no row read as the open thread's and no flag
    /// learned its row. The app keeps the full tree on until it quits. Call
    /// off the main actor.
    static func askForFullTree(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// The sidebar in `window`; nil when none shows (hidden, or not read).
    /// `landmark`: the one found last time, tried first. Returns the landmark
    /// the rows were found in, to pass next time. `openThreadName`: the open
    /// thread's name, for a sidebar that doesn't mark its row
    /// (`ChatSidebar.currentRows`). Call off the main actor.
    static func read(
        window: AXUIElement,
        landmark known: AXUIElement?,
        openThreadName: String? = nil
    ) -> (sidebar: ChatSidebar?, landmark: AXUIElement?) {
        let deadline = Date().addingTimeInterval(readDeadline)
        if let known, let sidebar = rows(in: known, openThreadName: openThreadName, deadline: deadline) { return (sidebar, known) }
        // The thread list is the landmark that holds rows: an app may have
        // another navigation landmark before it.
        for landmark in sidebarLandmarks(in: window, deadline: deadline) {
            if let sidebar = rows(in: landmark, openThreadName: openThreadName, deadline: deadline) { return (sidebar, landmark) }
        }
        return (nil, nil)
    }

    private static func rows(in landmark: AXUIElement, openThreadName: String?, deadline: Date) -> ChatSidebar? {
        AXUIElementSetMessagingTimeout(landmark, messagingTimeout)
        guard let landmarkFrame = frame(of: landmark) else { return nil }
        var rows: [ChatSidebar.Row] = []
        var style: Style?
        var scrollArea: CGRect?
        // Each element with the scrolling group and the Codex project it's
        // in, and whether it's inside a Claude thread's item.
        var queue: [(element: AXUIElement, depth: Int, scrollArea: CGRect?, project: String?, inThreadItem: Bool)] = [
            (landmark, 0, nil, nil, false),
        ]
        var index = 0
        while index < queue.count, index < rowSearchLimit, Date() < deadline {
            let (node, depth, nodeScrollArea, project, inThreadItem) = queue[index]
            index += 1
            AXUIElementSetMessagingTimeout(node, messagingTimeout)
            let nodeClasses = classes(of: node)
            if let rowStyle = Style(classes: nodeClasses, inThreadItem: inThreadItem) {
                if let rowFrame = frame(of: node), let label = label(of: node, style: rowStyle, project: project) {
                    rows.append(.init(
                        element: node,
                        label: label,
                        frame: rowFrame,
                        isCurrent: string(of: node, "AXARIACurrent") == "page",
                        isUnderProject: rowStyle == .codex && project != nil
                    ))
                    style = style ?? rowStyle
                    scrollArea = scrollArea ?? nodeScrollArea
                }
                continue
            }
            guard depth < rowMaxDepth else { continue }
            // The nearest scrolling group is where rows can be seen: the
            // rows' parent in T3 Code, a group a few levels up in Codex.
            let scrolls = nodeClasses.contains("overflow-auto") || nodeClasses.contains("overflow-y-auto")
            let innerScrollArea = scrolls ? frame(of: node) ?? nodeScrollArea : nodeScrollArea
            let innerProject = nodeClasses.contains("group/cwd") ? string(of: node, kAXTitleAttribute) ?? project : project
            let innerInThreadItem = inThreadItem || nodeClasses.contains("df-drag-shiftable")
            queue += children(of: node).map { ($0, depth + 1, innerScrollArea, innerProject, innerInThreadItem) }
        }
        guard !rows.isEmpty, let style else { return nil }
        let current = ChatSidebar.currentRows(marked: rows.map(\.isCurrent), labels: rows.map(\.label), openThreadName: openThreadName)
        let visible = (scrollArea ?? landmarkFrame).intersection(landmarkFrame)
        return ChatSidebar(
            rows: zip(rows, current).map { row, isCurrent in
                .init(element: row.element, label: row.label, frame: row.frame, isCurrent: isCurrent, isUnderProject: row.isUnderProject)
            },
            visible: visible.isNull ? .zero : visible,
            rowBadgeWidth: style.rowBadgeWidth
        )
    }

    /// T3 Code: "Title\nProject" from the row's texts; its accessible label
    /// when those can't be read. Codex: "Name\nProject" from its accessible
    /// label and the project it's listed under; the name alone in Recent.
    /// Claude: its name, the first text of its name group.
    private static func label(of row: AXUIElement, style: Style, project: String?) -> String? {
        switch style {
        case .t3Code:
            let parts = children(of: row)
            let title = parts.first { string(of: $0, kAXRoleAttribute) == "AXStaticText" }.flatMap { string(of: $0, kAXValueAttribute) }
            let project = parts.first { string(of: $0, kAXRoleAttribute) == "AXGroup" }
                .flatMap { group in children(of: group).first { string(of: $0, kAXRoleAttribute) == "AXStaticText" } }
                .flatMap { string(of: $0, kAXValueAttribute) }
            guard let title, !title.isEmpty else { return string(of: row, kAXDescriptionAttribute) }
            return [title, project].compactMap { $0 }.joined(separator: "\n")
        case .codex:
            guard let name = string(of: row, kAXDescriptionAttribute), !name.isEmpty else { return nil }
            return [name, project].compactMap { $0 }.joined(separator: "\n")
        case .claude:
            // Row > name group > text, a level deeper beside a status mark.
            var level = children(of: row)
            for _ in 0..<2 {
                if let group = level.first(where: { classes(of: $0).contains("dframe-fade-label") }) {
                    let text = children(of: group).first { string(of: $0, kAXRoleAttribute) == "AXStaticText" }
                    return text.flatMap { string(of: $0, kAXValueAttribute) }.flatMap { $0.isEmpty ? nil : $0 }
                }
                level = level.flatMap(children(of:))
            }
            return nil
        }
    }

    /// Navigation landmarks (T3 Code, Codex), then complementary ones
    /// (Claude's sidebar; Codex's holds its navigation landmarks, so it's
    /// searched inside too).
    private static func sidebarLandmarks(in window: AXUIElement, deadline: Date) -> [AXUIElement] {
        var navigation: [AXUIElement] = []
        var complementary: [AXUIElement] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var index = 0
        while index < queue.count, index < landmarkSearchLimit, Date() < deadline {
            let (node, depth) = queue[index]
            index += 1
            if index > 1 { AXUIElementSetMessagingTimeout(node, messagingTimeout) }
            switch string(of: node, kAXSubroleAttribute) {
            case "AXLandmarkNavigation":
                navigation.append(node)
                continue
            case "AXLandmarkComplementary":
                complementary.append(node)
            default:
                break
            }
            guard depth < landmarkMaxDepth else { continue }
            queue += children(of: node).map { ($0, depth + 1) }
        }
        return navigation + complementary
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func classes(of element: AXUIElement) -> [String] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &value) == .success else { return [] }
        return value as? [String] ?? []
    }

    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: AnyObject?
        var size: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }
}
