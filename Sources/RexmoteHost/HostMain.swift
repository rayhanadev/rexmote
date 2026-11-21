import AppKit
import ApplicationServices
import RexmoteCore

@MainActor final class SetupWindow: NSObject, NSWindowDelegate {
    let window = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 580, height: 300), styleMask: [.titled, .closable],
        backing: .buffered, defer: false)
    let status = NSTextField(wrappingLabelWithString: "")
    var timer: Timer?
    override init() {
        super.init()
        window.title = "rexmote · permissions on this Mac"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let description = NSTextField(
            wrappingLabelWithString:
                "rexmote shows this Mac’s desktop inside your connected Rex pane. Enable Screen Recording to view the desktop and Accessibility to control it. You approve these permissions on this Mac.\n\nReconnect the pane after changing permissions. The display icon in the menu bar lets you stop sharing."
        )
        description.frame = NSRect(x: 24, y: 123, width: 532, height: 155)
        window.contentView!.addSubview(description)
        status.frame = NSRect(x: 24, y: 74, width: 532, height: 44)
        window.contentView!.addSubview(status)
        let capture = NSButton(title: "Screen Recording…", target: self, action: #selector(requestCapture))
        capture.frame = NSRect(x: 24, y: 25, width: 252, height: 34)
        let input = NSButton(title: "Accessibility…", target: self, action: #selector(requestInput))
        input.frame = NSRect(x: 304, y: 25, width: 252, height: 34)
        window.contentView!.addSubview(capture)
        window.contentView!.addSubview(input)
        refresh()
    }
    func show() {
        NSApp.setActivationPolicy(.regular)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    func refresh() {
        status.stringValue =
            "Screen Recording: \(CGPreflightScreenCaptureAccess() ? "enabled" : "not enabled")\nAccessibility: \(AXIsProcessTrusted() ? "enabled" : "not enabled")"
    }
    @objc func requestCapture() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }
    @objc func requestInput() {
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        NSApp.terminate(nil)
    }
}

@MainActor final class HostDelegate: NSObject, NSApplicationDelegate {
    var session: HostSession?, setup: SetupWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args == ["--setup"] {
            setup = SetupWindow()
            setup!.show()
            return
        }
        do {
            guard args.count == 2, args[0] == "--service" else {
                throw RexmoteError.invalid("Use rexmote to start desktop sharing.")
            }
            var metadata = stat()
            guard lstat(args[1], &metadata) == 0, metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o600,
                metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size > 0, metadata.st_size <= 4096
            else { throw RexmoteError.invalid("Invalid helper launch file.") }
            let request = try JSONDecoder().decode(
                LaunchRequest.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            guard request.token.count >= 64, request.token.count <= 256,
                request.socketPath == URL(fileURLWithPath: args[1]).deletingLastPathComponent().path + "/session.sock"
            else { throw RexmoteError.invalid("Invalid helper launch request.") }
            let connection = try WireSocket.connect(path: request.socketPath)
            session = HostSession(request: request, connection: connection)
            try session!.start()
        } catch {
            FileHandle.standardError.write(Data("Rexmote: \(error)\n".utf8))
            NSApp.terminate(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        session?.input.enabled = false
        session?.pump.stop()
        session?.connection.close()
        session?.power.end()
        session?.paneDisplay.close()
    }
}

@main @MainActor struct HostMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = HostDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
