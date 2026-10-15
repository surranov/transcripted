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
    }

    let rows: [Row]
    /// Where rows can be seen: the sidebar's scrolled area, same coordinates.
    let visible: CGRect

    var currentRow: Row? { rows.first(where: \.isCurrent) }
}

enum ChatSidebarReader {
    private static let messagingTimeout: Float = 0.3
    private static let rowClass = "group/sidebar-row"
    /// The landmark sits 5 or 6 deep in T3 Code's window, under its page;
    /// rows a few more inside it. Nothing inside a row or the thread is read.
    private static let landmarkSearchLimit = 400
    private static let landmarkMaxDepth = 12
    private static let rowSearchLimit = 600
    private static let rowMaxDepth = 6

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
        var scrollArea: CGRect?
        var queue: [(element: AXUIElement, depth: Int)] = [(landmark, 0)]
        var index = 0
        while index < queue.count, index < rowSearchLimit, Date() < deadline {
            let (node, depth) = queue[index]
            index += 1
            AXUIElementSetMessagingTimeout(node, messagingTimeout)
            if classes(of: node).contains(rowClass) {
                if let rowFrame = frame(of: node), let label = label(of: node) {
                    rows.append(.init(
                        element: node,
                        label: label,
                        frame: rowFrame,
                        isCurrent: string(of: node, "AXARIACurrent") == "page"
                    ))
                    if scrollArea == nil, let parent = element(of: node, kAXParentAttribute) {
                        scrollArea = frame(of: parent)
                    }
                }
                continue
            }
            guard depth < rowMaxDepth else { continue }
            queue += children(of: node).map { ($0, depth + 1) }
        }
        guard !rows.isEmpty else { return nil }
        let visible = (scrollArea ?? landmarkFrame).intersection(landmarkFrame)
        return ChatSidebar(rows: rows, visible: visible.isNull ? .zero : visible)
    }

    /// "Title\nProject" from the row's texts; its accessible label when
    /// those can't be read.
    private static func label(of row: AXUIElement) -> String? {
        let parts = children(of: row)
        let title = parts.first { string(of: $0, kAXRoleAttribute) == "AXStaticText" }.flatMap { string(of: $0, kAXValueAttribute) }
        let project = parts.first { string(of: $0, kAXRoleAttribute) == "AXGroup" }
            .flatMap { group in children(of: group).first { string(of: $0, kAXRoleAttribute) == "AXStaticText" } }
            .flatMap { string(of: $0, kAXValueAttribute) }
        guard let title, !title.isEmpty else { return string(of: row, kAXDescriptionAttribute) }
        return [title, project].compactMap { $0 }.joined(separator: "\n")
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

    private static func element(of element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
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
