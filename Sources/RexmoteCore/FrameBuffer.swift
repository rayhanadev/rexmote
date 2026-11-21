import CoreGraphics
import Foundation

/// Reconstruct one complete RGBA image from the host's validated updates.
public struct FrameBuffer {
    public private(set) var pixels = Data()
    private var size = PixelSize(0, 0)
    private var revision: UInt64?
    public init() {}

    public mutating func apply(_ frame: FrameInfo, payload: Data) throws {
        guard frame.size.valid, frame.full || (size == frame.size && revision == frame.revision) else {
            throw RexmoteError.invalid("A new desktop configuration needs a complete refresh.")
        }
        do {
            if let scroll = frame.scroll {
                guard !frame.full, scroll.fits(size) else { throw RexmoteError.invalid("Invalid scroll region.") }
                move(scroll)
            }
            try frame.decodePatches(payload: payload) { rect, rows in
                if frame.full {
                    if rect.y == 0 {
                        pixels = rows
                        if rect.height < frame.size.height {
                            pixels.reserveCapacity(frame.size.width * frame.size.height * 4)
                        }
                    } else {
                        pixels.append(rows)
                    }
                    return
                }
                let stride = rect.width * 4
                pixels.withUnsafeMutableBytes { target in
                    rows.withUnsafeBytes { source in
                        for y in 0..<rect.height {
                            let offset = ((rect.y + y) * frame.size.width + rect.x) * 4
                            target.baseAddress!.advanced(by: offset).copyMemory(
                                from: source.baseAddress!.advanced(by: y * stride), byteCount: stride)
                        }
                    }
                }
            }
        } catch {
            self = FrameBuffer()
            throw error
        }
        size = frame.size
        revision = frame.revision
    }

    private mutating func move(_ scroll: FrameScroll) {
        let rect = scroll.destination
        let stride = size.width * 4
        pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            let base = bytes.baseAddress!
            let source = base + scroll.sourceY * stride + rect.x * 4
            let destination = base + rect.y * stride + rect.x * 4
            if rect.width == size.width {
                memmove(destination, source, rect.height * stride)
            } else {
                for i in 0..<rect.height {
                    let row = rect.y > scroll.sourceY ? rect.height - 1 - i : i
                    memmove(destination + row * stride, source + row * stride, rect.width * 4)
                }
            }
        }
    }

    public var image: CGImage? {
        guard size.valid, let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
