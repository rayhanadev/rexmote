import Foundation

/// The base advances only for frames handed to the ordered sender.
/// Captures superseded before encoding never become delta dependencies.
public final class FrameDiffer {
    // Reusing the middle of a patch leaves up to four edge patches.
    private static let scrollPatchLimit = FrameInfo.maxPatches - 3
    private var previous: Data?, previousSize: PixelSize?
    private var nextID: UInt64 = 0
    public init() {}
    public func reset() {
        previous = nil
        previousSize = nil
    }
    public func encode(rgba: Data, size: PixelSize, captureTime: Double) throws -> Packet? {
        guard size.valid, rgba.count == size.width * size.height * 4 else {
            throw RexmoteError.invalid("Invalid captured pixels.")
        }
        let full = PixelRect(0, 0, size.width, size.height)
        var rects: [PixelRect]
        var scroll: FrameScroll?
        if let previous, previousSize == size {
            func trimmed(_ regions: [PixelRect]) -> [PixelRect] {
                rgba.withUnsafeBytes { current in
                    previous.withUnsafeBytes { old in
                        regions.compactMap { Self.trim($0, stride: size.width * 4, current: current, old: old) }
                    }
                }
            }
            rects = changedRegions(in: rgba, comparedTo: previous, size: size)
            if rects.count > FrameInfo.maxPatches {
                rects = Self.coalesce(trimmed(rects), full: full)
            }
            if rects.count <= Self.scrollPatchLimit,
                let index = rects.indices.max(by: {
                    rects[$0].width * rects[$0].height < rects[$1].width * rects[$1].height
                }), let movement = Self.scroll(in: rects[index], size: size, image: rgba, previous: previous)
            {
                let region = rects.remove(at: index)
                let moved = movement.destination
                if moved.y > region.y {
                    rects.append(PixelRect(region.x, region.y, region.width, moved.y - region.y))
                }
                let bottom = moved.y + moved.height
                if bottom < region.y + region.height {
                    rects.append(PixelRect(region.x, bottom, region.width, region.y + region.height - bottom))
                }
                if region.x < moved.x {
                    rects.append(PixelRect(region.x, moved.y, moved.x - region.x, moved.height))
                }
                let right = moved.x + moved.width
                if right < region.x + region.width {
                    rects.append(PixelRect(right, moved.y, region.x + region.width - right, moved.height))
                }
                scroll = movement
            }
            rects = trimmed(rects)
        } else {
            rects = [full]
        }
        guard !rects.isEmpty || scroll != nil else { return nil }
        let fullRefresh = rects == [full]
        // Large updates can use four CPU cores without building a backlog of frames.
        if rects.count == 1, let rect = rects.first, rect.width * rect.height >= 512 * 1024 {
            rects = (0..<4).map { i in
                let start = i * rect.height / 4
                let end = (i + 1) * rect.height / 4
                return PixelRect(rect.x, rect.y + start, rect.width, end - start)
            }
        }
        let compressed = try Self.compress(rects, image: rgba, size: size)
        var payload = Data()
        var patches: [Patch] = []
        payload.reserveCapacity(compressed.reduce(0) { $0 + $1.count })
        for (rect, bytes) in zip(rects, compressed) {
            patches.append(Patch(rect: rect, offset: payload.count, length: bytes.count))
            payload.append(bytes)
        }
        var info = FrameInfo(id: nextID, size: size, full: fullRefresh, captureTime: captureTime, patches: patches)
        info.scroll = scroll
        nextID += 1
        previous = rgba
        previousSize = size
        return Packet(.frame(info), payload: payload)
    }

    // Join neighboring runs in scan order, choosing the pair that adds the fewest unchanged pixels.
    private static func coalesce(_ regions: [PixelRect], full: PixelRect) -> [PixelRect] {
        var regions = regions
        while regions.count > scrollPatchLimit {
            var bestIndex = 0
            var bestCost = Int.max
            var bestBounds = full
            for i in 1..<regions.count {
                let a = regions[i - 1], b = regions[i]
                let left = min(a.x, b.x), top = min(a.y, b.y)
                let width = max(a.x + a.width, b.x + b.width) - left
                let height = max(a.y + a.height, b.y + b.height) - top
                let cost = width * height - a.width * a.height - b.width * b.height
                if cost < bestCost {
                    bestCost = cost
                    bestIndex = i
                    bestBounds = PixelRect(left, top, width, height)
                }
            }
            regions[bestIndex - 1] = bestBounds
            regions.remove(at: bestIndex)
        }
        let area = regions.reduce(0) { $0 + $1.width * $1.height }
        return area < full.width * full.height ? regions : [full]
    }

    private static func compress(_ regions: [PixelRect], image: Data, size: PixelSize) throws -> [Data] {
        func encode(_ rect: PixelRect) throws -> Data {
            if rect.width == size.width {
                let start = image.startIndex + rect.y * size.width * 4
                return try PixelCompression.compress(image[start..<(start + rect.height * size.width * 4)])
            }
            var patch = Data(capacity: rect.width * rect.height * 4)
            image.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                let base = bytes.bindMemory(to: UInt8.self).baseAddress!
                for y in rect.y..<(rect.y + rect.height) {
                    patch.append(base.advanced(by: (y * size.width + rect.x) * 4), count: rect.width * 4)
                }
            }
            return try PixelCompression.compress(patch)
        }
        guard regions.count >= 2, regions.reduce(0, { $0 + $1.width * $1.height }) >= 512 * 1024 else {
            return try regions.map(encode)
        }
        let lock = NSLock()
        let workers = min(4, regions.count)
        var results = [Result<Data, Error>?](repeating: nil, count: regions.count)
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for index in stride(from: worker, to: regions.count, by: workers) {
                let result = Result { try encode(regions[index]) }
                lock.withLock { results[index] = result }
            }
        }
        return try results.map { try $0!.get() }
    }

    private static func trim(
        _ rect: PixelRect, stride: Int, current: UnsafeRawBufferPointer, old: UnsafeRawBufferPointer
    ) -> PixelRect? {
        var left = rect.width
        var right = 0
        var top = rect.y + rect.height
        var bottom = rect.y
        for y in rect.y..<(rect.y + rect.height) {
            let offset = y * stride + rect.x * 4
            let new = current.baseAddress! + offset
            let prior = old.baseAddress! + offset
            guard memcmp(new, prior, rect.width * 4) != 0 else { continue }
            top = min(top, y)
            bottom = y + 1
            if left > 0 && memcmp(new, prior, left * 4) != 0 {
                var x = 0
                while x < left, memcmp(new + x * 4, prior + x * 4, 4) == 0 { x += 1 }
                left = x
            }
            if right < rect.width && memcmp(new + right * 4, prior + right * 4, (rect.width - right) * 4) != 0 {
                var x = rect.width
                while x > right, memcmp(new + (x - 1) * 4, prior + (x - 1) * 4, 4) == 0 { x -= 1 }
                right = x
            }
        }
        guard right > left else { return nil }
        return PixelRect(rect.x + left, top, right - left, bottom - top)
    }

    // Sample rows to find a likely scroll distance. Compare every byte before reusing any pixels.
    private static func scroll(in rect: PixelRect, size: PixelSize, image: Data, previous: Data) -> FrameScroll? {
        guard rect.height >= 128, rect.width * rect.height >= 128 * 1024 else { return nil }
        return image.withUnsafeBytes { current in
            previous.withUnsafeBytes { old in
                let stride = size.width * 4
                let first = current.baseAddress! + rect.x * 4
                let base = old.baseAddress! + rect.x * 4
                // Damage tiles can include stationary wallpaper or a scrollbar at either edge.
                let center = rect.width / 4
                let middle = rect.width - 2 * center
                let columns = (0..<16).map { (center + (2 * $0 + 1) * middle / 32) * 4 }
                func signature(_ row: UnsafeRawPointer) -> UInt64 {
                    var hash: UInt64 = 14_695_981_039_346_656_037
                    for column in columns {
                        hash =
                            (hash ^ UInt64(row.loadUnaligned(fromByteOffset: column, as: UInt32.self)))
                            &* 1_099_511_628_211
                    }
                    return hash
                }
                let rows = rect.y..<(rect.y + rect.height)
                var prior: [UInt64: Int] = [:]
                for y in rows { prior[signature(base + y * stride)] = y }
                var votes: [Int: Int] = [:]
                for y in Swift.stride(from: rows.lowerBound, to: rows.upperBound, by: 3) {
                    let key = signature(first + y * stride)
                    if let source = prior[key], source != y, signature(base + y * stride) != key {
                        votes[source - y, default: 0] += 1
                    }
                }
                guard let (offset, count) = votes.max(by: { $0.value < $1.value }), count >= 3 else { return nil }
                var start = rect.y
                var longest = 0
                var end = rect.y
                for y in rows {
                    let from = y + offset
                    if from < 0 || from >= size.height
                        || memcmp(first + y * stride + center * 4, base + from * stride + center * 4, middle * 4) != 0
                    {
                        start = y + 1
                    } else if y + 1 - start > longest {
                        longest = y + 1 - start
                        end = y + 1
                    }
                }
                guard longest >= max(16, rect.height / 8) else { return nil }
                let y = end - longest
                var left = 0
                var right = rect.width
                for row in y..<end {
                    let new = first + row * stride
                    let prior = base + (row + offset) * stride
                    if memcmp(new + left * 4, prior + left * 4, (center - left) * 4) != 0 {
                        var x = center
                        while x > left, memcmp(new + (x - 1) * 4, prior + (x - 1) * 4, 4) == 0 { x -= 1 }
                        left = x
                    }
                    let middleEnd = center + middle
                    if memcmp(new + middleEnd * 4, prior + middleEnd * 4, (right - middleEnd) * 4) != 0 {
                        var x = middleEnd
                        while x < right, memcmp(new + x * 4, prior + x * 4, 4) == 0 { x += 1 }
                        right = x
                    }
                }
                return FrameScroll(destination: PixelRect(rect.x + left, y, right - left, longest), sourceY: y + offset)
            }
        }
    }

    // Coalesce changed tiles across each row, then join matching runs down the image.
    private func changedRegions(in image: Data, comparedTo previous: Data, size: PixelSize) -> [PixelRect] {
        var regions: [PixelRect] = []
        func appendRun(x: Int, y: Int, width: Int, height: Int) {
            if let index = regions.lastIndex(where: { $0.x == x && $0.width == width && $0.y + $0.height == y }) {
                regions[index].height += height
            } else {
                regions.append(PixelRect(x, y, width, height))
            }
        }
        image.withUnsafeBytes { current in
            previous.withUnsafeBytes { old in
                for y in stride(from: 0, to: size.height, by: 64) {
                    let height = min(64, size.height - y)
                    var start: Int?
                    for x in stride(from: 0, to: size.width, by: 128) {
                        let width = min(128, size.width - x)
                        let changed = (y..<(y + height)).contains { row in
                            let offset = (row * size.width + x) * 4
                            return memcmp(current.baseAddress! + offset, old.baseAddress! + offset, width * 4) != 0
                        }
                        if changed {
                            start = start ?? x
                        } else if let left = start {
                            appendRun(x: left, y: y, width: x - left, height: height)
                            start = nil
                        }
                    }
                    if let left = start { appendRun(x: left, y: y, width: size.width - left, height: height) }
                }
            }
        }
        return regions
    }
}

/// Two frames can cross the network concurrently. New captures replace the single waiting frame.
public struct FlightWindow<Value> {
    private var sentFrames: [UInt64] = []
    public var canSend: Bool { sentFrames.count < 2 }
    public private(set) var latest: Value?
    public private(set) var coalesced = 0
    public init() {}
    public mutating func offer(_ value: Value) {
        if latest != nil { coalesced += 1 }
        latest = value
    }
    public mutating func take() -> Value? {
        guard canSend else { return nil }
        defer { latest = nil }
        return latest
    }
    public mutating func sent(_ id: UInt64) {
        precondition(canSend)
        sentFrames.append(id)
    }
    public mutating func acknowledge(_ id: UInt64) -> Bool {
        guard sentFrames.first == id else { return false }
        sentFrames.removeFirst()
        return true
    }
    public mutating func clearPending() { latest = nil }
}
