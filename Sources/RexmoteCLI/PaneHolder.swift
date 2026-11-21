import Darwin
import Foundation
import RexmoteCore

private var holderStopping: sig_atomic_t = 0

/// The Rex block owns this process. Registration survives viewer restarts.
enum PaneHolder {
    private static let contextKeys = [
        "REX_SERVER", "REX_CLIENT", "REX_SESSION", "REX_BLOCK",
    ]

    static func run(environment: [String: String]) throws {
        guard let block = environment["REX_BLOCK"], RemoteSession.validID(block, prefix: "block:"),
            let session = environment["REX_SESSION"], RemoteSession.validID(session, prefix: "session:")
        else {
            throw RexmoteError.invalid("Open this pane from Rex.")
        }
        let port = try ViewerEndpoint.port()
        let registration = PaneRequest(action: "register", block: block, session: session, pid: getpid())
        var terminal = termios()
        let terminalAttached = tcgetattr(STDIN_FILENO, &terminal) == 0
        if terminalAttached {
            var quiet = terminal
            quiet.c_lflag |= tcflag_t(ICANON)
            quiet.c_lflag &= ~tcflag_t(ECHO | ECHONL)
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &quiet)
            FileHandle.standardOutput.write(Data("\u{1b}[?25l\u{1b}]2;Remote Desktop\u{7}".utf8))
        }
        for sig in [SIGHUP, SIGTERM, SIGINT] { signal(sig) { _ in holderStopping = 1 } }
        defer {
            if terminalAttached {
                _ = tcsetattr(STDIN_FILENO, TCSANOW, &terminal)
                FileHandle.standardOutput.write(Data("\u{1b}[?25h".utf8))
            }
            _ = try? ViewerEndpoint.request(
                PaneRequest(action: "unregister", block: block, session: session, pid: getpid()))
        }

        var nextLaunch: TimeInterval = 0, nextRegistration: TimeInterval = 0
        while holderStopping == 0 {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextRegistration {
                nextRegistration = now + 1
                do {
                    _ = try ViewerEndpoint.request(registration)
                } catch {
                    if now >= nextLaunch {
                        nextLaunch = now + 5
                        if (try? ViewerEndpoint.request(PaneRequest(action: "health"))) == nil {
                            startViewer(port: port, useLoginAgent: environment["REXMOTE_PORT"] == nil)
                        }
                    }
                }
            }
            if terminalAttached {
                let remaining = max(0, nextRegistration - ProcessInfo.processInfo.systemUptime)
                var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                let ready = poll(&input, 1, Int32(ceil(remaining * 1000)))
                if ready < 0 && errno == EINTR { continue }
                if ready < 0 || input.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { break }
                if input.revents & Int16(POLLIN) != 0 {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let count = read(STDIN_FILENO, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { break }
                    for line in String(decoding: buffer.prefix(count), as: UTF8.self).split(whereSeparator: \.isNewline) {
                        if let activity = FileTransferActivity(holderLine: String(line)) {
                            FileHandle.standardOutput.write(activity.report)
                        }
                    }
                }
            } else {
                sleep(1)
            }
        }
    }

    private static func startViewer(port: UInt16, useLoginAgent: Bool) {
        func launch(_ executable: String, _ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            // Launch the viewer outside the holder's terminal context.
            process.environment = ProcessInfo.processInfo.environment.filter {
                !contextKeys.contains($0.key)
            }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch { return false }
        }
        if useLoginAgent && launch("/bin/launchctl", ["kickstart", "gui/\(getuid())/dev.rexmote.viewer"]) { return }
        _ = launch("/usr/bin/open", ["-g", "-a", Installation.app.path, "--args", "--port", String(port)])
    }
}
