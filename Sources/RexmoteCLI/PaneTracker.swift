import AppKit
import RexmoteCore

/// WindowServer reports presentation bounds during a Space transition. Only a
/// settled rectangle, or a window the user is dragging, is a new layout.
struct WindowAnchor {
    private var sample: CGRect?
    private(set) var changedAt: TimeInterval = 0

    mutating func accepts(_ frame: CGRect, now: TimeInterval, dragging: Bool, panelIsAnimating: Bool = false) -> Bool {
        if panelIsAnimating {
            sample = nil
            changedAt = now
            return false
        }
        if sample != frame {
            sample = frame
            changedAt = now
        }
        return dragging || now - changedAt >= 0.08
    }

    // Both rectangles are in WindowServer coordinates. AppKit keeps the panel's logical
    // frame during a Spaces animation; the compositor can translate or scale its surface.
    static func isAnimating(panel: CGRect, presented: CGRect) -> Bool {
        abs(panel.minX - presented.minX) > 1 || abs(panel.minY - presented.minY) > 1
            || abs(panel.width - presented.width) > 1 || abs(panel.height - presented.height) > 1
    }

    static func parent(remembered: Int?, named: [Int], visible: [Int]) -> Int? {
        if let remembered { return visible.contains(remembered) ? remembered : nil }
        if named.count == 1 { return named[0] }
        return visible.count == 1 ? visible[0] : nil
    }
}

/// Window titles may be hidden by macOS. Pair Rex's front window with its selected session
/// after two matching preference reads, just as rexweb does when several windows are open.
struct RexWindowBindings {
    private var learned: [Int: RemoteSession] = [:]
    private var candidate: (window: Int, session: RemoteSession?)?

    mutating func observe(front: Int?, session: RemoteSession?) {
        guard let front else {
            candidate = nil
            return
        }
        if learned[front] != session {
            learned.removeValue(forKey: front)
            if let session, candidate?.window == front, candidate?.session == session {
                learned = learned.filter { $0.value != session }
                learned[front] = session
            }
        }
        candidate = (front, session)
    }

    mutating func retain(_ windows: Set<Int>) { learned = learned.filter { windows.contains($0.key) } }

    func parent(for scope: RemoteSession, selected: Bool, remembered: Int?, named: [Int], visible: [Int]) -> Int? {
        // A live parent in another Space must never be replaced by an apparent match here.
        if let remembered, !visible.contains(remembered) { return nil }
        let candidates = visible.filter { id in
            if candidate?.window == id, candidate?.session != scope { return false }
            if let owner = learned[id] { return owner == scope }
            return selected
        }
        if let confirmed = candidates.first(where: { learned[$0] == scope }) { return confirmed }
        if let remembered, candidates.contains(remembered) { return remembered }
        guard selected else { return nil }
        if let candidate, candidate.session == scope, !candidates.contains(candidate.window) { return nil }
        return WindowAnchor.parent(remembered: nil, named: named.filter(candidates.contains), visible: candidates)
    }
}

extension PaneChrome {
    func corners(floating: Bool) -> CACornerMask {
        let bottom: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        return (floating ? floatHeader : header) > 0 ? bottom : bottom.union([.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
    }
}

@MainActor final class PaneTracker: NSObject {
    static let shared = PaneTracker()

    struct Position {
        let frame: CGRect
        let radius: CGFloat
        let corners: CACornerMask
        let parent: Int
        let selected: Bool
        let rexActive: Bool
        let stacked: Bool
    }

    private struct Window {
        let id: Int
        let owner: pid_t
        let title: String
        let frame: CGRect

        init?(_ values: [String: Any]) {
            guard values[kCGWindowLayer as String] as? Int == 0,
                let id = values[kCGWindowNumber as String] as? Int,
                let owner = values[kCGWindowOwnerPID as String] as? pid_t,
                let bounds = values[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            self.id = id
            self.owner = owner
            self.frame = frame
            title = values[kCGWindowName as String] as? String ?? ""
        }
    }

    private final class Session {
        let scope: RemoteSession
        let rex: RexCommand
        var focusedBlock: String?
        var parent: Int?
        var label = ""
        var refreshing = false
        var nextRefresh: TimeInterval = 0
        var lastLayoutAt: TimeInterval = 0
        var placements: [String: PanePlacement] = [:]

        init(scope: RemoteSession, rex: RexCommand) {
            self.scope = scope
            self.rex = rex
        }
    }

    private struct Pane {
        let session: Session
        let number: Int
        let place: (Position?) -> Void
    }

    private var panes: [String: Pane] = [:]
    private var anchors: [Int: WindowAnchor] = [:]
    private var timer: Timer?
    private var settleUntil: TimeInterval = 0
    private var chrome = PaneChrome(preference: { _ in nil })
    private var nextPreferences: TimeInterval = 0
    private var selectedSession: (UUID, String)?
    private var bindings = RexWindowBindings()

    nonisolated static func preference(_ key: String) -> Any? {
        CFPreferencesCopyAppValue("Workspace.\(key)" as CFString, "com.superlogical.rex" as CFString)
    }

    override init() {
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self, selector: #selector(activationChanged), name: NSWorkspace.didActivateApplicationNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    func add(block: String, scope: RemoteSession, rex: RexCommand, number: Int, place: @escaping (Position?) -> Void) {
        let session = panes.values.first { $0.session.scope == scope }?.session ?? Session(scope: scope, rex: rex)
        session.nextRefresh = 0
        panes[block] = Pane(session: session, number: number, place: place)
        activationChanged()
    }

    func remove(_ block: String) {
        panes.removeValue(forKey: block)
        if panes.isEmpty { stopTracking() }
    }

    @objc private func spaceChanged() {
        anchors.removeAll()
        settleUntil = ProcessInfo.processInfo.systemUptime + 0.16
        for pane in panes.values { pane.place(nil) }
        activationChanged()
    }

    @objc private func activationChanged() {
        guard !panes.isEmpty else { return }
        bindings.observe(front: nil, session: nil)
        nextPreferences = 0
        schedule(every: 1 / 24)
        tick()
    }

    private func stopTracking() {
        timer?.invalidate()
        timer = nil
        anchors.removeAll()
        bindings = RexWindowBindings()
    }

    private func schedule(every interval: TimeInterval) {
        if timer?.timeInterval == interval { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh(_ session: Session, at now: TimeInterval) {
        guard !session.refreshing, now >= session.nextRefresh else { return }
        session.refreshing = true
        session.nextRefresh = now + 0.45
        let rex = session.rex
        let id = session.scope.session
        Task {
            let view = await Task.detached(priority: .utility) {
                try? rex.object(["session", "inspect", id, "--json"], quiet: true)
            }.value
            session.refreshing = false
            guard let view else {
                if ProcessInfo.processInfo.systemUptime - session.lastLayoutAt > 1.5 {
                    session.placements.removeAll()
                }
                return
            }
            session.lastLayoutAt = ProcessInfo.processInfo.systemUptime
            session.placements.removeAll(keepingCapacity: true)
            session.label = view["label"] as? String ?? ""
            let active = PanePlacement.activeWindow(in: view)
            session.focusedBlock = active?["focused_block_id"] as? String
            for (block, pane) in panes where pane.session === session {
                session.placements[block] = active.flatMap { PanePlacement.locate(block: block, inWindow: $0) }
            }

        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= settleUntil, let screen = NSScreen.screens.first,
            let front = NSWorkspace.shared.frontmostApplication
        else { return }
        let rexActive = front.bundleIdentifier == RexCommand.bundleID
        let rexPID = rexActive ? front.processIdentifier : RexCommand.localApp?.processIdentifier
        let info =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windows = info.compactMap(Window.init)
        let parents = windows.filter { $0.owner == rexPID && $0.frame.width > 60 && $0.frame.height > 60 }
        let parentIDs = parents.map(\.id)
        let ids = Set(parentIDs)
        anchors = anchors.filter { ids.contains($0.key) }
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let animating = Set(panes.values.compactMap { pane -> Int? in
            guard let parent = pane.session.parent, let presented = byID[pane.number]?.frame,
                let panel = NSApp.window(withWindowNumber: pane.number), panel.isVisible
            else { return nil }
            let frame = panel.frame
            let model = CGRect(x: frame.minX, y: screen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
            return WindowAnchor.isAnimating(panel: model, presented: presented) ? parent : nil
        })
        var dragged: Int?
        if NSEvent.pressedMouseButtons & 1 != 0 {
            let mouse = NSEvent.mouseLocation
            let pointer = CGPoint(x: mouse.x, y: screen.frame.maxY - mouse.y)
            if let target = windows.first(where: { $0.frame.contains(pointer) }), ids.contains(target.id) {
                dragged = target.id
            }
        }
        let settled = Set(
            parents.filter {
                anchors[$0.id, default: WindowAnchor()].accepts(
                    $0.frame, now: now, dragging: dragged == $0.id, panelIsAnimating: animating.contains($0.id))
            }
                .map(\.id))
        if parents.isEmpty {
            schedule(every: 0.5)
        } else if dragged != nil || anchors.values.contains(where: { now - $0.changedAt < 0.3 }) {
            schedule(every: 1 / 24)
        } else if !rexActive && front.processIdentifier != getpid() {
            schedule(every: 0.25)
        } else {
            schedule(every: 0.12)
        }
        if now >= nextPreferences {
            nextPreferences = now + 0.2
            CFPreferencesAppSynchronize(RexCommand.bundleID as CFString)
            chrome = PaneChrome(preference: Self.preference)
            selectedSession = RemoteSession.selection(Self.preference("lastFocusedSession") as? Data)
            let selected = panes.values.first { $0.session.scope.matches(selectedSession) }?.session.scope
            bindings.observe(front: rexActive ? parentIDs.first : nil, session: selected)
            bindings.retain(ids.union(panes.values.compactMap { $0.session.parent }))
        }

        for (block, pane) in panes {
            let session = pane.session
            guard !parents.isEmpty else {
                pane.place(nil)
                continue
            }
            let selected = session.scope.matches(selectedSession)
            if selected { refresh(session, at: now) }
            let named = parents.filter {
                !session.label.isEmpty && ($0.title == session.label || $0.title.hasSuffix(" - " + session.label))
            }
            // Keep the same Rex window across Spaces even when another Rex window becomes visible.
            guard let id = bindings.parent(for: session.scope, selected: selected, remembered: session.parent,
                                           named: named.map(\.id), visible: parentIDs),
                let parent = byID[id]
            else {
                if let id = session.parent, !ids.contains(id),
                    (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(id)) as NSArray?)?.count == 0
                {
                    session.parent = nil
                }
                pane.place(nil)
                continue
            }
            if session.parent != parent.id {
                pane.place(nil)
                session.parent = parent.id
            }
            if !selected { refresh(session, at: now) }
            guard let layout = session.placements[block] else {
                pane.place(nil)
                continue
            }
            guard settled.contains(parent.id) else { continue }

            let body = chrome.body(layout, in: parent.frame)
            guard !body.isNull, body.width > 20, body.height > 20 else {
                pane.place(nil)
                continue
            }
            let frame = CGRect(x: body.minX, y: screen.frame.maxY - body.maxY, width: body.width, height: body.height)
            let stacked: Bool
            if let panelIndex = windows.firstIndex(where: { $0.id == pane.number }),
                let parentIndex = windows.firstIndex(where: { $0.id == parent.id }), panelIndex < parentIndex
            {
                stacked = windows[(panelIndex + 1)..<parentIndex].allSatisfy { $0.owner == getpid() }
            } else {
                stacked = false
            }
            pane.place(
                Position(
                    frame: frame, radius: layout.floating ? 10 : chrome.radius,
                    corners: chrome.corners(floating: layout.floating), parent: parent.id,
                    selected: session.focusedBlock == block, rexActive: selected && rexActive && parent.id == parentIDs.first,
                    stacked: stacked))
        }
    }
}
