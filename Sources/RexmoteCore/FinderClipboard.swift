import AppKit
import Darwin

/// Finder pastes file URLs. Only an opaque staging ID crosses the desktop control channel.
public enum FinderClipboard {
    public static let relativeRoot = ".rexmote/clipboard-files"
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relativeRoot, isDirectory: true)
    }
    private static let limit = 1024
    private static let invalid = RexmoteError.invalid("Invalid Finder clipboard selection.")
    private static let marker = Data("rexmote-finder-v1\n".utf8)

    public static let copyFailed = Data("rexmote-finder-copy-failed".utf8)
    public static func reservation(_ id: UUID) -> Data { Data([0]) + reference(id) }
    public static func reservedID(in data: Data) -> UUID? {
        guard data.first == 0 else { return nil }
        return id(in: data.dropFirst())
    }

    public static func inBackground<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public static func reference(_ id: UUID) -> Data { marker + Data(id.uuidString.utf8) }
    public static func id(in data: Data) -> UUID? {
        guard data.count == marker.count + 36, data.starts(with: marker) else { return nil }
        return UUID(uuidString: String(decoding: data.dropFirst(marker.count), as: UTF8.self))
    }

    @MainActor public static func selection(from board: NSPasteboard) -> [URL]? {
        let change = board.changeCount
        guard board.types?.contains(.fileURL) == true, let items = board.pasteboardItems,
            (1...limit).contains(items.count)
        else { return nil }
        let urls = items.compactMap { item -> URL? in
            guard let string = item.string(forType: .fileURL), let url = URL(string: string),
                url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                url.path.hasPrefix("/"), !url.path.utf8.contains(0), !url.lastPathComponent.isEmpty, url.path != "/"
            else { return nil }
            return url
        }
        return urls.count == items.count && board.changeCount == change ? urls : nil
    }

    public static func stages(containing urls: [URL], in root: URL) -> Set<UUID> {
        let prefix = root.standardizedFileURL.path + "/"
        return Set(
            urls.compactMap { url in
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(prefix), let name = path.dropFirst(prefix.count).split(separator: "/").first else {
                    return nil
                }
                return UUID(uuidString: String(name))
            })
    }

    private static func info(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw invalid }
        return value
    }

    public static func prepare(_ root: URL) throws {
        if root == Self.root {
            let parent = root.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let metadata = try info(parent)
            guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0
            else { throw invalid }
        }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = try info(root)
        guard directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == getuid() else { throw invalid }
        guard chmod(root.path, 0o700) == 0 else { throw invalid }
    }

    /// Reserve an unused, private destination before the SSH file receiver opens it.
    public static func prepareTransfer(_ id: UUID, receiving: Bool) throws {
        try prepare(root)
        let directory = root.appendingPathComponent(id.uuidString)
        if receiving {
            guard mkdir(directory.path, 0o700) == 0 else { throw invalid }
        } else {
            _ = try files(id, in: root)
        }
    }

    /// Do not follow symlinks while walking. Frameworks and packages often contain internal relative links.
    private static func validate(_ source: URL) throws {
        let kind = try info(source).st_mode & S_IFMT
        if kind == S_IFREG { return }
        guard kind == S_IFDIR else { throw invalid }
        let base = source.resolvingSymlinksInPath().standardizedFileURL.path
        var failure: Error?
        guard
            let children = FileManager.default.enumerator(
                at: source, includingPropertiesForKeys: nil,
                errorHandler: { _, error in
                    failure = error
                    return false
                })
        else { throw invalid }
        for case let url as URL in children {
            try Task.checkCancellation()
            switch try info(url).st_mode & S_IFMT {
            case S_IFREG, S_IFDIR: continue
            case S_IFLNK:
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                let resolved = url.deletingLastPathComponent().appendingPathComponent(target)
                    .resolvingSymlinksInPath().standardizedFileURL.path
                guard !target.hasPrefix("/"), resolved == base || resolved.hasPrefix(base + "/") else { throw invalid }
            default: throw invalid
            }
        }
        if let failure { throw failure }
    }

    public static func stage(_ sources: [URL], in root: URL) throws -> UUID {
        guard (1...limit).contains(sources.count) else { throw invalid }
        try prepare(root)
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for (index, url) in sources.enumerated() {
                try Task.checkCancellation()
                guard url.isFileURL, !["", "/", ".", ".."].contains(url.lastPathComponent) else { throw invalid }
                let source = url.resolvingSymlinksInPath().standardizedFileURL.path
                let destination = directory.resolvingSymlinksInPath().standardizedFileURL.path
                guard !destination.hasPrefix(source + "/") else { throw invalid }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try validate(url)
                let slot = directory.appendingPathComponent(String(index))
                try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: false)
                let staged = slot.appendingPathComponent(url.lastPathComponent)
                try Task.checkCancellation()
                let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW)
                guard copyfile(url.path, staged.path, nil, flags) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            return id
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public static func files(_ id: UUID, in root: URL) throws -> [URL] {
        let manager = FileManager.default
        let directory = root.appendingPathComponent(id.uuidString)
        guard try info(root).st_mode & S_IFMT == S_IFDIR, try info(directory).st_mode & S_IFMT == S_IFDIR else {
            throw invalid
        }
        let slots = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard (1...limit).contains(slots.count) else { throw invalid }
        return try (0..<slots.count).map { index in
            let slot = directory.appendingPathComponent(String(index))
            guard try info(slot).st_mode & S_IFMT == S_IFDIR else { throw invalid }
            let contents = try manager.contentsOfDirectory(at: slot, includingPropertiesForKeys: nil)
            guard contents.count == 1, let file = contents.first else { throw invalid }
            try validate(file)
            return file
        }
    }

    @MainActor public static func publish(_ id: UUID, in root: URL, to board: NSPasteboard) -> Bool {
        guard let urls = try? files(id, in: root) else { return false }
        return publish(urls, to: board)
    }

    @MainActor public static func publish(_ urls: [URL], to board: NSPasteboard) -> Bool {
        guard !urls.isEmpty else { return false }
        board.prepareForNewContents(with: .currentHostOnly)
        return board.writeObjects(urls.map { $0 as NSURL })
    }

    /// Finder can keep reading the source after Paste or after the pane closes.
    public static func prune(in root: URL, preserving: Set<UUID> = []) {
        guard let attributes = try? info(root), attributes.st_mode & S_IFMT == S_IFDIR,
            let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return }
        let expiry = time(nil) - 7 * 24 * 3600
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent), !preserving.contains(id),
                let attributes = try? info(dir), attributes.st_uid == getuid(), attributes.st_ctimespec.tv_sec < expiry
            else { continue }
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

extension RemoteInput {
    public var interruptsFilePaste: Bool {
        switch self {
        case .key(let key): return key.event == 1
        case .pointer(let pointer): return pointer.action == "down"
        case .releaseAll, .text, .trackpad: return true
        }
    }
}
