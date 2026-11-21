import AppKit
import Network
import RexmoteCore

/// The holder and CLI use the same authenticated loopback POST routes as rexweb.
@MainActor final class PaneService {
    private var panes: [String: NativePane] = [:]
    private var registrations: [String: PaneInfo] = [:]
    private var port: UInt16?
    private var emptySince = Date()

    func run(port: UInt16, followRex: Bool) throws {
        let token = try ViewerEndpoint.token(create: true)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.port = port
        let queue = DispatchQueue(label: "rexmote.pane-api")
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: queue)
            let timeout = DispatchWorkItem { connection.cancel() }
            queue.asyncAfter(deadline: .now() + 8, execute: timeout)
            Self.read(connection, token: token) { route, request in
                timeout.cancel()
                DispatchQueue.main.async {
                    let reply: PaneReply
                    do {
                        guard let self else { throw RexmoteError.disconnected }
                        if route == "askpass" {
                            guard let id = request.block, let pane = self.panes[id] else {
                                throw RexmoteError.disconnected
                            }
                            pane.requestCredential(ticket: request.ticket, prompt: request.prompt) { answer in
                                Self.respond(connection, reply: PaneReply(answer: answer), code: 200)
                            }
                            return
                        }
                        reply = try self.handle(route, request)
                    } catch { reply = PaneReply(error: String(describing: error)) }
                    Self.respond(connection, reply: reply, code: reply.error == nil ? 200 : 400)
                }
            }
        }
        listener.stateUpdateHandler = {
            if case .failed(let error) = $0 {
                fputs("rexmote: \(error)\n", stderr)
                exit(1)
            }
        }
        listener.start(queue: queue)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let edit = NSMenu(title: "Edit")
        for (name, action, key) in [
            ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
        ] {
            edit.addItem(withTitle: name, action: Selector(action), keyEquivalent: key)
        }
        let menu = NSMenu()
        let applicationMenu = NSMenuItem()
        let editMenu = NSMenuItem()
        applicationMenu.submenu = NSMenu(title: "Rexmote")
        editMenu.submenu = edit
        menu.addItem(applicationMenu)
        menu.addItem(editMenu)
        app.mainMenu = menu
        let inputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .magnify, .rotate, .swipe, .smartMagnify]
        ) { event in
            let window = event.window?.isKeyWindow == true ? event.window : NSApp.keyWindow
            let handled = PaneWindow.routeKeyEvent(event, in: window) || PaneWindow.routeGesture(event, in: window)
            return handled ? nil : event
        }
        let discovery = followRex ? RemotePaneDiscovery() : nil
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.registrations = self.registrations.filter { _, holder in
                    guard let pid = holder.holderPID else { return false }
                    return kill(pid, 0) == 0 || errno != ESRCH
                }
                if !self.registrations.isEmpty { self.emptySince = Date() }
                if let discovery {
                    discovery.refresh(tracked: Set(self.panes.values.map(\.scope))) { [weak self] in
                        self?.syncRemote($0, holders: $1)
                    }
                } else if self.registrations.isEmpty && self.panes.isEmpty
                    && Date().timeIntervalSince(self.emptySince) > 45
                {
                    NSApp.terminate(nil)
                }
            }
        }
        defer {
            timer.invalidate()
            listener.cancel()
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        }
        app.run()
    }

    nonisolated private static func read(
        _ connection: NWConnection, token: String, bytes: Data = Data(),
        deliver: @escaping (String, PaneRequest) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            guard error == nil, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            var buffer = bytes
            buffer.append(data)
            guard buffer.count <= 131072 else {
                connection.cancel()
                return
            }
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if !done && buffer.count < 8192 {
                    read(connection, token: token, bytes: buffer, deliver: deliver)
                } else {
                    connection.cancel()
                }
                return
            }
            let lines = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let start = (lines.first ?? "").split(separator: " ")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let i = line.firstIndex(of: ":") else {
                    connection.cancel()
                    return
                }
                headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
            guard start.count == 3, start[0] == "POST", start[1].first == "/",
                headers["x-rexmote-token"] == token, headers["origin"] == nil,
                headers["transfer-encoding"] == nil, headers["content-type"]?.hasPrefix("application/json") == true,
                let length = Int(headers["content-length"] ?? ""), (0...65536).contains(length)
            else {
                respond(connection, reply: PaneReply(error: "Unauthorized or malformed pane request."), code: 403)
                return
            }
            let body = buffer[separator.upperBound...]
            if body.count < length && !done {
                read(connection, token: token, bytes: buffer, deliver: deliver)
                return
            }
            guard body.count == length, let request = try? JSONDecoder().decode(PaneRequest.self, from: body) else {
                respond(connection, reply: PaneReply(error: "Invalid pane request."), code: 400)
                return
            }
            deliver(String(start[1].dropFirst()), request)
        }
    }

    nonisolated private static func respond(_ connection: NWConnection, reply: PaneReply, code: Int) {
        guard let data = try? JSONEncoder().encode(reply) else {
            connection.cancel()
            return
        }
        var response = Data(
            "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                .utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func remove(_ id: String) {
        panes.removeValue(forKey: id)?.stop()
        if panes.isEmpty { emptySince = Date() }
    }

    private func syncRemote(_ scope: RemoteSession, holders: [HostedPane]) {
        let current = Set(holders.map(\.id))
        for (id, pane) in panes
        where pane.scope == scope && !current.contains(id) {
            remove(id)
        }
        for holder in holders where RemoteSession.validID(holder.id, prefix: "block:") && holder.pid > 1 {
            if let existing = panes[holder.id] {
                guard existing.scope == scope,
                    existing.holderPID != holder.pid || existing.origin != holder.origin
                else { continue }
                remove(holder.id)
            }
            guard
                let pane = try? NativePane(
                    id: holder.id, scope: scope, pid: holder.pid, origin: holder.origin, port: port)
            else { continue }
            panes[holder.id] = pane
            pane.start()
        }
    }

    func handle(_ route: String, _ req: PaneRequest) throws -> PaneReply {
        if route == "health" { return PaneReply() }
        if route == "holders" {
            guard let session = req.session, RemoteSession.validID(session, prefix: "session:") else {
                throw RexmoteError.invalid("A Rex session ID is required.")
            }
            return PaneReply(panes: registrations.values.filter { $0.session == session })
        }
        if route == "register" || route == "unregister" || (route == "info" && req.pid != nil) {
            guard let id = req.block, let pid = req.pid, pid > 1, RemoteSession.validID(id, prefix: "block:") else {
                throw RexmoteError.invalid("Invalid Rex pane.")
            }
            if let existing = registrations[id], existing.holderPID == pid,
                req.session == nil || existing.session == req.session
            {
                if route == "unregister" { registrations.removeValue(forKey: id) }
                return PaneReply(info: existing)
            }
            guard route == "register", let session = req.session, RemoteSession.validID(session, prefix: "session:"),
                kill(pid, 0) == 0, registrations[id]?.holderPID.map({ kill($0, 0) < 0 && errno == ESRCH }) ?? true
            else { throw RexmoteError.invalid("Unknown desktop holder.") }
            let holder = PaneInfo(id: id, session: session, holderPID: pid, state: "registered")
            registrations[id] = holder
            return PaneReply(info: holder)
        }
        let list = panes.values.filter { req.session == nil || $0.info.session == req.session }.sorted {
            $0.info.lastUsed > $1.info.lastUsed
        }
        if route == "list" { return PaneReply(panes: list.map(\.info)) }
        let pane: NativePane
        if let query = req.block, !query.isEmpty {
            if let exact = list.first(where: { $0.info.id == query }) {
                pane = exact
            } else {
                let matches = list.filter {
                    $0.info.id.hasSuffix(query) || $0.info.title.localizedCaseInsensitiveContains(query)
                }
                guard matches.count == 1 else { throw RexmoteError.invalid("Use a unique desktop name or block ID.") }
                pane = matches[0]
            }
        } else {
            guard let first = list.first else { throw RexmoteError.invalid("No remote desktop panes are open.") }
            pane = first
        }
        switch route {
        case "info": break
        case "focus": pane.requestFocus()
        case "reload": pane.connect()
        case "screenshot": return PaneReply(info: pane.info, png: try pane.screenshot())
        default: throw RexmoteError.invalid("Unknown pane operation.")
        }
        return PaneReply(info: pane.info)
    }
}
