import AppKit

/// Quartz specifies line, fixed-point and pixel deltas separately. Applications use all three.
private struct ScrollAxis: Codable, Equatable {
    let lines: Int64
    let fixed: Double
    let pixels: Int64

    init(_ event: CGEvent, _ lines: CGEventField, _ fixed: CGEventField, _ pixels: CGEventField) {
        self.lines = event.getIntegerValueField(lines)
        self.fixed = event.getDoubleValueField(fixed)
        self.pixels = event.getIntegerValueField(pixels)
    }

    var valid: Bool {
        (-32768...32767).contains(lines) && (-32768...32767).contains(pixels) && (-32768...32768).contains(fixed)
    }

    func apply(to event: CGEvent, _ lines: CGEventField, _ fixed: CGEventField, _ pixels: CGEventField) {
        event.setIntegerValueField(lines, value: self.lines)
        event.setDoubleValueField(fixed, value: self.fixed)
        event.setIntegerValueField(pixels, value: self.pixels)
    }
}

private struct Wheel: Codable, Equatable {
    let x: ScrollAxis, y: ScrollAxis
    let continuous: Bool
    let phase: Int64, momentum: Int64, count: Int64

    init(_ event: CGEvent) {
        x = ScrollAxis(event, .scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2)
        y = ScrollAxis(event, .scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1)
        continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        count = event.getIntegerValueField(.scrollWheelEventScrollCount)
    }

    func event(source: CGEventSource?) -> CGEvent? {
        guard x.valid, y.valid, [0, 1, 2, 4, 8, 128].contains(phase), (0...3).contains(momentum),
            (0...Int64(Int32.max)).contains(count),
            let event = CGEvent(scrollWheelEvent2Source: source, units: continuous ? .pixel : .line,
                wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)
        else { return nil }
        x.apply(to: event, .scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2)
        y.apply(to: event, .scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.setIntegerValueField(.scrollWheelEventScrollCount, value: count)
        return event
    }
}

private enum RecognizedGesture: String, Codable {
    case magnify, rotate, swipe, smartMagnify

    init?(_ event: NSEvent) {
        switch event.type {
        case .magnify where (-1...16).contains(event.magnification): self = .magnify
        case .rotate where (-360...360).contains(event.rotation): self = .rotate
        case .swipe where (-1...1).contains(event.deltaX) && (-1...1).contains(event.deltaY): self = .swipe
        case .smartMagnify: self = .smartMagnify
        default: return nil
        }
    }

    func matches(_ event: CGEvent) -> Bool {
        let quartzType = UInt(event.type.rawValue)
        let allowed: [NSEvent.EventType] = [.gesture, .magnify, .rotate, .swipe, .smartMagnify]
        guard allowed.contains(where: { $0.rawValue == quartzType }), let appEvent = NSEvent(cgEvent: event),
            quartzType == NSEvent.EventType.gesture.rawValue || quartzType == appEvent.type.rawValue
        else { return false }
        return Self(appEvent) == self
    }
}

public struct TrackpadInput: Codable, Equatable {
    public let point: CGPoint
    public let modifiers: Int

    private enum Motion: Codable, Equatable {
        case wheel(Wheel)
        case gesture(RecognizedGesture, Data)
    }
    private let motion: Motion
    // A gesture is carried in the bounded JSON control header.
    private static let archiveLimit = 32 * 1024

    public init?(event: NSEvent, point: CGPoint, modifiers: Int) {
        guard let quartz = event.cgEvent else { return nil }
        if event.type == .scrollWheel, quartz.type == .scrollWheel {
            motion = .wheel(Wheel(quartz))
        } else {
            guard let gesture = RecognizedGesture(event), gesture.matches(quartz), let bytes = quartz.data as Data?,
                !bytes.isEmpty, bytes.count <= Self.archiveLimit else { return nil }
            motion = .gesture(gesture, bytes)
        }
        self.point = point
        self.modifiers = modifiers
    }

    public func event(in bounds: CGRect, source: CGEventSource?, flags: CGEventFlags) -> CGEvent? {
        guard !bounds.isEmpty, (0...1).contains(point.x), (0...1).contains(point.y), modifiers & ~79 == 0 else { return nil }
        let event: CGEvent
        switch motion {
        case .wheel(let wheel):
            guard let wheelEvent = wheel.event(source: source) else { return nil }
            event = wheelEvent
        case .gesture(let gesture, let bytes):
            guard !bytes.isEmpty, bytes.count <= Self.archiveLimit,
                let native = CGEvent(withDataAllocator: nil, data: bytes as CFData), gesture.matches(native)
            else { return nil }
            native.setSource(source)
            for field: CGEventField in [.eventTargetUnixProcessID, .mouseEventWindowUnderMousePointer,
                .mouseEventWindowUnderMousePointerThatCanHandleThisEvent] {
                native.setIntegerValueField(field, value: 0)
            }
            event = native
        }
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.location = CGPoint(x: bounds.minX + point.x * max(0, bounds.width - 1),
                                 y: bounds.minY + point.y * max(0, bounds.height - 1))
        event.flags = flags
        return event
    }
}
