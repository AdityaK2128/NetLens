import Foundation

struct RouteEntry: Identifiable, Hashable {
    let id = UUID()
    let destination: String
    let gateway: String
    let flags: String
    let interface: String
    let expire: String
    let isV6: Bool

    var isDefault: Bool { destination == "default" }
    var isHost: Bool { flags.contains("H") }
    var viaGateway: Bool { flags.contains("G") }
    var isTunnel: Bool { interface.hasPrefix("utun") || interface.hasPrefix("ipsec") }
    var isScoped: Bool { flags.contains("I") }

    var kind: String {
        if isDefault { return isScoped ? "default (scoped)" : "default" }
        if destination.hasPrefix("224") || destination.hasPrefix("ff") { return "multicast" }
        if destination.hasPrefix("127") || destination == "::1" || interface == "lo0" { return "loopback" }
        if isHost && gateway.contains(":") && !viaGateway && !isV6 { return "ARP entry" }
        if isHost { return "host" }
        if gateway.hasPrefix("link#") { return "on-link subnet" }
        return viaGateway ? "via gateway" : "network"
    }
}

enum Routes {
    static func read() async -> [RouteEntry] {
        let r = await Shell.run("/usr/sbin/netstat", ["-rn"], timeout: 6)
        var out: [RouteEntry] = []
        var v6 = false
        for raw in r.stdout.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("Internet6") { v6 = true; continue }
            if line.hasPrefix("Internet") { v6 = false; continue }
            let t = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard t.count >= 4, t[0] != "Destination", t[0] != "Routing" else { continue }
            out.append(RouteEntry(destination: t[0], gateway: t[1], flags: t[2], interface: t[3],
                                  expire: t.count > 4 ? t[4...].joined(separator: " ") : "", isV6: v6))
        }
        return out
    }

    static let flagMeanings: [(Character, String)] = [
        ("U", "Up — usable"), ("G", "Gateway — next hop is a router"), ("H", "Host — single address, not a network"),
        ("S", "Static — added manually or by configd"), ("C", "Cloning — creates per-host routes on use"),
        ("c", "Protocol-specified cloning"), ("L", "Link-layer address valid (ARP/NDP)"), ("W", "Was cloned"),
        ("I", "Interface-scoped — only for traffic bound to this interface"), ("i", "Interface-scoped (ifscope)"),
        ("g", "Gateway is a generic (multi-homed) route"), ("R", "Reject — unreachable"), ("B", "Blackhole — silently dropped"),
        ("D", "Dynamic — created by redirect"), ("M", "Modified by redirect"), ("b", "Broadcast address"),
        ("m", "Multicast address"), ("A", "Address is a local alias"), ("X", "External daemon resolves"),
        ("1", "Protocol flag 1"), ("2", "Protocol flag 2"), ("3", "Protocol flag 3"), ("P", "Pinned"),
    ]

    static func explain(_ flags: String) -> String {
        flags.compactMap { f in flagMeanings.first { $0.0 == f }.map { "\(f): \($0.1)" } }.joined(separator: "\n")
    }

    struct Lookup {
        var destination: String?
        var gateway: String?
        var interface: String?
        var flags: String?
        var mtu: String?
        var rtt: String?
        var rttvar: String?
        var hopcount: String?
        var raw: String
    }

    /// `route -n get` — the kernel's actual decision for a destination.
    static func lookup(_ target: String) async -> Lookup {
        var host = target.trimmed
        if !IP.isIP(host) { host = await Resolver.resolve(host).first ?? host }
        let args = IP.isV6(host) ? ["-n", "get", "-inet6", host] : ["-n", "get", host]
        let r = await Shell.run("/sbin/route", args, timeout: 5)
        var l = Lookup(raw: r.stdout + r.stderr)
        let lines = r.stdout.split(separator: "\n").map(String.init)
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            func val() -> String { String(t.split(separator: ":", maxSplits: 1).last ?? "").trimmed }
            if t.hasPrefix("destination:") { l.destination = val() }
            if t.hasPrefix("gateway:") { l.gateway = val() }
            if t.hasPrefix("interface:") { l.interface = val() }
            if t.hasPrefix("flags:") { l.flags = val() }
            if t.hasPrefix("recvpipe"), i + 1 < lines.count {
                let h = t.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                let v = lines[i + 1].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                for (k, name) in h.enumerated() where k < v.count {
                    switch name {
                    case "mtu": l.mtu = v[k]
                    case "rtt,msec": l.rtt = v[k]
                    case "rttvar": l.rttvar = v[k]
                    case "hopcount": l.hopcount = v[k]
                    default: break
                    }
                }
            }
        }
        return l
    }
}
