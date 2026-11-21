import Foundation
import zlib

public enum RexmoteError: Error, CustomStringConvertible {
    case invalid(String)
    case system(String)
    case disconnected
    public var description: String {
        switch self {
        case .invalid(let text), .system(let text): return text
        case .disconnected: return "The desktop helper disconnected."
        }
    }
}

public struct PixelSize: Codable, Equatable {
    public var width: Int, height: Int
    public init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }
    public var valid: Bool { width > 0 && height > 0 && width <= 3840 && height <= 2160 }

    public static func capture(viewport: CGSize, backingScale: CGFloat, maxWidth: Int) -> PixelSize {
        let width = max(1, viewport.width)
        let height = max(1, viewport.height)
        let scale = min(max(1, backingScale), CGFloat(maxWidth) / width, 2160 / height)
        return PixelSize(max(1, Int((width * scale).rounded())), max(1, Int((height * scale).rounded())))
    }

    public func fitting(width limitWidth: Int, height limitHeight: Int) -> PixelSize {
        let factor = min(1, Double(limitWidth) / Double(width), Double(limitHeight) / Double(height))
        return PixelSize(
            max(1, Int((Double(width) * factor).rounded())),
            max(1, Int((Double(height) * factor).rounded())))
    }
}

public struct VirtualDisplayMode: Codable, Equatable {
    public let points: PixelSize

    public let hiDPI: Bool
    public init(points: PixelSize, hiDPI: Bool = false) {
        self.points = points
        self.hiDPI = hiDPI
    }

    /// WindowServer needs room for a complete macOS desktop, even in a very small Rex split.
    public init(viewport: CGSize, backingScale: CGFloat = 1) {
        let width = max(1, viewport.width.rounded())
        let height = max(1, viewport.height.rounded())
        let aspect = min(4096.0 / 600, max(800.0 / 4096, width / height))
        let minHeight = max(600, 800 / aspect)
        let maxHeight = min(4096, 4096 / aspect, sqrt(CGFloat(3840 * 2160) / aspect))
        let h = min(maxHeight, max(minHeight, height))
        points = PixelSize(
            max(800, Int((h * aspect + 1e-8).rounded(.down))),
            max(600, Int((h + 1e-8).rounded(.down))))
        hiDPI = backingScale > 1 && (width * backingScale > CGFloat(points.width) || height * backingScale > CGFloat(points.height))
            && Self.supportsRetina(points)
    }

    private static func supportsRetina(_ points: PixelSize) -> Bool {
        (1...2048).contains(points.width) && (1...2048).contains(points.height)
            && points.width * points.height <= 3840 * 2160 / 4
    }

    public var valid: Bool {
        (!hiDPI || Self.supportsRetina(points)) && (800...4096).contains(points.width) && (600...4096).contains(points.height)
            && points.width * points.height <= 3840 * 2160
    }
}
public struct PixelRect: Codable, Equatable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(_ x: Int, _ y: Int, _ width: Int, _ height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    public func fits(_ size: PixelSize) -> Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0 && width <= size.width && height <= size.height
            && x <= size.width - width && y <= size.height - height
    }
}
public struct DisplayInfo: Codable, Equatable {
    public var id: UInt32, name: String, x: Double, y: Double, width: Double, height: Double
    public init(id: UInt32, name: String, x: Double, y: Double, width: Double, height: Double) {
        self.id = id
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
public struct HostStatus: Codable, Equatable {
    public var hostname: String, screenRecording: Bool?, accessibility: Bool?
    public var displays: [DisplayInfo], state: String, detail: String
    public var selectedDisplayID: UInt32?, virtualDisplayID: UInt32?
    public var captureBackend: String?
    public init(
        hostname: String, screenRecording: Bool? = nil, accessibility: Bool? = nil,
        displays: [DisplayInfo], state: String, detail: String
    ) {
        self.hostname = hostname
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.displays = displays
        self.state = state
        self.detail = detail
    }
}
public struct Configuration: Codable, Equatable {
    public var revision: UInt64 = 0
    public var virtualMode: VirtualDisplayMode?
    public var maxWidth: Int, maxHeight: Int, fps: Int, control: Bool, paused: Bool
    public init(
        maxWidth: Int = 1920, maxHeight: Int = 1200,
        fps: Int = 30, control: Bool = false, paused: Bool = false
    ) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.fps = fps
        self.control = control
        self.paused = paused
    }
    public var valid: Bool {
        PixelSize(maxWidth, maxHeight).valid && (1...60).contains(fps) && virtualMode?.valid != false
    }
}
public struct KeyInput: Codable, Equatable {
    public let keyCode: UInt16
    public let modifiers: Int, event: Int
    public let text: String
    public init(keyCode: UInt16, modifiers: Int = 0, event: Int = 1, text: String = "") {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.event = event
        self.text = text
    }

    public enum ClipboardAction { case copy, paste }

    public var clipboardAction: ClipboardAction? {
        guard event == 1 else { return nil }
        let flags = modifiers & ~64 // Caps Lock does not change a menu shortcut.
        switch (text.lowercased(), flags) {
        case ("c", 8), ("x", 8): return .copy
        case ("v", 8), ("v", 9), ("v", 11): return .paste
        default: return nil
        }
    }
}
public struct PointerInput: Codable, Equatable {
    public var action: String, x: Double, y: Double, button: Int, modifiers: Int
    public init(
        action: String, x: Double, y: Double, button: Int = 0, modifiers: Int = 0
    ) {
        self.action = action
        self.x = x
        self.y = y
        self.button = button
        self.modifiers = modifiers
    }
    public var valid: Bool {
        x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
            && (0...2).contains(button) && ["move", "down", "up"].contains(action)
    }
}
public enum RemoteInput: Codable, Equatable {
    case key(KeyInput)
    case pointer(PointerInput)
    case trackpad(TrackpadInput)
    case text(String)
    case releaseAll
}
public struct Patch: Codable {
    public var rect: PixelRect, offset: Int, length: Int
    public init(rect: PixelRect, offset: Int, length: Int) {
        self.rect = rect
        self.offset = offset
        self.length = length
    }
}
/// Copies a rectangle vertically within the preceding frame, before applying new pixels.
public struct FrameScroll: Codable {
    public var destination: PixelRect
    public var sourceY: Int

    public func fits(_ size: PixelSize) -> Bool {
        destination.fits(size) && sourceY >= 0 && sourceY <= size.height - destination.height
    }
}
public struct FrameInfo: Codable {
    public var scroll: FrameScroll?
    public var revision: UInt64 = 0
    public var id: UInt64, size: PixelSize, full: Bool, captureTime: Double, patches: [Patch]
    public init(id: UInt64, size: PixelSize, full: Bool, captureTime: Double, patches: [Patch]) {
        self.id = id
        self.size = size
        self.full = full
        self.captureTime = captureTime
        self.patches = patches
    }
    public func validate(payload: Data) throws {
        try decodePatches(payload: payload) { _, _ in }
    }
    public func decodePatches(payload: Data, apply: (PixelRect, Data) -> Void) throws {
        guard size.valid, captureTime.isFinite, patches.count <= 32,
            !patches.isEmpty || scroll != nil,
            scroll.map({ !full && $0.fits(size) }) ?? true
        else {
            throw RexmoteError.invalid("Invalid frame geometry.")
        }
        if full {
            var nextRow = 0
            for patch in patches {
                let rect = patch.rect
                guard rect.fits(size), rect.width == size.width, rect.y == nextRow else {
                    throw RexmoteError.invalid("Incomplete desktop refresh.")
                }
                nextRow += rect.height
            }
            guard nextRow == size.height else { throw RexmoteError.invalid("Incomplete desktop refresh.") }
        }
        var end = 0
        for p in patches {
            guard p.rect.fits(size), p.offset == end, p.length > 0, p.length <= payload.count - end else {
                throw RexmoteError.invalid("Invalid desktop patch.")
            }
            let bytes = try PixelCompression.decompress(
                payload.subdata(in: p.offset..<(p.offset + p.length)), expected: p.rect.width * p.rect.height * 4)
            apply(p.rect, bytes)
            end += p.length
        }
        guard end == payload.count else { throw RexmoteError.invalid("Unexpected frame bytes.") }
    }
}
public enum LocalComputer {
    public static var hostname: String {
        var bytes = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&bytes, bytes.count) == 0 else { return "" }
        return String(cString: bytes)
    }
}

public enum DesktopProtocol { public static let version = 7 }

public enum Message: Codable {
    case hello(version: Int, token: String)
    case status(HostStatus)
    case configure(Configuration)
    case frame(FrameInfo)
    case acknowledge(UInt64)
    case input(revision: UInt64, event: RemoteInput, copyRequest: UUID? = nil)
    case copied(request: UUID, changed: Bool)
    case filePasteResult(UUID, applied: Bool)
    case heartbeat
    case refresh
    case quit
    case error(String)
}
public struct Packet {
    public var message: Message, payload: Data
    public init(_ message: Message, payload: Data = Data()) {
        self.message = message
        self.payload = payload
    }
    public func encoded() throws -> Data {
        let header = try JSONEncoder().encode(message)
        guard header.count <= PacketDecoder.maxHeader, payload.count <= PacketDecoder.maxPayload else {
            throw RexmoteError.invalid("Desktop packet is too large.")
        }
        var result = Data([0x52, 0x58, 0x54, 0x31])
        for count in [header.count, payload.count] {
            var big = UInt32(count).bigEndian
            withUnsafeBytes(of: &big) { result.append(contentsOf: $0) }
        }
        result.append(header)
        result.append(payload)
        return result
    }
}
public struct PacketDecoder {
    public static let maxHeader = 65_536, maxPayload = 40 * 1024 * 1024
    private var buffer = Data()
    public init() {}
    public mutating func feed(_ data: Data) throws -> [Packet] {
        guard buffer.count + data.count <= Self.maxHeader + Self.maxPayload + 12 + 65_536 else {
            throw RexmoteError.invalid("Desktop buffer limit exceeded.")
        }
        buffer.append(data)
        var packets: [Packet] = []
        while buffer.count >= 12 {
            let prefix = Array(buffer.prefix(12))
            guard Array(prefix[0..<4]) == [0x52, 0x58, 0x54, 0x31] else {
                throw RexmoteError.invalid("Unsupported desktop protocol.")
            }
            let h = prefix[4..<8].reduce(0) { ($0 << 8) | Int($1) }
            let p = prefix[8..<12].reduce(0) { ($0 << 8) | Int($1) }
            guard h > 0 && h <= Self.maxHeader && p <= Self.maxPayload else {
                throw RexmoteError.invalid("Invalid desktop packet length.")
            }
            guard buffer.count >= 12 + h + p else { break }
            let bytes = Data(buffer.prefix(12 + h + p))
            let message = try JSONDecoder().decode(Message.self, from: bytes.subdata(in: 12..<(12 + h)))
            let payload = bytes.subdata(in: (12 + h)..<(12 + h + p))
            switch message {
            case .frame: break
            case .input(_, .key(let key), let request):
                guard request == nil || key.clipboardAction == .copy,
                    payload.isEmpty || (key.clipboardAction == .paste && payload.count <= DesktopClipboard.byteLimit)
                else { throw RexmoteError.invalid("Unexpected clipboard input.") }
            case .copied(_, let changed):
                guard payload.count <= DesktopClipboard.byteLimit, changed || payload.isEmpty else {
                    throw RexmoteError.invalid("Invalid clipboard reply.")
                }
            case .input(_, _, .some):
                throw RexmoteError.invalid("A copy request requires a keyboard shortcut.")
            default: if !payload.isEmpty { throw RexmoteError.invalid("Unexpected control payload.") }
            }
            packets.append(Packet(message, payload: payload))
            buffer.removeFirst(12 + h + p)
        }
        return packets
    }
    public func finish() throws { if !buffer.isEmpty { throw RexmoteError.invalid("Truncated desktop packet.") } }
}
public enum PixelCompression {
    public static func compress(_ data: Data) throws -> Data {
        var length = compressBound(uLong(data.count))
        var result = Data(count: Int(length))
        let code = result.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compress2(
                    dst.bindMemory(to: Bytef.self).baseAddress!, &length, src.bindMemory(to: Bytef.self).baseAddress!,
                    uLong(data.count), 1)
            }
        }
        guard code == Z_OK else { throw RexmoteError.invalid("Image compression failed.") }
        result.count = Int(length)
        return result
    }
    public static func decompress(_ data: Data, expected: Int) throws -> Data {
        guard expected > 0 && expected <= 3840 * 2160 * 4 else {
            throw RexmoteError.invalid("Invalid decompressed image length.")
        }
        var length = uLongf(expected)
        var sourceLength = uLong(data.count)
        var result = Data(count: expected)
        let code = result.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                uncompress2(
                    dst.bindMemory(to: Bytef.self).baseAddress!, &length, src.bindMemory(to: Bytef.self).baseAddress!,
                    &sourceLength)
            }
        }
        guard code == Z_OK && Int(length) == expected && Int(sourceLength) == data.count else {
            throw RexmoteError.invalid("Corrupted compressed pixels.")
        }
        return result
    }
}

public struct LaunchRequest: Codable {
    public var socketPath: String, token: String
    public init(socketPath: String, token: String) {
        self.socketPath = socketPath
        self.token = token
    }
}
