import CryptoKit
import Darwin
import Foundation
import IOKit
import RexmoteCore

/// The session's authenticated Rex action supplies the address and OpenSSH public keys together.
struct SessionHost: Codable, Equatable {
    let account: String
    let hostname: String
    let vpnAddress: String?
    let publicKeys: [String]
    var machineID: String? = nil

    private static let localID: String? = {
        let platform = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard platform != 0 else { return nil }
        defer { IOObjectRelease(platform) }
        guard
            let uuid = IORegistryEntryCreateCFProperty(platform, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
        else { return nil }
        return SHA256.hash(data: Data(("rexmote:" + uuid.lowercased()).utf8)).map { String(format: "%02x", $0) }
            .joined()
    }()

    var isThisMac: Bool {
        if let machineID, machineID == Self.localID { return true }
        return !Set(publicKeys).isDisjoint(with: Self.current.publicKeys)
    }

    static var current: Self {
        let keys = ["ed25519", "ecdsa", "rsa"].compactMap { algorithm -> String? in
            guard let text = try? String(contentsOfFile: "/etc/ssh/ssh_host_\(algorithm)_key.pub", encoding: .utf8)
            else { return nil }
            let fields = text.split(whereSeparator: \.isWhitespace)
            return fields.count >= 2 ? fields.prefix(2).joined(separator: " ") : nil
        }
        return Self(
            account: NSUserName(), hostname: LocalComputer.hostname, vpnAddress: localVPNAddress,
            publicKeys: keys, machineID: localID)
    }

    static var localVPNAddress: String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(first) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = item.pointee.ifa_addr, addr.pointee.sa_family == AF_INET else { continue }
            var ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard UInt32(bigEndian: ip.s_addr) >> 22 == 0x191 else { continue }  // 100.64.0.0/10
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &ip, &text, socklen_t(text.count)) != nil { return String(cString: text) }
        }
        return nil
    }

    func address(localVPN: String?) throws -> String {
        let address = localVPN == nil ? hostname : (vpnAddress ?? hostname)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        func valid(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 253 && value.first != "-"
                && value.unicodeScalars.allSatisfy(allowed.contains)
        }
        guard valid(account), valid(address) else {
            throw RexmoteError.invalid("The Rex session host did not provide a usable SSH address.")
        }
        return address
    }

    // Multiplex only connections established for the same Rex-authenticated SSH keys and account.
    func controlSocket(for address: String, in directory: URL) -> String? {
        let identity = ([account, address] + Array(Set(publicKeys)).sorted()).joined(separator: "\n")
        let hash = SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let path = directory.appendingPathComponent("ssh-" + hash).path
        // OpenSSH appends a temporary suffix when publishing a new master socket.
        return path.utf8.count < 88 ? path : nil
    }

    /// The SSH client must authenticate this machine before requesting a password or opening a desktop.
    func writeKnownHosts(to file: URL) throws {
        let algorithms = [
            "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa",
        ]
        let records = publicKeys.compactMap { key -> String? in
            let parts = key.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 2, algorithms.contains(String(parts[0])), parts[1].count <= 8192,
                let bytes = Data(base64Encoded: String(parts[1])), !bytes.isEmpty
            else { return nil }
            return "rexmote-session " + key
        }
        guard !records.isEmpty else {
            throw RexmoteError.invalid("Enable Remote Login on the Mac hosting this Rex session.")
        }
        try Data((records.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
    }
}
