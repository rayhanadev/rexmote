import AppKit
import RexmoteCore

@MainActor final class PaneClipboard {
    struct RemoteBoard: Equatable {
        let serverID: UUID
        let account: String
    }

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

    func filesToPaste(in pane: String, on remoteBoard: RemoteBoard? = nil) -> [URL]? {
        if usesRemoteClipboard(in: pane, on: remoteBoard) { return nil }
        return FinderClipboard.selection(from: board)
    }

    private func usesRemoteClipboard(in pane: String, on remoteBoard: RemoteBoard?) -> Bool {
        guard let copy, copy.change == board.changeCount else { return false }
        if let owner = copy.remoteBoard, let remoteBoard { return owner == remoteBoard }
        return copy.pane == pane
    }

    // The source block owns the reply. Every virtual display in its Mac login shares the copied selection.
    private var copy: (pane: String, remoteBoard: RemoteBoard?, change: Int, request: UUID?)?

    init(board: NSPasteboard) { self.board = board }

    func packet(for event: RemoteInput, revision: UInt64, pane: String, on remoteBoard: RemoteBoard? = nil) -> Packet? {
        let input = Packet(.input(revision: revision, event: event))
        guard case .key(let key) = event, let action = key.clipboardAction else { return input }
        switch action {
        case .copy:
            cancelDownload()
            let request = UUID()
            copy = (pane, remoteBoard, board.changeCount, request)
            return Packet(.input(revision: revision, event: event, copyRequest: request))
        case .paste:
            // The host already has the selection, even while it is still being transferred to this Mac.
            if usesRemoteClipboard(in: pane, on: remoteBoard) { return input }
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
            copy?.request = nil
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
                    copy?.change = board.changeCount
                    copy?.request = nil
                    status(.received)
                } catch {
                    if !Task.isCancelled {
                        copy?.request = nil
                        status(.receiveFailed)
                    }
                }
            }
            return
        }
        copy?.request = nil
        if !data.isEmpty, DesktopClipboard.write(data, to: board) {
            copy?.change = board.changeCount
        }
    }

    func forget(_ pane: String) {
        if copy?.pane == pane {
            cancelDownload()
            copy = nil
        }
    }
}
