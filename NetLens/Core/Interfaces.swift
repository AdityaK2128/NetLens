import Foundation
import Darwin
import SystemConfiguration

struct InterfaceAddress: Hashable, Identifiable {
    var id: String { address }
    let address: String
    let netmask: String?
    let prefix: Int?
    let broadcast: String?
    let isV6: Bool

    var scope: IPScope { IP.scope(address) }
    var cidr: String { prefix.map { "\(IP.stripScope(address))/\($0)" } ?? address }
}

struct InterfaceCounters: Hashable {
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var packetsIn: UInt64 = 0
    var packetsOut: UInt64 = 0
    var errorsIn: UInt64 = 0
    var errorsOut: UInt64 = 0
    var multicastIn: UInt64 = 0
    var multicastOut: UInt64 = 0
    var dropsIn: UInt64 = 0
    var collisions: UInt64 = 0
    var mtu: UInt32 = 0
    var baudrate: UInt64 = 0
}

struct NetInterface: Identifiable, Hashable {
    enum Kind: String {
        case wifi = "Wi-Fi", ethernet = "Ethernet", loopback = "Loopback", tunnel = "Tunnel",
             awdl = "AWDL", bridge = "Bridge", cellular = "Cellular", hotspot = "Access Point",
             virtual = "Virtual", other = "Other"

        var symbol: String {
            switch self {
            case .wifi: "wifi"
            case .ethernet: "cable.connector"
            case .loopback: "arrow.triangle.2.circlepath"
            case .tunnel: "lock.shield"
            case .awdl: "dot.radiowaves.left.and.right"
            case .bridge: "point.3.connected.trianglepath.dotted"
            case .cellular: "antenna.radiowaves.left.and.right"
            case .hotspot: "personalhotspot"
            case .virtual: "shippingbox"
            case .other: "network"
            }
        }
    }

    var id: String { name }
    let name: String
    var index: UInt32 = 0
    var displayName: String
    var kind: Kind
    var flags: UInt32 = 0
    var mac: String?
    var ipv4: [InterfaceAddress] = []
    var ipv6: [InterfaceAddress] = []
    var counters = InterfaceCounters()

    var isUp: Bool { flags & UInt32(IFF_UP) != 0 }
    var isRunning: Bool { flags & UInt32(IFF_RUNNING) != 0 }
    var isActive: Bool { isUp && isRunning && (!ipv4.isEmpty || ipv6.contains { $0.scope != .linkLocal }) }
    var hasAddresses: Bool { !ipv4.isEmpty || !ipv6.isEmpty }

    var flagNames: [String] {
        var out: [String] = []
        let table: [(Int32, String)] = [
            (IFF_UP, "UP"), (IFF_BROADCAST, "BROADCAST"), (IFF_DEBUG, "DEBUG"), (IFF_LOOPBACK, "LOOPBACK"),
            (IFF_POINTOPOINT, "POINTOPOINT"), (IFF_NOTRAILERS, "SMART"), (IFF_RUNNING, "RUNNING"),
            (IFF_NOARP, "NOARP"), (IFF_PROMISC, "PROMISC"), (IFF_ALLMULTI, "ALLMULTI"),
            (IFF_OACTIVE, "OACTIVE"), (IFF_SIMPLEX, "SIMPLEX"), (IFF_MULTICAST, "MULTICAST"),
        ]
        for (bit, name) in table where flags & UInt32(bit) != 0 { out.append(name) }
        return out
    }

    /// What this interface is for — the part `ifconfig` never tells you.
    var explanation: String {
        let n = name
        if n == "lo0" { return "Loopback — traffic your Mac sends to itself (127.0.0.1, ::1). Never touches hardware." }
        if n.hasPrefix("awdl") { return "Apple Wireless Direct Link — peer-to-peer Wi-Fi used by AirDrop, AirPlay, Sidecar and Universal Control. Hops channels alongside your normal Wi-Fi." }
        if n.hasPrefix("llw") { return "Low-Latency WLAN — companion to AWDL for latency-sensitive peer links (e.g. Continuity, Sidecar)." }
        if n.hasPrefix("utun") { return "Userspace tunnel — created by VPNs (WireGuard, Tailscale, IKEv2 clients), iCloud Private Relay and some Apple services. Packets are encrypted/encapsulated in userspace." }
        if n.hasPrefix("ipsec") { return "IPsec tunnel — kernel-level VPN (IKEv2/L2TP)." }
        if n.hasPrefix("gif") { return "Generic tunnel interface — IPv4/IPv6 encapsulation (rarely used)." }
        if n.hasPrefix("stf") { return "6to4 tunnel — legacy IPv6 transition mechanism; normally idle." }
        if n.hasPrefix("anpi") { return "Apple private network interface — internal link used by Apple silicon Macs for device services." }
        if n.hasPrefix("ap") { return "Access-point interface — active when Internet Sharing / hotspot is on." }
        if n.hasPrefix("bridge") { return kind == .bridge && displayName.lowercased().contains("thunderbolt") ? "Thunderbolt Bridge — IP networking directly over a Thunderbolt cable between Macs." : "Software bridge — joins interfaces at layer 2 (Thunderbolt Bridge, Internet Sharing, virtual machines)." }
        if n.hasPrefix("pdp_ip") { return "Cellular data context." }
        if n.hasPrefix("vmenet") || n.hasPrefix("feth") { return "Virtual Ethernet — used by virtual machines and container runtimes." }
        switch kind {
        case .wifi: return "802.11 wireless radio."
        case .ethernet: return "Wired Ethernet (built-in, USB or Thunderbolt adapter)."
        default: return "Network interface."
        }
    }
}

enum InterfaceReader {
    static func read() -> [NetInterface] {
        var byName: [String: NetInterface] = [:]
        let names = scNames()

        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(first) }

        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            var iface = byName[name] ?? makeInterface(name, scInfo: names[name])
            iface.flags = cur.pointee.ifa_flags
            guard let sa = cur.pointee.ifa_addr else { byName[name] = iface; continue }
            let family = Int32(sa.pointee.sa_family)
            if family == AF_LINK {
                sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                    let d = dl.pointee
                    iface.index = UInt32(d.sdl_index)
                    if d.sdl_alen == 6 {
                        // sdl_data is variable-length (name then address) — read past the
                        // declared 12-byte array from the raw sockaddr.
                        let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) ?? 8
                        let base = UnsafeRawPointer(dl) + dataOffset + Int(d.sdl_nlen)
                        let mac = (0..<6).map { base.load(fromByteOffset: $0, as: UInt8.self) }
                        if mac.contains(where: { $0 != 0 }) {
                            iface.mac = mac.map { String(format: "%02x", $0) }.joined(separator: ":")
                        }
                    }
                }
            } else if family == AF_INET || family == AF_INET6 {
                guard let addr = SockAddr.string(sa) else { continue }
                let mask = cur.pointee.ifa_netmask.flatMap { SockAddr.string($0) }
                var bcast: String? = nil
                if let d = cur.pointee.ifa_dstaddr, family == AF_INET {
                    bcast = SockAddr.string(d)
                }
                let a = InterfaceAddress(address: addr, netmask: mask,
                                         prefix: mask.flatMap { IP.prefixLength(netmask: IP.stripScope($0)) },
                                         broadcast: bcast, isV6: family == AF_INET6)
                if family == AF_INET { iface.ipv4.append(a) } else { iface.ipv6.append(a) }
            }
            byName[name] = iface
        }

        let counters = readCounters()
        for (name, c) in counters {
            byName[name]?.counters = c
        }
        return byName.values.sorted { sortKey($0) < sortKey($1) }
    }

    private static func sortKey(_ i: NetInterface) -> String {
        let rank: Int
        switch i.kind {
        case .wifi, .ethernet: rank = i.isActive ? 0 : 3
        case .tunnel: rank = i.hasAddresses ? 1 : 4
        case .loopback: rank = 5
        default: rank = i.isActive ? 2 : 6
        }
        return "\(rank)-\(i.name)"
    }

    private struct SCInfo { let display: String; let type: String }

    private static func scNames() -> [String: SCInfo] {
        var out: [String: SCInfo] = [:]
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return out }
        for i in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { continue }
            let display = (SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? bsd
            let type = (SCNetworkInterfaceGetInterfaceType(i) as String?) ?? ""
            out[bsd] = SCInfo(display: display, type: type)
        }
        return out
    }

    private static func makeInterface(_ name: String, scInfo: SCInfo?) -> NetInterface {
        var kind: NetInterface.Kind = .other
        var display = scInfo?.display ?? name
        if let t = scInfo?.type {
            if t == (kSCNetworkInterfaceTypeIEEE80211 as String) { kind = .wifi }
            else if t == (kSCNetworkInterfaceTypeEthernet as String) { kind = .ethernet }
            else if t == "Bridge" { kind = .bridge }
            else if t == (kSCNetworkInterfaceTypeWWAN as String) { kind = .cellular }
        }
        if kind == .other {
            switch true {
            case name == "lo0": kind = .loopback; display = "Loopback"
            case name.hasPrefix("utun"), name.hasPrefix("ipsec"), name.hasPrefix("gif"), name.hasPrefix("stf"):
                kind = .tunnel
                display = name.hasPrefix("utun") ? "Tunnel (\(name))" : name.hasPrefix("ipsec") ? "IPsec" : name.hasPrefix("gif") ? "Generic tunnel" : "6to4 tunnel"
            case name.hasPrefix("awdl"): kind = .awdl; display = "AirDrop / AWDL"
            case name.hasPrefix("llw"): kind = .awdl; display = "Low-latency WLAN"
            case name.hasPrefix("bridge"): kind = .bridge; display = scInfo?.display ?? "Bridge"
            case name.hasPrefix("ap"): kind = .hotspot; display = "Access point"
            case name.hasPrefix("pdp_ip"): kind = .cellular; display = "Cellular"
            case name.hasPrefix("anpi"), name.hasPrefix("vmenet"), name.hasPrefix("feth"):
                kind = .virtual
                display = name.hasPrefix("anpi") ? "Apple private" : "Virtual Ethernet"
            case name.hasPrefix("en"): kind = .ethernet
            default: break
            }
        }
        return NetInterface(name: name, displayName: display, kind: kind)
    }

    /// 64-bit interface counters via the routing socket sysctl (NET_RT_IFLIST2).
    /// `getifaddrs` only exposes 32-bit counters that wrap every 4 GiB.
    static func readCounters() -> [String: InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }

        var out: [String: InterfaceCounters] = [:]
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                let msglen = Int(hdr.ifm_msglen)
                guard msglen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(m.ifm_index), &name) != nil {
                        let d = m.ifm_data
                        out[String(cString: name)] = InterfaceCounters(
                            bytesIn: d.ifi_ibytes, bytesOut: d.ifi_obytes,
                            packetsIn: d.ifi_ipackets, packetsOut: d.ifi_opackets,
                            errorsIn: d.ifi_ierrors, errorsOut: d.ifi_oerrors,
                            multicastIn: d.ifi_imcasts, multicastOut: d.ifi_omcasts,
                            dropsIn: d.ifi_iqdrops, collisions: d.ifi_collisions,
                            mtu: d.ifi_mtu, baudrate: d.ifi_baudrate)
                    }
                }
                off += msglen
            }
        }
        return out
    }
}
