import AppKit
import XCTest

@testable import RexmoteCore

final class TrackpadTests: XCTestCase {
    func testTrackpadWheelPreservesQuartzPrecisionPhasesAndCoordinates() throws {
        let bounds = CGRect(x: -800, y: 160, width: 801, height: 401)
        let point = CGPoint(x: 0.25, y: 0.75)
        for (phase, momentum) in [(128, 0), (1, 0), (2, 0), (4, 0), (8, 0), (0, 1), (0, 2), (0, 3)] {
            let original = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                                wheel1: 481, wheel2: -349, wheel3: 0))
            original.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 4.25)
            original.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -7.125)
            original.setIntegerValueField(.scrollWheelEventScrollCount, value: 3)
            original.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
            original.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum))
            let source = try XCTUnwrap(NSEvent(cgEvent: original))
            let captured = try XCTUnwrap(TrackpadInput(event: source, point: point, modifiers: 1))
            let packet = Packet(.input(revision: 1, event: .trackpad(captured)))
            var decoder = PacketDecoder()
            let decoded = try XCTUnwrap(decoder.feed(packet.encoded()).first)
            guard case .input(_, .trackpad(let motion), nil) = decoded.message else { return XCTFail("Missing scroll") }
            let rebuilt = try XCTUnwrap(motion.event(in: bounds, source: nil, flags: .maskShift))
            XCTAssertEqual(rebuilt.type, .scrollWheel)
            XCTAssertEqual(rebuilt.location, CGPoint(x: -600, y: 460))
            XCTAssertEqual(rebuilt.flags, .maskShift)
            let received = try XCTUnwrap(NSEvent(cgEvent: rebuilt))
            XCTAssertEqual(received.phase, source.phase)
            XCTAssertEqual(received.momentumPhase, source.momentumPhase)
            XCTAssertTrue(received.hasPreciseScrollingDeltas)
            XCTAssertEqual(received.scrollingDeltaY, source.scrollingDeltaY)
            XCTAssertEqual(received.scrollingDeltaX, source.scrollingDeltaX)
            XCTAssertEqual(rebuilt.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 481)
            XCTAssertEqual(rebuilt.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), -349)
            XCTAssertEqual(rebuilt.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), 4.25)
            XCTAssertEqual(rebuilt.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2), -7.125)
            XCTAssertEqual(rebuilt.getIntegerValueField(.scrollWheelEventScrollCount), 3)
        }
    }

    func testOrdinaryMouseWheelRetainsLineUnits() throws {
        let original = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                            wheel1: -3, wheel2: 0, wheel3: 0))
        let source = try XCTUnwrap(NSEvent(cgEvent: original))
        let motion = try XCTUnwrap(TrackpadInput(event: source, point: .zero, modifiers: 0))
        let event = try XCTUnwrap(motion.event(in: CGRect(x: 0, y: 0, width: 10, height: 10), source: nil, flags: []))
        let result = try XCTUnwrap(NSEvent(cgEvent: event))
        XCTAssertFalse(result.hasPreciseScrollingDeltas)
        XCTAssertEqual(result.scrollingDeltaY, source.scrollingDeltaY)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -3)
    }

    func testGestureDecoderRejectsOtherQuartzEventsAndOutOfBoundsInput() throws {
        let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        XCTAssertNil(TrackpadInput(event: try XCTUnwrap(NSEvent(cgEvent: key)), point: .zero, modifiers: 0))
        let bytes = try XCTUnwrap(key.data) as Data
        let record: [String: Any] = [
            "point": [0.0, 0.0], "modifiers": 0,
            "motion": ["gesture": ["_0": "smartMagnify", "_1": bytes.base64EncodedString()]],
        ]
        let bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        let imported = try JSONDecoder().decode(TrackpadInput.self, from: JSONSerialization.data(withJSONObject: record))
        XCTAssertNil(imported.event(in: bounds, source: nil, flags: []))

        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                         wheel1: 0, wheel2: 0, wheel3: 0))
        let source = try XCTUnwrap(NSEvent(cgEvent: wheel))
        let outside = try XCTUnwrap(TrackpadInput(event: source, point: CGPoint(x: -0.5, y: 0), modifiers: 0))
        XCTAssertNil(outside.event(in: bounds, source: nil, flags: []))
    }
}
