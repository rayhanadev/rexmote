import Foundation
import XCTest

@testable import RexmoteCLI

final class PaneWorkflowTests: XCTestCase {
    @MainActor func testRegistrationNeverCreatesAViewerAndIsScopedToItsSessionAndProcess() throws {
        let service = PaneService()
        let id = "block:" + UUID().uuidString
        let session = "session:" + UUID().uuidString
        let other = "session:" + UUID().uuidString
        let holder = PaneRequest(block: id, session: session, pid: getpid())
        XCTAssertEqual(try service.handle("register", holder).info?.state, "registered")
        XCTAssertEqual(try service.handle("register", holder).info?.holderPID, getpid())
        XCTAssertEqual(try service.handle("list", PaneRequest()).panes?.count, 0)
        XCTAssertEqual(try service.handle("holders", PaneRequest(session: session)).panes?.map(\.id), [id])
        XCTAssertEqual(try service.handle("holders", PaneRequest(session: other)).panes?.count, 0)
        XCTAssertThrowsError(try service.handle("holders", PaneRequest()))
        XCTAssertThrowsError(try service.handle("unregister", PaneRequest(block: id, session: other, pid: getpid())))
        XCTAssertThrowsError(
            try service.handle("unregister", PaneRequest(block: id, session: session, pid: getpid() + 1)))
        _ = try service.handle("unregister", holder)
        XCTAssertEqual(try service.handle("holders", PaneRequest(session: session)).panes?.count, 0)
    }

    func testHolderReportsFileTransfersUsingOneNativeRexActivityRecord() throws {
        for activity in FileTransferActivity.allCases {
            let lines = activity.holderInput.split(whereSeparator: \.isNewline)
            XCTAssertEqual(lines.count, 1)
            XCTAssertEqual(FileTransferActivity(holderLine: String(try XCTUnwrap(lines.first))), activity)
            let report = String(decoding: activity.report, as: UTF8.self)
            XCTAssertTrue(report.hasPrefix("\u{1B}]7501;id=files:state="))
            XCTAssertTrue(report.hasSuffix("\u{1B}\\"))
            let state: String
            switch activity {
            case .sending, .pasting, .receiving: state = "working"
            case .sent, .received: state = "done"
            case .cancelled: state = "idle"
            case .unreadable, .sendFailed, .receiveFailed: state = "error"
            case .clear: state = "clear"
            }
            XCTAssertTrue(report.contains("state=" + state))
            if activity != .clear {
                XCTAssertTrue(report.contains("msg=" + Data(activity.message.utf8).base64EncodedString()))
            }
        }
    }

    func testHolderIgnoresUnrelatedInputAndUnrecognizedActivity() {
        for line in ["", "sent", "rexmote/files made-up", "rexmote/files sent\u{7}"] {
            XCTAssertNil(FileTransferActivity(holderLine: line))
        }
    }

    func testIdentityComesFromTheRemoteMachineAndRejectsUnusableEndpoints() throws {
        let host = SessionHost(account: "demo", hostname: "studio.local", vpnAddress: "100.70.1.2", publicKeys: [])
        XCTAssertEqual(try host.address(localVPN: nil), "studio.local")
        XCTAssertEqual(try host.address(localVPN: "100.70.1.3"), "100.70.1.2")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try host.writeKnownHosts(to: file))
        let malformed = SessionHost(
            account: "demo", hostname: "-wrong", vpnAddress: nil, publicKeys: ["ssh-ed25519 !!!!"])
        XCTAssertThrowsError(try malformed.address(localVPN: nil))
        XCTAssertThrowsError(try malformed.writeKnownHosts(to: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
