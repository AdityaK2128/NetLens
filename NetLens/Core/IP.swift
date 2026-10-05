import Foundation
import Darwin

/// Address classification per IANA special-purpose registries (RFC 6890 et al).
enum IPScope: String {
    case loopback = "Loopback"
    case linkLocal = "Link-local"
    case privateNet = "Private (RFC 1918)"
    case cgnat = "Shared / CGNAT (RFC 6598)"
    case uniqueLocal = "Unique local (ULA)"
    case multicast = "Multicast"
    case broadcast = "Broadcast"
    case unspecified = "Unspecified"
    case documentation = "Documentation"
    case benchmarking = "Benchmarking (RFC 2544)"
    case reserved = "Reserved"
    case global = "Public"

    var isRoutable: Bool { self == .global }
}

enum IP {
    static func isV4(_ s: String) -> Bool {
        var a = in_addr()
        return inet_pton(AF_INET, s, &a) == 1
    }

    static func isV6(_ s: String) -> Bool {
        var a = in6_addr()
        return inet_pton(AF_INET6, stripScope(s), &a) == 1
    }

    static func isIP(_ s: String) -> Bool { isV4(s) || isV6(s) }

    static func stripScope(_ s: String) -> String {
        if let i = s.firstIndex(of: "%") { return String(s[..<i]) }
        return s
    }

    static func v4Bytes(_ s: String) -> [UInt8]? {
        var a = in_addr()
        guard inet_pton(AF_INET, s, &a) == 1 else { return nil }
        return withUnsafeBytes(of: a.s_addr) { Array($0) }
    }

    static func v6Bytes(_ s: String) -> [UInt8]? {
        var a = in6_addr()
        guard inet_pton(AF_INET6, stripScope(s), &a) == 1 else { return nil }
        return withUnsafeBytes(of: a) { Array($0) }
    }

    static func v4Value(_ s: String) -> UInt32? {
        guard let b = v4Bytes(s) else { return nil }
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    static func v4String(_ v: UInt32) -> String {
        "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
    }

    static func scope(_ raw: String) -> IPScope {
        let s = stripScope(raw)
        if let b = v4Bytes(s) {
            let v = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
            func inNet(_ net: UInt32, _ bits: Int) -> Bool {
                let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
                return v & mask == net & mask
            }
            if v == 0 { return .unspecified }
            if v == 0xFFFFFFFF { return .broadcast }
            if inNet(0x7F000000, 8) { return .loopback }
            if inNet(0xA9FE0000, 16) { return .linkLocal }
            if inNet(0x0A000000, 8) || inNet(0xAC100000, 12) || inNet(0xC0A80000, 16) { return .privateNet }
            if inNet(0x64400000, 10) { return .cgnat }
            if inNet(0xE0000000, 4) { return .multicast }
            if inNet(0xC0000200, 24) || inNet(0xC6336400, 24) || inNet(0xCB007100, 24) { return .documentation }
            if inNet(0xC6120000, 15) { return .benchmarking }
            if inNet(0x00000000, 8) || inNet(0xF0000000, 4) || inNet(0xC0000000, 24) { return .reserved }
            return .global
        }
        if let b = v6Bytes(s) {
            if b.allSatisfy({ $0 == 0 }) { return .unspecified }
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return .loopback }
            // IPv4-mapped ::ffff:a.b.c.d
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
                return scope("\(b[12]).\(b[13]).\(b[14]).\(b[15])")
            }
            if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return .linkLocal }
            if (b[0] & 0xFE) == 0xFC { return .uniqueLocal }
            if b[0] == 0xFF { return .multicast }
            if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8 { return .documentation }
            if (b[0] & 0xE0) == 0x20 { return .global }   // 2000::/3
            return .reserved
        }
        return .reserved
    }

    static func isGlobal(_ s: String) -> Bool { scope(s) == .global }

    /// Reverse-DNS name: 1.2.3.4 → 4.3.2.1.in-addr.arpa
    static func reverseName(_ s: String) -> String? {
        if let b = v4Bytes(s) {
            return "\(b[3]).\(b[2]).\(b[1]).\(b[0]).in-addr.arpa"
        }
        if let b = v6Bytes(s) {
            var nibbles: [String] = []
            for byte in b.reversed() {
                nibbles.append(String(byte & 0x0F, radix: 16))
                nibbles.append(String(byte >> 4, radix: 16))
            }
            return nibbles.joined(separator: ".") + ".ip6.arpa"
        }
        return nil
    }

    /// Prefix length from a dotted netmask (255.255.255.0 → 24).
    static func prefixLength(netmask: String) -> Int? {
        if let v = v4Value(netmask) { return v.nonzeroBitCount }
        if let b = v6Bytes(netmask) { return b.reduce(0) { $0 + $1.nonzeroBitCount } }
        return nil
    }

    /// Network address + host range for an IPv4 interface.
    static func v4Network(address: String, netmask: String) -> (network: String, broadcast: String, first: String, last: String, hosts: UInt32)? {
        guard let a = v4Value(address), let m = v4Value(netmask) else { return nil }
        let net = a & m
        let bcast = net | ~m
        let hosts = m == 0xFFFFFFFF ? 1 : (m == 0xFFFFFFFE ? 2 : (~m) - 1)
        let first = m >= 0xFFFFFFFE ? net : net + 1
        let last = m >= 0xFFFFFFFE ? bcast : bcast - 1
        return (v4String(net), v4String(bcast), v4String(first), v4String(last), hosts)
    }

    /// Compact canonical v6 string (normalises user input / tool output).
    static func canonical(_ s: String) -> String {
        if let b = v6Bytes(s) {
            var a = in6_addr()
            withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: b) }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
            return String(cString: buf)
        }
        return s
    }
}

// MARK: - sockaddr helpers

enum SockAddr {
    static func string(_ sa: UnsafePointer<sockaddr>) -> String? {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                var addr = p.pointee.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
                return String(cString: buf)
            }
        case AF_INET6:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                var addr = p.pointee.sin6_addr
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count))
                var s = String(cString: buf)
                if p.pointee.sin6_scope_id != 0 {
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(p.pointee.sin6_scope_id, &name) != nil {
                        s += "%" + String(cString: name)
                    }
                }
                return s
            }
        default:
            return nil
        }
    }

    /// Builds a sockaddr_storage for a literal IP (with optional port).
    static func make(_ ip: String, port: UInt16 = 0) -> (storage: sockaddr_storage, length: socklen_t)? {
        var storage = sockaddr_storage()
        if IP.isV4(ip) {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = port.bigEndian
            inet_pton(AF_INET, ip, &sin.sin_addr)
            withUnsafeMutableBytes(of: &storage) { dst in
                withUnsafeBytes(of: sin) { dst.copyMemory(from: $0) }
            }
            return (storage, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        if IP.isV6(ip) {
            var sin6 = sockaddr_in6()
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sin6.sin6_family = sa_family_t(AF_INET6)
            sin6.sin6_port = port.bigEndian
            inet_pton(AF_INET6, IP.stripScope(ip), &sin6.sin6_addr)
            if let pct = ip.firstIndex(of: "%") {
                let ifname = String(ip[ip.index(after: pct)...])
                sin6.sin6_scope_id = if_nametoindex(ifname)
            }
            withUnsafeMutableBytes(of: &storage) { dst in
                withUnsafeBytes(of: sin6) { dst.copyMemory(from: $0) }
            }
            return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
        return nil
    }
}

// MARK: - Resolution

enum Resolver {
    /// System resolution via getaddrinfo (honours /etc/hosts, scoped resolvers, VPN DNS).
    static func resolve(_ host: String, family: Int32 = AF_UNSPEC) async -> [String] {
        let h = host.trimmed
        if IP.isIP(h) { return [h] }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = family
                hints.ai_socktype = SOCK_STREAM
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(h, nil, &hints, &res) == 0, let first = res else {
                    cont.resume(returning: []); return
                }
                var out: [String] = []
                var p: UnsafeMutablePointer<addrinfo>? = first
                while let cur = p {
                    if let sa = cur.pointee.ai_addr, let s = SockAddr.string(sa), !out.contains(s) { out.append(s) }
                    p = cur.pointee.ai_next
                }
                freeaddrinfo(first)
                cont.resume(returning: out)
            }
        }
    }
}
