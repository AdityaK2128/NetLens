import Foundation

struct Neighbor: Identifiable, Hashable {
    var id: String { ip + "|" + interface }
    let ip: String
    var mac: String?
    let interface: String
    var isV6: Bool
    var permanent: Bool
    var expires: String?
    var isRouter: Bool
    var state: String?
    var hostname: String?
    var services: [String] = []

    var vendor: String? { mac.flatMap(Neighbors.vendor) }
    var isRandomizedMAC: Bool { mac.map(Neighbors.isLocallyAdministered) ?? false }
    /// Broadcast and multicast entries aren't devices (e.g. the subnet broadcast → ff:ff:ff:ff:ff:ff).
    var isMulticast: Bool { IP.scope(ip) == .multicast || ip.hasSuffix(".255") || (mac.map(Neighbors.isGroupMAC) ?? false) }
}

enum Neighbors {
    /// IPv4 neighbours from the ARP cache.
    ///
    /// Read in-process from the routing table (the same sysctl `arp -a` uses). Recent
    /// macOS versions return nothing here to apps, even with Local Network access, so
    /// callers fall back to `arpViaHelper()` and to probing hosts directly.
    static func arp() async -> [Neighbor] {
        await Task.detached(priority: .utility) { linkLayerTable(family: AF_INET) }.value
    }

    /// The ARP cache as read by NetLens's root helper (launchd daemons aren't subject to
    /// the redaction apps get). Nil when the helper isn't installed or is too old.
    static func arpViaHelper() async -> [Neighbor]? {
        guard let r = await BandwidthShaper.send(["cmd": "neighbors"]), r["ok"] as? Bool == true,
              let text = r["arp"] as? String else { return nil }
        return parseARP(text)
    }

    /// `arp -an`: "? (192.168.1.1) at 0:11:22:aa:bb:c on en0 ifscope [ethernet]"
    static func parseARP(_ text: String) -> [Neighbor] {
        text.split(separator: "\n").compactMap { line in
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close else { return nil }
            let ip = String(line[line.index(after: open)..<close])
            let rest = line[close...].split(separator: " ")
            guard let at = rest.firstIndex(of: "at"), at + 1 < rest.count else { return nil }
            let rawMAC = String(rest[at + 1])
            let mac = rawMAC.contains(":") ? normaliseMAC(rawMAC) : nil
            let iface = rest.firstIndex(of: "on").flatMap { $0 + 1 < rest.count ? String(rest[$0 + 1]) : nil } ?? ""
            let permanent = line.contains("permanent")
            return Neighbor(ip: ip, mac: mac, interface: iface, isV6: false, permanent: permanent, expires: nil,
                            isRouter: false, state: mac == nil ? "incomplete" : nil)
        }
    }

    /// IPv6 neighbours from the NDP cache (same mechanism as `ndp -a`).
    static func ndp() async -> [Neighbor] {
        await Task.detached(priority: .utility) { linkLayerTable(family: AF_INET6) }.value
    }

    /// Walks `sysctl(CTL_NET, PF_ROUTE, 0, family, NET_RT_FLAGS, RTF_LLINFO)`: one
    /// `rt_msghdr` per neighbour, followed by its destination address and a
    /// `sockaddr_dl` holding the link-layer (MAC) address.
    static func linkLayerTable(family: Int32) -> [Neighbor] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, family, NET_RT_FLAGS, RTF_LLINFO]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: len + 1024)
        len = buf.count
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [] }

        func roundup(_ n: Int) -> Int { n > 0 ? 1 + ((n - 1) | 3) : 4 }
        let now = Int(Date().timeIntervalSince1970)
        var out: [Neighbor] = []
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<rt_msghdr>.size <= len {
                let rtm = raw.loadUnaligned(fromByteOffset: off, as: rt_msghdr.self)
                let msglen = Int(rtm.rtm_msglen)
                guard msglen > 0, off + msglen <= len else { break }
                defer { off += msglen }

                var sa = off + MemoryLayout<rt_msghdr>.size
                guard sa + 2 <= off + msglen else { continue }
                // destination
                let dstLen = Int(raw[sa])
                var ip: String?
                if family == AF_INET, dstLen >= MemoryLayout<sockaddr_in>.size {
                    let sin = raw.loadUnaligned(fromByteOffset: sa, as: sockaddr_in.self)
                    var a = sin.sin_addr
                    var b = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &a, &b, socklen_t(b.count))
                    ip = String(cString: b)
                } else if family == AF_INET6, dstLen >= MemoryLayout<sockaddr_in6>.size {
                    var sin6 = raw.loadUnaligned(fromByteOffset: sa, as: sockaddr_in6.self)
                    // KAME embeds the scope id in bytes 2–3 of link-local addresses.
                    var bytes = withUnsafeBytes(of: sin6.sin6_addr) { Array($0) }
                    if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 {
                        let embedded = UInt32(bytes[2]) << 8 | UInt32(bytes[3])
                        if sin6.sin6_scope_id == 0 { sin6.sin6_scope_id = embedded }
                        bytes[2] = 0; bytes[3] = 0
                        withUnsafeMutableBytes(of: &sin6.sin6_addr) { $0.copyBytes(from: bytes) }
                    }
                    var b = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    var a = sin6.sin6_addr
                    inet_ntop(AF_INET6, &a, &b, socklen_t(b.count))
                    ip = String(cString: b)
                }
                guard let ip else { continue }
                sa += roundup(dstLen)
                // link-layer address
                guard sa + 8 <= off + msglen, Int32(raw[sa + 1]) == AF_LINK else { continue }
                let nlen = Int(raw[sa + 5]), alen = Int(raw[sa + 6])
                let index = UInt32(raw[sa + 2]) | UInt32(raw[sa + 3]) << 8
                var iface = ""
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(index, &name) != nil { iface = String(cString: name) }
                var mac: String?
                let macStart = sa + 8 + nlen
                if alen == 6, macStart + 6 <= off + msglen {
                    mac = (0..<6).map { String(format: "%02x", raw[macStart + $0]) }.joined(separator: ":")
                }
                let expire = Int(rtm.rtm_rmx.rmx_expire)
                let permanent = expire == 0
                out.append(Neighbor(ip: ip, mac: mac, interface: iface, isV6: family == AF_INET6, permanent: permanent,
                                    expires: permanent ? nil : "\(max(0, expire - now))s", isRouter: false,
                                    state: mac == nil ? "incomplete" : nil))
            }
        }
        return out
    }

    static func ndpState(_ s: String?) -> String? {
        switch s {
        case "R": "reachable"
        case "S": "stale"
        case "D": "delay"
        case "P": "probe"
        case "I": "incomplete"
        case "N": "nostate"
        case "W": "waitdelete"
        default: s
        }
    }

    /// "a:b:c:d:e:f" → "0a:0b:0c:0d:0e:0f"
    static func normaliseMAC(_ m: String) -> String {
        m.split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":").lowercased()
    }

    /// I/G bit set → a broadcast or multicast address, never a single device.
    static func isGroupMAC(_ mac: String) -> Bool {
        guard let first = mac.split(separator: ":").first, let b = UInt8(first, radix: 16) else { return false }
        return b & 0x01 != 0
    }

    /// U/L bit set → locally administered, almost always a privacy-randomised address.
    static func isLocallyAdministered(_ mac: String) -> Bool {
        guard let first = mac.split(separator: ":").first, let b = UInt8(first, radix: 16) else { return false }
        return b & 0x02 != 0 && b & 0x01 == 0
    }

    static func vendor(_ mac: String) -> String? {
        let parts = mac.lowercased().split(separator: ":")
        guard parts.count >= 3 else { return nil }
        if isLocallyAdministered(mac) {
            if parts[0] == "02" && parts[1] == "42" { return "Docker (virtual)" }
            return nil
        }
        let oui = parts.prefix(3).joined(separator: ":")
        return ouiTable[oui]
    }

    /// Small, deliberately conservative OUI table — common home-lab and virtualisation
    /// vendors. Unknown is better than wrong.
    static let ouiTable: [String: String] = {
        var t: [String: String] = [:]
        func add(_ vendor: String, _ ouis: [String]) { for o in ouis { t[o] = vendor } }
        add("VMware", ["00:50:56", "00:0c:29", "00:05:69", "00:1c:14"])
        add("Parallels", ["00:1c:42"])
        add("VirtualBox", ["08:00:27", "0a:00:27"])
        add("QEMU / KVM", ["52:54:00"])
        add("Hyper-V", ["00:15:5d"])
        add("Xen", ["00:16:3e"])
        add("Raspberry Pi", ["b8:27:eb", "dc:a6:32", "e4:5f:01", "d8:3a:dd", "28:cd:c1", "2c:cf:67"])
        add("Espressif (ESP32/ESP8266)", ["24:0a:c4", "30:ae:a4", "84:f3:eb", "a4:cf:12", "24:6f:28", "ec:fa:bc",
                                          "5c:cf:7f", "18:fe:34", "60:01:94", "7c:9e:bd", "8c:aa:b5", "bc:dd:c2",
                                          "c4:4f:33", "cc:50:e3", "3c:71:bf", "98:f4:ab", "48:3f:da", "ac:67:b2"])
        add("Ubiquiti", ["00:15:6d", "00:27:22", "04:18:d6", "24:a4:3c", "44:d9:e7", "68:72:51", "78:8a:20",
                         "80:2a:a8", "b4:fb:e4", "dc:9f:db", "f0:9f:c2", "fc:ec:da", "74:83:c2", "e0:63:da"])
        add("Synology", ["00:11:32"])
        add("Philips Hue", ["00:17:88", "ec:b5:fa"])
        add("Sonos", ["00:0e:58", "5c:aa:fd", "94:9f:3e", "b8:e9:37", "48:a6:b8", "78:28:ca"])
        add("Cisco", ["00:00:0c"])
        add("Apple", ["00:03:93", "00:0a:27", "00:0a:95", "00:1e:c2", "00:25:00", "f0:18:98", "a4:5e:60",
                      "ac:bc:32", "3c:07:54", "00:1b:63", "00:23:12", "88:66:5a", "70:56:81"])
        add("Nest / Google", ["18:b4:30", "64:16:66"])
        return t
    }()
}
