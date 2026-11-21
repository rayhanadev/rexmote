import CoreVideo
import Darwin
import Foundation
import RexmoteCore
import XCTest

@testable import RexmoteCLI
@testable import RexmoteHost

final class DesktopSessionTests: XCTestCase {
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

    func testEncoderWakesForCaptureAndAcknowledgementAndPausesWithThePane() throws {
        var pair = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let receiver = WireSocket(fd: pair[0])
        let sender = WireSocket(fd: pair[1])
        let pump = FramePump(connection: sender)
        defer { pump.stop() }
        func image(_ value: UInt8) throws -> CaptureImage {
            var pixelBuffer: CVPixelBuffer?
            XCTAssertEqual(
                CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer)!, Int32(value), CVPixelBufferGetBytesPerRow(buffer) * 16)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return CaptureImage(buffer: buffer, time: ProcessInfo.processInfo.systemUptime)
        }
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
}
