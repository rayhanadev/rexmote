import RexmoteCore
import VirtualDisplay

protocol VirtualScreen: AnyObject {
    var displayID: UInt32 { get }
    func resize(toWidth width: UInt32, height: UInt32, retina: Bool) throws
    func close()
}

extension RXTDisplay: VirtualScreen {}

/// A helper owns one display for the lifetime of its pane, including across resizes.
@MainActor final class PaneDisplay {
    private let create: (UInt32, UInt32, Bool) throws -> VirtualScreen
    private var screen: VirtualScreen?
    private var failure: Error?
    private(set) var mode: VirtualDisplayMode?
    var id: UInt32? { screen?.displayID }

    init(
        create: @escaping (UInt32, UInt32, Bool) throws -> VirtualScreen = {
            try RXTDisplay.create(withWidth: $0, height: $1, retina: $2)
        }
    ) {
        self.create = create
    }

    func apply(_ requested: VirtualDisplayMode) throws {
        guard requested.valid else { throw RexmoteError.invalid("Unsupported virtual desktop dimensions.") }
        if mode == requested {
            if let failure { throw failure }
            return
        }
        mode = requested
        failure = nil
        let width = UInt32(requested.points.width)
        let height = UInt32(requested.points.height)
        do {
            if let screen {
                try screen.resize(toWidth: width, height: height, retina: requested.hiDPI)
            } else {
                screen = try create(width, height, requested.hiDPI)
            }
        } catch {
            failure = error
            throw error
        }
    }

    func close() {
        screen?.close()
        screen = nil
        mode = nil
        failure = nil
    }
}
