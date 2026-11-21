import AppKit
import RexmoteCore

struct HostedPane: Codable {
    let id: String
    let pid: Int32
    let origin: SessionHost?

    static func list(session: String) throws -> [HostedPane] {
        guard RemoteSession.validID(session, prefix: "session:") else {
            throw RexmoteError.invalid("A Rex session ID is required.")
        }
        let reply = try ViewerEndpoint.request(PaneRequest(action: "holders", session: session))
        guard let rows = reply.panes, !rows.isEmpty else { return [] }
        let origin = SessionHost.current
        return rows.compactMap {
            guard $0.rexHost == nil, $0.session == session, let pid = $0.holderPID else { return nil }
            return HostedPane(id: $0.id, pid: pid, origin: origin)
        }
    }
}

struct RemoteSession: Hashable {
    let serverID: UUID
    let host: String
    let session: String

    func matches(_ selection: (UUID, String)?) -> Bool {
        selection?.0 == serverID && selection?.1 == session
    }

    static func validID(_ value: String, prefix: String) -> Bool {
        value.hasPrefix(prefix) && UUID(uuidString: String(value.dropFirst(prefix.count))) != nil
    }

    static func selection(_ data: Data?) -> (UUID, String)? {
        guard let data, let saved = try? JSONSerialization.jsonObject(with: data) as? [String: String],
            let external = saved["externalServerID"], let host = UUID(uuidString: external),
            let session = saved["sessionID"], validID(session, prefix: "session:")
        else { return nil }
        return (host, session)
    }

    static func label(for id: UUID, in inventory: [String: Any]) -> String? {
        for row in inventory["hosts"] as? [[String: Any]] ?? [] {
            guard let host = row["host"] as? [String: Any], let key = host["id"] as? String,
                validID(key, prefix: "host:"), UUID(uuidString: String(key.dropFirst(5))) == id
            else { continue }
            return host["label"] as? String
        }
        return nil
    }

    func holders(alreadyTracking: Bool) throws -> [HostedPane] {
        let rex = try RexCommand(host: host)
        do {
            let data = try rex.run(["do", "-s", session, "rexmote_panes", "--json"], quiet: true)
            let listing = try JSONDecoder().decode(String.self, from: data)
            return try JSONDecoder().decode([HostedPane].self, from: Data(listing.utf8))
        } catch {
            if alreadyTracking,
                let sessions = try? rex.object(["ls", "--json"], quiet: true)["sessions"] as? [[String: Any]],
                !sessions.contains(where: { $0["session_id"] as? String == session })
            {
                return []
            }
            throw error
        }
    }
}

/// The viewing Mac discovers holders through the same authenticated Rex host as its frontmost session.
@MainActor final class RemotePaneDiscovery {
    private var busy = false, hostLabels: [UUID: String] = [:]
    private var lastBackgroundScan = Date.distantPast, retryAfter: [RemoteSession: Date] = [:]

    func refresh(tracked: Set<RemoteSession>, apply: @escaping @MainActor (RemoteSession, [HostedPane]) -> Void) {
        guard !busy else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let active = front == RexCommand.bundleID || front == "dev.rexmote.viewer"
        let background = Date().timeIntervalSince(lastBackgroundScan) >= 5
        guard active || background else { return }
        let selection =
            RexCommand.localApp == nil
            ? nil : RemoteSession.selection(PaneTracker.preference("lastFocusedSession") as? Data)
        guard selection != nil || (background && !tracked.isEmpty) else { return }
        if background { lastBackgroundScan = Date() }
        let labels = hostLabels
        let retries = retryAfter
        busy = true
        Task {
            let (resolved, results) = await Task.detached(priority: .utility) {
                var scopes = background ? tracked : []
                var resolved = labels
                if let (id, session) = selection {
                    if resolved[id] == nil, let hosts = try? RexCommand().object(["hosts", "--json"], quiet: true) {
                        resolved[id] = RemoteSession.label(for: id, in: hosts)
                    }
                    if let host = resolved[id] {
                        scopes.insert(RemoteSession(serverID: id, host: host, session: session))
                    }
                }
                var results: [RemoteSession: Result<[HostedPane], Error>] = [:]
                for scope in scopes where (retries[scope] ?? .distantPast) <= Date() {
                    results[scope] = Result { try scope.holders(alreadyTracking: tracked.contains(scope)) }
                }
                return (resolved, results)
            }.value
            hostLabels = resolved
            for (scope, result) in results {
                switch result {
                case .success(let records):
                    retryAfter.removeValue(forKey: scope)
                    apply(scope, records)
                case .failure:
                    retryAfter[scope] = Date().addingTimeInterval(5)
                    hostLabels = hostLabels.filter { $0.value != scope.host }
                }
            }
            busy = false
        }
    }
}
