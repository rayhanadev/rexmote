import CoreGraphics
import Foundation
import RexmoteCore

/// One reader reconstructs each frame and waits for AppKit to present it before
/// acknowledging it. All host input and configuration travel on this same link.
final class DesktopConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var socket: WireSocket?
    private let writer = DispatchQueue(label: "rexmote.desktop-write")
    private var cancelled: Bool { lock.withLock { stopped } }
    private var wire: WireSocket? { lock.withLock { socket } }

    enum Update {
        case status(HostStatus)
        case frame(FrameInfo, CGImage)
        case copied(UUID, changed: Bool, Data)
        case filePasteResult(UUID, applied: Bool)
        case failed(String)
    }

    func start(
        origin: SessionHost, environment: [String: String], promptForSSH: Bool,
        receive: @escaping @MainActor (Update) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let link = DesktopLink(origin: origin, environment: environment, cancelled: { self.cancelled })
            defer { link.close() }
            var authenticated = false
            do {
                let stream = try link.connect(promptForSSH: promptForSSH)
                defer { stream.close() }
                let keep = self.lock.withLock {
                    if self.stopped { return false }
                    self.socket = stream
                    return true
                }
                guard keep else { return }
                var image = FrameBuffer()
                var nextID: UInt64 = 0
                var lastSeen = ProcessInfo.processInfo.systemUptime
                var heartbeat = lastSeen
                while !self.cancelled {
                    let now = ProcessInfo.processInfo.systemUptime
                    let timeout: Double = !authenticated && promptForSSH ? 120 : 12
                    guard now - lastSeen < timeout else {
                        throw RexmoteError.system("The sharing Mac stopped responding.")
                    }
                    if authenticated && now - heartbeat >= 1 {
                        try stream.send(Packet(.heartbeat))
                        heartbeat = now
                    }
                    var watch = pollfd(fd: stream.fd, events: Int16(POLLIN), revents: 0)
                    let n = poll(&watch, 1, 250)
                    if n == 0 || (n < 0 && errno == EINTR) { continue }
                    guard n > 0 else { throw RexmoteError.disconnected }
                    for packet in try stream.receive() {
                        lastSeen = now
                        if !authenticated {
                            guard case .hello(DesktopProtocol.version, link.expectedToken) = packet.message else {
                                throw RexmoteError.invalid("Install the same version of Rexmote on both Macs.")
                            }
                            authenticated = true
                            continue
                        }
                        switch packet.message {
                        case .frame(let frame):
                            guard frame.id == nextID else {
                                throw RexmoteError.invalid("The desktop frame sequence was interrupted.")
                            }
                            nextID += 1
                            try image.apply(frame, payload: packet.payload)
                            guard let pixels = image.image else { throw RexmoteError.invalid("Invalid desktop image.") }
                            DispatchQueue.main.sync { receive(.frame(frame, pixels)) }
                            try stream.send(Packet(.acknowledge(frame.id)))
                        case .status(let value):
                            if value.state == "signed-out" {
                                image = FrameBuffer()
                                nextID = 0
                            }
                            DispatchQueue.main.sync { receive(.status(value)) }
                        case .filePasteResult(let id, let applied):
                            DispatchQueue.main.sync { receive(.filePasteResult(id, applied: applied)) }
                        case .copied(let request, let changed):
                            DispatchQueue.main.sync { receive(.copied(request, changed: changed, packet.payload)) }
                        case .heartbeat: break
                        case .error(let message): throw RexmoteError.system(message)
                        default: throw RexmoteError.invalid("Unexpected desktop message.")
                        }
                    }
                }
            } catch {
                guard !self.cancelled else { return }
                let message: String
                if !authenticated, case RexmoteError.disconnected = error {
                    message =
                        "SSH could not open the desktop on " + origin.hostname
                        + ". Check Remote Login on the session host, then reconnect."
                } else {
                    message = String(describing: error)
                }
                DispatchQueue.main.async { receive(.failed(message)) }
            }
        }
    }

    func send(_ packet: Packet) {
        writer.async {
            guard let wire = self.wire, !self.cancelled else { return }
            do { try wire.send(packet) } catch { wire.close() }
        }
    }

    func close() {
        let stream = lock.withLock {
            stopped = true
            return socket
        }
        stream?.close()
    }
}
