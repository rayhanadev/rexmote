import Foundation

/// The holder reports one activity record to the Rex block that owns its terminal.
enum FileTransferActivity: String, CaseIterable {
    case sending, pasting, receiving, sent, received, cancelled, unreadable, sendFailed, receiveFailed, clear

    var message: String {
        switch self {
        case .sending: return "Sending files…"
        case .pasting: return "Pasting files…"
        case .receiving: return "Receiving files…"
        case .sent: return "Files sent to the remote app."
        case .received: return "Files are ready to paste on this Mac."
        case .cancelled: return "File paste cancelled."
        case .unreadable: return "Couldn’t read the selected files."
        case .sendFailed: return "Couldn’t send the files."
        case .receiveFailed: return "Couldn’t receive the files."
        case .clear: return ""
        }
    }

    var isFinished: Bool {
        switch self {
        case .sending, .pasting, .receiving, .clear: return false
        default: return true
        }
    }

    private var state: String {
        switch self {
        case .sending, .pasting, .receiving: return "working"
        case .sent, .received: return "done"
        case .cancelled: return "idle"
        case .unreadable, .sendFailed, .receiveFailed: return "error"
        case .clear: return "clear"
        }
    }

    static let prefix = "rexmote/files "
    var holderInput: String { "\n" + Self.prefix + rawValue + "\n" }

    init?(holderLine: String) {
        guard holderLine.hasPrefix(Self.prefix) else { return nil }
        self.init(rawValue: String(holderLine.dropFirst(Self.prefix.count)))
    }

    var report: Data {
        var fields = ["id=files", "state=" + state]
        if self != .clear {
            fields += ["app=rexmote", "title=" + Data("File transfer".utf8).base64EncodedString(),
                "msg=" + Data(message.utf8).base64EncodedString()]
        }
        return Data(("\u{1B}]7501;" + fields.joined(separator: ":") + "\u{1B}\\").utf8)
    }
}
