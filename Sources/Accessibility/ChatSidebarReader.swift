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

    let rows: [Row]
    /// Where rows can be seen: the sidebar's scrolled area, same coordinates.
    let visible: CGRect
    /// What the app draws at a row's right end (T3 Code's agent badge, Codex's
    /// unread dot or status), with its margin: the flags sit to its left.
    let rowBadgeWidth: CGFloat

    /// The open thread's row. Of two (a Codex thread just started), the one
    /// under its project: its label tells it from same-named threads.
    var currentRow: Row? {
        rows.first { $0.isCurrent && $0.isUnderProject } ?? rows.first(where: \.isCurrent)
    }
}

enum ChatSidebarReader {
    private static let messagingTimeout: Float = 0.3
    /// The landmark sits 5 or 6 deep in T3 Code's window and 15 in Codex's,
    /// under the page; rows up to 6 (T3 Code) or 11 (Codex, under a project)
    /// more inside it. Nothing inside a row or the thread is read.
    private static let landmarkSearchLimit = 400
    private static let landmarkMaxDepth = 17
    private static let rowSearchLimit = 600
    private static let rowMaxDepth = 12

    /// The sidebars read here, told apart by their rows' classes.
    private enum Style {
        case t3Code
        case codex

        init?(classes: [String]) {
            if classes.contains("group/sidebar-row") {
                self = .t3Code
            } else if classes.contains("data-[app-action-sidebar-thread-selected=true]:bg-primary-ghost-hover") {
                self = .codex
            } else {
                return nil
            }
        }

        /// T3 Code's agent badge: 20 pt wide, 6 pt from the edges. Codex's dot
        /// or status: 25 pt wide, 10 pt from the edge, so 29 past the flags'
        /// corner inset, plus a 4 pt gap.
        var rowBadgeWidth: CGFloat {
            switch self {
            case .t3Code: 26
            case .codex: 33
            }
        }
    }

    /// The whole read stops here with what it found: a busy app answers
    /// each call only at its timeout.
    private static let readDeadline: TimeInterval = 0.5

    /// The sidebar in `window`; nil when none shows (hidden, or not read).
    /// `landmark`: the one found last time, tried first. Returns the landmark
    /// the rows were found in, to pass next time. Call off the main actor.
    static func read(window: AXUIElement, landmark known: AXUIElement?) -> (sidebar: ChatSidebar?, landmark: AXUIElement?) {
        let deadline = Date().addingTimeInterval(readDeadline)
        if let known, let sidebar = rows(in: known, deadline: deadline) { return (sidebar, known) }
        // The thread list is the landmark that holds rows: an app may have
        // another navigation landmark before it.
        for landmark in navigationLandmarks(in: window, deadline: deadline) {
            if let sidebar = rows(in: landmark, deadline: deadline) { return (sidebar, landmark) }
        }
        return (nil, nil)
    }

    private static func rows(in landmark: AXUIElement, deadline: Date) -> ChatSidebar? {
        AXUIElementSetMessagingTimeout(landmark, messagingTimeout)
        guard let landmarkFrame = frame(of: landmark) else { return nil }
        var rows: [ChatSidebar.Row] = []
        var style: Style?
        var scrollArea: CGRect?
        // Each element with the scrolling group and the Codex project it's in.
        var queue: [(element: AXUIElement, depth: Int, scrollArea: CGRect?, project: String?)] = [(landmark, 0, nil, nil)]
        var index = 0
        while index < queue.count, index < rowSearchLimit, Date() < deadline {
            let (node, depth, nodeScrollArea, project) = queue[index]
            index += 1
            AXUIElementSetMessagingTimeout(node, messagingTimeout)
            let nodeClasses = classes(of: node)
            if let rowStyle = Style(classes: nodeClasses) {
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
            queue += children(of: node).map { ($0, depth + 1, innerScrollArea, innerProject) }
        }
        guard !rows.isEmpty, let style else { return nil }
        let visible = (scrollArea ?? landmarkFrame).intersection(landmarkFrame)
        return ChatSidebar(rows: rows, visible: visible.isNull ? .zero : visible, rowBadgeWidth: style.rowBadgeWidth)
    }

    /// T3 Code: "Title\nProject" from the row's texts; its accessible label
    /// when those can't be read. Codex: "Name\nProject" from its accessible
    /// label and the project it's listed under; the name alone in Recent.
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
        }
    }

    private static func navigationLandmarks(in window: AXUIElement, deadline: Date) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var index = 0
        while index < queue.count, index < landmarkSearchLimit, Date() < deadline {
            let (node, depth) = queue[index]
            index += 1
            if index > 1 { AXUIElementSetMessagingTimeout(node, messagingTimeout) }
            if string(of: node, kAXSubroleAttribute) == "AXLandmarkNavigation" {
                found.append(node)
                continue
            }
            guard depth < landmarkMaxDepth else { continue }
            queue += children(of: node).map { ($0, depth + 1) }
        }
        return found
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
