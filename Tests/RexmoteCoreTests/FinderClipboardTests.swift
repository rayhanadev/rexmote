import AppKit
import XCTest

@testable import RexmoteCore
@testable import RexmoteHost

@MainActor final class FinderClipboardTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rexmote-file-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        let name = board.name.rawValue
        addTeardownBlock { await MainActor.run { NSPasteboard(name: .init(rawValue: name)).releaseGlobally() } }
        return board
    }

    private func select(_ urls: [URL], on board: NSPasteboard) throws {
        board.clearContents()
        XCTAssertTrue(board.writeObjects(urls.map { $0 as NSURL }))
        XCTAssertEqual(board.pasteboardItems?.count, urls.count)
    }

    private func selectedURLs(on board: NSPasteboard) throws -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return try XCTUnwrap(board.readObjects(forClasses: [NSURL.self], options: options) as? [URL])
    }

    func testFinderReceivesIndependentURLsForTheWholeSelection() throws {
        let source = try temporaryDirectory()
        let chapter = source.appendingPathComponent("Café 🧭", isDirectory: true)
        let nested = chapter.appendingPathComponent("Nested", isDirectory: true)
        let empty = chapter.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let binary = Data([0, 10, 13, 127, 128, 255])
        try binary.write(to: nested.appendingPathComponent(".sample"))
        let note = source.appendingPathComponent("file with spaces.txt")
        try Data("second selected item\n".utf8).write(to: note)
        let resourceFork = Data([15, 7, 8])
        try resourceFork.write(to: note.appendingPathComponent("..namedfork/rsrc"))
        try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: note.path)
        let from = pasteboard(), into = pasteboard()
        try select([note, chapter], on: from)
        let outgoing = try temporaryDirectory(), incoming = try temporaryDirectory()
        let selected = try XCTUnwrap(FinderClipboard.selection(from: from))
        XCTAssertEqual(selected.map(\.lastPathComponent), [note.lastPathComponent, chapter.lastPathComponent])
        let batch = try FinderClipboard.stage(selected, in: outgoing)
        try FileManager.default.copyItem(
            at: outgoing.appendingPathComponent(batch.uuidString), to: incoming.appendingPathComponent(batch.uuidString))
        XCTAssertTrue(FinderClipboard.publish(batch, in: incoming, to: into))
        let incomingRoot = incoming.resolvingSymlinksInPath().path + "/"
        XCTAssertTrue(try FinderClipboard.files(batch, in: incoming).allSatisfy {
            $0.resolvingSymlinksInPath().path.hasPrefix(incomingRoot)
        })
        let received = try selectedURLs(on: into)
        XCTAssertEqual(received.map(\.lastPathComponent), [note.lastPathComponent, chapter.lastPathComponent])
        XCTAssertEqual(received.count, 2)
        guard received.count == 2 else { return }
        XCTAssertNotEqual(received[0].resolvingSymlinksInPath(), note.resolvingSymlinksInPath())
        XCTAssertNotEqual(received[1].resolvingSymlinksInPath(), chapter.resolvingSymlinksInPath())
        try FileManager.default.removeItem(at: chapter)
        try FileManager.default.removeItem(at: note)
        XCTAssertEqual(try Data(contentsOf: received[0]), Data("second selected item\n".utf8))
        XCTAssertEqual(try Data(contentsOf: received[0].appendingPathComponent("..namedfork/rsrc")), resourceFork)
        let attributes = try FileManager.default.attributesOfItem(atPath: received[0].path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o751)
        XCTAssertEqual(try Data(contentsOf: received[1].appendingPathComponent("Nested/.sample")), binary)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: received[1].appendingPathComponent("Empty").path), [])
    }

    func testSameNamedFilesAndFilesAboveTheInlineClipboardLimit() throws {
        let a = try temporaryDirectory().appendingPathComponent("same.bin")
        let b = try temporaryDirectory().appendingPathComponent("same.bin")
        let root = try temporaryDirectory()
        try Data().write(to: a)
        try Data("small".utf8).write(to: b)
        let offset = UInt64(DesktopClipboard.byteLimit) + 8192
        let handle = try FileHandle(forWritingTo: a)
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data([0x7f]))
        try handle.close()

        let id = try FinderClipboard.stage([a, b], in: root)
        let destinations = try FinderClipboard.files(id, in: root)
        XCTAssertEqual(destinations.map(\.lastPathComponent), ["same.bin", "same.bin"])
        guard destinations.count == 2 else { return }
        XCTAssertNotEqual(destinations[0], destinations[1])
        let staged = try FileHandle(forReadingFrom: destinations[0])
        defer { try? staged.close() }
        XCTAssertEqual(try staged.seekToEnd(), offset + 1)
        try staged.seek(toOffset: offset)
        XCTAssertEqual(try staged.read(upToCount: 1), Data([0x7f]))
        XCTAssertEqual(try Data(contentsOf: destinations[1]), Data("small".utf8))
    }

    func testLinksInsideFoldersStayLinksAndRootLinksAreRejected() throws {
        let source = try temporaryDirectory()
        let item = source.appendingPathComponent("asset")
        let link = source.appendingPathComponent("alias")
        try Data([42]).write(to: item)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "asset")
        let root = try temporaryDirectory()
        let id = try FinderClipboard.stage([source], in: root)
        let stagedFolder = try XCTUnwrap(FinderClipboard.files(id, in: root).first)
        let alias = stagedFolder.appendingPathComponent("alias")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), "asset")
        XCTAssertEqual(try Data(contentsOf: alias), Data([42]))
        XCTAssertThrowsError(try FinderClipboard.stage([link], in: root))

        let external = try temporaryDirectory().appendingPathComponent("separate.txt")
        try Data([1]).write(to: external)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("outside"), withDestinationURL: external)
        XCTAssertThrowsError(try FinderClipboard.stage([source], in: root))
    }

    func testPublishingAnIncompleteSelectionOrAnIndirectStagingDirectoryPreservesTheClipboard() throws {
        let root = try temporaryDirectory()
        let incoming = try temporaryDirectory()
        let file = try temporaryDirectory().appendingPathComponent("document")
        try Data([7]).write(to: file)
        let id = try FinderClipboard.stage([file], in: root)
        let realBatch = root.appendingPathComponent(id.uuidString)
        let indirectBatch = incoming.appendingPathComponent(id.uuidString)
        try FileManager.default.createSymbolicLink(at: indirectBatch, withDestinationURL: realBatch)
        let board = pasteboard()
        board.setString("keep this copy", forType: .string)
        let generation = board.changeCount
        XCTAssertFalse(FinderClipboard.publish(id, in: incoming, to: board))
        try FileManager.default.removeItem(at: indirectBatch)
        try FileManager.default.createDirectory(at: indirectBatch, withIntermediateDirectories: false)
        XCTAssertFalse(FinderClipboard.publish(id, in: incoming, to: board))
        let slot = indirectBatch.appendingPathComponent("0")
        try FileManager.default.createSymbolicLink(at: slot, withDestinationURL: realBatch.appendingPathComponent("0"))
        XCTAssertFalse(FinderClipboard.publish(id, in: incoming, to: board))
        XCTAssertEqual(board.changeCount, generation)
        XCTAssertEqual(board.string(forType: .string), "keep this copy")
    }

    func testAnInlineSourceURLCannotPublishAFileOnTheReceivingMac() throws {
        let board = pasteboard()
        board.setString("existing copy", forType: .string)
        let generation = board.changeCount
        let source = try temporaryDirectory().appendingPathComponent("source.txt")
        let inlineURL = [[NSPasteboard.PasteboardType.fileURL.rawValue: Data(source.absoluteString.utf8)]]
        XCTAssertFalse(DesktopClipboard.write(try PropertyListEncoder().encode(inlineURL), to: board))
        XCTAssertEqual(board.changeCount, generation)
        XCTAssertEqual(board.string(forType: .string), "existing copy")
    }

    func testFailedRestagingRemovesOnlyTheUnfinishedBatch() throws {
        let root = try temporaryDirectory()
        let source = try temporaryDirectory()
        let one = source.appendingPathComponent("available")
        try Data([0, 1]).write(to: one)
        let original = try FinderClipboard.stage([one], in: root)
        XCTAssertThrowsError(try FinderClipboard.stage([one, source.appendingPathComponent("missing")], in: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [original.uuidString])
        let copy = try XCTUnwrap(FinderClipboard.files(original, in: root).first)
        XCTAssertEqual(try Data(contentsOf: copy), Data([0, 1]))
    }

    func testHostCopiesFinderSelectionAndHonorsOnlyCurrentPasteReservations() async throws {
        try XCTSkipIf(NSWorkspace.shared.frontmostApplication == nil, "A GUI session is required for a paste reservation")
        let root = try temporaryDirectory(), board = pasteboard()
        let clipboard = HostClipboard(board: board, root: root)
        defer { clipboard.cancel() }
        let source = try temporaryDirectory().appendingPathComponent("report")
        try Data("contents".utf8).write(to: source)
        let copied = expectation(description: "Host returns a Finder transfer reference")
        var reference: UUID?
        try clipboard.copy {
            try select([source], on: board)
        } canRead: { true } reply: { changed, data in
            XCTAssertTrue(changed)
            reference = FinderClipboard.id(in: data)
            copied.fulfill()
        }
        await fulfillment(of: [copied], timeout: 3)
        let batch = try XCTUnwrap(reference)
        try FileManager.default.removeItem(at: source)
        let pasted = expectation(description: "The reserved destination receives a native file URL before Paste")
        clipboard.reserve(batch)
        clipboard.pasteFiles(batch, canPaste: { true }) {
            do {
                let url = try XCTUnwrap(self.selectedURLs(on: board).first)
                XCTAssertEqual(try Data(contentsOf: url), Data("contents".utf8))
            } catch { XCTFail(String(describing: error)) }
            pasted.fulfill()
        }
        await fulfillment(of: [pasted], timeout: 3)

        clipboard.reserve(batch)
        board.clearContents()
        board.setString("newer local activity", forType: .string)
        let unchanged = board.changeCount
        let stale = expectation(description: "A newer clipboard supersedes the transfer")
        stale.isInverted = true
        clipboard.pasteFiles(batch, canPaste: { true }) { stale.fulfill() }
        await fulfillment(of: [stale], timeout: 0.2)
        XCTAssertEqual(board.changeCount, unchanged)
        XCTAssertEqual(board.string(forType: .string), "newer local activity")
    }
}
