import Darwin
import Foundation
import RexmoteCore

/// Launch the signed capture helper on this Mac, or carry the same packet
/// protocol on the stdin/stdout of an authenticated, non-interactive SSH session.
final class DesktopLink {
    static let sshGreeting = "rexmote-stdio-v4"
    let origin: SessionHost?
    private var knownHosts: URL?
    let expectedToken: String
    private var ssh: Process?

    let environment: [String: String]
    let cancelled: () -> Bool
    init(
        origin: SessionHost? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
        cancelled: @escaping () -> Bool = { false }
    ) {
        self.environment = environment
        self.cancelled = cancelled
        self.origin = origin
        expectedToken = origin == nil ? UUID().uuidString + UUID().uuidString : Self.sshGreeting
    }

    func connect(promptForSSH: Bool = false) throws -> WireSocket {
        if let host = origin { return try connectSSH(host, prompt: promptForSSH) }
        guard Self.hasConsoleSession else { throw RexmoteError.system(Self.signedOutStatus.detail) }
        let listener = try LocalListener()
        let file = URL(fileURLWithPath: listener.directory).appendingPathComponent("launch.json")
        let request = LaunchRequest(socketPath: listener.path, token: expectedToken)
        try JSONEncoder().encode(request).write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else {
            throw RexmoteError.system("Unable to protect the helper launch file.")
        }
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-g", "-n", "-a", Installation.host.path, "--args", "--service", file.path]
        launcher.standardInput = FileHandle.nullDevice
        launcher.standardOutput = FileHandle.nullDevice
        try launcher.run()
        launcher.waitUntilExit()
        guard launcher.terminationStatus == 0 else {
            throw RexmoteError.system("Could not launch the signed Rexmote app.")
        }

        var wait = pollfd(fd: listener.fd, events: Int16(POLLIN), revents: 0)
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while !cancelled() && ProcessInfo.processInfo.systemUptime < deadline {
            let result = Darwin.poll(&wait, 1, 200)
            if result > 0, let wire = try listener.acceptConnection() { return wire }
            if result < 0 && errno != EINTR { break }
        }
        throw RexmoteError.system("The desktop helper did not connect. Run rexmote doctor on the sharing Mac.")
    }

    enum SSHOperation: String { case relay, setup }

    func sshTransport(_ host: SessionHost, prompt: Bool) throws -> (process: Process, address: String) {
        let address = try host.address(localVPN: SessionHost.localVPNAddress)
        var pattern = Array("/tmp/rexmote-host-keys.XXXXXX".utf8CString)
        let fd = mkstemp(&pattern)
        guard fd >= 0 else { throw RexmoteError.system("Could not create the SSH host key file.") }
        Darwin.close(fd)
        let file = URL(fileURLWithPath: String(cString: pattern))
        knownHosts = file
        try host.writeKnownHosts(to: file)

        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var env = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        if prompt {
            env["SSH_ASKPASS"] = Installation.app.appendingPathComponent("Contents/MacOS/rexmote").path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["REXMOTE_ASKPASS_HOST"] = address
        }
        ssh.environment = env
        let socket = host.controlSocket(for: address, in: ViewerEndpoint.directory)
        let multiplex = [
            "-o", "ControlPath=" + (socket ?? "none"), "-o", "ControlMaster=" + (socket == nil ? "no" : "auto"), "-o",
            "ControlPersist=60",
        ]
        ssh.arguments =
            multiplex + [
                "-T", "-o", "BatchMode=" + (prompt ? "no" : "yes"), "-o", "NumberOfPasswordPrompts=1",
                "-o", "Hostname=" + address, "-o", "HostKeyAlias=rexmote-session", "-o",
                "UserKnownHostsFile=" + file.path,
                "-o", "GlobalKnownHostsFile=/dev/null", "-o", "KnownHostsCommand=none", "-o", "VerifyHostKeyDNS=no",
                "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no",
                "-o", "ConnectTimeout=8", "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no",
                "-l", host.account, "--",
            ]
        return (ssh, address)
    }

    func sshProcess(_ host: SessionHost, operation: SSHOperation, prompt: Bool) throws -> Process {
        let (ssh, address) = try sshTransport(host, prompt: prompt)
        let command = "exec \"$HOME/Applications/Rexmote.app/Contents/MacOS/rexmote\" " + operation.rawValue
        ssh.arguments = (ssh.arguments ?? []) + [address, command]
        return ssh
    }

    private func connectSSH(_ host: SessionHost, prompt: Bool) throws -> WireSocket {
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw RexmoteError.system("Cannot open the SSH channel.")
        }
        let wire = WireSocket(fd: pair[0])
        let child = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
        defer { try? child.close() }
        let process = try sshProcess(host, operation: .relay, prompt: prompt)
        process.standardInput = child
        process.standardOutput = child
        try process.run()
        ssh = process
        return wire
    }

    func status() throws -> HostStatus {
        if origin == nil, !Self.hasConsoleSession { return Self.signedOutStatus }
        let wire = try connect()
        defer {
            try? wire.send(Packet(.quit))
            wire.close()
            close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var authenticated = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            var watch = pollfd(fd: wire.fd, events: Int16(POLLIN), revents: 0)
            if poll(&watch, 1, 250) <= 0 { continue }
            for packet in try wire.receive() {
                if !authenticated {
                    guard case .hello(DesktopProtocol.version, expectedToken) = packet.message else {
                        throw RexmoteError.invalid("Install the same version of Rexmote on both Macs.")
                    }
                    authenticated = true
                } else if case .status(let value) = packet.message {
                    return value
                }
            }
        }
        throw RexmoteError.system("The sharing Mac did not return its status.")
    }

    func setup(promptForSSH: Bool = false) throws {
        let process: Process
        if let host = origin {
            process = try sshProcess(host, operation: .setup, prompt: promptForSSH)
        } else {
            guard Self.hasConsoleSession else { throw RexmoteError.system(Self.signedOutStatus.detail) }
            process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", "-a", Installation.host.path, "--args", "--setup"]
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RexmoteError.system("Could not open permission setup on the sharing Mac.")
        }
    }

    static var hasConsoleSession: Bool {
        var console = stat()
        return lstat("/dev/console", &console) == 0 && console.st_uid == geteuid() && geteuid() != 0
    }

    static var signedOutStatus: HostStatus {
        HostStatus(
            hostname: LocalComputer.hostname, displays: [], state: "signed-out",
            detail: "Sign in to macOS as \(NSUserName()). This pane will connect automatically.")
    }

    func close() {
        if let ssh, ssh.isRunning { ssh.terminate() }
        if let knownHosts {
            try? FileManager.default.removeItem(at: knownHosts)
            self.knownHosts = nil
        }
    }
    deinit { close() }
}

func relayDesktop(_ args: [String]) throws {
    guard args.isEmpty, isatty(STDIN_FILENO) == 0, isatty(STDOUT_FILENO) == 0 else {
        throw RexmoteError.invalid("relay is the transport for a hosted Rex pane.")
    }
    signal(SIGPIPE, SIG_IGN)
    let link = DesktopLink()
    let relay = DesktopRelay(
        input: .standardInput, output: .standardOutput, hasConsole: { DesktopLink.hasConsoleSession })
    try relay.run { (try link.connect(), link.expectedToken) }
}

/// Keep the authenticated SSH channel while the GUI account is signed out.
final class DesktopRelay {
    private let input: FileHandle, output: FileHandle, hasConsole: () -> Bool
    private var decoder = PacketDecoder(), buffer = [UInt8](repeating: 0, count: 65_536)

    init(input: FileHandle, output: FileHandle, hasConsole: @escaping () -> Bool) {
        self.input = input
        self.output = output
        self.hasConsole = hasConsole
    }

    func run(connect: () throws -> (WireSocket, String)) throws {
        try send(Packet(.hello(version: DesktopProtocol.version, token: DesktopLink.sshGreeting)))
        if !hasConsole(), try !waitForSignIn() { return }
        while true {
            do {
                let (wire, token) = try connect()
                defer { wire.close() }
                if try !forward(wire, token: token) { return }
            } catch RexmoteError.disconnected {
                // During logout, LaunchServices can terminate the helper just before the console owner changes.
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while hasConsole(), ProcessInfo.processInfo.systemUptime < deadline {
                    var client = pollfd(fd: input.fileDescriptor, events: Int16(POLLIN), revents: 0)
                    let count = poll(&client, 1, 100)
                    if count < 0 && errno != EINTR { throw RexmoteError.disconnected }
                    if count > 0, try !readClient(client.revents, to: nil) { return }
                }
                if hasConsole() { throw RexmoteError.disconnected }
            } catch {
                if hasConsole() { throw error }
            }
            if try !waitForSignIn() { return }
        }
    }

    private func send(_ packet: Packet) throws {
        try output.write(contentsOf: packet.encoded())
    }

    private func waitForSignIn() throws -> Bool {
        try send(Packet(.status(DesktopLink.signedOutStatus)))
        var lastHeartbeat = ProcessInfo.processInfo.systemUptime
        while !hasConsole() {
            var client = pollfd(fd: input.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let count = poll(&client, 1, 1000)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw RexmoteError.disconnected }
            if count > 0, try !readClient(client.revents, to: nil) { return false }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastHeartbeat >= 1 {
                try send(Packet(.heartbeat))
                lastHeartbeat = now
            }
        }
        return true
    }

    private func forward(_ wire: WireSocket, token: String) throws -> Bool {
        var authenticated = false
        while hasConsole() {
            var fds = [
                pollfd(fd: wire.fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: input.fileDescriptor, events: Int16(POLLIN), revents: 0),
            ]
            let count = poll(&fds, 2, 12_000)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw RexmoteError.system("Desktop relay timed out.") }
            if fds[0].revents & Int16(POLLIN) != 0 {
                for packet in try wire.receive() {
                    if authenticated {
                        try send(packet)
                    } else {
                        guard case .hello(DesktopProtocol.version, token) = packet.message else {
                            throw RexmoteError.invalid("Unexpected desktop helper.")
                        }
                        authenticated = true
                    }
                }
            }
            if try !readClient(fds[1].revents, to: authenticated ? wire : nil) { return false }
            if fds[0].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw RexmoteError.disconnected }
        }
        return true
    }

    private func readClient(_ events: Int16, to wire: WireSocket?) throws -> Bool {
        if events & Int16(POLLIN) != 0 {
            let count = Darwin.read(input.fileDescriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { return true }
            guard count > 0 else { return false }
            for packet in try decoder.feed(Data(buffer.prefix(count))) {
                try wire?.send(packet)
                if case .quit = packet.message { return false }
            }
        }
        return events & Int16(POLLHUP | POLLERR | POLLNVAL) == 0
    }
}
