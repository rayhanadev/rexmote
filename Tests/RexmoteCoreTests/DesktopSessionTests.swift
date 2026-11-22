import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import RexmoteCore
import ScreenCaptureKit
import XCTest

@testable import RexmoteCLI
@testable import RexmoteHost

final class DesktopSessionTests: XCTestCase {
    private let uid: uid_t = 501
    private var activeSnapshot: [String: Any] {
        [
            kCGSessionUserIDKey as String: NSNumber(value: uid),
            kCGSessionLoginDoneKey as String: true,
            kCGSessionOnConsoleKey as String: true,
        ]
    }

    func testWindowServerSessionSnapshotDistinguishesLockSwitchAndUnavailable() {
        let locked = "CGSSessionScreenIsLocked"
        func state(_ changes: [String: Any]) -> DesktopSessionState {
            DesktopSessionState(snapshot: activeSnapshot.merging(changes) { _, new in new }, uid: uid)
        }
        XCTAssertEqual(state([:]), .active)
        XCTAssertEqual(state([locked: false]), .active)
        XCTAssertEqual(state([locked: true]), .locked)
        XCTAssertEqual(state([kCGSessionOnConsoleKey as String: false]), .inactive)
        XCTAssertEqual(state([kCGSessionLoginDoneKey as String: false]), .inactive)
        XCTAssertEqual(state([kCGSessionUserIDKey as String: NSNumber(value: uid + 1)]), .inactive)
        XCTAssertEqual(DesktopSessionState(snapshot: nil, uid: uid), .unavailable)
        for key in activeSnapshot.keys {
            var incomplete = activeSnapshot
            incomplete.removeValue(forKey: key)
            XCTAssertEqual(DesktopSessionState(snapshot: incomplete, uid: uid), .unavailable, key)
        }
        XCTAssertEqual(state([kCGSessionOnConsoleKey as String: "invalid"]), .unavailable)
    }

    @MainActor func testReconcileResumesTheSameHelperWithoutAnUnlockNotification() async throws {
        var observed = DesktopSessionState.unavailable
        let (session, client) = try helper { observed }
        defer { session.pump.stop() }
        func expectStatus(_ expected: [String]) throws {
            var fd = pollfd(fd: client.fd, events: Int16(POLLIN), revents: 0)
            guard poll(&fd, 1, 1000) == 1 else { return XCTFail("Missing status for \(observed)") }
            var last: String?
            repeat {
                for packet in try client.receive() {
                    if case .status(let status) = packet.message { last = status.state }
                }
            } while poll(&fd, 1, 0) == 1
            let state = try XCTUnwrap(last)
            XCTAssertTrue(expected.contains(state), "Unexpected status \(state) for \(observed)")
            XCTAssertNil(session.paneDisplay.id)
        }
        func finishInventory() async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while session.reconciling {
                guard ContinuousClock.now < deadline else { throw RexmoteError.system("Inventory did not finish") }
                await Task.yield()
            }
        }

        // Repeated inventory checks must see transitions even when AppKit delivers no notifications.
        let transitions: [(DesktopSessionState, [String])] = [
            (.unavailable, ["unavailable"]), (.locked, ["locked"]), (.inactive, ["inactive"]),
            (.active, ["ready", "permission"]), (.locked, ["locked"]), (.active, ["ready", "permission"]),
        ]
        for (snapshot, statuses) in transitions {
            observed = snapshot
            await session.reconcile()
            try expectStatus(statuses)
        }

        // A suspend can arrive before the snapshot changes. Its missing partner must not latch the pane.
        session.sessionWillSuspend(Notification(name: Notification.Name("com.apple.screenIsLocked")))
        try await finishInventory()
        try expectStatus(["locked"])
        session.lastInventory = 0
        session.tick()
        try await finishInventory()
        try expectStatus(["ready", "permission"])
    }

    @MainActor func testInputChecksTheCurrentSessionBetweenInventoryUpdates() throws {
        var observed = DesktopSessionState.active
        let (session, client) = try helper { observed }
        defer {
            client.close()
            session.pump.stop()
        }
        var config = Configuration(control: true)
        config.revision = 7
        session.desired = config
        session.applied = config
        session.input.enabled = true
        session.sendStatus(state: "streaming", detail: "Test desktop")
        XCTAssertTrue(session.canControl(revision: 7))
        XCTAssertFalse(session.canControl(revision: 6))
        for blocked: DesktopSessionState in [.locked, .inactive, .unavailable] {
            observed = blocked
            XCTAssertFalse(session.canControl(revision: 7))
        }
        observed = .active
        XCTAssertTrue(session.canControl(revision: 7))
    }

    @MainActor private func helper(sessionState: @escaping () -> DesktopSessionState) throws -> (HostSession, WireSocket) {
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw RexmoteError.system("Test socket pair failed") }
        let session = HostSession(
            request: LaunchRequest(socketPath: "", token: ""), connection: WireSocket(fd: pair[0]), sessionState: sessionState)
        return (session, WireSocket(fd: pair[1]))
    }

    private final class Screen: VirtualScreen {
        let displayID: UInt32
        var sizes: [PixelSize]
        var closed = false
        init(id: UInt32, size: PixelSize) {
            displayID = id
            sizes = [size]
        }
        func resize(toWidth width: UInt32, height: UInt32, retina: Bool) throws { sizes.append(PixelSize(Int(width), Int(height))) }
        func close() { closed = true }
    }

    private func image(_ value: UInt8) throws -> CaptureImage {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer)!, Int32(value), CVPixelBufferGetBytesPerRow(buffer) * 16)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return CaptureImage(buffer: buffer, time: ProcessInfo.processInfo.systemUptime)
    }

    private func sample(_ value: UInt8, status: SCFrameStatus = .complete) throws -> CMSampleBuffer {
        let pixels = try image(value).buffer
        let format = try CMVideoFormatDescription(imageBuffer: pixels)
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        let sample = try CMSampleBuffer(imageBuffer: pixels, formatDescription: format, sampleTiming: timing)
        let key = CMSampleBuffer.PerSampleAttachmentsDictionary.Key(rawValue: SCStreamFrameInfo.status.rawValue as CFString)
        sample.sampleAttachments[0][key] = status.rawValue
        return sample
    }

    func testRestartedStreamSendsItsFirstFrameOnAnIdleDesktop() throws {
        let received = expectation(description: "Initial keyframe after resize")
        let pump = FramePump { packet, commit in
            guard commit(), case .frame(let frame) = packet.message else { return }
            XCTAssertTrue(frame.full)
            var desktop = FrameBuffer()
            try desktop.apply(frame, payload: packet.payload)
            XCTAssertEqual(desktop.pixels, Data(repeating: 42, count: 16 * 16 * 4))
            received.fulfill()
        }
        defer { pump.stop() }
        let output = CaptureOutput(pump: pump)
        output.offer(try sample(42, status: .started))
        output.offer(try sample(99, status: .idle))
        pump.configure(Configuration())
        output.enable()
        wait(for: [received], timeout: 2)
    }

    @MainActor func testCaptureOnlyPublishesTheNewestStartupFrameAfterTheSessionIsActive() throws {
        let (host, client) = try helper { .active }
        let pump = host.pump
        defer { pump.stop() }
        pump.configure(Configuration(fps: 60))

        let abandoned = CaptureOutput(pump: pump)
        abandoned.offer(try sample(3))
        abandoned.disable()
        abandoned.enable()
        abandoned.offer(try sample(4))

        let output = CaptureOutput(pump: pump)
        output.offer(try sample(11))
        output.offer(try sample(99))
        var fd = pollfd(fd: client.fd, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&fd, 1, 50), 0)
        output.enable()
        guard poll(&fd, 1, 1000) == 1 else { return XCTFail("Missing initial frame") }
        let packet = try XCTUnwrap(client.receive().first)
        guard case .frame(let frame) = packet.message else { return XCTFail("Expected desktop pixels") }
        var buffer = FrameBuffer()
        try buffer.apply(frame, payload: packet.payload)
        XCTAssertEqual(buffer.pixels, Data(repeating: 99, count: 16 * 16 * 4))
        pump.acknowledge(frame.id)

        output.disable()
        output.offer(try sample(188))
        output.enable()
        XCTAssertEqual(poll(&fd, 1, 50), 0)
    }

    func testEncoderWakesForCaptureAndAcknowledgementAndPausesWithThePane() throws {
        var pair = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let receiver = WireSocket(fd: pair[0])
        let sender = WireSocket(fd: pair[1])
        let pump = FramePump(connection: sender)
        defer { pump.stop() }
        func frame(within ms: Int32) throws -> FrameInfo? {
            var fd = pollfd(fd: receiver.fd, events: Int16(POLLIN), revents: 0)
            guard poll(&fd, 1, ms) == 1 else { return nil }
            guard let packet = try receiver.receive().first, case .frame(let frame) = packet.message else { return nil }
            return frame
        }
        var config = Configuration(fps: 30)
        pump.configure(config)
        pump.offer(try image(10))
        let first = try XCTUnwrap(frame(within: 1000))
        pump.offer(try image(100))
        let second = try XCTUnwrap(frame(within: 1000))
        XCTAssertEqual(second.id, first.id + 1)
        pump.offer(try image(140))
        XCTAssertNil(try frame(within: 75))
        pump.acknowledge(first.id)
        let third = try XCTUnwrap(frame(within: 1000))
        XCTAssertEqual(third.id, second.id + 1)
        config.paused = true
        pump.configure(config)
        pump.acknowledge(second.id)
        pump.offer(try image(170))
        XCTAssertNil(try frame(within: 75))
    }

    func testLockDropsAnEncodedFrameWaitingToWriteWithoutConsumingItsSequenceNumber() throws {
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return XCTFail("Could not create test socket") }
        let sender = WireSocket(fd: pair[0]), client = WireSocket(fd: pair[1])
        let stale = try image(41)
        let encoded = DispatchSemaphore(value: 0)
        let pump = FramePump(send: { packet, when in
            if case .frame(let frame) = packet.message, frame.captureTime == stale.time { encoded.signal() }
            try sender.send(packet, when: when)
        })
        defer { pump.stop() }

        var buffer = FrameBuffer()
        func expectFrame(id: UInt64, value: UInt8) throws {
            var fd = pollfd(fd: client.fd, events: Int16(POLLIN), revents: 0)
            guard poll(&fd, 1, 2000) == 1 else { return XCTFail("Missing frame \(id)") }
            let packets = try client.receive()
            XCTAssertEqual(packets.count, 1)
            let packet = try XCTUnwrap(packets.first)
            guard case .frame(let frame) = packet.message else { return XCTFail("Expected desktop frame") }
            XCTAssertEqual(frame.id, id)
            try buffer.apply(frame, payload: packet.payload)
            XCTAssertEqual(buffer.pixels, Data(repeating: value, count: 16 * 16 * 4))
            pump.acknowledge(frame.id)
        }

        var config = Configuration(fps: 60)
        pump.configure(config)
        pump.offer(try image(10))
        try expectFrame(id: 0, value: 10)

        let writerEntered = DispatchSemaphore(value: 0), releaseWriter = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try sender.send(Packet(.heartbeat)) {
                    writerEntered.signal()
                    if releaseWriter.wait(timeout: .now() + 5) == .timedOut { XCTFail("Socket writer was never released") }
                    return false
                }
            } catch { XCTFail("Cannot hold socket writer: \(error)") }
        }
        defer { releaseWriter.signal() }
        guard writerEntered.wait(timeout: .now() + 2) == .success else { return XCTFail("Socket writer did not start") }
        pump.offer(stale)
        guard encoded.wait(timeout: .now() + 2) == .success else { return XCTFail("Frame did not reach the socket writer") }

        // A lock and unlock can reuse the viewer's configuration revision.
        config.paused = true
        pump.configure(config)
        pump.forgetDisplay()
        config.paused = false
        pump.configure(config)
        pump.offer(try image(82))
        releaseWriter.signal()
        try expectFrame(id: 1, value: 82)
        pump.offer(try image(123))
        try expectFrame(id: 2, value: 123)
    }

    @MainActor func testTwoPanesResizeAndReleaseOnlyTheirOwnDisplay() throws {
        var screens: [Screen] = []
        func create(_ width: UInt32, _ height: UInt32, retina: Bool) -> VirtualScreen {
            let screen = Screen(id: UInt32(screens.count + 1), size: PixelSize(Int(width), Int(height)))
            screens.append(screen)
            return screen
        }
        let first = PaneDisplay(create: create)
        let second = PaneDisplay(create: create)
        let initial = VirtualDisplayMode(viewport: CGSize(width: 1280, height: 800))
        let resized = VirtualDisplayMode(viewport: CGSize(width: 1110, height: 746))
        try first.apply(initial)
        try second.apply(initial)
        let firstID = try XCTUnwrap(first.id)
        let secondID = try XCTUnwrap(second.id)
        XCTAssertNotEqual(firstID, secondID)
        try first.apply(resized)
        try first.apply(resized)
        XCTAssertEqual(first.id, firstID)
        XCTAssertEqual(second.id, secondID)
        XCTAssertEqual(screens.map(\.sizes), [[initial.points, resized.points], [initial.points]])
        first.close()
        XCTAssertNil(first.id)
        XCTAssertFalse(screens[1].closed)
        second.close()
        XCTAssertTrue(screens.allSatisfy(\.closed))
    }

    @MainActor func testInvalidModesNeverReachMacOSAndARejectionIsNotRetried() {
        var calls = 0
        let pane = PaneDisplay { _, _, _ in
            calls += 1
            throw RexmoteError.system("Declined")
        }
        XCTAssertThrowsError(try pane.apply(VirtualDisplayMode(points: PixelSize(20, 10))))
        XCTAssertEqual(calls, 0)
        let normal = VirtualDisplayMode(viewport: CGSize(width: 1024, height: 768))
        XCTAssertThrowsError(try pane.apply(normal))
        XCTAssertThrowsError(try pane.apply(normal))
        XCTAssertEqual(calls, 1)
    }

    func testSSHRelayWaitsForSignInAndOpensTheNativeHelperOnTheSameConnection() throws {
        let listener = try LocalListener()
        let client = try WireSocket.connect(path: listener.path)
        let relaySocket = try XCTUnwrap(listener.acceptConnection())
        defer {
            relaySocket.close()
            client.close()
        }
        let io = FileHandle(fileDescriptor: relaySocket.fd, closeOnDealloc: false)
        let session = NSLock()
        var signedIn = false
        var launches = 0
        let relay = DesktopRelay(input: io, output: io, hasConsole: { session.withLock { signedIn } })
        let finished = expectation(description: "Relay exits on quit")
        let helperClient = try WireSocket.connect(path: listener.path)
        let helper = try XCTUnwrap(listener.acceptConnection())
        defer { helper.close() }
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                try relay.run {
                    session.withLock { launches += 1 }
                    try helper.send(Packet(.hello(version: DesktopProtocol.version, token: "private")))
                    let status = HostStatus(
                        hostname: "host", screenRecording: true, accessibility: true,
                        displays: [], state: "ready", detail: "Desktop ready.")
                    try helper.send(Packet(.status(status)))
                    return (helperClient, "private")
                }
            } catch { XCTFail(String(describing: error)) }
        }

        var pending: [Packet] = []
        func next() throws -> Message {
            while pending.isEmpty {
                var fd = pollfd(fd: client.fd, events: Int16(POLLIN), revents: 0)
                guard poll(&fd, 1, 3000) > 0 else { throw RexmoteError.system("No relay response") }
                pending = try client.receive()
            }
            return pending.removeFirst().message
        }
        guard case .hello(DesktopProtocol.version, DesktopLink.sshGreeting) = try next(),
            case .status(let waiting) = try next()
        else { return XCTFail("Missing signed-out status") }
        XCTAssertEqual(waiting.state, "signed-out")
        XCTAssertNil(waiting.screenRecording)
        XCTAssertEqual(session.withLock { launches }, 0)
        try client.send(Packet(.input(revision: 1, event: .releaseAll)))
        guard case .heartbeat = try next() else { return XCTFail("SSH channel did not stay alive") }
        session.withLock { signedIn = true }
        try client.send(Packet(.heartbeat))
        var message = try next()
        if case .heartbeat = message { message = try next() }
        guard case .status(let ready) = message else { return XCTFail("Expected native helper status after sign-in") }
        XCTAssertEqual(ready.state, "ready")
        XCTAssertEqual(session.withLock { launches }, 1)
        var configuration = Configuration()
        configuration.revision = 1
        try client.send(Packet(.configure(configuration)))
        var readable = pollfd(fd: helper.fd, events: Int16(POLLIN), revents: 0)
        guard poll(&readable, 1, 3000) > 0 else { return XCTFail("No configuration reached the helper") }
        let received = try helper.receive()
        guard case .configure(let forwarded) = received.first?.message else {
            return XCTFail("Stale input reached the new desktop")
        }
        XCTAssertEqual(forwarded, configuration)

        helper.close()
        // macOS may terminate the GUI helper before loginwindow takes back /dev/console.
        Thread.sleep(forTimeInterval: 0.12)
        session.withLock { signedIn = false }
        guard case .status(let signedOut) = try next() else { return XCTFail("Expected the relay to survive logout") }
        XCTAssertEqual(signedOut.state, "signed-out")
        try client.send(Packet(.quit))
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(session.withLock { launches }, 1)
    }

    func testSSHRelayForwardsControlWhileALargeClipboardReplyIsStillInTransit() throws {
        func sockets() throws -> (WireSocket, WireSocket) {
            var fds = [Int32](repeating: -1, count: 2)
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw RexmoteError.system("socketpair") }
            return (WireSocket(fd: fds[0]), WireSocket(fd: fds[1]))
        }
        let (viewer, relayClient) = try sockets(), (relayHost, host) = try sockets()
        let transport = FileHandle(fileDescriptor: relayClient.fd, closeOnDealloc: false)
        var capacity: Int32 = 16 * 1024
        XCTAssertEqual(setsockopt(relayClient.fd, SOL_SOCKET, SO_SNDBUF, &capacity, socklen_t(MemoryLayout.size(ofValue: capacity))), 0)
        let relay = DesktopRelay(input: transport, output: transport, hasConsole: { true })
        let finished = expectation(description: "Relay closed")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                try relay.run {
                    try host.send(Packet(.hello(version: DesktopProtocol.version, token: "helper")))
                    return (relayHost, "helper")
                }
            } catch { XCTFail(String(describing: error)) }
        }
        var output = pollfd(fd: viewer.fd, events: Int16(POLLIN), revents: 0)
        guard poll(&output, 1, 2000) == 1, case .hello = try viewer.receive().first?.message else {
            return XCTFail("Missing relay greeting")
        }
        let request = UUID(), payload = Data(repeating: 3, count: 2 * 1024 * 1024)
        try host.send(Packet(.copied(request: request, changed: true), payload: payload))
        guard poll(&output, 1, 2000) == 1 else { return XCTFail("Clipboard transfer did not start") }

        // Leave the clipboard bytes unread so the relay exhausts its tiny send buffer.
        try viewer.send(Packet(.input(revision: 1, event: .releaseAll)))
        var input = pollfd(fd: host.fd, events: Int16(POLLIN), revents: 0)
        let controls = poll(&input, 1, 1000) == 1 ? try host.receive() : []
        XCTAssertTrue(controls.contains {
            if case .input(_, .releaseAll, _) = $0.message { return true }
            return false
        }, "An outgoing clipboard transfer blocked incoming controls")
        var packets: [Packet] = []
        while packets.isEmpty {
            guard poll(&output, 1, 2000) == 1 else { return XCTFail("Clipboard transfer stalled") }
            packets = try viewer.receive()
        }
        let copy = try XCTUnwrap(packets.first)
        guard case .copied(request, true) = copy.message else { return XCTFail("Wrong clipboard reply") }
        XCTAssertEqual(copy.payload, payload)

        let paste = RemoteInput.key(KeyInput(keyCode: 9, modifiers: 8, text: "v"))
        let bytes = try Packet(.input(revision: 1, event: paste), payload: payload).encoded()
        let clientIO = FileHandle(fileDescriptor: viewer.fd, closeOnDealloc: false)
        try clientIO.write(contentsOf: bytes.prefix(8192))
        guard poll(&input, 1, 2000) == 1, case .heartbeat = try host.receive().first?.message else {
            return XCTFail("The host could not see progress on the incomplete paste")
        }
        try clientIO.write(contentsOf: bytes.dropFirst(8192))
        var pasted: Packet?
        while pasted == nil {
            guard poll(&input, 1, 2000) == 1 else { return XCTFail("Paste did not reach the host") }
            pasted = try host.receive().first {
                if case .input = $0.message { return true }
                return false
            }
        }
        XCTAssertEqual(pasted?.payload, payload)
        try viewer.send(Packet(.quit))
        wait(for: [finished], timeout: 2)
    }
}
