import Foundation
import Darwin

struct PacketRow: Identifiable, Hashable {
    enum Category: Hashable { case tcp, tcpControl, tcpReset, udp, dns, tls, quic, http, arp, icmp, other }
    let id: Int
    let time: Double
    let length: Int
    let src: String
    let dst: String
    let proto: String
    let info: String
    let category: Category
    let srcPort: UInt16?
    let dstPort: UInt16?
    let protocols: Set<String>
    let relSeq: UInt32?
    let relAck: UInt32?
    let sni: String?

    func hash(into h: inout Hasher) { h.combine(id) }
    static func == (a: PacketRow, b: PacketRow) -> Bool { a.id == b.id }
}

/// One node in the packet-details tree; `range` points into the raw bytes so the hex
/// view can highlight exactly what you selected.
struct PField: Identifiable, Hashable {
    let id: Int
    let label: String
    let range: Range<Int>?
    var children: [PField]?
}

final class PacketDecoder {
    let dlt: UInt32
    private var isn: [String: UInt32] = [:]

    init(dlt: UInt32) { self.dlt = dlt }

    /// Fast path: row summary for the list (runs on the capture thread).
    func summarize(_ p: RawPacket, number: Int, t0: Double) -> PacketRow {
        let ctx = Ctx(detail: false)
        var s = Summary()
        Self.decode(p.data, dlt: dlt, ctx: ctx, s: &s)
        // Relative TCP sequence numbers, Wireshark-style.
        var relSeq: UInt32?, relAck: UInt32?
        if let seq = s.tcpSeq, let sp = s.srcPort, let dp = s.dstPort {
            let fwd = "\(s.src):\(sp)>\(s.dst):\(dp)", rev = "\(s.dst):\(dp)>\(s.src):\(sp)"
            if isn[fwd] == nil || (s.tcpFlags & 0x02 != 0) { isn[fwd] = seq }
            relSeq = seq &- isn[fwd]!
            if let ack = s.tcpAck, s.tcpFlags & 0x10 != 0, let r = isn[rev] { relAck = ack &- r }
            if isn.count > 50_000 { isn.removeAll() }
        }
        var info = s.info
        if s.proto == "TCP" {
            info = "\(s.srcPort ?? 0) → \(s.dstPort ?? 0) [\(Self.flagString(s.tcpFlags))]"
                + (relSeq.map { " Seq=\($0)" } ?? "") + (relAck.map { " Ack=\($0)" } ?? "")
                + " Win=\(s.tcpWindow) Len=\(s.payloadLen)" + s.infoSuffix
        }
        return PacketRow(id: number, time: p.timestamp - t0, length: p.wirelen, src: s.src, dst: s.dst, proto: s.proto,
                         info: info, category: s.category, srcPort: s.srcPort, dstPort: s.dstPort, protocols: s.protocols,
                         relSeq: relSeq, relAck: relAck, sni: s.sni)
    }

    /// Slow path: full field tree for the selected packet.
    static func dissect(_ p: RawPacket, row: PacketRow, dlt: UInt32, interface: String) -> [PField] {
        let ctx = Ctx(detail: true)
        var s = Summary()
        let frame = ctx.f("Frame \(row.id): \(p.wirelen) bytes on wire, \(p.caplen) bytes captured on \(interface)", 0..<p.data.count, [
            ctx.f("Arrival time: \(Fmt.clockMillis.string(from: Date(timeIntervalSince1970: p.timestamp)))", nil),
            ctx.f(String(format: "Time since capture start: %.6f s", row.time), nil),
            ctx.f("Frame length: \(p.wirelen) bytes", nil),
            ctx.f("Link type: \(linkName(dlt)) (DLT \(dlt))", nil),
            ctx.f("Protocols in frame: \(row.protocols.sorted().joined(separator: ":"))", nil),
        ])
        var layers = [frame]
        layers += decode(p.data, dlt: dlt, ctx: ctx, s: &s)
        // annotate TCP with relative numbers
        if let r = row.relSeq, let i = layers.firstIndex(where: { $0.label.hasPrefix("Transmission Control") }) {
            layers[i].children?.insert(ctx.f("[Relative sequence number: \(r)]" + (row.relAck.map { "  [Relative ack: \($0)]" } ?? ""), nil), at: 0)
        }
        return layers
    }

    static func linkName(_ dlt: UInt32) -> String {
        switch dlt {
        case 0: "BSD loopback / null"
        case 1: "Ethernet"
        case 12, 14: "Raw IP"
        case 108: "OpenBSD loopback"
        case 105: "802.11"
        case 127: "802.11 + radiotap"
        default: "DLT \(dlt)"
        }
    }

    static func flagString(_ f: UInt8) -> String {
        var a: [String] = []
        if f & 0x02 != 0 { a.append("SYN") }
        if f & 0x10 != 0 { a.append("ACK") }
        if f & 0x08 != 0 { a.append("PSH") }
        if f & 0x01 != 0 { a.append("FIN") }
        if f & 0x04 != 0 { a.append("RST") }
        if f & 0x20 != 0 { a.append("URG") }
        if f & 0x40 != 0 { a.append("ECE") }
        if f & 0x80 != 0 { a.append("CWR") }
        return a.joined(separator: ", ")
    }

    // MARK: - plumbing

    final class Ctx {
        let detail: Bool
        var next = 0
        init(detail: Bool) { self.detail = detail }
        func f(_ label: @autoclosure () -> String, _ range: Range<Int>?, _ children: [PField]? = nil) -> PField {
            next += 1
            return detail ? PField(id: next, label: label(), range: range, children: children?.isEmpty == true ? nil : children)
                          : PField(id: 0, label: "", range: nil, children: nil)
        }
    }

    struct Summary {
        var src = "?", dst = "?"
        var proto = "Unknown"
        var info = ""
        var infoSuffix = ""
        var category: PacketRow.Category = .other
        var srcPort: UInt16?, dstPort: UInt16?
        var protocols: Set<String> = []
        var tcpSeq: UInt32?, tcpAck: UInt32?
        var tcpFlags: UInt8 = 0
        var tcpWindow = 0
        var payloadLen = 0
        var sni: String?
    }

    static func mac(_ d: [UInt8], _ o: Int) -> String {
        guard o + 6 <= d.count else { return "?" }
        return d[o..<o + 6].map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    static func v4(_ d: [UInt8], _ o: Int) -> String {
        guard o + 4 <= d.count else { return "?" }
        return "\(d[o]).\(d[o + 1]).\(d[o + 2]).\(d[o + 3])"
    }

    static func v6(_ d: [UInt8], _ o: Int) -> String {
        guard o + 16 <= d.count else { return "?" }
        var a = in6_addr()
        withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: d[o..<o + 16]) }
        var buf = [CChar](repeating: 0, count: 64)
        inet_ntop(AF_INET6, &a, &buf, 64)
        return String(cString: buf)
    }

    // MARK: - link layer

    @discardableResult
    static func decode(_ d: [UInt8], dlt: UInt32, ctx: Ctx, s: inout Summary) -> [PField] {
        switch dlt {
        case 1:
            return ethernet(d, ctx: ctx, s: &s)
        case 0, 108:
            guard d.count >= 4 else { return [] }
            let fam = dlt == 0 ? d.loadLE32(0) : d.be32(0)
            let f = ctx.f("Null/Loopback, family: \(fam == 2 ? "IPv4" : fam == 30 || fam == 24 || fam == 28 ? "IPv6" : "\(fam)")", 0..<4)
            return [f] + ip(d, 4, ctx: ctx, s: &s)
        case 12, 14:
            return ip(d, 0, ctx: ctx, s: &s)
        default:
            s.proto = "DLT\(dlt)"
            return []
        }
    }

    static func ethernet(_ d: [UInt8], ctx: Ctx, s: inout Summary) -> [PField] {
        guard d.count >= 14 else { return [] }
        s.protocols.insert("eth")
        var type = d.be16(12)
        var off = 14
        var children = [
            ctx.f("Destination: \(mac(d, 0))\(Neighbors.vendor(mac(d, 0)).map { " (\($0))" } ?? "")", 0..<6),
            ctx.f("Source: \(mac(d, 6))\(Neighbors.vendor(mac(d, 6)).map { " (\($0))" } ?? "")", 6..<12),
        ]
        if type == 0x8100, d.count >= 18 {
            children.append(ctx.f("802.1Q VLAN: ID \(d.be16(14) & 0x0FFF), priority \(d[14] >> 5)", 12..<16))
            type = d.be16(16)
            off = 18
        }
        children.append(ctx.f(String(format: "Type: %@ (0x%04x)", etherName(type), type), (off - 2)..<off))
        let eth = ctx.f("Ethernet II, Src: \(mac(d, 6)), Dst: \(mac(d, 0))", 0..<off, children)
        s.src = mac(d, 6); s.dst = mac(d, 0)
        switch type {
        case 0x0800, 0x86DD: return [eth] + ip(d, off, ctx: ctx, s: &s)
        case 0x0806: return [eth] + arp(d, off, ctx: ctx, s: &s)
        case 0x888E: s.proto = "EAPOL"; s.info = "802.1X authentication"; return [eth]
        case 0x88CC: s.proto = "LLDP"; s.info = "Link Layer Discovery"; return [eth]
        default:
            s.proto = String(format: "0x%04x", type)
            s.info = "Ethernet type \(etherName(type))"
            return [eth]
        }
    }

    static func etherName(_ t: Int) -> String {
        switch t {
        case 0x0800: "IPv4"; case 0x86DD: "IPv6"; case 0x0806: "ARP"; case 0x8100: "802.1Q"
        case 0x888E: "EAPOL"; case 0x88CC: "LLDP"; case 0x8847: "MPLS"; default: "unknown"
        }
    }

    static func arp(_ d: [UInt8], _ o: Int, ctx: Ctx, s: inout Summary) -> [PField] {
        guard d.count >= o + 28 else { return [] }
        s.protocols.insert("arp")
        s.proto = "ARP"; s.category = .arp
        let op = d.be16(o + 6)
        let sha = mac(d, o + 8), spa = v4(d, o + 14), tha = mac(d, o + 18), tpa = v4(d, o + 24)
        switch op {
        case 1: s.info = spa == tpa ? "ARP Announcement for \(spa)" : "Who has \(tpa)? Tell \(spa)"
        case 2: s.info = "\(spa) is at \(sha)"
        default: s.info = "ARP op \(op)"
        }
        s.src = sha
        s.dst = op == 1 ? "Broadcast" : tha
        return [ctx.f("Address Resolution Protocol (\(op == 1 ? "request" : op == 2 ? "reply" : "op \(op)"))", o..<(o + 28), [
            ctx.f("Hardware type: \(d.be16(o) == 1 ? "Ethernet" : "\(d.be16(o))") (\(d.be16(o)))", o..<(o + 2)),
            ctx.f(String(format: "Protocol type: IPv4 (0x%04x)", d.be16(o + 2)), (o + 2)..<(o + 4)),
            ctx.f("Opcode: \(op == 1 ? "request" : "reply") (\(op))", (o + 6)..<(o + 8)),
            ctx.f("Sender MAC: \(sha)", (o + 8)..<(o + 14)),
            ctx.f("Sender IP: \(spa)", (o + 14)..<(o + 18)),
            ctx.f("Target MAC: \(tha)", (o + 18)..<(o + 24)),
            ctx.f("Target IP: \(tpa)", (o + 24)..<(o + 28)),
        ])]
    }

    // MARK: - network layer

    static func ip(_ d: [UInt8], _ o: Int, ctx: Ctx, s: inout Summary) -> [PField] {
        guard d.count > o else { return [] }
        let version = d[o] >> 4
        if version == 4 { return ipv4(d, o, ctx: ctx, s: &s) }
        if version == 6 { return ipv6(d, o, ctx: ctx, s: &s) }
        s.proto = "IP?"
        return []
    }

    static func ipv4(_ d: [UInt8], _ o: Int, ctx: Ctx, s: inout Summary) -> [PField] {
        guard d.count >= o + 20 else { return [] }
        s.protocols.insert("ip")
        let ihl = Int(d[o] & 0x0F) * 4
        let total = d.be16(o + 2)
        let flags = d[o + 6] >> 5
        let fragOff = (d.be16(o + 6) & 0x1FFF) * 8
        let ttl = d[o + 8]
        let proto = d[o + 9]
        let src = v4(d, o + 12), dst = v4(d, o + 16)
        s.src = src; s.dst = dst
        s.proto = "IPv4"
        s.info = "IPv4 protocol \(proto)"
        let dscp = d[o + 1] >> 2, ecn = d[o + 1] & 3
        let field = ctx.f("Internet Protocol Version 4, Src: \(src), Dst: \(dst)", o..<min(d.count, o + ihl), [
            ctx.f("Version: 4", o..<(o + 1)),
            ctx.f("Header length: \(ihl) bytes", o..<(o + 1)),
            ctx.f("DSCP: \(dscp)\(dscpName(dscp))  ECN: \(ecnName(ecn))", (o + 1)..<(o + 2)),
            ctx.f("Total length: \(total)", (o + 2)..<(o + 4)),
            ctx.f(String(format: "Identification: 0x%04x (%d)", d.be16(o + 4), d.be16(o + 4)), (o + 4)..<(o + 6)),
            ctx.f("Flags: \(flags & 2 != 0 ? "Don't fragment" : "")\(flags & 1 != 0 ? " More fragments" : "")\(flags == 0 ? "none" : "")", (o + 6)..<(o + 7)),
            ctx.f("Fragment offset: \(fragOff)", (o + 6)..<(o + 8)),
            ctx.f("Time to live: \(ttl)", (o + 8)..<(o + 9)),
            ctx.f("Protocol: \(ipProtoName(proto)) (\(proto))", (o + 9)..<(o + 10)),
            ctx.f(String(format: "Header checksum: 0x%04x", d.be16(o + 10)), (o + 10)..<(o + 12)),
            ctx.f("Source: \(src)", (o + 12)..<(o + 16)),
            ctx.f("Destination: \(dst)", (o + 16)..<(o + 20)),
        ])
        guard fragOff == 0 else {
            s.info = "Fragmented IP protocol (\(ipProtoName(proto)), off=\(fragOff))"
            return [field]
        }
        let end = min(d.count, o + max(total, ihl))
        return [field] + transport(d, o + ihl, end: end, proto: proto, v6: false, ctx: ctx, s: &s)
    }

    static func ipv6(_ d: [UInt8], _ o: Int, ctx: Ctx, s: inout Summary) -> [PField] {
        guard d.count >= o + 40 else { return [] }
        s.protocols.insert("ipv6")
        let tc = (d.be16(o) >> 4) & 0xFF
        let flow = Int(d.be32(o) & 0xFFFFF)
        let plen = d.be16(o + 4)
        var next = d[o + 6]
        let hop = d[o + 7]
        let src = v6(d, o + 8), dst = v6(d, o + 24)
        s.src = src; s.dst = dst
        s.proto = "IPv6"
        var children = [
            ctx.f("Version: 6", o..<(o + 1)),
            ctx.f("Traffic class: 0x\(String(tc, radix: 16))", o..<(o + 2)),
            ctx.f(String(format: "Flow label: 0x%05x", flow), (o + 1)..<(o + 4)),
            ctx.f("Payload length: \(plen)", (o + 4)..<(o + 6)),
            ctx.f("Next header: \(ipProtoName(next)) (\(next))", (o + 6)..<(o + 7)),
            ctx.f("Hop limit: \(hop)", (o + 7)..<(o + 8)),
            ctx.f("Source: \(src)", (o + 8)..<(o + 24)),
            ctx.f("Destination: \(dst)", (o + 24)..<(o + 40)),
        ]
        var off = o + 40
        // walk extension headers
        var guardCount = 0
        while [0, 43, 60, 51].contains(next), off + 8 <= d.count, guardCount < 8 {
            let len = next == 51 ? (Int(d[off + 1]) + 2) * 4 : (Int(d[off + 1]) + 1) * 8
            children.append(ctx.f("Extension header: \(ipProtoName(next))", off..<min(d.count, off + len)))
            next = d[off]
            off += len
            guardCount += 1
        }
        if next == 44, off + 8 <= d.count {
            children.append(ctx.f("Fragment header", off..<(off + 8)))
            let fragOff = d.be16(off + 2) & 0xFFF8
            next = d[off]
            off += 8
            if fragOff != 0 {
                s.info = "IPv6 fragment"
                return [ctx.f("Internet Protocol Version 6, Src: \(src), Dst: \(dst)", o..<off, children)]
            }
        }
        let field = ctx.f("Internet Protocol Version 6, Src: \(src), Dst: \(dst)", o..<off, children)
        return [field] + transport(d, off, end: min(d.count, o + 40 + plen), proto: next, v6: true, ctx: ctx, s: &s)
    }

    static func ipProtoName(_ p: UInt8) -> String {
        switch p {
        case 0: "Hop-by-hop"; case 1: "ICMP"; case 2: "IGMP"; case 6: "TCP"; case 17: "UDP"; case 41: "IPv6-in-IPv4"
        case 43: "Routing"; case 44: "Fragment"; case 47: "GRE"; case 50: "ESP"; case 51: "AH"; case 58: "ICMPv6"
        case 59: "No next header"; case 60: "Destination options"; case 132: "SCTP"; default: "proto \(p)"
        }
    }

    static func dscpName(_ d: UInt8) -> String {
        switch d {
        case 0: " (CS0 best effort)"; case 8: " (CS1 background)"; case 46: " (EF voice)"; case 34: " (AF41 video)"
        case 48: " (CS6 network control)"; case 40: " (CS5)"; case 10: " (AF11)"; case 18: " (AF21)"; case 26: " (AF31)"
        default: ""
        }
    }

    static func ecnName(_ e: UInt8) -> String {
        switch e { case 0: "Not-ECT"; case 1: "ECT(1) — L4S"; case 2: "ECT(0)"; default: "CE (congestion experienced)" }
    }

    // MARK: - transport layer

    static func transport(_ d: [UInt8], _ o: Int, end: Int, proto: UInt8, v6: Bool, ctx: Ctx, s: inout Summary) -> [PField] {
        switch proto {
        case 6: return tcp(d, o, end: end, ctx: ctx, s: &s)
        case 17: return udp(d, o, end: end, ctx: ctx, s: &s)
        case 1: return icmp(d, o, end: end, ctx: ctx, s: &s)
        case 58: return icmpv6(d, o, end: end, ctx: ctx, s: &s)
        case 2:
            s.proto = "IGMP"; s.info = "Multicast group management"; s.protocols.insert("igmp")
            return []
        case 50:
            s.proto = "ESP"; s.info = "IPsec encrypted payload"; s.protocols.insert("esp")
            return []
        default:
            s.proto = ipProtoName(proto)
            return []
        }
    }

    static func tcp(_ d: [UInt8], _ o: Int, end: Int, ctx: Ctx, s: inout Summary) -> [PField] {
        guard d.count >= o + 20 else { return [] }
        s.protocols.insert("tcp")
        let sp = UInt16(d.be16(o)), dp = UInt16(d.be16(o + 2))
        let seq = d.be32(o + 4), ack = d.be32(o + 8)
        let hlen = Int(d[o + 12] >> 4) * 4
        let flags = d[o + 13]
        let win = d.be16(o + 14)
        s.srcPort = sp; s.dstPort = dp
        s.tcpSeq = seq; s.tcpAck = ack; s.tcpFlags = flags; s.tcpWindow = win
        let payloadStart = o + hlen
        let payloadLen = max(0, end - payloadStart)
        s.payloadLen = payloadLen
        s.proto = "TCP"
        s.category = flags & 0x04 != 0 ? .tcpReset : (flags & 0x03 != 0 ? .tcpControl : .tcp)

        var opts: [PField] = []
        if ctx.detail, hlen > 20 {
            var i = o + 20
            while i < min(d.count, o + hlen) {
                let kind = d[i]
                if kind == 0 { break }
                if kind == 1 { i += 1; continue }
                guard i + 1 < d.count else { break }
                let len = max(2, Int(d[i + 1]))
                let r = i..<min(d.count, i + len)
                switch kind {
                case 2: opts.append(ctx.f("Maximum segment size: \(d.be16(i + 2)) bytes", r))
                case 3: opts.append(ctx.f("Window scale: \(d[i + 2]) (×\(1 << Int(min(d[i + 2], 14))))", r))
                case 4: opts.append(ctx.f("SACK permitted", r))
                case 5: opts.append(ctx.f("SACK blocks: \((len - 2) / 8)", r))
                case 8: opts.append(ctx.f("Timestamps: TSval \(d.be32(i + 2)), TSecr \(d.be32(i + 6))", r))
                case 30: opts.append(ctx.f("Multipath TCP", r))
                case 34: opts.append(ctx.f("TCP Fast Open cookie", r))
                default: opts.append(ctx.f("Option kind \(kind), \(len) bytes", r))
                }
                i += len
            }
        }
        let field = ctx.f("Transmission Control Protocol, Src Port: \(sp), Dst Port: \(dp), Len: \(payloadLen)", o..<min(d.count, o + hlen), [
            ctx.f("Source port: \(sp)\(Services.name(sp, tcp: true).map { " (\($0))" } ?? "")", o..<(o + 2)),
            ctx.f("Destination port: \(dp)\(Services.name(dp, tcp: true).map { " (\($0))" } ?? "")", (o + 2)..<(o + 4)),
            ctx.f("Sequence number (raw): \(seq)", (o + 4)..<(o + 8)),
            ctx.f("Acknowledgment number (raw): \(ack)", (o + 8)..<(o + 12)),
            ctx.f("Header length: \(hlen) bytes", (o + 12)..<(o + 13)),
            ctx.f(String(format: "Flags: 0x%03x [%@]", flags, flagString(flags)), (o + 12)..<(o + 14)),
            ctx.f("Window: \(win)", (o + 14)..<(o + 16)),
            ctx.f(String(format: "Checksum: 0x%04x", d.be16(o + 16)), (o + 16)..<(o + 18)),
            ctx.f("Urgent pointer: \(d.be16(o + 18))", (o + 18)..<(o + 20)),
        ] + (opts.isEmpty ? [] : [ctx.f("Options (\(hlen - 20) bytes)", (o + 20)..<min(d.count, o + hlen), opts)]))
        var out = [field]
        guard payloadLen > 0, payloadStart < d.count else { return out }
        let payload = Array(d[payloadStart..<min(d.count, end)])
        if let tls = tls(payload, base: payloadStart, ctx: ctx, s: &s) {
            out.append(tls)
        } else if sp == 80 || dp == 80 || sp == 8080 || dp == 8080 || looksLikeHTTP(payload) {
            if let h = http(payload, base: payloadStart, ctx: ctx, s: &s) { out.append(h) }
        } else if sp == 53 || dp == 53, payload.count > 2 {
            if let dns = dns(Array(payload.dropFirst(2)), base: payloadStart + 2, mdns: false, ctx: ctx, s: &s) { out.append(dns) }
        } else if sp == 22 || dp == 22 {
            s.proto = "SSH"; s.protocols.insert("ssh")
            if let line = String(bytes: payload.prefix(64), encoding: .ascii), line.hasPrefix("SSH-") {
                s.infoSuffix = "  " + line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            out.append(ctx.f("SSH (encrypted, \(payloadLen) bytes)", payloadStart..<min(d.count, end)))
            s.category = .tcp
        } else {
            out.append(ctx.f("Data (\(payloadLen) bytes)", payloadStart..<min(d.count, end)))
        }
        return out
    }

    static func udp(_ d: [UInt8], _ o: Int, end: Int, ctx: Ctx, s: inout Summary) -> [PField] {
        guard d.count >= o + 8 else { return [] }
        s.protocols.insert("udp")
        let sp = UInt16(d.be16(o)), dp = UInt16(d.be16(o + 2))
        let len = d.be16(o + 4)
        s.srcPort = sp; s.dstPort = dp
        s.proto = "UDP"; s.category = .udp
        s.info = "\(sp) → \(dp) Len=\(max(0, len - 8))"
        let field = ctx.f("User Datagram Protocol, Src Port: \(sp), Dst Port: \(dp)", o..<(o + 8), [
            ctx.f("Source port: \(sp)\(Services.name(sp, tcp: false).map { " (\($0))" } ?? "")", o..<(o + 2)),
            ctx.f("Destination port: \(dp)\(Services.name(dp, tcp: false).map { " (\($0))" } ?? "")", (o + 2)..<(o + 4)),
            ctx.f("Length: \(len)", (o + 4)..<(o + 6)),
            ctx.f(String(format: "Checksum: 0x%04x", d.be16(o + 6)), (o + 6)..<(o + 8)),
        ])
        let ps = o + 8
        guard ps < d.count else { return [field] }
        let payload = Array(d[ps..<min(d.count, max(ps, end))])
        var out = [field]
        let ports = Set([sp, dp])
        if ports.contains(53) || ports.contains(5353) || ports.contains(5355) {
            if let f = dns(payload, base: ps, mdns: ports.contains(5353), ctx: ctx, s: &s) { out.append(f) }
        } else if ports.contains(443) || ports.contains(4433), let q = quic(payload, base: ps, ctx: ctx, s: &s) {
            out.append(q)
        } else if ports.contains(67) || ports.contains(68), let f = dhcp(payload, base: ps, ctx: ctx, s: &s) {
            out.append(f)
        } else if ports.contains(1900) || ports.contains(3702) {
            s.proto = ports.contains(1900) ? "SSDP" : "WS-Discovery"; s.protocols.insert("ssdp")
            let first = String(decoding: payload.prefix(120), as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            s.info = first
            out.append(ctx.f("\(s.proto): \(first)", ps..<min(d.count, end)))
        } else if ports.contains(123), payload.count >= 48 {
            s.proto = "NTP"; s.protocols.insert("ntp")
            let mode = payload[0] & 7
            s.info = "NTP \(["reserved", "symmetric active", "symmetric passive", "client", "server", "broadcast", "control", "private"][Int(mode)]), stratum \(payload[1])"
            out.append(ctx.f("Network Time Protocol: version \((payload[0] >> 3) & 7), mode \(mode), stratum \(payload[1])", ps..<min(d.count, end)))
        } else if ports.contains(41641) || ports.contains(51820) {
            s.proto = "WireGuard"; s.protocols.insert("wireguard")
            s.info = "WireGuard \(payload.first.map { ["?", "handshake init", "handshake response", "cookie", "transport data"][Int(min($0, 4))] } ?? "")"
        } else if ports.contains(3478) || ports.contains(19302) {
            s.proto = "STUN"; s.protocols.insert("stun")
            s.info = "STUN / TURN (NAT traversal)"
        } else if ports.contains(5351) {
            s.proto = "NAT-PMP"; s.protocols.insert("natpmp")
            s.info = "NAT-PMP / PCP op \(payload.count > 1 ? payload[1] : 0)"
        }
        return out
    }

    static func icmp(_ d: [UInt8], _ o: Int, end: Int, ctx: Ctx, s: inout Summary) -> [PField] {
        guard d.count >= o + 4 else { return [] }
        s.protocols.insert("icmp")
        s.proto = "ICMP"; s.category = .icmp
        let type = d[o], code = d[o + 1]
        let name: String
        switch type {
        case 0: name = "Echo (ping) reply"
        case 3: name = "Destination unreachable (\(["net", "host", "protocol", "port", "frag needed", "source route failed"][min(Int(code), 5)]))"
        case 5: name = "Redirect"
        case 8: name = "Echo (ping) request"
        case 11: name = "Time-to-live exceeded"
        default: name = "Type \(type) code \(code)"
        }
        var info = name
        if (type == 0 || type == 8), d.count >= o + 8 {
            info += String(format: "  id=0x%04x, seq=%d", d.be16(o + 4), d.be16(o + 6))
        }
        s.info = info
        return [ctx.f("Internet Control Message Protocol: \(name)", o..<min(d.count, end), [
            ctx.f("Type: \(type)", o..<(o + 1)),
            ctx.f("Code: \(code)", (o + 1)..<(o + 2)),
            ctx.f(String(format: "Checksum: 0x%04x", d.be16(o + 2)), (o + 2)..<(o + 4)),
        ])]
    }

    static func icmpv6(_ d: [UInt8], _ o: Int, end: Int, ctx: Ctx, s: inout Summary) -> [PField] {
        guard d.count >= o + 4 else { return [] }
        s.protocols.insert("icmpv6")
        s.proto = "ICMPv6"; s.category = .icmp
        let type = d[o]
        var name: String
        switch type {
        case 1: name = "Destination unreachable"
        case 2: name = "Packet too big (MTU \(d.be32(o + 4)))"
        case 3: name = "Time exceeded"
        case 128: name = "Echo (ping) request"
        case 129: name = "Echo (ping) reply"
        case 133: name = "Router Solicitation"
        case 134: name = "Router Advertisement"
        case 135: name = "Neighbor Solicitation for \(v6(d, o + 8))"
        case 136: name = "Neighbor Advertisement \(v6(d, o + 8))"
        case 143: name = "Multicast Listener Report v2"
        default: name = "Type \(type)"
        }
        if type == 134, d.count >= o + 16 {
            name += " (router lifetime \(d.be16(o + 6))s\(d[o + 5] & 0x80 != 0 ? ", managed" : "")\(d[o + 5] & 0x40 != 0 ? ", other config" : ""))"
        }
        s.info = name
        return [ctx.f("Internet Control Message Protocol v6: \(name)", o..<min(d.count, end), [
            ctx.f("Type: \(type)", o..<(o + 1)),
            ctx.f("Code: \(d[o + 1])", (o + 1)..<(o + 2)),
        ])]
    }

    // MARK: - application layer

    static func dns(_ p: [UInt8], base: Int, mdns: Bool, ctx: Ctx, s: inout Summary) -> PField? {
        guard p.count >= 12, let m = try? DNSMessage.parse(p) else { return nil }
        s.protocols.insert(mdns ? "mdns" : "dns")
        s.proto = mdns ? "mDNS" : "DNS"
        s.category = .dns
        let q = m.questions.first
        var info = (m.qr ? "Standard query response" : "Standard query") + String(format: " 0x%04x", m.id)
        if let q { info += " \(DNSType.name(q.type)) \(q.name)" }
        if m.qr {
            if m.rcode != 0 { info += " \(DNSRcode.name(m.rcode))" }
            for a in m.answers.prefix(3) { info += " \(a.typeName) \(a.data)" }
            if m.answers.count > 3 { info += " …" }
        }
        s.info = info
        guard ctx.detail else { return ctx.f("", nil) }
        var kids: [PField] = [
            ctx.f(String(format: "Transaction ID: 0x%04x", m.id), base..<(base + 2)),
            ctx.f("Flags: \(m.flagNames.joined(separator: " ")) \(DNSRcode.name(m.rcode))", (base + 2)..<(base + 4)),
        ]
        kids += m.questions.map { q in ctx.f("Query: \(q.name) type \(DNSType.name(q.type))", nil) }
        kids += m.answers.map { a in ctx.f("Answer: \(a.name) \(a.ttl) \(a.typeName) \(a.data)", nil) }
        kids += m.authority.map { a in ctx.f("Authority: \(a.name) \(a.typeName) \(a.data)", nil) }
        kids += m.additional.filter { !$0.isOPT }.map { a in ctx.f("Additional: \(a.name) \(a.typeName) \(a.data)", nil) }
        return ctx.f(mdns ? "Multicast Domain Name System" : "Domain Name System (\(m.qr ? "response" : "query"))", base..<(base + p.count), kids)
    }

    static func tls(_ p: [UInt8], base: Int, ctx: Ctx, s: inout Summary) -> PField? {
        guard p.count >= 5, [20, 21, 22, 23].contains(p[0]), p[1] == 3, p[2] <= 4 else { return nil }
        s.protocols.insert("tls")
        s.proto = "TLS"
        s.category = .tls
        let recLen = p.be16(3)
        var label: String
        var kids: [PField] = [
            ctx.f("Content type: \(["Change Cipher Spec", "Alert", "Handshake", "Application Data"][Int(p[0] - 20)]) (\(p[0]))", base..<(base + 1)),
            ctx.f(String(format: "Record version: 0x%04x", p.be16(1)), (base + 1)..<(base + 3)),
            ctx.f("Length: \(recLen)", (base + 3)..<(base + 5)),
        ]
        switch p[0] {
        case 20: label = "Change Cipher Spec"
        case 21: label = "Alert"
        case 23: label = "Application Data"
        default:
            let hs = p.count > 5 ? p[5] : 0
            switch hs {
            case 1:
                label = "Client Hello"
                let (sni, alpn, tls13, ckids) = clientHello(p, base: base, ctx: ctx)
                if let sni { label += " (SNI=\(sni))"; s.sni = sni }
                if !alpn.isEmpty { kids.append(ctx.f("ALPN: \(alpn.joined(separator: ", "))", nil)) }
                if tls13 { kids.append(ctx.f("Supported versions include TLS 1.3", nil)) }
                kids += ckids
            case 2:
                label = "Server Hello"
                if p.count > 44 {
                    let sidLen = Int(p[43])
                    let cs = p.be16(44 + sidLen)
                    let names: [Int: String] = [0x1301: "TLS_AES_128_GCM_SHA256", 0x1302: "TLS_AES_256_GCM_SHA384", 0x1303: "TLS_CHACHA20_POLY1305_SHA256",
                                                0xC02F: "ECDHE-RSA-AES128-GCM-SHA256", 0xC02B: "ECDHE-ECDSA-AES128-GCM-SHA256", 0xC030: "ECDHE-RSA-AES256-GCM-SHA384"]
                    label += " (\(names[cs] ?? String(format: "0x%04x", cs)))"
                }
            case 4: label = "New Session Ticket"
            case 11: label = "Certificate"
            case 12: label = "Server Key Exchange"
            case 16: label = "Client Key Exchange"
            default: label = "Handshake (encrypted or type \(hs))"
            }
        }
        s.info = label
        return ctx.f("Transport Layer Security: \(label)", base..<(base + min(p.count, recLen + 5)), kids)
    }

    static func clientHello(_ p: [UInt8], base: Int, ctx: Ctx) -> (String?, [String], Bool, [PField]) {
        // record(5) + handshake hdr(4) + version(2) + random(32)
        var i = 5 + 4 + 2 + 32
        guard i < p.count else { return (nil, [], false, []) }
        i += 1 + Int(p[i])                              // session id
        guard i + 2 <= p.count else { return (nil, [], false, []) }
        let csLen = p.be16(i)
        var kids: [PField] = [ctx.f("Cipher suites offered: \(csLen / 2)", (base + i)..<(base + i + 2 + csLen))]
        i += 2 + csLen
        guard i < p.count else { return (nil, [], false, kids) }
        i += 1 + Int(p[i])                              // compression
        guard i + 2 <= p.count else { return (nil, [], false, kids) }
        let extEnd = min(p.count, i + 2 + p.be16(i))
        i += 2
        var sni: String?
        var alpn: [String] = []
        var tls13 = false
        var extNames: [String] = []
        while i + 4 <= extEnd {
            let type = p.be16(i), len = p.be16(i + 2)
            let body = i + 4
            switch type {
            case 0x0000 where body + 5 <= p.count:
                let nameLen = p.be16(body + 3)
                if body + 5 + nameLen <= p.count {
                    sni = String(decoding: p[(body + 5)..<(body + 5 + nameLen)], as: UTF8.self)
                    kids.append(ctx.f("Server Name Indication: \(sni!)", (base + body + 5)..<(base + body + 5 + nameLen)))
                }
                extNames.append("server_name")
            case 0x0010:
                var j = body + 2
                while j < min(p.count, body + len) {
                    let l = Int(p[j])
                    if j + 1 + l <= p.count { alpn.append(String(decoding: p[(j + 1)..<(j + 1 + l)], as: UTF8.self)) }
                    j += 1 + l
                }
                extNames.append("alpn")
            case 0x002B:
                var j = body + 1
                while j + 1 < min(p.count, body + len) { if p.be16(j) == 0x0304 { tls13 = true }; j += 2 }
                extNames.append("supported_versions")
            case 0x0033: extNames.append("key_share")
            case 0x000A: extNames.append("supported_groups")
            case 0x000D: extNames.append("signature_algorithms")
            case 0xFE0D: extNames.append("encrypted_client_hello (ECH)")
            case 0x0029: extNames.append("pre_shared_key")
            default: extNames.append(String(format: "0x%04x", type))
            }
            i = body + len
        }
        kids.append(ctx.f("Extensions: \(extNames.joined(separator: ", "))", nil))
        return (sni, alpn, tls13, kids)
    }

    static func quic(_ p: [UInt8], base: Int, ctx: Ctx, s: inout Summary) -> PField? {
        guard let b0 = p.first else { return nil }
        s.protocols.insert("quic")
        s.proto = "QUIC"
        s.category = .quic
        if b0 & 0x80 != 0, p.count >= 7 {
            let version = p.be32(1)
            let types = ["Initial", "0-RTT", "Handshake", "Retry"]
            let t = version == 0 ? "Version Negotiation" : types[Int((b0 & 0x30) >> 4)]
            let dcidLen = Int(p[5])
            let dcid = p.count >= 6 + dcidLen ? p[6..<(6 + dcidLen)].map { String(format: "%02x", $0) }.joined() : ""
            let v = version == 1 ? "v1" : version == 0x6b3343cf ? "v2" : String(format: "0x%08x", version)
            s.info = "\(t), DCID=\(dcid.prefix(16)), \(v)"
            return ctx.f("QUIC IETF: long header, \(t)", base..<(base + p.count), [
                ctx.f(String(format: "Version: %@ (0x%08x)", v, version), (base + 1)..<(base + 5)),
                ctx.f("Destination connection ID: \(dcid)", (base + 6)..<(base + 6 + dcidLen)),
            ])
        }
        if b0 & 0x40 != 0 {
            s.info = "Protected Payload (1-RTT), \(p.count) bytes"
            return ctx.f("QUIC IETF: short header (1-RTT, encrypted)", base..<(base + p.count))
        }
        return nil
    }

    static func looksLikeHTTP(_ p: [UInt8]) -> Bool {
        guard p.count >= 4 else { return false }
        let start = String(decoding: p.prefix(8), as: UTF8.self)
        return ["GET ", "POST", "PUT ", "HEAD", "DELE", "OPTI", "PATC", "HTTP"].contains { start.hasPrefix($0) }
    }

    static func http(_ p: [UInt8], base: Int, ctx: Ctx, s: inout Summary) -> PField? {
        guard looksLikeHTTP(p) else { return nil }
        s.protocols.insert("http")
        s.proto = "HTTP"
        s.category = .http
        let text = String(decoding: p.prefix(2048), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        s.info = lines.first ?? ""
        let headers = lines.dropFirst().prefix { !$0.isEmpty }.prefix(20).map { ctx.f($0, nil) }
        return ctx.f("Hypertext Transfer Protocol: \(lines.first ?? "")", base..<(base + p.count), Array(headers))
    }

    static func dhcp(_ p: [UInt8], base: Int, ctx: Ctx, s: inout Summary) -> PField? {
        guard p.count >= 240, p.be32(236) == 0x63825363 else { return nil }
        s.protocols.insert("dhcp")
        s.proto = "DHCP"
        s.category = .udp
        var i = 240
        var type = "?"
        var hostname: String?
        var kids: [PField] = [
            ctx.f(String(format: "Transaction ID: 0x%08x", p.be32(4)), (base + 4)..<(base + 8)),
            ctx.f("Client MAC: \(mac(p, 28))", (base + 28)..<(base + 34)),
            ctx.f("Your IP: \(v4(p, 16))", (base + 16)..<(base + 20)),
        ]
        while i + 2 <= p.count, p[i] != 255 {
            let code = p[i]
            if code == 0 { i += 1; continue }
            let len = Int(p[i + 1])
            let v = Array(p[min(p.count, i + 2)..<min(p.count, i + 2 + len)])
            switch code {
            case 53: type = ["?", "Discover", "Offer", "Request", "Decline", "ACK", "NAK", "Release", "Inform"][Int(min(v.first ?? 0, 8))]
            case 12: hostname = String(decoding: v, as: UTF8.self)
            case 50 where v.count == 4: kids.append(ctx.f("Requested IP: \(v4(v, 0))", nil))
            case 51 where v.count == 4: kids.append(ctx.f("Lease time: \(v.be32(0)) s", nil))
            case 54 where v.count == 4: kids.append(ctx.f("Server identifier: \(v4(v, 0))", nil))
            default: break
            }
            i += 2 + len
        }
        s.info = "DHCP \(type)" + (hostname.map { " — \($0)" } ?? "") + String(format: " — xid 0x%08x", p.be32(4))
        return ctx.f("Dynamic Host Configuration Protocol (\(type))", base..<(base + p.count), kids)
    }
}

// MARK: - Display filters

/// A small Wireshark-flavoured filter language:
///   tcp · udp · dns · tls · quic · http · arp · icmp · ipv6 · mdns · dhcp
///   host 1.2.3.4 · ip.addr == x · ip.src == x · ip.dst == x · port 443 · tcp.port == 443
///   syn · rst · sni contains openai
///   combine with and / or / not (&&, ||, !), anything else is a text match
struct PacketFilter {
    let expression: String

    func matches(_ r: PacketRow) -> Bool {
        let e = expression.trimmed.lowercased()
        guard !e.isEmpty else { return true }
        return evalOr(e, r)
    }

    private func evalOr(_ e: String, _ r: PacketRow) -> Bool {
        e.replacingOccurrences(of: "||", with: " or ").components(separatedBy: " or ").contains { evalAnd($0, r) }
    }

    private func evalAnd(_ e: String, _ r: PacketRow) -> Bool {
        e.replacingOccurrences(of: "&&", with: " and ").components(separatedBy: " and ").allSatisfy { term($0.trimmed, r) }
    }

    private func term(_ t: String, _ r: PacketRow) -> Bool {
        if t.hasPrefix("not ") { return !term(String(t.dropFirst(4)).trimmed, r) }
        if t.hasPrefix("!") { return !term(String(t.dropFirst()).trimmed, r) }
        if t.isEmpty { return true }
        let parts = t.components(separatedBy: " ").filter { !$0.isEmpty }
        func value() -> String { parts.last ?? "" }
        if parts.first == "host" || t.hasPrefix("ip.addr") { return r.src == value() || r.dst == value() }
        if t.hasPrefix("ip.src") { return r.src == value() }
        if t.hasPrefix("ip.dst") { return r.dst == value() }
        if parts.first == "port" || t.hasPrefix("tcp.port") || t.hasPrefix("udp.port") {
            guard let p = UInt16(value()) else { return false }
            let protoOK = t.hasPrefix("tcp.") ? r.protocols.contains("tcp") : t.hasPrefix("udp.") ? r.protocols.contains("udp") : true
            return protoOK && (r.srcPort == p || r.dstPort == p)
        }
        if t.hasPrefix("sni") { return r.sni?.lowercased().contains(value()) ?? false }
        if t == "syn" { return r.info.contains("SYN") }
        if t == "rst" { return r.info.contains("RST") }
        if t == "ip" { return r.protocols.contains("ip") }
        let known: Set<String> = ["tcp", "udp", "dns", "tls", "quic", "http", "arp", "icmp", "icmpv6", "ipv6", "mdns", "dhcp", "ssdp", "ntp", "eth", "wireguard", "stun", "ssh", "igmp", "esp"]
        if known.contains(t) { return r.protocols.contains(t) || (t == "icmp" && r.protocols.contains("icmpv6")) }
        return r.info.lowercased().contains(t) || r.src.lowercased().contains(t) || r.dst.lowercased().contains(t) || r.proto.lowercased() == t
    }
}
