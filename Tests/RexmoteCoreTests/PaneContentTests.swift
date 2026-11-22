import AppKit
import XCTest

@testable import RexmoteCLI

@MainActor final class PaneContentTests: XCTestCase {
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func testStatusCentersWrappedTextAndActionInTheVisiblePane() throws {
        let pane = PaneContent()
        let title = "MacBook Pro is locked"
        let message = "Unlock the remote Mac. This pane will resume automatically."
        pane.show(.status(title: title, detail: message, action: "Reconnect"))

        for width in [CGFloat(723), 320, 150] {
            pane.setFrameSize(CGSize(width: width, height: 320))
            pane.layoutSubtreeIfNeeded()
            let views = descendants(of: pane)
            let labels = views.compactMap { $0 as? NSTextField }.filter { $0.stringValue == title || $0.stringValue == message }
            XCTAssertEqual(labels.count, 2)
            for label in labels {
                XCTAssertEqual(label.alignment, .center)
                XCTAssertGreaterThanOrEqual(label.bounds.height + 1, label.fittingSize.height)
            }
            let action = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Reconnect" })
            let frames = (labels as [NSView] + [action]).map { $0.convert($0.bounds, to: pane) }
            for frame in frames {
                XCTAssertEqual(frame.midX, pane.bounds.midX, accuracy: 1)
                XCTAssertTrue(pane.bounds.insetBy(dx: -1, dy: -1).contains(frame))
            }
            let group = frames.reduce(CGRect.null) { $0.union($1) }
            XCTAssertEqual(group.midY, pane.bounds.midY, accuracy: 1)
        }
        pane.setFrameSize(CGSize(width: 150, height: 45))
        pane.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(descendants(of: pane).compactMap { $0 as? NSScrollView }.first)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height, scroll.contentSize.height)
        XCTAssertLessThanOrEqual(scroll.documentVisibleRect.minY, 1)
        pane.show(.desktop)
        pane.layoutSubtreeIfNeeded()
        XCTAssertTrue(scroll.isHidden)
        XCTAssertEqual(pane.desktop.frame, pane.bounds)
    }

    func testInterfaceColorsUseRexTokensAndCustomColorSpaces() {
        let orange: [String: Any] = ["colorSpace": "display-p3", "red": 0.81, "green": 0.43, "blue": 0.08, "alpha": 1.0]
        let expected = NSColor(displayP3Red: 0.81, green: 0.43, blue: 0.08, alpha: 1)
        let palette = RexPalette(semantic: ["contentSecondary": orange, "accentOnSolid": orange])
        XCTAssertEqual(palette.secondary, expected)
        XCTAssertEqual(palette.onAccent, expected)
        let custom = RexPalette(custom: ["foreground": orange, "cursorText": orange])
        XCTAssertEqual(custom.primary, expected)
        XCTAssertEqual(custom.onAccent, expected)
        XCTAssertEqual(RexPalette(custom: ["background": "#123456"]).background,
                       NSColor(srgbRed: 0x12 / 255.0, green: 0x34 / 255.0, blue: 0x56 / 255.0, alpha: 1))
    }
}
