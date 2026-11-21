import AppKit
import ImageIO
import RexmoteCore

final class PaneWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// AppKit can send menu shortcuts and their key-up events without a window number.
    static func routeKeyEvent(_ event: NSEvent, in keyWindow: NSWindow?) -> Bool {
        guard let pane = keyWindow as? PaneWindow,
            event.windowNumber <= 0 || event.windowNumber == pane.windowNumber,
            let desktop = pane.firstResponder as? DesktopView, !desktop.isHiddenOrHasHiddenAncestor
        else { return false }
        switch event.type {
        case .keyDown: desktop.keyDown(with: event)
        case .keyUp: desktop.keyUp(with: event)
        default: return false
        }
        return true
    }

    static func routeGesture(_ event: NSEvent, in keyWindow: NSWindow?) -> Bool {
        guard let pane = keyWindow as? PaneWindow, pane.isKeyWindow,
            event.windowNumber <= 0 || event.windowNumber == pane.windowNumber,
            let desktop = pane.firstResponder as? DesktopView
        else { return false }
        switch event.type {
        case .magnify, .rotate, .swipe, .smartMagnify: return desktop.forwardTrackpad(event)
        default: return false
        }
    }
}

@MainActor final class NativePane: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let holderPID: Int32
    private(set) var info: PaneInfo
    private let rexCommand: RexCommand
    let scope: RemoteSession
    let origin: SessionHost?
    private let window = PaneWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let content = PaneContent()
    private var desktop: DesktopView { content.desktop }
    private var activity = FileTransferActivity.clear
    private let activityQueue = DispatchQueue(label: "rexmote.file-activity")
    private var pendingFilePaste: UUID?
    private var fileUpload: Task<Void, Never>?
    private var promptTicket = UUID().uuidString
    private var credential: (prompt: String, reply: (String?) -> Void)?
    private var credentialTimeout: DispatchWorkItem?
    private let port: UInt16?
    private var connection: DesktopConnection?, status: HostStatus?, configuration: Configuration?
    private var lastImage: CGImage?, frameRevision: UInt64?
    private var pendingFocus = true, rexFocused = false, stopped = false
    private var resizeWork: DispatchWorkItem?
    private var viewport = CGSize.zero, backingScale: CGFloat = 1

    init(id: String, scope: RemoteSession, pid: Int32, origin: SessionHost?, port: UInt16? = nil) throws {
        guard !scope.host.isEmpty, origin?.isThisMac != true else {
            throw RexmoteError.invalid("This Rex session is already on this Mac.")
        }
        self.port = port
        self.scope = scope
        self.origin = origin
        self.holderPID = pid
        info = PaneInfo(
            id: id, session: scope.session, holderPID: pid, rexHost: scope.host, host: scope.host, title: scope.host)
        rexCommand = try RexCommand(host: scope.host)
        super.init()
    }

    private func fileTransferStatus(_ next: FileTransferActivity) {
        guard next != activity else { return }
        activity = next
        switch next {
        case .sent, .received, .clear: info.fileTransfer = nil
        default: info.fileTransfer = next.message
        }
        let session = info.session, block = info.id, command = rexCommand
        activityQueue.async {
            _ = try? command.run(["send", "-s", session, "-b", block, "--", next.holderInput], quiet: true)
        }
    }

    func start() {
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.isExcludedFromWindowsMenu = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.animationBehavior = .none
        window.level = .normal
        window.collectionBehavior = [.managed, .fullScreenAuxiliary, .ignoresCycle]
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        window.contentView = content
        window.title = info.title
        content.password.delegate = self
        content.primaryAction = { [weak self] in self?.submit() }
        desktop.input = { [weak self] in self?.input($0) }
        desktop.navigateRex = { [weak self] direction in self?.returnToRex(direction) }
        PaneTracker.shared.add(block: info.id, scope: scope, rex: rexCommand, number: window.windowNumber) {
            [weak self] in
            self?.place($0)
        }
        update()
    }

    func windowDidResize(_ notification: Notification) {
        scheduleResize()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) { scheduleResize() }

    private func scheduleResize() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitViewport() }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func commitViewport() {
        viewport = content.bounds.size
        backingScale = window.backingScaleFactor
        configure()
    }

    private func place(_ placement: PaneTracker.Position?) {
        guard !stopped else { return }
        guard let placement else {
            if info.visible {
                info.visible = false
                rexFocused = false
                window.orderOut(nil)
                release()
                configure()
                update()
            }
            return
        }
        let first = !info.visible
        if first { content.applyTheme() }
        content.layer?.cornerRadius = placement.radius
        if window.frame != placement.frame {
            window.setFrame(placement.frame, display: true, animate: false)
        }
        if first || !placement.stacked {
            // A previously hidden Rex window may have been moved to a different Space.
            // Rehome only while showing it against a verified, visible parent.
            let rehome = first && !window.isOnActiveSpace
            if rehome { window.collectionBehavior.insert(.moveToActiveSpace) }
            window.order(.above, relativeTo: placement.parent)
            if rehome { window.collectionBehavior.remove(.moveToActiveSpace) }
        }
        info.visible = true
        if placement.selected && (pendingFocus || (!rexFocused && placement.rexActive)) {
            pendingFocus = false
            focus()
        }
        rexFocused = placement.selected
        if first {
            commitViewport()
            if connection == nil && info.error == nil { connect() } else { update() }
        }
    }

    func requestFocus() {
        pendingFocus = true
        if info.visible {
            pendingFocus = false
            focus()
        }
    }
    private func focus() {
        info.lastUsed = Date.timeIntervalSinceReferenceDate
        window.makeKey()
        if credential != nil {
            window.makeFirstResponder(content.password)
        } else {
            window.makeFirstResponder(desktop)
        }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        info.focused = true
        info.lastUsed = Date.timeIntervalSinceReferenceDate
        if !rexFocused { rex(["block", "focus", "-s", info.session, info.id]) }
        update()
    }
    func windowDidResignKey(_ notification: Notification) {
        info.focused = false
        release()
        update()
    }
    private func rex(_ arguments: [String]) {
        let rex = rexCommand
        DispatchQueue.global(qos: .userInitiated).async { _ = try? rex.run(arguments, quiet: true) }
    }

    private func submit() {
        if credential != nil {
            finishCredential(content.password.stringValue)
        } else if info.state == "permission", let origin {
            let env = sshEnvironment
            DispatchQueue.global(qos: .userInitiated).async {
                try? DesktopLink(origin: origin, environment: env).setup(promptForSSH: true)
            }
        } else {
            connect()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === content.password, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        finishCredential(nil)
        return true
    }

    private var sshEnvironment: [String: String] {
        var env = [String: String]()
        env["REXMOTE_ASKPASS_PANE"] = info.id
        env["REXMOTE_ASKPASS_TICKET"] = promptTicket
        if let port { env["REXMOTE_PORT"] = String(port) }
        return env
    }

    func requestCredential(ticket: String?, prompt: String?, reply: @escaping (String?) -> Void) {
        guard ticket == promptTicket, credential == nil, let prompt, !stopped, origin != nil
        else {
            reply(nil)
            return
        }
        credential = (String(prompt.prefix(300)), reply)
        let timeout = DispatchWorkItem { [weak self] in self?.finishCredential(nil) }
        credentialTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 115, execute: timeout)
        release()
        configure()
        update()
        if window.isKeyWindow { window.makeFirstResponder(content.password) }
    }

    private func finishCredential(_ answer: String?) {
        guard let pending = credential else { return }
        credentialTimeout?.cancel()
        credentialTimeout = nil
        credential = nil
        content.password.stringValue = ""
        pending.reply(answer)
        configure()
        update()
        if window.isKeyWindow { window.makeFirstResponder(desktop) }
    }

    func connect() {
        cancelFileUpload()
        PaneClipboard.shared.forget(info.id)
        finishCredential(nil)
        promptTicket = UUID().uuidString
        connection?.close()
        connection = nil
        status = nil
        configuration = nil
        clearFrame()
        info.error = nil
        guard let origin else {
            info.error = "Update Rexmote on " + info.title + " to open its virtual desktop."
            update()
            return
        }
        update()
        guard info.visible else { return }
        let current = DesktopConnection()
        connection = current
        current.start(origin: origin, environment: sshEnvironment, promptForSSH: true) {
            [weak self, weak current] event in
            guard let self, let current, self.connection === current else { return }
            switch event {
            case .status(let next):
                self.status = next
                if next.state == "signed-out" { self.configuration = nil }
                if ["signed-out", "locked", "permission", "unavailable"].contains(next.state) {
                    PaneClipboard.shared.forget(self.info.id)
                    self.clearFrame()
                }
                self.configure()
                self.update()
            case .frame(let frame, let image):
                guard frame.revision == self.configuration?.revision, self.configuration?.paused == false,
                    ["starting", "streaming", "ready"].contains(self.status?.state ?? "")
                else { return }
                let firstOfRevision = self.frameRevision != frame.revision
                self.lastImage = image
                self.frameRevision = frame.revision
                self.info.width = frame.size.width
                self.info.height = frame.size.height
                self.desktop.show(image)
                if firstOfRevision || self.info.state != "ready" { self.update() }
            case .copied(let request, let changed, let data):
                PaneClipboard.shared.received(data, request: request, changed: changed, pane: self.info.id, host: self.origin) {
                    [weak self] message in self?.fileTransferStatus(message)
                }
            case .filePasteResult(let id, let applied):
                if self.pendingFilePaste == id {
                    self.pendingFilePaste = nil
                    self.fileTransferStatus(applied ? .sent : .cancelled)
                }
            case .failed(let error):
                self.cancelFileUpload()
                PaneClipboard.shared.forget(self.info.id)
                self.finishCredential(nil)
                self.connection = nil
                self.clearFrame()
                self.status = nil
                self.configuration = nil
                self.info.error = error
                self.update()
            }
        }
    }

    private func clearFrame() {
        info.width = nil
        info.height = nil
        frameRevision = nil
        lastImage = nil
        desktop.show(nil)
    }

    private func configure() {
        guard let status, status.state != "signed-out", let connection else { return }
        let stream = PixelSize.capture(viewport: viewport, backingScale: backingScale, maxWidth: 3840)
        let inactive = !info.visible || viewport.width < 1 || viewport.height < 1
        var next = Configuration(
            maxWidth: stream.width, maxHeight: stream.height, fps: 60,
            control: !inactive && status.accessibility == true && status.state != "locked" && credential == nil,
            paused: inactive)
        next.virtualMode = VirtualDisplayMode(viewport: viewport, backingScale: backingScale)
        next.revision = configuration?.revision ?? 0
        guard next != configuration else { return }
        next.revision += 1
        configuration = next
        connection.send(Packet(.configure(next)))
        update()
    }
    private func release() { desktop.releaseInput() }
    private func cancelFileUpload(notify: Bool = false) {
        guard fileUpload != nil || pendingFilePaste != nil else { return }
        pendingFilePaste = nil
        fileUpload?.cancel()
        self.fileUpload = nil
        fileTransferStatus(notify ? .cancelled : .clear)
        if notify {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if self?.activity == .cancelled { self?.fileTransferStatus(.clear) }
            }
        }
    }

    private func input(_ event: RemoteInput) {
        if pendingFilePaste != nil, case .key(let key) = event, key.event == 2 { return }
        if event.interruptsFilePaste { cancelFileUpload(notify: true) }
        guard let connection, let config = configuration else { return }
        if case .releaseAll = event {
            connection.send(Packet(.input(revision: config.revision, event: .releaseAll)))
            return
        }
        guard window.isKeyWindow, info.visible, credential == nil, config.control,
            frameRevision == config.revision,
            status?.state == "streaming"
        else { return }
        if case .key(let key) = event, let action = key.clipboardAction {
            if activity.isFinished { fileTransferStatus(.clear) }
            if action == .paste, let origin, let files = PaneClipboard.shared.filesToPaste(in: info.id) {
                let id = UUID(), change = PaneClipboard.shared.generation
                let input = Message.input(revision: config.revision, event: event)
                connection.send(Packet(input, payload: FinderClipboard.reservation(id)))
                pendingFilePaste = id
                fileTransferStatus(.sending)
                fileUpload = Task { [weak self, weak connection] in
                    do {
                        try await FinderClipboard.inBackground { try FinderTransfer.upload(files, id: id, to: origin) }
                        guard !Task.isCancelled, let self, let connection, self.connection === connection else { return }
                        self.fileUpload = nil
                        guard self.window.isKeyWindow, self.info.visible, self.credential == nil,
                            self.configuration?.revision == config.revision, PaneClipboard.shared.generation == change
                        else { self.cancelFileUpload(notify: true); return }
                        self.fileTransferStatus(.pasting)
                        connection.send(Packet(input, payload: FinderClipboard.reference(id)))
                    } catch {
                        if !Task.isCancelled { self?.fileUpload = nil; self?.pendingFilePaste = nil; self?.fileTransferStatus(.sendFailed) }
                    }
                }
                return
            }
        }
        if let packet = PaneClipboard.shared.packet(for: event, revision: config.revision, pane: info.id) {
            connection.send(packet)
        }
    }
    private func update() {
        if credential != nil {
            info.state = "authenticating"
        } else if info.error != nil {
            info.state = "error"
        } else if let hostState = status?.state,
            ["permission", "locked", "signed-out", "unavailable", "input-error"].contains(hostState)
        {
            info.state = hostState
        } else if connection != nil && !info.visible {
            info.state = "paused"
        } else {
            info.state = lastImage != nil && frameRevision == configuration?.revision ? "ready" : "connecting"
        }
        let state = info.state
        info.mode = configuration?.control == true && info.focused ? "control" : "view-only"
        let selected = status?.displays.first(where: { $0.id == status?.selectedDisplayID })
        info.display = selected?.name
        info.displayID = status?.selectedDisplayID
        info.desktopWidth = selected.map { Int($0.width) }
        info.desktopHeight = selected.map { Int($0.height) }
        let screen: PaneContent.Screen
        if let credential {
            screen = .credential(host: info.title, prompt: credential.prompt)
        } else {
            switch state {
            case "ready": screen = .desktop
            case "connecting":
                screen =
                    lastImage == nil ? .status(title: "Connecting to " + info.title, detail: "", action: nil) : .desktop
            case "permission":
                screen = .status(
                    title: "Screen Recording required",
                    detail: "Allow Rexmote Host to record the screen on " + info.title + ".",
                    action: "Open Permissions")
            case "locked", "signed-out": screen = .status(title: info.title, detail: status?.detail ?? "", action: nil)
            case "paused": screen = .status(title: "Desktop paused", detail: "", action: nil)
            default:
                screen = .status(
                    title: "Connection unavailable", detail: info.error ?? status?.detail ?? "", action: "Reconnect")
            }
        }
        content.show(screen)
        if state == "ready", let lastImage { desktop.show(lastImage) }
    }

    private func returnToRex(_ direction: String?) {
        window.makeFirstResponder(nil)
        window.resignKey()
        RexCommand.localApp?.activate()
        if let direction { rex(["focus", "-s", info.session, direction]) }
    }
    func screenshot() throws -> Data {
        guard let lastImage, ["ready", "paused"].contains(info.state) else {
            throw RexmoteError.invalid("A desktop frame is required for a screenshot.")
        }
        let data = NSMutableData()
        guard let png = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw RexmoteError.invalid("Cannot encode the desktop image.")
        }
        CGImageDestinationAddImage(png, lastImage, nil)
        guard CGImageDestinationFinalize(png) else { throw RexmoteError.invalid("Cannot finish the desktop image.") }
        return data as Data
    }
    func stop() {
        cancelFileUpload()
        stopped = true
        PaneClipboard.shared.forget(info.id)
        finishCredential(nil)
        resizeWork?.cancel()
        PaneTracker.shared.remove(info.id)
        release()
        connection?.close()
        connection = nil
        window.orderOut(nil)
        window.close()
    }
}
