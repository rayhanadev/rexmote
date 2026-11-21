import AppKit
import RexmoteCore

/// The same aspect-fit rectangle positions pixels and maps pointer events to the host.
final class DesktopView: NSView {
    var input: ((RemoteInput) -> Void)?
    var navigateRex: ((String?) -> Void)?
    private var tracking: NSTrackingArea?
    private let pixels = CALayer()
    private var size = CGSize.zero
    private var modifiersDown = Set<UInt16>()
    private var lastTrackpadPoint: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        pixels.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        pixels.contentsGravity = .resize
        pixels.magnificationFilter = .linear
        layer?.addSublayer(pixels)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Remote desktop")
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ image: CGImage?) {
        let next = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        if size != next {
            size = next
            needsLayout = true
        }
        pixels.contents = image
    }
    override func layout() {
        super.layout()
        if size.width > 0 && size.height > 0 {
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            let width = size.width * scale
            let height = size.height * scale
            pixels.frame = CGRect(
                x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    static func flags(_ event: NSEvent) -> Int {
        let flags = event.modifierFlags
        return (flags.contains(.shift) ? 1 : 0) | (flags.contains(.option) ? 2 : 0)
            | (flags.contains(.control) ? 4 : 0) | (flags.contains(.command) ? 8 : 0)
            | (flags.contains(.capsLock) ? 64 : 0)
    }
    func keyboard(_ event: NSEvent, kind: Int) {
        let flags = Self.flags(event)
        let chars = flags & (2 | 4 | 8) == 0 ? event.characters : event.charactersIgnoringModifiers
        input?(.key(KeyInput(keyCode: event.keyCode, modifiers: flags, event: kind, text: chars ?? "")))
    }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == [.control, .option], let navigateRex {
            if event.keyCode == 50 {
                navigateRex(nil)
                return
            }
            if let direction = [123: "left", 124: "right", 125: "down", 126: "up"][Int(event.keyCode)] {
                navigateRex(direction)
                return
            }
        }
        keyboard(event, kind: event.isARepeat ? 2 : 1)
    }
    override func keyUp(with event: NSEvent) { keyboard(event, kind: 3) }
    override func flagsChanged(with event: NSEvent) {
        let map: [UInt16: NSEvent.ModifierFlags] = [
            54: .command, 55: .command, 56: .shift, 60: .shift, 58: .option, 61: .option, 59: .control, 62: .control,
            57: .capsLock,
        ]
        guard let flag = map[event.keyCode] else { return }
        let down = event.modifierFlags.contains(flag) && !modifiersDown.contains(event.keyCode)
        if down { modifiersDown.insert(event.keyCode) } else { modifiersDown.remove(event.keyCode) }
        input?(.key(KeyInput(keyCode: event.keyCode, modifiers: Self.flags(event), event: down ? 1 : 3)))
    }
    func releaseInput() {
        modifiersDown.removeAll()
        lastTrackpadPoint = nil
        input?(.releaseAll)
    }

    private func desktopPoint(_ event: NSEvent) -> CGPoint? {
        guard let window else { return nil }
        // AppKit supplies screen coordinates for process-targeted events without a window.
        let local = event.windowNumber <= 0 ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
        let point = convert(local, from: nil)
        let frame = pixels.frame
        guard size.width > 0, !frame.isEmpty, frame.contains(point) else { return nil }
        return CGPoint(x: (point.x - frame.minX) / frame.width, y: (frame.maxY - point.y) / frame.height)
    }

    private func pointer(_ event: NSEvent, _ action: String) {
        if action == "down", let window {
            if !window.isKeyWindow { window.makeKey() }
            window.makeFirstResponder(self)
        }
        guard let point = desktopPoint(event) else {
            if action == "up" { input?(.releaseAll) }
            return
        }
        let button: Int
        switch event.buttonNumber {
        case 0: button = 0
        case 1: button = 2
        case 2: button = 1
        default: return
        }
        input?(.pointer(PointerInput(action: action, x: point.x, y: point.y, button: button, modifiers: Self.flags(event))))
    }

    @discardableResult func forwardTrackpad(_ event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, window?.firstResponder === self, !isHiddenOrHasHiddenAncestor else { return false }
        let phase = event.phase
        let momentum = event.type == .scrollWheel ? event.momentumPhase : []
        if phase == .began || phase == .mayBegin || (phase.isEmpty && momentum.isEmpty) {
            lastTrackpadPoint = nil
        }
        let continuing = phase == .changed || phase == .ended || phase == .cancelled || !momentum.isEmpty
        guard let point = desktopPoint(event) ?? (continuing && event.windowNumber > 0 ? lastTrackpadPoint : nil),
            let motion = TrackpadInput(event: event, point: point, modifiers: Self.flags(event))
        else { return false }
        let finished = phase == .cancelled || momentum == .ended || (event.type != .scrollWheel && phase == .ended)
        lastTrackpadPoint = finished || (phase.isEmpty && momentum.isEmpty) ? nil : point
        input?(.trackpad(motion))
        return true
    }
    override func mouseDown(with e: NSEvent) { pointer(e, "down") }
    override func mouseUp(with e: NSEvent) { pointer(e, "up") }
    override func rightMouseDown(with e: NSEvent) { pointer(e, "down") }
    override func rightMouseUp(with e: NSEvent) { pointer(e, "up") }
    override func otherMouseDown(with e: NSEvent) { pointer(e, "down") }
    override func otherMouseUp(with e: NSEvent) { pointer(e, "up") }
    override func mouseMoved(with e: NSEvent) { pointer(e, "move") }
    override func mouseDragged(with e: NSEvent) { pointer(e, "move") }
    override func rightMouseDragged(with e: NSEvent) { pointer(e, "move") }
    override func otherMouseDragged(with e: NSEvent) { pointer(e, "move") }
    override func scrollWheel(with event: NSEvent) { forwardTrackpad(event) }
    override func magnify(with event: NSEvent) { forwardTrackpad(event) }
    override func rotate(with event: NSEvent) { forwardTrackpad(event) }
    override func swipe(with event: NSEvent) { forwardTrackpad(event) }
    override func smartMagnify(with event: NSEvent) { forwardTrackpad(event) }
}
