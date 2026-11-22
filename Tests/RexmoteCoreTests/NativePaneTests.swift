import AppKit
import XCTest

@testable import RexmoteCLI
@testable import RexmoteCore

final class NativePaneTests: XCTestCase {
    func testRemoteRexSessionResolvesItsHostByID() throws {
        let server = UUID()
        let session = "session:" + UUID().uuidString.lowercased()
        func selection(_ object: [String: String]) throws -> (UUID, String)? {
            RemoteSession.selection(try JSONEncoder().encode(object))
        }
        XCTAssertNil(try selection(["sessionID": session]))
        XCTAssertNil(try selection(["externalServerID": server.uuidString, "sessionID": "../invalid"]))
        let selected = try XCTUnwrap(selection(["externalServerID": server.uuidString, "sessionID": session]))
        XCTAssertEqual(selected.0, server)
        XCTAssertEqual(selected.1, session)
        let scope = RemoteSession(serverID: server, host: "Studio", session: session)
        XCTAssertTrue(scope.matches(selected))
        XCTAssertFalse(scope.matches((UUID(), session)))
        XCTAssertFalse(scope.matches(nil))
        let hosts = ["hosts": [["host": ["id": "host:" + server.uuidString.lowercased(), "label": "Studio Mac"]]]]
        XCTAssertEqual(RemoteSession.label(for: server, in: hosts), "Studio Mac")
        XCTAssertNil(RemoteSession.label(for: UUID(), in: hosts))
    }

    private let scope = RemoteSession(serverID: UUID(), host: "Studio", session: "remote-test")
    private let remote = SessionHost(
        account: "demo", hostname: "studio.local", vpnAddress: nil, publicKeys: ["ssh-ed25519 Zml4dHVyZQ=="])

    @MainActor func testCurrentMachineCannotBecomeAPaneEvenThroughAnExternalRexAlias() throws {
        XCTAssertTrue(SessionHost.current.isThisMac)
        XCTAssertThrowsError(
            try NativePane(id: "same", scope: scope, pid: 42, origin: .current))
        XCTAssertThrowsError(
            try NativePane(
                id: "same", scope: RemoteSession(serverID: UUID(), host: "", session: "test"), pid: 42, origin: remote))
    }

    @MainActor func testLegacyHolderCannotRedirectThePaneOrFallBackToTheViewingMac() throws {
        let data = Data(#"{"id":"desktop","pid":42,"arguments":["--ssh","wrong-mac"]}"#.utf8)
        let holder = try JSONDecoder().decode(HostedPane.self, from: data)
        let pane = try NativePane(
            id: holder.id, scope: scope, pid: holder.pid, origin: holder.origin)
        defer { pane.stop() }
        pane.connect()
        XCTAssertEqual(pane.info.state, "error")
        XCTAssertEqual(pane.info.host, "Studio")
        XCTAssertTrue(pane.info.error?.contains("Update Rexmote on Studio") == true)
    }

    func testSpaceTransitionIgnoresMovingCompositorBounds() {
        var anchor = WindowAnchor()
        let rest = CGRect(x: 8, y: 50, width: 1454, height: 898)
        XCTAssertFalse(anchor.accepts(rest, now: 0, dragging: false))
        XCTAssertTrue(anchor.accepts(rest, now: 0.1, dragging: false))
        for step in 1...12 {
            let intermediate = rest.offsetBy(dx: CGFloat(step) * 20, dy: 0)
            XCTAssertFalse(anchor.accepts(intermediate, now: 0.1 + Double(step) / 30, dragging: false))
        }
        XCTAssertFalse(anchor.accepts(rest, now: 0.6, dragging: false))
        XCTAssertTrue(anchor.accepts(rest, now: 0.7, dragging: false))
        XCTAssertTrue(anchor.accepts(rest.offsetBy(dx: 12, dy: 8), now: 0.71, dragging: true))
    }

    func testAReversibleOrPausedSpaceSwipeNeverBecomesThePanelFrame() {
        var anchor = WindowAnchor()
        let parent = CGRect(x: 12, y: 80, width: 940, height: 720)
        let panel = CGRect(x: 40, y: 144, width: 700, height: 600)
        XCTAssertFalse(anchor.accepts(parent, now: 0, dragging: false))
        XCTAssertTrue(anchor.accepts(parent, now: 0.1, dragging: false))

        for (time, offset) in [(0.2, 200.0), (0.7, 200.0), (0.9, 100.0)] {
            let transformed = WindowAnchor.isAnimating(panel: panel, presented: panel.offsetBy(dx: offset, dy: 0))
            XCTAssertTrue(transformed)
            XCTAssertFalse(anchor.accepts(parent.offsetBy(dx: offset, dy: 0), now: time,
                                          dragging: true, panelIsAnimating: transformed))
        }
        XCTAssertFalse(WindowAnchor.isAnimating(panel: panel, presented: panel.offsetBy(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(WindowAnchor.isAnimating(panel: panel, presented: panel.insetBy(dx: 70, dy: 50)))
        XCTAssertFalse(anchor.accepts(parent, now: 1, dragging: false))
        XCTAssertTrue(anchor.accepts(parent, now: 1.1, dragging: false))
    }

    func testRememberedRexWindowStaysBoundWhenAnotherSpaceHasTheSameTitle() {
        XCTAssertEqual(WindowAnchor.parent(remembered: nil, named: [2], visible: [1, 2]), 2)
        XCTAssertNil(WindowAnchor.parent(remembered: 2, named: [1], visible: [1]))
        XCTAssertEqual(WindowAnchor.parent(remembered: 2, named: [1], visible: [1, 2]), 2)
        XCTAssertNil(WindowAnchor.parent(remembered: nil, named: [1, 2], visible: [1, 2]))
    }

    @MainActor func testDesktopFillsThePaneAndSignInStaysInTheSameWindow() throws {
        let pane = try NativePane(id: "surface", scope: scope, pid: 42, origin: remote)
        pane.start()
        defer { pane.stop() }
        let window = try XCTUnwrap(NSApplication.shared.windows.first { $0.delegate === pane })
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertEqual(window.animationBehavior, .none)
        XCTAssertFalse(window.isMovable)
        let content = try XCTUnwrap(window.contentView as? PaneContent)
        content.show(.credential(host: "studio", prompt: "Passphrase for your SSH key"))
        XCTAssertFalse(content.password.isHidden)
        XCTAssertEqual(content.password.placeholderAttributedString?.string, "SSH key passphrase")
        content.show(.credential(host: "Studio", prompt: "(demo@rexmote-session) Password:"))
        XCTAssertEqual(content.password.placeholderAttributedString?.string, "Password")
        XCTAssertTrue(content.desktop.isHidden)
        content.show(.desktop)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.desktop.frame, content.bounds)
        XCTAssertFalse(content.desktop.isHidden)
        XCTAssertTrue(content.password.isHiddenOrHasHiddenAncestor)
    }

    func testPublicOpenRejectsAnExplicitMachineOrPhysicalDisplay() {
        for args in [["--local"], ["--display", "main"], ["--ssh", "studio"], ["another-mac"]] {
            XCTAssertThrowsError(try PaneCommands.open(args))
        }
    }

    func testVirtualDesktopTracksPanePointsIndependentlyOfCaptureResolution() throws {
        let viewport = CGSize(width: 723, height: 792)
        let desktop = VirtualDisplayMode(viewport: viewport)
        XCTAssertEqual(desktop.points.width, 800)
        XCTAssertEqual(Double(desktop.points.height) / 800, 792.0 / 723, accuracy: 0.002)
        let capture = PixelSize.capture(viewport: viewport, backingScale: 2, maxWidth: 1920)
        XCTAssertEqual(capture, PixelSize(1446, 1584))
        XCTAssertFalse(desktop.hiDPI)
        XCTAssertTrue(VirtualDisplayMode(viewport: viewport, backingScale: 2).hiDPI)
        XCTAssertFalse(VirtualDisplayMode(viewport: CGSize(width: 360, height: 300), backingScale: 2).hiDPI)
        XCTAssertFalse(VirtualDisplayMode(viewport: CGSize(width: 2510, height: 1600), backingScale: 2).hiDPI)
        XCTAssertFalse(VirtualDisplayMode(points: PixelSize(1920, 1600), hiDPI: true).valid)

        let wide = CGSize(width: 2520, height: 990)
        XCTAssertEqual(VirtualDisplayMode(viewport: wide).points, PixelSize(2520, 990))
        XCTAssertEqual(PixelSize.capture(viewport: wide, backingScale: 2, maxWidth: 640), PixelSize(640, 251))
        var config = Configuration(maxWidth: capture.width, maxHeight: capture.height)
        config.virtualMode = desktop
        XCTAssertTrue(config.valid)
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config)), config)
    }

    func testTinyAndExtremePanesNeverRequestTinyOrOversizedDisplayModes() {
        for width in [1, 41, 145, 723, 800, 1280, 4096, 10000] {
            for height in [1, 48, 67, 600, 812, 2160, 4096, 10000] {
                let pane = CGSize(width: width, height: height)
                XCTAssertTrue(VirtualDisplayMode(viewport: pane).valid, "Viewport " + String(describing: pane))
                XCTAssertTrue(PixelSize.capture(viewport: pane, backingScale: 2, maxWidth: 1920).valid)
            }
        }
        for invalid in [PixelSize(1, 1), PixelSize(799, 599), PixelSize(4096, 4096), PixelSize(Int.max, Int.max)] {
            var config = Configuration()
            config.virtualMode = VirtualDisplayMode(points: invalid)
            XCTAssertFalse(config.valid)
        }
        XCTAssertEqual(
            PixelSize.capture(viewport: CGSize(width: 41, height: 67), backingScale: 2, maxWidth: 1920),
            PixelSize(82, 134))
    }

    @MainActor func testFocusedDesktopReceivesCommandChordsIncludingRepeatsAndReleases() throws {
        let pane = PaneWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 80),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let desktop = DesktopView()
        pane.contentView = desktop
        XCTAssertTrue(desktop.needsPanelToBecomeKey)
        XCTAssertTrue(pane.makeFirstResponder(desktop))
        var sent: [RemoteInput] = []
        desktop.input = { sent.append($0) }
        desktop.navigateRex = { _ in XCTFail("Command shortcuts belong to the remote desktop.") }
        let chords: [(UInt16, String, NSEvent.ModifierFlags, Int)] = [
            (13, "w", .command, 8), (17, "t", .command, 8), (15, "r", .command, 8),
            (8, "c", .command, 8), (9, "v", .command, 8), (12, "q", .command, 8),
            (24, "=", .command, 8), (46, "m", [.command, .shift], 9), (37, "l", [.command, .option], 10),
            (123, "", [.control, .option, .command], 14),
        ]
        for (code, text, flags, wireFlags) in chords {
            sent.removeAll()
            for (type, repeatKey) in [(NSEvent.EventType.keyDown, false), (.keyDown, true), (.keyUp, false)] {
                let event = try XCTUnwrap(
                    NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: flags,
                        timestamp: 0, windowNumber: type == .keyUp ? 0 : pane.windowNumber, context: nil,
                        characters: text, charactersIgnoringModifiers: text, isARepeat: repeatKey, keyCode: code))
                XCTAssertTrue(PaneWindow.routeKeyEvent(event, in: pane))
            }
            XCTAssertEqual(
                sent, [1, 2, 3].map { .key(KeyInput(keyCode: code, modifiers: wireFlags, event: $0, text: text)) })
        }
    }

    @MainActor func testKeyboardRoutingLeavesOtherWindowsAndSecureFieldsAlone() throws {
        let frame = NSRect(x: 0, y: 0, width: 100, height: 80)
        let pane = PaneWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let other = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let content = PaneContent(frame: frame)
        pane.contentView = content
        content.show(.desktop)
        XCTAssertTrue(pane.makeFirstResponder(content.desktop))
        var sent: [RemoteInput] = []
        content.desktop.input = { sent.append($0) }
        func chord(window: Int, key: UInt16 = 13, flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: window, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: key))
        }
        XCTAssertFalse(PaneWindow.routeKeyEvent(try chord(window: other.windowNumber), in: pane))
        XCTAssertFalse(PaneWindow.routeKeyEvent(try chord(window: 0), in: nil))
        XCTAssertFalse(PaneWindow.routeKeyEvent(try chord(window: 0), in: other))
        var direction: String?
        content.desktop.navigateRex = { direction = $0 }
        XCTAssertTrue(PaneWindow.routeKeyEvent(try chord(window: 0, key: 123, flags: [.control, .option]), in: pane))
        XCTAssertEqual(direction, "left")
        content.show(.credential(host: "Studio", prompt: "Password:"))
        XCTAssertFalse(PaneWindow.routeKeyEvent(try chord(window: 0), in: pane))
        XCTAssertTrue(pane.makeFirstResponder(content.password))
        XCTAssertFalse(PaneWindow.routeKeyEvent(try chord(window: 0), in: pane))
        XCTAssertTrue(sent.isEmpty)
    }

    @MainActor func testPointerUsesTheDisplayedPixelsAcrossLetterboxingAndResize() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 160, height: 160),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let view = DesktopView()
        window.contentView = view
        let bitmap = try XCTUnwrap(
            CGContext(
                data: nil, width: 160, height: 80, bitsPerComponent: 8, bytesPerRow: 640,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        view.show(try XCTUnwrap(bitmap.makeImage()))
        var clicks: [PointerInput] = []
        view.input = { if case .pointer(let pointer) = $0 { clicks.append(pointer) } }
        func click(_ x: CGFloat, _ y: CGFloat, count: Int = 1, type: NSEvent.EventType = .leftMouseDown) throws {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: CGPoint(x: x, y: y),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: count, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        view.layoutSubtreeIfNeeded()
        try click(80, 10)
        XCTAssertTrue(clicks.isEmpty)
        try click(120, 60)
        XCTAssertEqual(clicks.last?.x, 0.75)
        XCTAssertEqual(clicks.last?.y, 0.75)
        window.setContentSize(CGSize(width: 240, height: 120))
        view.layoutSubtreeIfNeeded()
        try click(60, 90)
        XCTAssertEqual(clicks.last?.x, 0.25)
        XCTAssertEqual(clicks.last?.y, 0.25)
        clicks.removeAll()
        for count in 1...3 {
            try click(60, 90, count: count)
            try click(60, 90, count: count, type: .leftMouseUp)
        }
        let decoded = try JSONDecoder().decode([PointerInput].self, from: JSONEncoder().encode(clicks))
        XCTAssertEqual(decoded.map(\.clickCount), [1, 1, 2, 2, 3, 3])
        let legacy = Data(#"{"action":"down","x":0.25,"y":0.25,"button":0,"modifiers":0}"#.utf8)
        let oldClick = try JSONDecoder().decode(PointerInput.self, from: legacy)
        XCTAssertTrue(oldClick.valid)
        XCTAssertNil(oldClick.clickCount)
    }

    func testSSHPinsTheSessionHostBeforeAuthenticationAndScopesConnectionReuse() throws {
        let link = DesktopLink(origin: remote)
        defer { link.close() }
        let process = try link.sshProcess(remote, operation: .relay, prompt: true)
        let args = try XCTUnwrap(process.arguments)
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("HostKeyAlias=rexmote-session"))
        XCTAssertTrue(args.contains("Hostname=studio.local"))
        XCTAssertEqual(process.environment?["SSH_ASKPASS_REQUIRE"], "force")
        let pin = try XCTUnwrap(args.first(where: { $0.hasPrefix("UserKnownHostsFile=") }))
        let file = String(pin.dropFirst("UserKnownHostsFile=".count))
        XCTAssertEqual(try String(contentsOfFile: file), "rexmote-session " + remote.publicKeys[0] + "\n")
        let another = SessionHost(
            account: remote.account, hostname: remote.hostname, vpnAddress: nil,
            publicKeys: ["ssh-ed25519 YW5vdGhlcg=="])
        let dir = URL(fileURLWithPath: "/tmp/test-rexmote")
        XCTAssertNotEqual(
            another.controlSocket(for: "studio.local", in: dir), remote.controlSocket(for: "studio.local", in: dir))
        link.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
    }

    @MainActor func testNarrowRexSplitControlsTheActualWindowWidth() throws {
        let app = NSApplication.shared
        let pane = try NativePane(
            id: "desktop", scope: scope, pid: getpid(), origin: remote)
        pane.start()
        defer { pane.stop() }
        let window = try XCTUnwrap(app.windows.first { $0.delegate === pane })
        let parent = CGRect(x: 8, y: 50, width: 723, height: 898)
        let compact = PaneChrome { $0 == "paneDensity" ? "compact" : nil }
        let layout: [String: Any] = [
            "active_window_id": "tab",
            "windows": [
                [
                    "window_id": "tab",
                    "layers": [["kind": "tiled", "layout": ["block_id": "desktop", "rect": [0.5, 0, 0.5, 1]]]],
                ]
            ],
        ]
        let split = try XCTUnwrap(PanePlacement.locate(block: "desktop", in: layout))
        let frame = compact.body(split, in: parent)
        XCTAssertEqual(frame, CGRect(x: 371, y: 126, width: 360, height: 822))
        for width in [frame.width, 150, 723] {
            let target = CGRect(x: frame.minX, y: frame.minY, width: width, height: frame.height)
            window.setFrame(target, display: false)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.frame, target)
            let content = try XCTUnwrap(window.contentView as? PaneContent)
            content.show(.credential(host: "Studio", prompt: "Password:"))
            content.layoutSubtreeIfNeeded()
            let field = content.password.convert(content.password.bounds, to: content)
            XCTAssertGreaterThan(field.width, 0)
            XCTAssertEqual(field.midX, content.bounds.midX, accuracy: 1)
            XCTAssertTrue(content.bounds.contains(field))
        }
    }

    func testFrameBufferReconstructsAndRequiresARefreshAfterResizeOrCorruption() throws {
        let size = PixelSize(8, 4)
        let rgba = Data((0..<(8 * 4 * 4)).map(UInt8.init))
        let compressed = try PixelCompression.compress(rgba)
        let full = FrameInfo(
            id: 0, size: size, full: true, captureTime: 0,
            patches: [Patch(rect: PixelRect(0, 0, 8, 4), offset: 0, length: compressed.count)])
        var buffer = FrameBuffer()
        try buffer.apply(full, payload: compressed)
        let firstImage = try XCTUnwrap(buffer.image)
        XCTAssertEqual(firstImage.width, 8)
        let patch = Data(repeating: 212, count: 16)
        let bytes = try PixelCompression.compress(patch)
        var delta = FrameInfo(
            id: 1, size: size, full: false, captureTime: 1,
            patches: [Patch(rect: PixelRect(2, 1, 2, 2), offset: 0, length: bytes.count)])
        try buffer.apply(delta, payload: bytes)
        var expected = rgba
        expected.replaceSubrange(40..<48, with: patch.prefix(8))
        expected.replaceSubrange(72..<80, with: patch.suffix(8))
        XCTAssertEqual(buffer.pixels, expected)
        XCTAssertEqual(firstImage.dataProvider?.data as Data?, rgba)
        delta.revision += 1
        XCTAssertThrowsError(try buffer.apply(delta, payload: bytes))
        delta.revision = 0
        XCTAssertThrowsError(try buffer.apply(delta, payload: Data(repeating: 0, count: bytes.count)))
        XCTAssertThrowsError(try buffer.apply(delta, payload: bytes))
    }

    func testPaneFollowsSplitZoomAndActiveTab() throws {
        let layer: [String: Any] = [
            "kind": "tiled", "layer_id": "main",
            "layout": [
                "split": [
                    "before": ["block_id": "editor", "rect": [0.0, 0, 0.7, 1]],
                    "after": ["block_id": "desktop", "rect": [0.7, 0, 0.3, 1]],
                ]
            ],
        ]
        var window: [String: Any] = ["window_id": "tab", "layers": [layer]]
        func place(active: String = "tab") -> PanePlacement? {
            PanePlacement.locate(block: "desktop", in: ["windows": [window], "active_window_id": active])
        }
        XCTAssertEqual(place()?.rect, CGRect(x: 0.7, y: 0, width: 0.3, height: 1))
        XCTAssertNil(place(active: "other"))
        window["zoomed_block_id"] = "editor"
        XCTAssertNil(place())
        window["zoomed_block_id"] = "desktop"
        XCTAssertEqual(place()?.rect, CGRect(x: 0, y: 0, width: 1, height: 1))
        window.removeValue(forKey: "zoomed_block_id")
        let floating: [String: Any] = ["layer_id": "dialog", "kind": "floating", "bounds": [0.6, 0, 0.4, 0.5]]
        window["layers"] = [layer, floating]
        XCTAssertNil(place())
    }
}
