import AppKit
import ApplicationServices
import RexmoteCore
import ScreenCaptureKit

enum DesktopSessionState {
    case active, locked, inactive, unavailable

    init(snapshot: [String: Any]?, uid: uid_t) {
        guard let snapshot, uid != 0, let user = snapshot[kCGSessionUserIDKey] as? NSNumber,
            CFGetTypeID(user) != CFBooleanGetTypeID(), let sessionUID = uid_t(exactly: user),
            let onConsole = snapshot[kCGSessionOnConsoleKey] as? Bool,
            let loggedIn = snapshot[kCGSessionLoginDoneKey] as? Bool
        else { self = .unavailable; return }
        guard sessionUID == uid, loggedIn else { self = .inactive; return }
        // WindowServer omits the lock flag when the desktop is unlocked.
        if let lock = snapshot["CGSSessionScreenIsLocked"] {
            guard let locked = lock as? Bool else { self = .unavailable; return }
            if locked { self = .locked; return }
        }
        self = onConsole ? .active : .inactive
    }

    static func current() -> Self {
        Self(snapshot: CGSessionCopyCurrentDictionary() as? [String: Any], uid: geteuid())
    }

    var interruption: (state: String, detail: String)? {
        switch self {
        case .active: return nil
        case .locked: return ("locked", "Unlock the remote Mac. This pane will resume automatically.")
        case .inactive: return ("inactive", "Switch to this account on the remote Mac. This pane will resume automatically.")
        case .unavailable: return ("unavailable", "Waiting for macOS to confirm the graphical session.")
        }
    }
}

final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let pump: FramePump
    private let lock = NSLock()
    private enum State {
        case starting(CaptureImage?), streaming, stopped
    }
    private var state: State = .starting(nil)
    var failed: ((String) -> Void)?
    init(pump: FramePump) { self.pump = pump }
    func enable() {
        lock.withLock {
            guard case .starting(let first) = state else { return }
            state = .streaming
            if let first { pump.offer(first) }
        }
    }
    func disable() { lock.withLock { state = .stopped } }
    func stream(_ stream: SCStream, didStopWithError error: Error) { failed?(error.localizedDescription) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue,
            let buffer = sample.imageBuffer
        else { return }
        offer(CaptureImage(buffer: buffer, time: ProcessInfo.processInfo.systemUptime))
    }
    func offer(_ image: CaptureImage) {
        lock.withLock {
            switch state {
            case .starting: state = .starting(image)
            case .streaming: pump.offer(image)
            case .stopped: break
            }
        }
    }
}

@MainActor final class HostSession: NSObject {
    let request: LaunchRequest, connection: WireSocket, pump: FramePump, input: InputController
    var desired: Configuration?, applied: Configuration?, stopped = false, reconciling = false
    private var needsReconcile = false
    private struct CaptureFormat: Equatable {
        let display: CGDirectDisplayID
        let nativeSize: PixelSize
        let frameSize: PixelSize
        let fps: Int
    }
    var stream: SCStream?, output: CaptureOutput?
    private var captureFormat: CaptureFormat?
    var statusItem: NSStatusItem?, timer: Timer?
    var lastHeartbeat = ProcessInfo.processInfo.systemUptime, lastInventory = 0.0
    var displays: [DisplayInfo] = []
    private var lastStatus: HostStatus?
    private let clipboard = HostClipboard(board: .general)
    private let sessionState: () -> DesktopSessionState
    private var pendingTransition: DesktopSessionState?
    let paneDisplay = PaneDisplay()
    private var modeRequestedAt = 0.0
    let power = PowerLease()
    init(request: LaunchRequest, connection: WireSocket, sessionState: @escaping () -> DesktopSessionState = DesktopSessionState.current) {
        self.request = request
        self.connection = connection
        self.sessionState = sessionState
        pump = FramePump(connection: connection)
        input = InputController()
        super.init()
    }
    func start() throws {
        try connection.send(Packet(.hello(version: DesktopProtocol.version, token: request.token)))
        pump.failed = { [weak self] message in Task { @MainActor in self?.fail(message) } }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "rexmote desktop sharing")
        item.button?.toolTip = "rexmote — desktop sharing"
        let menu = NSMenu()
        menu.addItem(withTitle: "Sharing this desktop", action: nil, keyEquivalent: "")
        let stop = NSMenuItem(title: "Stop sharing", action: #selector(stopFromMenu), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        item.menu = menu
        statusItem = item
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self, selector: #selector(screenChanged), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sessionWillSuspend(_:)), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(screenChanged), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sessionMayResume), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(sessionWillSuspend(_:)),
                                name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(sessionMayResume),
                                name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A blocking reader hands each bounded batch to the main actor before reading again.
        DispatchQueue(label: "rexmote.helper.control").async { [weak self, connection] in
            do {
                while true {
                    let packets = try connection.receive()
                    let ready = DispatchSemaphore(value: 0)
                    Task { @MainActor in
                        defer { ready.signal() }
                        guard let self = self, !self.stopped else { return }
                        for packet in packets { self.receive(packet) }
                    }
                    ready.wait()
                }
            } catch { Task { @MainActor in self?.stop() } }
        }
        scheduleReconcile()
    }
    func receive(_ packet: Packet) {
        guard !stopped else { return }
        switch packet.message {
        case .heartbeat: lastHeartbeat = ProcessInfo.processInfo.systemUptime
        case .configure(let config):
            guard config.valid, config.revision > (desired?.revision ?? 0) else {
                fail("Invalid desktop configuration.")
                return
            }
            desired = config
            input.enabled = false
            var paused = config
            paused.paused = true
            pump.configure(paused)
            scheduleReconcile()
        case .acknowledge(let id): pump.acknowledge(id)
        case .refresh: pump.refresh()
        case .input(let revision, let event, let copyRequest):
            if case .releaseAll = event {
                clipboard.cancelFilePaste()
                input.releaseAll()
                return
            }
            guard canControl(revision: revision) else {
                if let copyRequest { sendCopy(copyRequest, changed: false, contents: Data()) }
                if let id = FinderClipboard.id(in: packet.payload) { try? connection.send(Packet(.filePasteResult(id, applied: false))) }
                return
            }
            do {
                if let copyRequest {
                    let application = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    try clipboard.copy(
                        perform: { try input.handle(event) },
                        canRead: { [weak self] in
                            guard let self else { return false }
                            return self.canControl(revision: revision)
                                && NSWorkspace.shared.frontmostApplication?.processIdentifier == application
                        },
                        reply: { [weak self] changed, contents in
                            guard let self else { return }
                            let allowed = self.canControl(revision: revision)
                            self.sendCopy(copyRequest, changed: allowed && changed, contents: allowed ? contents : Data())
                        })
                } else if let reservation = FinderClipboard.reservedID(in: packet.payload) {
                    clipboard.reserve(reservation)
                } else if let id = FinderClipboard.id(in: packet.payload), case .key(let key) = event {
                    clipboard.pasteFiles(id, canPaste: { [weak self] in
                        self?.canControl(revision: revision) == true
                    }, finished: { [connection] applied in
                        try? connection.send(Packet(.filePasteResult(id, applied: applied)))
                    }, perform: { [input] in
                        try? input.pasteShortcut(key)
                    })
                } else if !packet.payload.isEmpty {
                    try clipboard.paste(packet.payload) { try input.handle(event) }
                } else {
                    if event.interruptsFilePaste { clipboard.cancelFilePaste() }
                    try input.handle(event)
                }
            } catch {
                input.enabled = false
                sendStatus(state: "input-error", detail: String(describing: error))
            }
        case .quit: stop()
        default: fail("Unexpected desktop control message.")
        }
    }

    private func sendCopy(_ request: UUID, changed: Bool, contents: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [connection] in
            let packet = Packet(.copied(request: request, changed: changed), payload: contents)
            do { try connection.send(packet) } catch { connection.close() }
        }
    }
    private var desktopState: DesktopSessionState {
        let current = sessionState()
        return current == .active ? pendingTransition ?? .active : current
    }

    func canControl(revision: UInt64) -> Bool {
        guard !stopped, let desired, desired.revision == revision, applied?.revision == revision,
            desired.control, !desired.paused, input.enabled, lastStatus?.state == "streaming"
        else { return false }
        return desktopState == .active
    }

    /// Capture setup yields to the main actor while macOS can lock, switch users, or resize the pane.
    private func canCapture(_ configuration: Configuration?) async -> Bool {
        guard !stopped, desired?.revision == configuration?.revision else { return false }
        guard let reason = desktopState.interruption else { return true }
        await stopCapture(interruption: reason)
        return false
    }
    func scheduleReconcile() {
        guard !stopped else { return }
        needsReconcile = true
        guard !reconciling else { return }
        reconciling = true
        Task {
            while needsReconcile && !stopped {
                needsReconcile = false
                await reconcile()
            }
            reconciling = false
        }
    }
    func reconcile() async {
        guard !stopped else { return }
        let configuration = desired
        guard await canCapture(configuration) else { return }
        if let c = configuration, !c.paused { power.begin() } else { power.end() }
        do {
            guard CGPreflightScreenCaptureAccess() else {
                await stopCapture()
                guard await canCapture(configuration) else { return }
                power.end()
                displays = []
                sendStatus(
                    state: "permission", detail: "Screen Recording is required. Choose Open Permissions in the pane.")
                return
            }
            guard let c = configuration else {
                sendStatus(state: "ready", detail: "Ready to create this pane’s desktop.")
                return
            }
            guard !c.paused else {
                await stopCapture()
                guard await canCapture(c) else { return }
                applied = c
                sendStatus(state: "paused", detail: "Sharing is paused while this pane is hidden.")
                return
            }
            let requested = c.virtualMode ?? VirtualDisplayMode(viewport: CGSize(width: c.maxWidth, height: c.maxHeight))
            if requested != paneDisplay.mode {
                await stopCapture()
                guard await canCapture(c) else { return }
                modeRequestedAt = ProcessInfo.processInfo.systemUptime
            }
            do { try paneDisplay.apply(requested) } catch {
                if paneDisplay.id == nil {
                    sendStatus(
                        state: "unavailable",
                        detail: "macOS declined this desktop size. Resize the pane or reconnect. " + error.localizedDescription)
                    return
                }
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard await canCapture(c) else { return }
            let available = content.displays.filter { $0.displayID == paneDisplay.id }
            displays = available.map { display in
                let bounds = CGDisplayBounds(display.displayID)
                return DisplayInfo(
                    id: display.displayID, name: "Virtual Desktop",
                    x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
            }
            guard let display = available.first, let geometry = displays.first else {
                await stopCapture()
                guard await canCapture(c) else { return }
                awaitingDisplay()
                return
            }
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            // Keep showing the actual desktop while WindowServer publishes its chosen mode.
            let nativeSize = PixelSize(mode?.pixelWidth ?? display.width, mode?.pixelHeight ?? display.height)
            let captureSize = nativeSize.fitting(width: c.maxWidth, height: c.maxHeight)
            let width = captureSize.width
            let height = captureSize.height
            let format = CaptureFormat(
                display: display.displayID, nativeSize: nativeSize, frameSize: PixelSize(width, height), fps: c.fps)
            if captureFormat != format {
                await stopCapture()
                guard await canCapture(c) else { return }
                let capture = SCStreamConfiguration()
                capture.width = width
                capture.height = height
                capture.pixelFormat = kCVPixelFormatType_32BGRA
                capture.minimumFrameInterval = CMTime(value: 1, timescale: Int32(c.fps))
                capture.queueDepth = 3
                capture.showsCursor = true
                capture.capturesAudio = false
                capture.colorSpaceName = CGColorSpace.sRGB
                let output = CaptureOutput(pump: pump)
                output.failed = { [weak self, weak output] error in
                    Task { @MainActor in
                        guard let self = self, self.output === output else { return }
                        self.pauseCapture()
                        if self.desktopState == .active {
                            self.sendStatus(state: "unavailable", detail: "Capture interrupted: \(error). Retrying…")
                        }
                        self.scheduleReconcile()
                    }
                }
                let stream = SCStream(
                    filter: SCContentFilter(display: display, excludingWindows: []), configuration: capture,
                    delegate: output)
                try stream.addStreamOutput(
                    output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "rexmote.capture"))
                self.output = output
                self.stream = stream
                sendStatus(state: "starting", detail: "Starting the desktop stream…")
                try await stream.startCapture()
                guard !stopped else {
                    try? await stream.stopCapture()
                    return
                }
                guard await canCapture(c), self.output === output else {
                    if self.stream === stream { await stopCapture() }
                    return
                }
                pump.configure(c)
                output.enable()
                captureFormat = format
            } else if applied != c {
                sendStatus(state: "starting", detail: "Refreshing the desktop…")
                pump.configure(c)
            }
            guard desired?.revision == c.revision else { return }
            applied = c
            input.display = geometry
            input.enabled = c.control && AXIsProcessTrusted() && CGPreflightPostEventAccess()
            sendStatus(
                state: "streaming", detail: input.enabled ? "Remote desktop control" : "Viewing the remote desktop")
        } catch {
            await stopCapture()
            guard await canCapture(configuration) else { return }
            sendStatus(
                state: "unavailable", detail: "Desktop capture unavailable: \(error.localizedDescription). Retrying…")
        }
    }
    private func pauseCapture() {
        input.enabled = false
        output?.disable()
        output = nil
        captureFormat = nil
        if var config = desired {
            config.paused = true
            pump.configure(config)
        }
        pump.forgetDisplay()
    }
    private func stopCapture(interruption: (state: String, detail: String)? = nil) async {
        pauseCapture()
        let previous = stream
        stream = nil
        if let interruption {
            power.end()
            clipboard.cancel()
            sendStatus(state: interruption.state, detail: interruption.detail)
        }
        try? await previous?.stopCapture()
    }

    private func awaitingDisplay() {
        if ProcessInfo.processInfo.systemUptime - modeRequestedAt < 8 {
            sendStatus(state: "starting", detail: "Waiting for macOS to publish this pane’s display…")
        } else {
            sendStatus(
                state: "unavailable", detail: "macOS hasn’t published this desktop size. Resize the pane or reconnect.")
        }
    }

    func sendStatus(state: String, detail: String) {
        guard !stopped else { return }
        var status = HostStatus(
            hostname: LocalComputer.hostname, screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted() && CGPreflightPostEventAccess(),
            displays: displays, state: state, detail: detail)
        if state == "streaming" { status.captureBackend = "screen-capture-kit" }
        status.selectedDisplayID = paneDisplay.id
        status.virtualDisplayID = paneDisplay.id
        do {
            guard status != lastStatus else { return }
            try connection.send(Packet(.status(status)))
            lastStatus = status
            statusItem?.button?.toolTip = "rexmote · \(state)"
        } catch { stop() }
    }
    func tick() {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastHeartbeat > 5 {
            stop()
            return
        }
        do { try connection.send(Packet(.heartbeat)) } catch {
            stop()
            return
        }
        if now - lastInventory >= 3 {
            lastInventory = now
            pendingTransition = nil
            scheduleReconcile()
        }
    }
    @objc func screenChanged() { scheduleReconcile() }
    @objc func sessionWillSuspend(_ note: Notification) {
        // AppKit announces a switch *before* the session dictionary changes. Stop now,
        // then let the next inventory read the real state even if the paired notice is lost.
        pendingTransition = note.name == NSWorkspace.sessionDidResignActiveNotification ? .inactive : .locked
        lastInventory = ProcessInfo.processInfo.systemUptime
        pauseCapture()
        clipboard.cancel()
        scheduleReconcile()
    }
    @objc func sessionMayResume() {
        pendingTransition = nil
        scheduleReconcile()
    }
    @objc func stopFromMenu() {
        try? connection.send(Packet(.error("Sharing stopped on this Mac.")))
        stop()
    }
    func fail(_ message: String) {
        try? connection.send(Packet(.error(message)))
        stop()
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        clipboard.cancel()
        timer?.invalidate()
        pump.stop()
        input.enabled = false
        output?.disable()
        power.end()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        connection.close()
        let old = stream
        stream = nil
        Task {
            try? await old?.stopCapture()
            paneDisplay.close()
            NSApp.terminate(nil)
        }
    }
}
