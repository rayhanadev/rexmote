import AppKit
import RexmoteCore

@MainActor final class PaneClipboard {
    static let shared = PaneClipboard(board: .general)
    private let board: NSPasteboard
    private var download: Task<Void, Never>?
    private var transferStatus: ((FileTransferActivity) -> Void)?
    var generation: Int { board.changeCount }

    private func cancelDownload() {
        download?.cancel()
        download = nil
        transferStatus?(.cancelled)
        transferStatus = nil
    }

    func filesToPaste(in pane: String) -> [URL]? {
        if usesRemoteClipboard(in: pane) { return nil }
        return FinderClipboard.selection(from: board)
    }

    private func usesRemoteClipboard(in pane: String) -> Bool {
        copy?.pane == pane && copy?.change == board.changeCount
    }

    // All panes share one Mac clipboard. Only the latest copy may publish to it.
    private var copy: (pane: String, change: Int, request: UUID?)?

    init(board: NSPasteboard) { self.board = board }

    func packet(for event: RemoteInput, revision: UInt64, pane: String) -> Packet? {
        let input = Packet(.input(revision: revision, event: event))
        guard case .key(let key) = event, let action = key.clipboardAction else { return input }
        switch action {
        case .copy:
            cancelDownload()
            let request = UUID()
            copy = (pane, board.changeCount, request)
            return Packet(.input(revision: revision, event: event, copyRequest: request))
        case .paste:
            // A quick copy then paste in the same pane can use the remote original immediately.
            if usesRemoteClipboard(in: pane) { return input }
            guard let data = DesktopClipboard.read(from: board) else { return nil }
            return Packet(input.message, payload: data)
        }
    }

    func received(
        _ data: Data, request: UUID, changed: Bool, pane: String,
        host: SessionHost? = nil, status: @escaping (FileTransferActivity) -> Void = { _ in }
    ) {
        guard let pending = copy, pending.pane == pane, pending.request == request else { return }
        guard changed, board.changeCount == pending.change else {
            copy = nil
            return
        }
        if data == FinderClipboard.copyFailed {
            copy = nil
            status(.unreadable)
            return
        }
        if let id = FinderClipboard.id(in: data), let host {
            cancelDownload()
            transferStatus = status
            status(.receiving)
            download = Task {
                defer {
                    if !Task.isCancelled {
                        transferStatus = nil
                        download = nil
                    }
                }
                do {
                    let (local, urls) = try await FinderClipboard.inBackground {
                        try FinderTransfer.download(id, from: host)
                    }
                    guard !Task.isCancelled, copy?.request == request, board.changeCount == pending.change else {
                        Task.detached(priority: .utility) {
                            try? FileManager.default.removeItem(
                                at: FinderClipboard.root.appendingPathComponent(local.uuidString))
                        }
                        if !Task.isCancelled {
                            copy = nil
                            status(.cancelled)
                        }
                        return
                    }
                    guard FinderClipboard.publish(urls, to: board) else {
                        throw RexmoteError.system("Couldn’t place the files on the clipboard.")
                    }
                    Task.detached(priority: .utility) {
                        FinderClipboard.prune(in: FinderClipboard.root, preserving: [local])
                    }
                    copy = (pane, board.changeCount, nil)
                    status(.received)
                } catch {
                    if !Task.isCancelled {
                        copy = nil
                        status(.receiveFailed)
                    }
                }
            }
            return
        }
        copy = nil
        if !data.isEmpty, !DesktopClipboard.write(data, to: board) { return }
        copy = (pane, board.changeCount, nil)
    }

    func forget(_ pane: String) {
        if copy?.pane == pane {
            cancelDownload()
            copy = nil
        }
    }
}
