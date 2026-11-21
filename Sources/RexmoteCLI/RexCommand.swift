import AppKit
import Darwin
import Foundation
import RexmoteCore

/// Talks to the same Rex server as the calling terminal, through its public CLI.
struct RexCommand {
    static let bundleID = "com.superlogical.rex"
    let binary: URL
    let host: String?

    let environment: [String: String]
    init(context: [String: String] = [:], host: String? = nil) throws {
        self.host = host
        let env = ProcessInfo.processInfo.environment.merging(context) { _, new in new }
        environment = env
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bundled = [
            "/Applications/Rex.app", "/Applications/Rex Beta.app",
            home + "/Applications/Rex.app", home + "/Applications/Rex Beta.app",
        ].map {
            $0 + "/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
        }
        let path = (env["PATH"] ?? "").split(separator: ":").map { String($0) + "/rex" }
        let candidates = env["REXMOTE_REX_BIN"].map { [$0] } ?? (path + bundled)
        guard let match = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw RexmoteError.invalid("Install Rex or set REXMOTE_REX_BIN to the rex executable.")
        }
        binary = URL(fileURLWithPath: match)
    }

    func run(_ args: [String], quiet: Bool = false) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = binary
        process.environment = environment
        process.arguments = ["--timeout", "4s"] + (host.map { ["-S", $0] } ?? []) + args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        if quiet { process.standardError = FileHandle.nullDevice }
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RexmoteError.system("Rex could not complete \(args.prefix(2).joined(separator: " ")).")
        }
        return data
    }

    struct Client {
        let id: String
        let label: String?
        let localPID: pid_t?

        init?(_ row: [String: Any]) {
            guard let id = row["client_id"] as? String,
                let info = row["info"] as? [String: Any], info["kind"] as? String == "app",
                let principal = row["principal"] as? [String: Any]
            else { return nil }
            self.id = id
            label = info["label"] as? String
            localPID = principal["transport"] as? String == "unix" ? principal["pid"] as? pid_t : nil
        }
    }

    static func clients(in result: [String: Any]) -> [Client] {
        (result["clients"] as? [[String: Any]] ?? []).compactMap(Client.init)
    }

    private func clients() throws -> [Client] {
        Self.clients(in: try object(["client", "ls", "--json"], quiet: true))
    }

    private func viewingClient() throws -> String {
        if host == nil, let id = environment["REX_CLIENT"], RemoteSession.validID(id, prefix: "client:") { return id }
        guard host != nil, let app = Self.localApp,
            let label = try RexCommand().clients().first(where: { $0.localPID == app.processIdentifier })?.label
        else { throw RexmoteError.invalid("Open the desktop from the remote session in Rex.") }
        let matches = try clients().filter { $0.localPID == nil && $0.label == label }
        guard matches.count == 1 else {
            throw RexmoteError.invalid("The Rex viewer is not attached to this session host.")
        }
        return matches[0].id
    }

    func openDesktop(session: String, block: String? = nil, tab: Bool = false) throws -> String {
        var args = ["-C", try viewingClient(), "do", "-s", session]
        if let block { args += ["-b", block] }
        let data = try run(args + [tab ? "rexmote_open_tab" : "rexmote_open", "--json"])
        let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = (result?["block_ids"] as? [String])?.first ?? result?["block_id"] as? String else {
            throw RexmoteError.invalid("The desktop action requires a Rex session hosted on another Mac.")
        }
        return id
    }

    func show(session: String, window: String? = nil) {
        guard let client = try? viewingClient() else { return }
        if let window { _ = try? run(["focus", "-s", session, window], quiet: true) }
        if let url = Self.localApp?.bundleURL {
            let launch = Process()
            launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launch.arguments = ["-a", url.path]
            if (try? launch.run()) != nil { launch.waitUntilExit() }
        }
        let select = ["-C", client, "do", "session.select", "session_id=" + session]
        _ = try? run(select + (window.map { ["window_id=" + $0] } ?? []), quiet: true)
    }

    static var localApp: NSRunningApplication? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        return apps.first(where: \.isActive) ?? apps.first
    }

    func object(_ args: [String], quiet: Bool = false) throws -> [String: Any] {
        let data = try run(args, quiet: quiet)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RexmoteError.invalid("Unexpected reply from Rex.")
        }
        return result
    }
}

enum PaneCommands {
    static let executable: String = {
        var length: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &length)
        var bytes = [CChar](repeating: 0, count: Int(length))
        _ = _NSGetExecutablePath(&bytes, &length)
        return URL(fileURLWithPath: String(cString: bytes)).standardizedFileURL.resolvingSymlinksInPath().path
    }()
    static let help = """
        rexmote · a virtual desktop for your remote Rex session

          rexmote open [--tab] [--no-wait] [--json]
          rexmote ls [-s SESSION] [--json]
          rexmote info | focus | close | reload | snapshot [-b PANE] [--json]
          rexmote wait [-b PANE] [--state STATE] [--timeout SECONDS]
          rexmote screenshot [PATH] [-b PANE]
          rexmote doctor | setup
        """
    static let guide = """
        In a Rex session hosted on another Mac, press Shift-Cmd-M to open its virtual
        desktop. Command shortcuts go to the app on the remote Mac while the desktop
        has focus. Ctrl-Option-arrow moves to a neighboring pane. Ctrl-Option-grave
        gives keyboard focus back to Rex.
        For scripts, keep the block ID from open and use it with -b.
        """

    static func open(_ args: [String]) throws {
        let flags = Set(args)
        guard flags.isSubset(of: ["--tab", "--no-wait", "--json"]) else {
            throw RexmoteError.invalid(
                "The desktop belongs to the current Rex session. Run rexmote open without a host.")
        }
        let local = try RexCommand()
        let rex: RexCommand
        let session: String
        if let shell = local.environment["REX_SESSION"], RemoteSession.validID(shell, prefix: "session:") {
            // A shell running inside Rex belongs to that server, even if the GUI has moved to another session.
            rex = local
            session = shell
        } else {
            guard let (id, selected) = RemoteSession.selection(PaneTracker.preference("lastFocusedSession") as? Data),
                let host = RemoteSession.label(for: id, in: try local.object(["hosts", "--json"]))
            else { throw RexmoteError.invalid("Open a Rex session hosted on another Mac.") }
            rex = try RexCommand(host: host)
            session = selected
        }
        let block = rex.host == nil ? rex.environment["REX_BLOCK"] : nil
        let id = try rex.openDesktop(session: session, block: block, tab: flags.contains("--tab"))
        if rex.host != nil { rex.show(session: session) }
        let json = flags.contains("--json")
        if !json {
            print(id)
            fflush(stdout)
        }
        // A CLI on the session host can report its Rex block. Only the viewing Mac owns the pixels.
        let info =
            rex.host == nil || flags.contains("--no-wait")
            ? PaneInfo(id: id, session: session, rexHost: rex.host)
            : try waitFor(id: id, session: session, state: nil, timeout: 25, registering: true)
        if json { try printJSON(info.dictionary) }
        try check(info)
    }

    static func manage(_ command: String, _ args: [String]) throws {
        let action = command
        var target: String?
        var session: String?
        var expected: String?
        var timeout = 25.0
        var json = false
        var noWait = false
        var words = [String]()
        var i = 0
        while i < args.count {
            let parts = args[i].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let flag = String(parts.first ?? "")
            i += 1
            func value() throws -> String {
                if parts.count == 2 { return String(parts[1]) }
                guard i < args.count else { throw RexmoteError.invalid("\(flag) needs a value.") }
                defer { i += 1 }
                return args[i]
            }
            switch flag {
            case "-s", "--session": session = try value()
            case "-b", "--block": target = try value()
            case "--json": json = true
            case "--no-wait" where action == "reload": noWait = true
            case "--state" where action == "wait": expected = try value()
            case "--timeout":
                guard let number = Double(try value()), number.isFinite, (0...3600).contains(number) else {
                    throw RexmoteError.invalid("Choose a timeout from 0 to 3600 seconds.")
                }
                timeout = number
            default:
                guard !flag.hasPrefix("-") else { throw RexmoteError.invalid("Unexpected option \(flag).") }
                words.append(args[i - 1])
            }
        }
        if let session, !RemoteSession.validID(session, prefix: "session:") {
            throw RexmoteError.invalid("Use a Rex session ID with -s.")
        }
        if action == "ls" {
            guard words.isEmpty, target == nil else {
                throw RexmoteError.invalid("Use -s SESSION to filter the pane list.")
            }
            let panes = try ViewerEndpoint.request(PaneRequest(action: "list", session: session)).panes ?? []
            if json { try printJSON(panes.map(\.dictionary)) } else { for info in panes { print(line(info)) } }
            return
        }
        let positional = action == "screenshot"
        guard words.count <= 1, positional || target == nil || words.isEmpty else {
            throw RexmoteError.invalid("Choose one pane with -b BLOCK.")
        }
        if !positional { target = target ?? words.first }
        if let expected,
            ![
                "ready", "authenticating", "connecting", "paused", "permission", "unavailable", "locked", "signed-out",
                "error",
            ]
            .contains(expected)
        {
            throw RexmoteError.invalid("Unknown desktop state \(expected).")
        }
        if action == "wait", let target, target.hasPrefix("block:") {
            let info = try waitFor(id: target, session: session, state: expected, timeout: timeout, registering: true)
            if expected == nil { try check(info) }
            if json { try printJSON(info.dictionary) } else { print(line(info)) }
            return
        }
        var query = PaneRequest(action: "info", block: target, session: session)
        guard var info = try ViewerEndpoint.request(query).info else {
            throw RexmoteError.invalid("Desktop pane unavailable.")
        }
        query.block = info.id
        query.session = info.session
        switch action {
        case "focus", "close":
            let rex = try RexCommand(host: info.rexHost)
            let process = try rex.object(["block", "call", "-s", info.session, "-b", info.id, "process"])
            guard let pid = info.holderPID, (process["child"] as? [String: Any])?["pid"] as? Int32 == pid else {
                throw RexmoteError.invalid("This desktop holder has closed.")
            }
            if action == "focus" {
                let block =
                    try rex.object(["block", "inspect", "-s", info.session, info.id, "--json"])["block"]
                    as? [String: Any]
                rex.show(session: info.session, window: block?["window_id"] as? String)
            }
            _ = try rex.run(["block", action, "-s", info.session, info.id])
            if action == "focus" {
                query.action = "focus"
                _ = try? ViewerEndpoint.request(query)
            }
            if !json { return }
        case "wait":
            info = try waitFor(id: info.id, session: info.session, state: expected, timeout: timeout)
            if expected == nil { try check(info) }
        case "reload":
            query.action = action
            if let next = try ViewerEndpoint.request(query).info { info = next }
            if !noWait {
                info = try waitFor(id: info.id, session: info.session, state: nil, timeout: timeout)
                try check(info)
            }
        case "screenshot":
            query.action = action
            guard let png = try ViewerEndpoint.request(query).png else {
                throw RexmoteError.invalid("No desktop frame available.")
            }
            let path = words.first ?? "rexmote-" + String(info.id.suffix(8)) + ".png"
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            try writeScreenshot(png, to: url)
            if json { try printJSON(["id": info.id, "path": url.path]) } else { print(url.path) }
            return
        default: break
        }
        if json {
            try printJSON(info.dictionary)
        } else if action == "snapshot" {
            print(line(info))
            if let width = info.width, let height = info.height {
                print("\(width) × \(height) · \(info.mode ?? "view-only")")
            }
            if let display = info.display { print(display) }
            if let error = info.error { print(error) }
        } else {
            print(line(info))
        }
    }

    private static func waitFor(
        id: String, session: String?, state: String?, timeout: Double, registering: Bool = false
    ) throws -> PaneInfo {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var registered = !registering
        var last = "registering"
        repeat {
            do {
                if let info = try ViewerEndpoint.request(PaneRequest(action: "info", block: id, session: session)).info
                {
                    registered = true
                    last = info.state
                    if state.map({ info.state == $0 }) ?? !info.loading { return info }
                    if state == "ready" { try check(info) }
                }
            } catch { if registered { throw error } }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            usleep(100_000)
        } while true
        throw RexmoteError.system("Timed out waiting for \(id) (\(last)).")
    }

    private static func check(_ info: PaneInfo) throws {
        if ["error", "unavailable", "permission"].contains(info.state) {
            throw RexmoteError.system(info.error ?? "Desktop unavailable.")
        }
    }

    private static func writeScreenshot(_ data: Data, to url: URL) throws {
        // Only the caller writes the requested pathname. Publish a complete owner-only PNG.
        let parent = url.deletingLastPathComponent()
        var template = Array(parent.appendingPathComponent(".rexmote-XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw RexmoteError.system("Could not create the screenshot in \(parent.path).") }
        let temporary = String(cString: template)
        defer { unlink(temporary) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.close()
        guard rename(temporary, url.path) == 0 else {
            throw RexmoteError.system("Could not save the screenshot at \(url.path).")
        }
    }

    static func integration() -> [String: Any] {
        var report: [String: Any] = [
            "holderInstalled": FileManager.default.isExecutableFile(atPath: Installation.holder.path),
            "viewerInstalled": FileManager.default.isExecutableFile(
                atPath: Installation.app.appendingPathComponent("Contents/MacOS/rexmote-viewer").path),
        ]
        if let rex = try? RexCommand(), let map = try? rex.object(["keymap", "--json"], quiet: true) {
            let actions = (map["actions"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            report["paletteInstalled"] = ["rexmote_open", "rexmote_open_tab"].allSatisfy(actions.contains)
            let bindings = map["bindings"] as? [[String: Any]] ?? []
            report["shortcuts"] = bindings.filter { $0["action"] as? String == "rexmote_open" }.compactMap {
                $0["keys"] as? [String]
            }
        } else {
            report["paletteInstalled"] = false
        }
        report["openPanes"] = (try? ViewerEndpoint.request(PaneRequest(action: "list")).panes?.count) ?? 0
        return report
    }

    static func printJSON(_ value: Any) throws {
        print(
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
    }
    private static func line(_ info: PaneInfo) -> String {
        "\(info.id)\t\(info.title)\t\(info.state)"
    }

}
