import AppKit
import XCTest

@testable import RexmoteCLI
@testable import RexmoteCore
@testable import RexmoteHost

@MainActor final class ClipboardTests: XCTestCase {
    private func key(_ character: String, modifiers: Int = 8, event: Int = 1) -> RemoteInput {
        let codes: [String: UInt16] = ["c": 8, "v": 9, "x": 7]
        return .key(KeyInput(keyCode: codes[character]!, modifiers: modifiers, event: event, text: character))
    }

    private func copy(_ viewer: PaneClipboard, pane: String) throws -> UUID {
        let packet = try XCTUnwrap(viewer.packet(for: key("c"), revision: 1, pane: pane))
        guard case .input(_, _, let request) = packet.message else { throw RexmoteError.invalid("Expected Copy") }
        return try XCTUnwrap(request)
    }

    func testPasteAndCopyRoundTripAcrossIndependentPasteboards() async throws {
        let local = NSPasteboard.withUniqueName(), remote = NSPasteboard.withUniqueName()
        defer { local.releaseGlobally(); remote.releaseGlobally() }
        let viewer = PaneClipboard(board: local), host = HostClipboard(board: remote)
        let text = "naïve 🐾\nsecond line"
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("<em>formatted</em>", forType: .html)
        let image = NSPasteboardItem()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jhZkAAAAASUVORK5CYII=")!
        image.setData(png, forType: .png)
        XCTAssertTrue(local.writeObjects([item, image]))

        let outgoing = try XCTUnwrap(viewer.packet(for: key("v"), revision: 1, pane: "A"))
        var decoder = PacketDecoder()
        let paste = try XCTUnwrap(decoder.feed(outgoing.encoded()).first)
        var pasted = false
        host.paste(paste.payload) {
            pasted = true
            XCTAssertEqual(remote.pasteboardItems?.first?.string(forType: .string), text)
            XCTAssertEqual(remote.pasteboardItems?.first?.string(forType: .html), "<em>formatted</em>")
            XCTAssertEqual(remote.pasteboardItems?.last?.data(forType: .png), png)
        }
        XCTAssertTrue(pasted)

        let request = try copy(viewer, pane: "A")
        let quickPaste = try XCTUnwrap(viewer.packet(for: key("v"), revision: 1, pane: "A"))
        XCTAssertTrue(quickPaste.payload.isEmpty)
        let copied = expectation(description: "The remote app completes Copy after its key event")
        host.copy {
            Task { @MainActor in
                remote.clearContents()
                remote.setString("copied on remote", forType: .string)
            }
        } canRead: { true } reply: { changed, contents in
            XCTAssertTrue(changed)
            viewer.received(contents, request: request, changed: changed, pane: "A")
            copied.fulfill()
        }
        await fulfillment(of: [copied], timeout: 3)
        XCTAssertEqual(local.string(forType: .string), "copied on remote")
        XCTAssertTrue(try XCTUnwrap(viewer.packet(for: key("v"), revision: 1, pane: "A")).payload.isEmpty)
        XCTAssertFalse(try XCTUnwrap(viewer.packet(for: key("v"), revision: 1, pane: "B")).payload.isEmpty)
    }

    func testLateOrUnrequestedRepliesCannotReplaceANewerCopy() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let viewer = PaneClipboard(board: board)
        let bytes = try XCTUnwrap(DesktopClipboard.read(from: board))
        let first = try copy(viewer, pane: "A"), second = try copy(viewer, pane: "B")
        let initial = board.changeCount
        viewer.received(bytes, request: first, changed: true, pane: "A")
        viewer.received(bytes, request: second, changed: true, pane: "A")
        XCTAssertEqual(board.changeCount, initial)
        board.clearContents()
        board.setString("new local copy", forType: .string)
        viewer.received(bytes, request: second, changed: true, pane: "B")
        XCTAssertEqual(board.string(forType: .string), "new local copy")
        let third = try copy(viewer, pane: "A")
        viewer.forget("A")
        viewer.received(bytes, request: third, changed: true, pane: "A")
        XCTAssertEqual(board.string(forType: .string), "new local copy")
    }

    func testOnlyClipboardShortcutsCanCarryData() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("content", forType: .string)
        let viewer = PaneClipboard(board: board)
        for flags in [8, 9, 11, 72] {
            let paste = try XCTUnwrap(viewer.packet(for: key("v", modifiers: flags), revision: 1, pane: "A"))
            XCTAssertFalse(paste.payload.isEmpty)
        }
        var decoder = PacketDecoder()
        for event in [key("v", event: 3), key("v", modifiers: 4), key("x"), .releaseAll] {
            let invalid = Packet(.input(revision: 1, event: event), payload: Data([1]))
            XCTAssertThrowsError(try decoder.feed(invalid.encoded()))
            decoder = PacketDecoder()
        }
        let cut = try XCTUnwrap(viewer.packet(for: key("x"), revision: 1, pane: "A"))
        guard case .input(_, _, .some) = cut.message else { return XCTFail("Cut must request the remote clipboard") }
        XCTAssertThrowsError(try decoder.feed(Packet(.copied(request: UUID(), changed: false), payload: Data([1])).encoded()))
    }

    func testAnInvalidPastePreservesTheBoardAndDoesNotTypeIntoTheApp() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("keep", forType: .string)
        let host = HostClipboard(board: board)
        let foreign = try PropertyListEncoder().encode([["unrecognized.format": Data([1])]])
        let initial = board.changeCount
        for data in [Data(), Data([1]), foreign] {
            host.paste(data) { XCTFail("Invalid data should not trigger a paste") }
        }
        XCTAssertEqual(board.changeCount, initial)
        XCTAssertEqual(board.string(forType: .string), "keep")
    }
}
