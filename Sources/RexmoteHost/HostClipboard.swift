import AppKit
import RexmoteCore

@MainActor final class HostClipboard {
    private let board: NSPasteboard
    private let root: URL
    private var pending: Task<Void, Never>?
    private var destination: (id: UUID, target: PasteTarget, change: Int)?

    // A long upload must not paste into a different foreground window.
    private struct PasteTarget: Equatable {
        let pid: pid_t
        let window: AXUIElement?
        let document: String?

        init?() {
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
            self.pid = pid
            var value: CFTypeRef?
            let app = AXUIElementCreateApplication(pid)
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
                let value, CFGetTypeID(value) == AXUIElementGetTypeID()
            {
                window = (value as! AXUIElement)
            } else {
                window = nil
            }
            var doc: CFTypeRef?
            if let window { _ = AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &doc) }
            document = doc as? String
        }
    }
    func reserve(_ id: UUID) {
        cancel()
        destination = PasteTarget().map { (id, $0, board.changeCount) }

    }
    func cancelFilePaste() { destination = nil }

    func pasteFiles(
        _ id: UUID, canPaste: @escaping () -> Bool, finished: @escaping (Bool) -> Void = { _ in },
        perform: @escaping () -> Void
    ) {
        guard destination?.id == id else {
            finished(false)
            return
        }
        pending = Task {
            guard
                let urls = try? await FinderClipboard.inBackground({ [root] in try FinderClipboard.files(id, in: root) }
                ),
                !Task.isCancelled, let target = destination, target.id == id, target.target == PasteTarget(),
                target.change == board.changeCount, canPaste()
            else {
                finished(false)
                return
            }
            destination = nil
            let published = FinderClipboard.publish(urls, to: board)
            if published {
                perform()
                Task.detached(priority: .utility) { [root] in FinderClipboard.prune(in: root, preserving: [id]) }
            }
            finished(published)
        }
    }

    init(board: NSPasteboard, root: URL = FinderClipboard.root) {
        self.board = board
        self.root = root
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        destination = nil
    }

    func copy(
        perform: () throws -> Void, canRead: @escaping () -> Bool,
        reply: @escaping (_ changed: Bool, _ contents: Data) -> Void
    ) rethrows {
        cancel()
        let before = board.changeCount
        try perform()
        // Posting a key returns before the foreground app has serviced its Copy or Cut menu item.
        pending = Task { [board] in
            let deadline = ContinuousClock.now + .seconds(2)
            while !Task.isCancelled && canRead() {
                if board.changeCount != before, board.types?.isEmpty == false {
                    if let urls = FinderClipboard.selection(from: board) {
                        let id = try? await FinderClipboard.inBackground { [root] in
                            FinderClipboard.prune(
                                in: root, preserving: FinderClipboard.stages(containing: urls, in: root))
                            return try FinderClipboard.stage(urls, in: root)
                        }
                        if !Task.isCancelled {
                            reply(true, id.map(FinderClipboard.reference) ?? FinderClipboard.copyFailed)
                        }
                    } else {
                        reply(true, DesktopClipboard.read(from: board) ?? Data())
                    }
                    return
                }
                if ContinuousClock.now >= deadline { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            if !Task.isCancelled { reply(canRead() && board.changeCount != before, Data()) }
        }
    }

    func paste(_ data: Data, perform: () throws -> Void) rethrows {
        cancel()
        if DesktopClipboard.write(data, to: board) { try perform() }
    }
}
