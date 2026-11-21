import AppKit
import RexmoteCore

/// WindowServer reports presentation bounds during a Space transition. Only a
/// settled rectangle, or a window the user is dragging, is a new layout.
struct WindowAnchor {
    private var sample: CGRect?
    private(set) var changedAt: TimeInterval = 0

    mutating func accepts(_ frame: CGRect, now: TimeInterval, dragging: Bool) -> Bool {
        if sample != frame {
            sample = frame
            changedAt = now
        }
        return dragging || now - changedAt >= 0.08
    }
}

@MainActor final class PaneTracker: NSObject {
    static let shared = PaneTracker()

    struct Position {
        let frame: CGRect
        let radius: CGFloat
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
        let app = NSWorkspace.shared.frontmostApplication
        guard !panes.isEmpty, app?.bundleIdentifier == RexCommand.bundleID || app?.processIdentifier == getpid() else {
            stopTracking()
            for pane in panes.values { pane.place(nil) }
            return
        }
        nextPreferences = 0
        schedule(every: 1 / 24)
        tick()
    }

    private func stopTracking() {
        timer?.invalidate()
        timer = nil
        anchors.removeAll()
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
            session.placements.removeAll(keepingCapacity: true)
            guard let view else { return }
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
        guard rexActive || front.processIdentifier == getpid() else {
            activationChanged()
            return
        }
        let rexPID = rexActive ? front.processIdentifier : RexCommand.localApp?.processIdentifier
        let info =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windows = info.compactMap(Window.init)
        let parents = windows.filter { $0.owner == rexPID && $0.frame.width > 60 && $0.frame.height > 60 }
        let ids = Set(parents.map(\.id))
        anchors = anchors.filter { ids.contains($0.key) }
        let dragging = NSEvent.pressedMouseButtons & 1 != 0
        let settled = Set(
            parents.filter { anchors[$0.id, default: WindowAnchor()].accepts($0.frame, now: now, dragging: dragging) }
                .map(\.id))
        if parents.isEmpty {
            schedule(every: 0.25)
        } else if dragging || anchors.values.contains(where: { now - $0.changedAt < 0.3 }) {
            schedule(every: 1 / 24)
        } else {
            schedule(every: 0.12)
        }
        if now >= nextPreferences {
            nextPreferences = now + 0.4
            chrome = PaneChrome(preference: Self.preference)
            selectedSession = RemoteSession.selection(Self.preference("lastFocusedSession") as? Data)
        }

        for (block, pane) in panes {
            let session = pane.session
            guard !parents.isEmpty, session.scope.matches(selectedSession) else {
                pane.place(nil)
                continue
            }
            refresh(session, at: now)
            guard let layout = session.placements[block] else {
                pane.place(nil)
                continue
            }

            let named = parents.filter {
                !session.label.isEmpty && ($0.title == session.label || $0.title.hasSuffix(" - " + session.label))
            }
            // Keep the same Rex window across Spaces even when another Rex window becomes visible.
            let current = parents.first { $0.id == session.parent }
            let parent =
                named.count == 1
                ? named.first : current ?? (session.parent == nil && parents.count == 1 ? parents.first : nil)
            guard let parent else {
                if let id = session.parent,
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
                    frame: frame, radius: layout.floating ? 10 : chrome.radius, parent: parent.id,
                    selected: session.focusedBlock == block, rexActive: rexActive, stacked: stacked))
        }
    }
}
