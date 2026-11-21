import AppKit
import RexmoteCore

@main @MainActor struct RexmoteCommand {
    static func main() {
        do { try run(Array(CommandLine.arguments.dropFirst())) } catch {
            FileHandle.standardError.write(Data("rexmote: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(_ args: [String]) throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["SSH_ASKPASS"] == PaneCommands.executable, environment["REXMOTE_ASKPASS_HOST"] != nil {
            guard args.count == 1, isatty(STDOUT_FILENO) == 0,
                let block = environment["REXMOTE_ASKPASS_PANE"], let ticket = environment["REXMOTE_ASKPASS_TICKET"],
                let answer = try ViewerEndpoint.request(
                    PaneRequest(action: "askpass", block: block, ticket: ticket, prompt: args[0])
                ).answer
            else { exit(1) }
            var bytes = Data(answer.utf8)
            bytes.append(10)
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            try FileHandle.standardOutput.write(contentsOf: bytes)
            return
        }
        if URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "rexmote-pane" {
            try PaneHolder.run(environment: environment)
            return
        }
        if URL(fileURLWithPath: PaneCommands.executable).lastPathComponent == "rexmote-viewer" {
            let port = try ViewerEndpoint.port(args.first == "--port" ? args.dropFirst().first : nil)
            try PaneService().run(port: port, followRex: args.contains("--follow-rex"))
            return
        }
        let tail = Array(args.dropFirst())
        guard let command = args.first else {
            if ProcessInfo.processInfo.environment["REX_BLOCK"] != nil {
                try PaneCommands.open([])
            } else {
                print(PaneCommands.help)
            }
            return
        }
        if tail.contains("--help") || tail.contains("-h") {
            print(PaneCommands.help)
            return
        }
        switch command {
        case "is-remote-server":
            guard tail.count == 1, let target = UUID(uuidString: tail[0]) else { exit(1) }
            let local = try RexCommand().object(["whoami", "--json"], quiet: true)
            guard (local["principal"] as? [String: Any])?["transport"] as? String == "unix",
                let id = local["host_id"] as? String, let viewer = UUID(uuidString: id), viewer != target
            else { exit(1) }
        case "registered-panes":
            guard tail.count == 1 else { throw RexmoteError.invalid("Choose one Rex session.") }
            print(String(decoding: try JSONEncoder().encode(HostedPane.list(session: tail[0])), as: UTF8.self))
        case "--version", "-v": print("rexmote 0.7.0")
        case "--help", "-h", "help": print(PaneCommands.help)
        case "open": try PaneCommands.open(tail)
        case "ls", "list": try PaneCommands.manage("ls", tail)
        case "focus", "close", "info", "reload", "wait", "screenshot", "snapshot":
            try PaneCommands.manage(command, tail)
        case "skill": print(PaneCommands.guide)
        case "file-stage":
            guard tail.count == 2, ["receive", "send"].contains(tail[0]), let id = UUID(uuidString: tail[1]) else {
                throw RexmoteError.invalid("Invalid clipboard transfer.")
            }
            try FinderClipboard.prepareTransfer(id, receiving: tail[0] == "receive")
        case "relay": try relayDesktop(tail)
        case "setup" where tail.isEmpty: try DesktopLink().setup()
        case "doctor" where tail.isEmpty || tail == ["--json"]:
            let status = try DesktopLink().status()
            let data = try JSONEncoder().encode(status)
            var report = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            report["paneIntegration"] = PaneCommands.integration()
            try PaneCommands.printJSON(report)
        default: throw RexmoteError.invalid("Unknown command \(command). Run rexmote --help.")
        }
    }
}
