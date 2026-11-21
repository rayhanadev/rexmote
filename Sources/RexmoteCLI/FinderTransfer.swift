import Foundation
import RexmoteCore

/// Use the system's metadata-aware rsync over a separate channel on the same pinned SSH master.
enum FinderTransfer {
    static func upload(_ files: [URL], id: UUID, to host: SessionHost) throws {
        let root = FinderClipboard.root
        let stage = try FinderClipboard.stage(files, in: root)
        let directory = root.appendingPathComponent(stage.uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        FinderClipboard.prune(in: root, preserving: FinderClipboard.stages(containing: files, in: root).union([stage]))
        try transfer(directory, remote: id, host: host, uploading: true)
    }

    static func download(_ id: UUID, from host: SessionHost) throws -> (UUID, [URL]) {
        let root = FinderClipboard.root
        try FinderClipboard.prepare(root)
        let localID = UUID()
        let directory = root.appendingPathComponent(localID.uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        do {
            try transfer(directory, remote: id, host: host, uploading: false)
            return (localID, try FinderClipboard.files(localID, in: root))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func transfer(_ local: URL, remote id: UUID, host: SessionHost, uploading: Bool) throws {
        let link = DesktopLink(origin: host)
        defer { link.close() }
        let (ssh, address) = try link.sshTransport(host, prompt: false)
        // rsync's remote-shell parser quotes a literal apostrophe with two adjacent apostrophes.
        let shell = ([ssh.executableURL!.path] + (ssh.arguments ?? []))
            .map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: " ")
        let remote = address + ":" + FinderClipboard.relativeRoot + "/" + id.uuidString + "/"
        let path = local.path + "/"
        let direction = uploading ? "receive" : "send"
        let server =
            "\"$HOME/Applications/Rexmote.app/Contents/MacOS/rexmote\" file-stage " + direction + " "
            + id.uuidString + " && exec /usr/bin/rsync"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments =
            ["-rlptE", "--safe-links", "--timeout=45", "--rsync-path=" + server, "-e", shell, "--"]
            + (uploading ? [path, remote] : [remote, path])
        process.environment = ssh.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.terminationStatus == 0 else {
            throw RexmoteError.system("The file transfer did not finish (rsync \(process.terminationStatus)).")
        }
    }
}
