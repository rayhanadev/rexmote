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
    private let connection: WireSocket
    private var window = FlightWindow<CaptureImage>()
    private var config = Configuration(paused: true)
    private var lastImage: CaptureImage?
    private var reset = true
    private var stopped = false
    private var nextFrameAt: TimeInterval = 0
    private var scheduledAt: TimeInterval?
    var failed: ((String) -> Void)?

    init(connection: WireSocket) {
        self.connection = connection
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.activate()
    }

    func configure(_ value: Configuration) {
        lock.withLock {
            config = value
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

    // With the lock held, arm exactly one deadline for the next frame or its acknowledgement.
    private func schedule() {
        guard !stopped else { return }
        var deadline = window.oldestSendTime.map { $0 + 10 }
        if !config.paused, window.canSend, window.latest != nil {
            deadline = min(deadline ?? nextFrameAt, nextFrameAt)
        }
        guard scheduledAt != deadline else { return }
        scheduledAt = deadline
        let when = deadline.map { DispatchTime.now() + max(0, $0 - ProcessInfo.processInfo.systemUptime) }
        timer.schedule(deadline: when ?? .distantFuture, leeway: .milliseconds(1))
    }

    private func tick() {
        do {
            let work: (image: CaptureImage, revision: UInt64, reset: Bool)? = try lock.withLock {
                scheduledAt = nil
                guard !stopped else { return nil }
                let now = ProcessInfo.processInfo.systemUptime
                if let oldest = window.oldestSendTime, now - oldest >= 10 {
                    throw RexmoteError.system("Desktop acknowledgement timed out.")
                }
                guard !config.paused, now >= nextFrameAt, let image = window.take() else {
                    schedule()
                    return nil
                }
                let period = 1 / Double(config.fps)
                nextFrameAt = now - nextFrameAt >= period ? now + period : nextFrameAt + period
                defer { reset = false }
                return (image, config.revision, reset)
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
            packet.message = .frame(frame)
            let running = lock.withLock {
                guard !stopped else { return false }
                window.sent(frame.id)
                schedule()
                return true
            }
            if running { try connection.send(packet) }
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
