import Darwin
import Foundation
import RexmoteCore

struct PaneInfo: Codable {
    let id: String, session: String
    var holderPID: Int32?
    var rexHost: String?
    var host: String?, title = "Remote Desktop", state = "connecting", error: String?
    var visible = false, focused = false
    var fileTransfer: String?
    var width: Int?, height: Int?, mode: String?, display: String?
    var displayID: UInt32?
    var desktopWidth: Int?, desktopHeight: Int?
    var lastUsed = Date.timeIntervalSinceReferenceDate
    var loading: Bool { state == "connecting" }
    var dictionary: [String: Any] {
        var value = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:]
        value["block_id"] = id
        value["label"] = title
        value["loading"] = loading
        value.removeValue(forKey: "lastUsed")
        value.removeValue(forKey: "holderPID")
        return value
    }
}

struct PaneRequest: Codable {
    var action: String? = nil
    var block: String?, session: String?
    var pid: Int32?
    var ticket: String?, prompt: String?
}

struct PaneReply: Codable {
    var info: PaneInfo?, panes: [PaneInfo]?, png: Data?
    var error: String?, answer: String?
}

enum ViewerEndpoint {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rexmote")
    static let tokenFile = directory.appendingPathComponent("token")

    static func port(_ override: String? = nil) throws -> UInt16 {
        let config = directory.appendingPathComponent("config.json")
        var configured: Int?
        if FileManager.default.fileExists(atPath: config.path) {
            let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
            configured = settings?["port"] as? Int
        }
        let text = override ?? ProcessInfo.processInfo.environment["REXMOTE_PORT"] ?? String(configured ?? 18803)
        guard let port = UInt16(text), port > 0 else { throw RexmoteError.invalid("Invalid local viewer port.") }
        return port
    }

    static func token(create: Bool) throws -> String {
        if create {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, metadata.st_uid == geteuid(),
            metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o077 == 0
        else {
            throw RexmoteError.invalid("The viewer needs an owner-only ~/.rexmote directory.")
        }
        if create && !FileManager.default.fileExists(atPath: tokenFile.path) {
            var template = Array(directory.appendingPathComponent("token.XXXXXX").path.utf8CString)
            let fd = mkstemp(&template)
            guard fd >= 0 else { throw RexmoteError.system("Cannot create the viewer token.") }
            let temporary = String(cString: template)
            defer { unlink(temporary) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: Data((UUID().uuidString + UUID().uuidString).utf8))
            try handle.close()
            guard link(temporary, tokenFile.path) == 0 || errno == EEXIST else {
                throw RexmoteError.system("Cannot save the viewer token.")
            }
        }
        let fd = Darwin.open(tokenFile.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RexmoteError.invalid("Open a desktop pane in Rex to start Rexmote.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fstat(fd, &metadata) == 0, metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_mode & 0o077 == 0, metadata.st_size == 72,
            let data = try handle.readToEnd(), let token = String(data: data, encoding: .ascii)
        else {
            throw RexmoteError.invalid("Invalid viewer token file.")
        }
        return token
    }

    static func request(_ query: PaneRequest) throws -> PaneReply {
        guard let action = query.action else { throw RexmoteError.invalid("Missing pane action.") }
        if ["list", "holders"].contains(action), !FileManager.default.fileExists(atPath: tokenFile.path) {
            return PaneReply(panes: [])
        }
        let url = URL(string: "http://127.0.0.1:\(try port())/\(action)")!
        var request = URLRequest(url: url, timeoutInterval: action == "askpass" ? 120 : 5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(query)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try token(create: false), forHTTPHeaderField: "x-rexmote-token")
        let reply = PendingReply()
        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                reply.result = .failure(error)
            } else {
                reply.result = Result { try JSONDecoder().decode(PaneReply.self, from: data ?? Data()) }
            }
            reply.done.signal()
        }
        task.resume()
        reply.done.wait()
        do {
            let response = try reply.result!.get()
            if let error = response.error { throw RexmoteError.invalid(error) }
            return response
        } catch let error as URLError where error.code == .cannotConnectToHost {
            if ["list", "holders"].contains(action) { return PaneReply(panes: []) }
            throw RexmoteError.invalid("Open a remote desktop pane in Rex to start the viewer.")
        }
    }

    private final class PendingReply: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var result: Result<PaneReply, Error>?
    }
}
