import Accelerate
import CoreVideo
import Foundation
import RexmoteCore

struct CaptureImage {
    let buffer: CVPixelBuffer
    let time: Double
}
final class FramePump: @unchecked Sendable {
    private let lock = NSLock()
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "rexmote.encoder"))
    private let differ = FrameDiffer()
    private let send: (Packet, () -> Bool) throws -> Void
    private var window = FlightWindow<CaptureImage>()
    private var config = Configuration(paused: true)
    private var generation: UInt64 = 0
    private var nextWireID: UInt64 = 0
    private var lastImage: CaptureImage?
    private var reset = true
    private var stopped = false
    private var nextFrameAt: TimeInterval = 0
    private var scheduledAt: TimeInterval?
    var failed: ((String) -> Void)?

    convenience init(connection: WireSocket) {
        self.init(send: connection.send(_:when:))
    }

    init(send: @escaping (Packet, () -> Bool) throws -> Void) {
        self.send = send
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.activate()
    }

    func configure(_ value: Configuration) {
        lock.withLock {
            config = value
            generation &+= 1
            nextFrameAt = 0
            reset = true
            window.clearPending()
            if !value.paused, let lastImage { window.offer(lastImage) }
            schedule()
        }
    }

    func offer(_ image: CaptureImage) {
        lock.withLock {
            guard !stopped, !config.paused else { return }
            lastImage = image
            window.offer(image)
            schedule()
        }
    }

    func acknowledge(_ id: UInt64) {
        lock.withLock {
            guard window.acknowledge(id) else { return }
            schedule()
        }
    }

    func refresh() {
        lock.withLock {
            reset = true
            if let lastImage, !config.paused { window.offer(lastImage) }
            schedule()
        }
    }

    func forgetDisplay() {
        lock.withLock {
            generation &+= 1
            lastImage = nil
            window.clearPending()
            reset = true
            schedule()
        }
    }

    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            lastImage = nil
            window.clearPending()
            timer.cancel()
        }
    }

    // HostSession monitors connection liveness. Slow acknowledgements simply apply backpressure.
    private func schedule() {
        guard !stopped else { return }
        let deadline = !config.paused && window.canSend && window.latest != nil ? nextFrameAt : nil
        guard scheduledAt != deadline else { return }
        scheduledAt = deadline
        let when = deadline.map { DispatchTime.now() + max(0, $0 - ProcessInfo.processInfo.systemUptime) }
        timer.schedule(deadline: when ?? .distantFuture, leeway: .milliseconds(1))
    }

    private func tick() {
        do {
            let work: (image: CaptureImage, revision: UInt64, generation: UInt64, reset: Bool)? = lock.withLock {
                scheduledAt = nil
                guard !stopped else { return nil }
                let now = ProcessInfo.processInfo.systemUptime
                guard !config.paused, now >= nextFrameAt, let image = window.take() else {
                    schedule()
                    return nil
                }
                let period = 1 / Double(config.fps)
                nextFrameAt = now - nextFrameAt >= period ? now + period : nextFrameAt + period
                defer { reset = false }
                return (image, config.revision, generation, reset)
            }
            guard let work else { return }
            if work.reset { differ.reset() }
            let (pixels, size) = try rgba(work.image)
            guard var packet = try differ.encode(rgba: pixels, size: size, captureTime: work.image.time),
                case .frame(var frame) = packet.message
            else {
                lock.withLock { schedule() }
                return
            }
            frame.revision = work.revision
            frame.id = nextWireID
            packet.message = .frame(frame)
            // Check under the socket's write lock so interrupted work cannot follow a lock
            // status onto the wire. Only transmitted frames consume sequence numbers.
            try send(packet) {
                lock.withLock {
                    guard !stopped, generation == work.generation else { return false }
                    window.sent(frame.id)
                    nextWireID += 1
                    schedule()
                    return true
                }
            }
        } catch {
            stop()
            failed?(String(describing: error))
        }
    }
    private func rgba(_ image: CaptureImage) throws -> (Data, PixelSize) {
        let buffer = image.buffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let size = PixelSize(width, height)
        guard size.valid, let base = CVPixelBufferGetBaseAddress(buffer),
            CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
        else { throw RexmoteError.invalid("Unsupported capture pixels.") }
        var data = Data(count: width * height * 4)
        let code = data.withUnsafeMutableBytes { bytes -> vImage_Error in
            var input = vImage_Buffer(
                data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                rowBytes: CVPixelBufferGetBytesPerRow(buffer))
            var output = vImage_Buffer(
                data: bytes.baseAddress!, height: vImagePixelCount(height), width: vImagePixelCount(width),
                rowBytes: width * 4)
            return [UInt8(2), 1, 0, 3].withUnsafeBufferPointer {
                vImagePermuteChannels_ARGB8888(&input, &output, $0.baseAddress!, vImage_Flags(kvImageNoFlags))
            }
        }
        guard code == kvImageNoError else { throw RexmoteError.invalid("Pixel conversion failed.") }
        return (data, size)
    }
}
