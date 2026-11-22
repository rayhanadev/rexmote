import AppKit
import XCTest

@testable import RexmoteCLI
@testable import RexmoteCore

final class PaneTrackingTests: XCTestCase {
    func testTheFrontmostOfTwoOverlappingFloatingDesktopsStaysVisible() throws {
        func floating(_ id: String, bounds: [Double]) -> [String: Any] {
            ["kind": "floating", "layer_id": id, "bounds": bounds, "layout": ["block_id": id, "rect": bounds]]
        }
        let back = floating("back", bounds: [0.2, 0.2, 0.45, 0.45])
        let front = floating("front", bounds: [0.4, 0.4, 0.4, 0.4])
        let window = ["layers": [back, front]]
        XCTAssertNil(PanePlacement.locate(block: "back", inWindow: window))
        let visible = try XCTUnwrap(PanePlacement.locate(block: "front", inWindow: window))
        XCTAssertTrue(visible.floating)
        XCTAssertEqual(visible.rect, CGRect(x: 0.4, y: 0.4, width: 0.4, height: 0.4))
    }

    func testNestedCompactPanesFitInsideRexTerminalBorders() throws {
        // Measured with Rex preview.21. AX exposes the terminal including a one-point border.
        let parent = CGRect(x: 8, y: 50, width: 1454, height: 898)
        let layout: [String: Any] = ["layers": [["kind": "tiled", "layout": ["split": [
            "before": ["block_id": "left", "rect": [0, 0, 0.5, 1]],
            "after": ["split": [
                "before": ["block_id": "top", "rect": [0.5, 0, 0.5, 0.67]],
                "after": ["block_id": "bottom", "rect": [0.5, 0.67, 0.5, 0.33]],
            ]],
        ]]]]]
        let chrome = PaneChrome { $0 == "paneDensity" ? "compact" : nil }
        for (id, terminal) in [
            ("left", CGRect(x: 7, y: 125, width: 728, height: 824)),
            ("top", CGRect(x: 735, y: 125, width: 728, height: 540.2)),
            ("bottom", CGRect(x: 735, y: 701.2, width: 728, height: 247.8)),
        ] {
            let pane = try XCTUnwrap(PanePlacement.locate(block: id, inWindow: layout))
            let actual = chrome.body(pane, in: parent), expected = terminal.insetBy(dx: 1, dy: 1)
            XCTAssertEqual(actual.minX, expected.minX)
            XCTAssertEqual(actual.maxX, expected.maxX)
            XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5)
            XCTAssertEqual(actual.maxY, expected.maxY, accuracy: 0.5)
        }
    }

    func testUntitledRexWindowsLearnTheSessionWithoutMovingAPaneAcrossSpaces() {
        let scope = RemoteSession(serverID: UUID(), host: "Mac", session: "remote")
        var bindings = RexWindowBindings()
        let visible = [12, 27]
        bindings.observe(front: 12, session: scope)
        XCTAssertNil(bindings.parent(for: scope, selected: true, remembered: nil, named: [], visible: visible))
        bindings.observe(front: 12, session: scope)
        XCTAssertEqual(bindings.parent(for: scope, selected: true, remembered: nil, named: [], visible: visible), 12)

        // Switching apps leaves the visible Rex window and its panel together.
        bindings.observe(front: nil, session: nil)
        XCTAssertEqual(bindings.parent(for: scope, selected: true, remembered: 12, named: [], visible: visible), 12)
        // A similarly named window on the new Space cannot claim a live, off-screen parent.
        XCTAssertNil(bindings.parent(for: scope, selected: true, remembered: 12, named: [27], visible: [27]))
    }

    func testTwoWindowsKeepTheirOwnPanesAndAnUntrackedSessionReleasesItsWindow() {
        let a = RemoteSession(serverID: UUID(), host: "Mac", session: "A")
        let b = RemoteSession(serverID: UUID(), host: "Studio", session: "B")
        var bindings = RexWindowBindings()
        for _ in 0..<2 { bindings.observe(front: 11, session: a) }
        for _ in 0..<2 { bindings.observe(front: 22, session: b) }
        XCTAssertEqual(bindings.parent(for: a, selected: false, remembered: 11, named: [], visible: [22, 11]), 11)
        XCTAssertEqual(bindings.parent(for: b, selected: true, remembered: 22, named: [], visible: [22, 11]), 22)

        bindings.observe(front: 22, session: nil)
        XCTAssertNil(bindings.parent(for: b, selected: false, remembered: 22, named: [22], visible: [22, 11]))
        bindings.observe(front: 22, session: nil)
        bindings.observe(front: nil, session: nil)
        XCTAssertNil(bindings.parent(for: b, selected: false, remembered: 22, named: [22], visible: [22, 11]))
        XCTAssertEqual(bindings.parent(for: a, selected: false, remembered: 11, named: [], visible: [22, 11]), 11)
    }

    func testHeaderlessFloatingAndTiledPanesRoundTheirExposedTopCorners() {
        let current = PaneChrome { _ in nil }
        let hidden = PaneChrome { $0 == "paneHeaderVisibility" ? "never" : nil }
        let bottom: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        for floating in [false, true] {
            XCTAssertEqual(current.corners(floating: floating), bottom)
            XCTAssertEqual(hidden.corners(floating: floating), bottom.union([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]))
        }
    }
}
