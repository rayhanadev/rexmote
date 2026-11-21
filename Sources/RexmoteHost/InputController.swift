import AppKit
import ApplicationServices
import RexmoteCore

@MainActor final class InputController {
    var enabled = false { didSet { if !enabled { releaseAll() } } }
    var display: DisplayInfo?
    private var keys = Set<CGKeyCode>(), buttons = Set<Int>()
    private var point = CGPoint.zero
    private let source = CGEventSource(stateID: .privateState)
    private var activeScroll: (point: CGPoint, momentum: Bool, flags: CGEventFlags)?
    // Core Graphics numbers the right button before the middle button.
    private static let nativeButtons = [CGMouseButton.left, .center, .right]
    private static let downEvents: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    private static let upEvents: [CGEventType] = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
    private static let dragEvents: [CGEventType] = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    static func flags(_ modifiers: Int) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & 1 != 0 { flags.insert(.maskShift) }
        if modifiers & 2 != 0 { flags.insert(.maskAlternate) }
        if modifiers & 4 != 0 { flags.insert(.maskControl) }
        if modifiers & 8 != 0 { flags.insert(.maskCommand) }
        if modifiers & 64 != 0 { flags.insert(.maskAlphaShift) }
        return flags
    }
    func post(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: 0x524558)
        event?.post(tap: .cghidEventTap)
    }
    func handle(_ input: RemoteInput) throws {
        if case .releaseAll = input {
            releaseAll()
            return
        }
        guard enabled && AXIsProcessTrusted() && CGPreflightPostEventAccess() else { return }
        switch input {
        case .pointer(let p):
            guard p.valid, let display = display else { throw RexmoteError.invalid("Invalid pointer input.") }
            let bounds = CGDisplayBounds(display.id)
            guard CGDisplayIsActive(display.id) != 0, !bounds.isEmpty else {
                releaseAll()
                return
            }
            point = CGPoint(
                x: bounds.minX + p.x * max(0, bounds.width - 1), y: bounds.minY + p.y * max(0, bounds.height - 1))
            let button = Self.nativeButtons[p.button]
            let buttonNumber = Int(button.rawValue)
            let type: CGEventType
            var activeButton = button
            switch p.action {
            case "down":
                buttons.insert(buttonNumber)
                type = Self.downEvents[buttonNumber]
            case "up":
                buttons.remove(buttonNumber)
                type = Self.upEvents[buttonNumber]
            default:
                if let held = buttons.min(), let pressed = CGMouseButton(rawValue: UInt32(held)) {
                    type = Self.dragEvents[held]
                    activeButton = pressed
                } else {
                    type = .mouseMoved
                    activeButton = .left
                }
            }
            let event = CGEvent(
                mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: activeButton)
            if let count = p.clickCount { event?.setIntegerValueField(.mouseEventClickState, value: Int64(count)) }
            event?.flags = Self.flags(p.modifiers)
            post(event)
        case .trackpad(let motion):
            guard let display, CGDisplayIsActive(display.id) != 0,
                let event = motion.event(in: CGDisplayBounds(display.id), source: source, flags: Self.flags(motion.modifiers))
            else { return }
            if event.type == .scrollWheel {
                let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
                let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
                if [1, 2].contains(momentum) || [1, 2, 128].contains(phase) {
                    activeScroll = (event.location, momentum != 0, event.flags)
                } else {
                    activeScroll = nil
                }
            }
            post(event)
        case .key(let key):
            guard (1...3).contains(key.event), (0..<256).contains(key.modifiers), key.keyCode < 128,
                key.text.utf8.count <= 4096
            else { throw RexmoteError.invalid("Invalid keyboard input.") }
            let pressed = key.event != 3
            let event = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: pressed)
            event?.flags = Self.flags(key.modifiers)
            if key.modifiers & (2 | 4 | 8) == 0,
                key.text.unicodeScalars.allSatisfy({ $0.value >= 32 && !(0xf700...0xf8ff).contains($0.value) })
            {
                setText(event, key.text)
            }
            if key.event == 2 { event?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            if pressed { keys.insert(key.keyCode) } else { keys.remove(key.keyCode) }
            post(event)
        case .text(let text):
            guard text.utf8.count <= 65_536 else { throw RexmoteError.invalid("Paste exceeds 64 KiB.") }
            typeText(text)
        case .releaseAll: releaseAll()
        }
    }
    /// Finder receives the shortcut after the upload, often after the user has released Command.
    func pasteShortcut(_ key: KeyInput) throws {
        let modifierKeys: [(mask: Int, left: CGKeyCode, right: CGKeyCode)] = [(8, 55, 54), (2, 58, 61), (1, 56, 60)]
        let missing = modifierKeys.filter {
            key.modifiers & $0.mask != 0 && !keys.contains($0.left) && !keys.contains($0.right)
                && !CGEventSource.flagsState(.combinedSessionState).contains(Self.flags($0.mask))
        }
        var flags = missing.reduce(key.modifiers) { $0 & ~$1.mask }
        var pressed: [(mask: Int, code: CGKeyCode)] = []
        defer {
            for modifier in pressed.reversed() {
                flags &= ~modifier.mask
                try? handle(.key(KeyInput(keyCode: modifier.code, modifiers: flags, event: 3)))
            }
        }
        for modifier in missing {
            flags |= modifier.mask
            try handle(.key(KeyInput(keyCode: modifier.left, modifiers: flags)))
            pressed.append((modifier.mask, modifier.left))
        }
        try handle(.key(key))
        try handle(.key(KeyInput(keyCode: key.keyCode, modifiers: key.modifiers, event: 3, text: key.text)))
    }

    private func setText(_ event: CGEvent?, _ text: String) {
        guard !text.isEmpty else { return }
        let chars = Array(text.utf16)
        chars.withUnsafeBufferPointer {
            event?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: $0.baseAddress!)
        }
    }
    private func typeText(_ text: String) {
        // Character chunks keep individual events bounded without splitting surrogate pairs.
        var chunk = ""
        func emit() {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.flags = []
                setText(event, chunk)
                post(event)
            }
            chunk = ""
        }
        for c in text {
            chunk.append(c)
            if chunk.utf16.count >= 64 { emit() }
        }
        emit()
    }
    func releaseAll() {
        if let scroll = activeScroll, let stop = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
            wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) {
            stop.location = scroll.point
            stop.flags = scroll.flags
            stop.setIntegerValueField(scroll.momentum ? .scrollWheelEventMomentumPhase : .scrollWheelEventScrollPhase,
                                      value: scroll.momentum ? 3 : 8)
            post(stop)
        }
        activeScroll = nil
        for key in keys.sorted() {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            event?.flags = []
            post(event)
        }
        for button in buttons.sorted() {
            let type: CGEventType = Self.upEvents[button]
            let event = CGEvent(
                mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                mouseButton: CGMouseButton(rawValue: UInt32(button))!)
            event?.flags = []
            post(event)
        }
        keys.removeAll()
        buttons.removeAll()
    }
}
