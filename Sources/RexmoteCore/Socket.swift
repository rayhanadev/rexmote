import Darwin
import Foundation

private func systemError(_ operation: String) -> RexmoteError {
    .system("\(operation): \(String(cString: strerror(errno)))")
}
private func address(_ path: String) throws -> sockaddr_un {
    var value = sockaddr_un()
    value.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else {
        throw RexmoteError.invalid("Helper socket path is too long.")
    }
    value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &value.sun_path) { raw in
        for (i, byte) in bytes.enumerated() { raw[i] = UInt8(bitPattern: byte) }
    }
    return value
}
public func peerIsCurrentUser(_ fd: Int32) -> Bool {
    var uid = uid_t()
    var gid = gid_t()
    return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
}
public final class LocalListener {
    public let fd: Int32, directory: String, path: String
    public init() throws {
        var pattern = Array("/tmp/rexmote.XXXXXX".utf8CString)
        guard let created = mkdtemp(&pattern) else { throw systemError("Create private helper directory") }
        directory = String(cString: created)
        path = directory + "/session.sock"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            rmdir(directory)
            throw systemError("Create helper socket")
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var addr = try address(path)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 && chmod(path, 0o600) == 0 && listen(fd, 16) == 0 else {
            Darwin.close(fd)
            try? FileManager.default.removeItem(atPath: directory)
            throw systemError("Listen for desktop helper")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    }
    public func acceptConnection() throws -> WireSocket? {
        let connection = Darwin.accept(fd, nil, nil)
        if connection < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return nil }
        guard connection >= 0 else { throw systemError("Accept desktop helper") }
        guard peerIsCurrentUser(connection) else {
            Darwin.close(connection)
            throw RexmoteError.invalid("Unexpected helper user.")
        }
        return WireSocket(fd: connection)
    }
    deinit {
        Darwin.close(fd)
        try? FileManager.default.removeItem(atPath: directory)
    }
}
// Writes and closure are synchronized. receive() has exactly one owner.
public final class WireSocket: @unchecked Sendable {
    public let fd: Int32
    private var decoder = PacketDecoder(), closed = false
    private let writeLock = NSLock(), stateLock = NSLock()
    public init(fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }
    public static func connect(path: String) throws -> WireSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemError("Create desktop connection") }
        var addr = try address(path)
        let result = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 && peerIsCurrentUser(fd) else {
            Darwin.close(fd)
            throw systemError("Connect to desktop command")
        }
        return WireSocket(fd: fd)
    }
    public func send(_ packet: Packet, when shouldSend: () -> Bool = { true }) throws {
        let data = try packet.encoded()
        writeLock.lock()
        defer { writeLock.unlock() }
        stateLock.lock()
        let isClosed = closed
        stateLock.unlock()
        guard !isClosed else { throw RexmoteError.disconnected }
        guard shouldSend() else { return }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, bytes.baseAddress! + offset, data.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw systemError("Write desktop packet") }
                offset += written
            }
        }
    }
    /// Call from one reader only. poll() first when running on an event loop.
    public func receive() throws -> [Packet] {
        stateLock.lock()
        let isClosed = closed
        stateLock.unlock()
        guard !isClosed else { throw RexmoteError.disconnected }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        var count: Int
        repeat {
            count = Darwin.read(fd, &bytes, bytes.count)
        } while count < 0 && errno == EINTR
        if count == 0 {
            try decoder.finish()
            throw RexmoteError.disconnected
        }
        guard count > 0 else { throw systemError("Read desktop packet") }
        return try decoder.feed(Data(bytes.prefix(count)))
    }
    public func close() {
        // shutdown interrupts readers/writers before taking the write lock.
        stateLock.lock()
        if closed {
            stateLock.unlock()
            return
        }
        closed = true
        stateLock.unlock()
        Darwin.shutdown(fd, SHUT_RDWR)
        // Keep the descriptor reserved until the last reader releases this object.
        // Closing it here could let another open() reuse it during a blocked read.
    }
    deinit {
        close()
        Darwin.close(fd)
    }
}
