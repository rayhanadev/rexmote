import Foundation
import XCTest

@testable import RexmoteCore

final class CoreTests: XCTestCase {
    func testFramingAcrossEveryBoundary() throws {
        let message = Packet(.hello(version: 1, token: String(repeating: "x", count: 64)))
        let bytes = try message.encoded() + Packet(.heartbeat).encoded()
        for split in 0...bytes.count {
            var decoder = PacketDecoder()
            let a = try decoder.feed(Data(bytes.prefix(split)))
            let b = try decoder.feed(Data(bytes.dropFirst(split)))
            XCTAssertEqual(a.count + b.count, 2)
            try decoder.finish()
        }
    }
    func testRejectTruncatedAndOversizedPackets() throws {
        let bytes = try Packet(.heartbeat).encoded()
        for size in 1..<bytes.count {
            var decoder = PacketDecoder()
            _ = try decoder.feed(Data(bytes.prefix(size)))
            XCTAssertThrowsError(try decoder.finish())
        }
        var decoder = PacketDecoder()
        XCTAssertThrowsError(try decoder.feed(Data([82, 88, 84, 49, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0])))
        var other = PacketDecoder()
        XCTAssertThrowsError(try other.feed(Packet(.heartbeat, payload: Data([1])).encoded()))
    }
    func testExactDamageReconstruction() throws {
        let differ = FrameDiffer()
        let size = PixelSize(301, 139)
        var data = Data(repeating: 32, count: size.width * size.height * 4)
        var reconstruction = Data()
        for frame in 0..<50 {
            // Deliberately includes the last pixel and small moving regions across tile edges.
            let index =
                frame == 49 ? data.count - 1 : ((frame * 47) % size.height * size.width + (frame * 23) % size.width) * 4
            data[index] = UInt8(frame + 40)
            let packet = try XCTUnwrap(differ.encode(rgba: data, size: size, captureTime: Double(frame)))
            guard case .frame(let info) = packet.message else { return XCTFail() }
            try info.validate(payload: packet.payload)
            if info.full { reconstruction = Data(count: data.count) }
            for p in info.patches {
                let pixels = try PixelCompression.decompress(
                    packet.payload.subdata(in: p.offset..<(p.offset + p.length)),
                    expected: p.rect.width * p.rect.height * 4)
                for y in 0..<p.rect.height {
                    let offset = ((p.rect.y + y) * size.width + p.rect.x) * 4
                    reconstruction.replaceSubrange(
                        offset..<(offset + p.rect.width * 4),
                        with: pixels[(y * p.rect.width * 4)..<((y + 1) * p.rect.width * 4)])
                }
            }
            XCTAssertEqual(reconstruction, data)
            XCTAssertEqual(info.id, UInt64(frame))
        }
        XCTAssertNil(try differ.encode(rgba: data, size: size, captureTime: 100))
        differ.reset()
        let packet = try XCTUnwrap(differ.encode(rgba: data, size: size, captureTime: 101))
        guard case .frame(let frame) = packet.message else { return XCTFail() }
        XCTAssertTrue(frame.full)
        XCTAssertEqual(frame.id, 50)
        let resized = try XCTUnwrap(
            differ.encode(rgba: Data(repeating: 7, count: 67 * 31 * 4), size: PixelSize(67, 31), captureTime: 102))
        guard case .frame(let frame2) = resized.message else { return XCTFail() }
        XCTAssertTrue(frame2.full)
    }
    func testCompressionRejectsTruncationTrailingBytesAndWrongSize() throws {
        let raw = Data(repeating: 42, count: 256)
        let compressed = try PixelCompression.compress(raw)
        XCTAssertEqual(try PixelCompression.decompress(compressed, expected: 256), raw)
        XCTAssertThrowsError(try PixelCompression.decompress(compressed, expected: 255))
        XCTAssertThrowsError(try PixelCompression.decompress(Data(compressed.dropLast()), expected: 256))
        XCTAssertThrowsError(try PixelCompression.decompress(compressed + Data([0]), expected: 256))
    }
    func testManyIsolatedChangesStayWithinThePatchBudgetWithoutResendingTheScreen() throws {
        let size = PixelSize(2051, 715)
        let differ = FrameDiffer()
        var receiver = FrameBuffer()
        var pixels = Data(repeating: 0, count: size.width * size.height * 4)
        for step in 0..<4 {
            if step != 0 {
                for y in stride(from: 9, to: size.height, by: 128) {
                    for x in stride(from: step, to: size.width, by: 256) {
                        pixels[(y * size.width + x) * 4] = UInt8(x % 250 + step)
                    }
                }
                pixels[pixels.count - 1] = UInt8(step)
            }
            let packet = try XCTUnwrap(differ.encode(rgba: pixels, size: size, captureTime: Double(step)))
            guard case .frame(let frame) = packet.message else { return XCTFail() }
            if step > 0 {
                XCTAssertFalse(frame.full)
                XCTAssertLessThanOrEqual(frame.patches.count, 32)
                let area = frame.patches.reduce(0) { $0 + $1.rect.width * $1.rect.height }
                XCTAssertLessThan(area, size.width * size.height / 25)
            }
            try receiver.apply(frame, payload: packet.payload)
            XCTAssertEqual(receiver.pixels, pixels)
        }
    }
    func testScrollingReusesRowsAndReconstructsEveryPixelInBothDirections() throws {
        let size = PixelSize(768, 512)
        let encoder = FrameDiffer()
        var receiver = FrameBuffer()
        for offset in [0, 19, 7, 43] {
            var pixels = Data(count: size.width * size.height * 4)
            pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                let words = raw.bindMemory(to: UInt32.self)
                for y in 0..<size.height {
                    for x in 0..<size.width {
                        // Stationary sidebar, header and footer around the scrolling region.
                        let row = x < 128 || y < 34 || y >= 491 ? y : y + offset
                        words[y * size.width + x] = UInt32(row << 16 | x)
                    }
                }
                words[77 * size.width + 512] ^= UInt32(offset)
            }
            let packet = try XCTUnwrap(encoder.encode(rgba: pixels, size: size, captureTime: 0))
            guard case .frame(let frame) = packet.message else { return XCTFail() }
            if offset != 0 { XCTAssertNotNil(frame.scroll) }
            try receiver.apply(frame, payload: packet.payload)
            XCTAssertEqual(receiver.pixels, pixels)
        }
        var invalid = FrameInfo(id: 4, size: size, full: false, captureTime: 0, patches: [])
        invalid.scroll = FrameScroll(destination: PixelRect(0, 0, 768, 400), sourceY: Int.max)
        XCTAssertThrowsError(try receiver.apply(invalid, payload: Data()))
        XCTAssertTrue(receiver.pixels.isEmpty)
    }
    func testFrameRejectsInvalidGeometryAndOffsets() throws {
        let compressed = try PixelCompression.compress(Data(repeating: 0, count: 16))
        var frame = FrameInfo(
            id: 0, size: PixelSize(2, 2), full: true, captureTime: 0,
            patches: [Patch(rect: PixelRect(0, 0, 2, 2), offset: 0, length: compressed.count)])
        try frame.validate(payload: compressed)
        frame.patches[0].rect.x = 1
        XCTAssertThrowsError(try frame.validate(payload: compressed))
        frame.patches[0].rect.x = 0
        frame.patches[0].offset = Int.max
        XCTAssertThrowsError(try frame.validate(payload: compressed))
    }
    func testLargeRefreshReconstructsAllBandsAndRejectsMissingRows() throws {
        let size = PixelSize(1024, 512)
        var pixels = Data(count: size.width * size.height * 4)
        pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for row in 0..<size.height {
                memset(raw.baseAddress! + row * size.width * 4, Int32(row % 251), size.width * 4)
            }
        }
        let packet = try XCTUnwrap(FrameDiffer().encode(rgba: pixels, size: size, captureTime: 0))
        guard case .frame(var frame) = packet.message else { return XCTFail() }
        XCTAssertTrue(frame.full)
        XCTAssertGreaterThan(frame.patches.count, 1)
        var buffer = FrameBuffer()
        try buffer.apply(frame, payload: packet.payload)
        XCTAssertEqual(buffer.pixels, pixels)
        frame.patches[1].rect.y += 1
        XCTAssertThrowsError(try buffer.apply(frame, payload: packet.payload))
        XCTAssertTrue(buffer.pixels.isEmpty)
    }
    func testBackpressureRetainsNewestOnly() {
        var flight = FlightWindow<Int>()
        flight.offer(1)
        XCTAssertEqual(flight.take(), 1)
        flight.sent(100)
        flight.offer(2)
        XCTAssertEqual(flight.take(), 2)
        flight.sent(101)
        for i in 3...1000 { flight.offer(i) }
        XCTAssertNil(flight.take())
        XCTAssertFalse(flight.acknowledge(101))
        XCTAssertNil(flight.take())
        XCTAssertTrue(flight.acknowledge(100))
        XCTAssertEqual(flight.take(), 1000)
        XCTAssertEqual(flight.coalesced, 997)
        flight.offer(1001)
        flight.clearPending()
        XCTAssertNil(flight.take())
    }
    func testPointerLimitsCannotOverflow() {
        XCTAssertFalse(PointerInput(action: "scroll", x: 0, y: 0).valid)
        XCTAssertFalse(PointerInput(action: "move", x: .nan, y: 0).valid)
        XCTAssertFalse(PointerInput(action: "down", x: 1.01, y: 0).valid)
        XCTAssertTrue(PointerInput(action: "move", x: 0, y: 1).valid)
    }
    func testUnixSocketRoundTripAndPermissions() throws {
        let listener = try LocalListener()
        let peer = try WireSocket.connect(path: listener.path)
        let server = try XCTUnwrap(listener.acceptConnection())
        XCTAssertTrue(peerIsCurrentUser(peer.fd))
        XCTAssertTrue(peerIsCurrentUser(server.fd))
        let attrs = try FileManager.default.attributesOfItem(atPath: listener.directory)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try peer.send(Packet(.heartbeat))
        XCTAssertEqual(try server.receive().count, 1)
        peer.close()
        peer.close()
        XCTAssertThrowsError(try server.receive())
        server.close()
    }
}
