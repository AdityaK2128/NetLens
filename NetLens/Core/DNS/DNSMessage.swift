import Foundation
import Darwin

/// RFC 1035 wire format (+ EDNS0, DNSSEC and SVCB/HTTPS record types).
enum DNSType: UInt16, CaseIterable, Identifiable {
    case A = 1, NS = 2, CNAME = 5, SOA = 6, PTR = 12, HINFO = 13, MX = 15, TXT = 16, AAAA = 28, LOC = 29,
         SRV = 33, NAPTR = 35, CERT = 37, DNAME = 39, OPT = 41, DS = 43, SSHFP = 44, RRSIG = 46, NSEC = 47,
         DNSKEY = 48, NSEC3 = 50, NSEC3PARAM = 51, TLSA = 52, CDS = 59, CDNSKEY = 60, SVCB = 64, HTTPS = 65,
         ANY = 255, CAA = 257

    var id: UInt16 { rawValue }
    var name: String { "\(self)" }

    static let common: [DNSType] = [.A, .AAAA, .CNAME, .MX, .TXT, .NS, .SOA, .HTTPS, .SVCB, .CAA, .SRV, .PTR, .DS, .DNSKEY, .TLSA, .ANY]

    static func name(_ v: UInt16) -> String { DNSType(rawValue: v)?.name ?? "TYPE\(v)" }
}

enum DNSRcode {
    static func name(_ v: Int) -> String {
        switch v {
        case 0: "NOERROR"; case 1: "FORMERR"; case 2: "SERVFAIL"; case 3: "NXDOMAIN"; case 4: "NOTIMP"
        case 5: "REFUSED"; case 6: "YXDOMAIN"; case 7: "YXRRSET"; case 8: "NXRRSET"; case 9: "NOTAUTH"
        case 10: "NOTZONE"; case 16: "BADVERS"; default: "RCODE\(v)"
        }
    }
    static func meaning(_ v: Int) -> String {
        switch v {
        case 0: "Success"
        case 1: "The server couldn't parse the query"
        case 2: "The resolver failed (often a DNSSEC validation failure or unreachable authoritative servers)"
        case 3: "The name does not exist"
        case 4: "Query type not implemented by this server"
        case 5: "The server refused to answer (policy / not a recursive resolver for you)"
        default: ""
        }
    }
}

struct DNSRecord: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let type: UInt16
    let cls: UInt16
    let ttl: UInt32
    let rdata: [UInt8]
    let data: String

    var typeName: String { DNSType.name(type) }
    var isOPT: Bool { type == DNSType.OPT.rawValue }
}

struct DNSMessage {
    var id: UInt16 = 0
    var qr = false, opcode = 0, aa = false, tc = false, rd = true, ra = false, ad = false, cd = false
    var rcode = 0
    var questions: [(name: String, type: UInt16, cls: UInt16)] = []
    var answers: [DNSRecord] = []
    var authority: [DNSRecord] = []
    var additional: [DNSRecord] = []
    // EDNS
    var ednsPresent = false
    var ednsUDPSize: UInt16 = 0
    var ednsDO = false
    var ednsVersion = 0
    var ednsOptions: [String] = []

    var flagNames: [String] {
        var f: [String] = []
        if qr { f.append("qr") }
        if aa { f.append("aa") }
        if tc { f.append("tc") }
        if rd { f.append("rd") }
        if ra { f.append("ra") }
        if ad { f.append("ad") }
        if cd { f.append("cd") }
        return f
    }

    // MARK: build

    static func query(name: String, type: UInt16, id: UInt16 = UInt16.random(in: 0...UInt16.max),
                      recursionDesired: Bool = true, dnssecOK: Bool = false, checkingDisabled: Bool = false,
                      edns: Bool = true) -> [UInt8] {
        var b: [UInt8] = []
        b += [UInt8(id >> 8), UInt8(id & 0xFF)]
        var flags: UInt16 = 0
        if recursionDesired { flags |= 0x0100 }
        if checkingDisabled { flags |= 0x0010 }
        if dnssecOK { flags |= 0x0020 }   // AD bit in query: "I understand AD"
        b += [UInt8(flags >> 8), UInt8(flags & 0xFF)]
        b += [0, 1, 0, 0, 0, 0, 0, edns ? 1 : 0]
        b += encodeName(name)
        b += [UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
        if edns {
            // OPT RR: root name, type 41, class = UDP payload size, TTL = extRcode|version|DO|Z
            b += [0, 0, 41, 0x04, 0xD0]          // 1232 bytes (DNS flag day 2020)
            b += [0, 0, dnssecOK ? 0x80 : 0, 0]
            b += [0, 0]                          // no options
        }
        return b
    }

    static func encodeName(_ name: String) -> [UInt8] {
        var out: [UInt8] = []
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        if !trimmed.isEmpty {
            for label in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
                let bytes = Array(label.utf8.prefix(63))
                out.append(UInt8(bytes.count))
                out += bytes
            }
        }
        out.append(0)
        return out
    }

    // MARK: parse

    enum ParseError: Error { case truncated, badPointer }

    static func parse(_ data: [UInt8]) throws -> DNSMessage {
        var r = Reader(data: data)
        var m = DNSMessage()
        m.id = try r.u16()
        let flags = try r.u16()
        m.qr = flags & 0x8000 != 0
        m.opcode = Int((flags >> 11) & 0xF)
        m.aa = flags & 0x0400 != 0
        m.tc = flags & 0x0200 != 0
        m.rd = flags & 0x0100 != 0
        m.ra = flags & 0x0080 != 0
        m.ad = flags & 0x0020 != 0
        m.cd = flags & 0x0010 != 0
        m.rcode = Int(flags & 0xF)
        let qd = try r.u16(), an = try r.u16(), ns = try r.u16(), ar = try r.u16()
        for _ in 0..<qd {
            let n = try r.name()
            m.questions.append((n, try r.u16(), try r.u16()))
        }
        func records(_ count: UInt16) throws -> [DNSRecord] {
            var out: [DNSRecord] = []
            for _ in 0..<count {
                let name = try r.name()
                let type = try r.u16()
                let cls = try r.u16()
                let ttl = try r.u32()
                let len = Int(try r.u16())
                let start = r.pos
                guard start + len <= data.count else { throw ParseError.truncated }
                let rdata = Array(data[start..<start + len])
                let text = format(type: type, rdata: rdata, message: data, offset: start)
                out.append(DNSRecord(name: name, type: type, cls: cls, ttl: ttl, rdata: rdata, data: text))
                r.pos = start + len
            }
            return out
        }
        m.answers = try records(an)
        m.authority = try records(ns)
        m.additional = try records(ar)
        if let opt = m.additional.first(where: \.isOPT) {
            m.ednsPresent = true
            m.ednsUDPSize = opt.cls
            m.ednsDO = (opt.ttl >> 15) & 1 == 1
            m.ednsVersion = Int((opt.ttl >> 16) & 0xFF)
            m.rcode |= Int(opt.ttl >> 24) << 4
            m.ednsOptions = parseEDNSOptions(opt.rdata)
        }
        return m
    }

    struct Reader {
        let data: [UInt8]
        var pos = 0
        mutating func u8() throws -> UInt8 {
            guard pos < data.count else { throw ParseError.truncated }
            defer { pos += 1 }
            return data[pos]
        }
        mutating func u16() throws -> UInt16 { UInt16(try u8()) << 8 | UInt16(try u8()) }
        mutating func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }
        mutating func name() throws -> String {
            let (n, next) = try DNSMessage.readName(data, at: pos)
            pos = next
            return n
        }
    }

    /// Reads a (possibly compressed) domain name. Returns name and the offset after it.
    static func readName(_ data: [UInt8], at start: Int) throws -> (String, Int) {
        var labels: [String] = []
        var pos = start
        var jumped = false
        var after = start
        var hops = 0
        while true {
            guard pos < data.count else { throw ParseError.truncated }
            let len = Int(data[pos])
            if len == 0 {
                if !jumped { after = pos + 1 }
                break
            }
            if len & 0xC0 == 0xC0 {
                guard pos + 1 < data.count else { throw ParseError.truncated }
                let ptr = (len & 0x3F) << 8 | Int(data[pos + 1])
                if !jumped { after = pos + 2 }
                jumped = true
                hops += 1
                guard hops < 64, ptr < data.count else { throw ParseError.badPointer }
                pos = ptr
                continue
            }
            guard pos + 1 + len <= data.count else { throw ParseError.truncated }
            let bytes = data[(pos + 1)..<(pos + 1 + len)]
            labels.append(String(decoding: bytes, as: UTF8.self))
            pos += 1 + len
        }
        return (labels.isEmpty ? "." : labels.joined(separator: ".") + ".", after)
    }

    // MARK: rdata formatting (dig-style presentation)

    static func format(type: UInt16, rdata d: [UInt8], message: [UInt8], offset: Int) -> String {
        func name(at rel: Int) -> (String, Int) {
            (try? readName(message, at: offset + rel)).map { ($0.0, $0.1 - offset) } ?? ("?", d.count)
        }
        func u16(_ i: Int) -> Int { i + 1 < d.count ? Int(d[i]) << 8 | Int(d[i + 1]) : 0 }
        func u32(_ i: Int) -> UInt32 { i + 3 < d.count ? UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3]) : 0 }
        func hex(_ s: ArraySlice<UInt8>) -> String { s.map { String(format: "%02X", $0) }.joined() }
        func b64(_ s: ArraySlice<UInt8>) -> String { Data(s).base64EncodedString() }

        switch DNSType(rawValue: type) {
        case .A where d.count == 4:
            return d.map(String.init).joined(separator: ".")
        case .AAAA where d.count == 16:
            var a = in6_addr()
            withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: d) }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count))
            return String(cString: buf)
        case .NS, .CNAME, .PTR, .DNAME:
            return name(at: 0).0
        case .MX:
            return "\(u16(0)) \(name(at: 2).0)"
        case .TXT:
            var parts: [String] = []
            var i = 0
            while i < d.count {
                let l = Int(d[i])
                let end = min(d.count, i + 1 + l)
                parts.append("\"" + String(decoding: d[(i + 1)..<end], as: UTF8.self) + "\"")
                i = end
            }
            return parts.joined(separator: " ")
        case .SOA:
            let (mname, n1) = name(at: 0)
            let (rname, n2) = name(at: n1)
            return "\(mname) \(rname) \(u32(n2)) \(u32(n2 + 4)) \(u32(n2 + 8)) \(u32(n2 + 12)) \(u32(n2 + 16))"
        case .SRV:
            return "\(u16(0)) \(u16(2)) \(u16(4)) \(name(at: 6).0)"
        case .CAA where d.count >= 2:
            let tagLen = Int(d[1])
            let tag = String(decoding: d[2..<min(d.count, 2 + tagLen)], as: UTF8.self)
            let value = String(decoding: d[min(d.count, 2 + tagLen)...], as: UTF8.self)
            return "\(d[0]) \(tag) \"\(value)\""
        case .DS, .CDS:
            guard d.count >= 4 else { break }
            return "\(u16(0)) \(d[2]) \(d[3]) \(hex(d[4...]))"
        case .DNSKEY, .CDNSKEY:
            guard d.count >= 4 else { break }
            let flags = u16(0)
            let role = flags & 1 == 1 ? "KSK" : "ZSK"
            return "\(flags) \(d[2]) \(d[3]) \(b64(d[4...]).prefix(44))… ; \(role), alg \(dnssecAlg(d[3])), keytag \(keyTag(d))"
        case .RRSIG:
            guard d.count >= 18 else { break }
            let (signer, n) = name(at: 18)
            let exp = Date(timeIntervalSince1970: TimeInterval(u32(8)))
            let inc = Date(timeIntervalSince1970: TimeInterval(u32(12)))
            let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss"; f.timeZone = TimeZone(identifier: "UTC")
            return "\(DNSType.name(UInt16(u16(0)))) \(d[2]) \(d[3]) \(u32(4)) \(f.string(from: exp)) \(f.string(from: inc)) \(u16(16)) \(signer) \(b64(d[n...]).prefix(32))…"
        case .NSEC:
            let (next, n) = name(at: 0)
            return "\(next) \(typeBitmap(Array(d[n...])).joined(separator: " "))"
        case .TLSA where d.count >= 3:
            return "\(d[0]) \(d[1]) \(d[2]) \(hex(d[3...]))"
        case .SSHFP where d.count >= 2:
            return "\(d[0]) \(d[1]) \(hex(d[2...]))"
        case .SVCB, .HTTPS:
            return formatSVCB(d, name: name)
        case .HINFO:
            return String(decoding: d, as: UTF8.self)
        default:
            break
        }
        return "\\# \(d.count) \(hex(d[...]))"
    }

    static func formatSVCB(_ d: [UInt8], name: (Int) -> (String, Int)) -> String {
        guard d.count >= 3 else { return "" }
        let prio = Int(d[0]) << 8 | Int(d[1])
        let (target, n) = name(2)
        var parts = ["\(prio)", target]
        var i = n
        while i + 4 <= d.count {
            let key = Int(d[i]) << 8 | Int(d[i + 1])
            let len = Int(d[i + 2]) << 8 | Int(d[i + 3])
            let v = Array(d[min(d.count, i + 4)..<min(d.count, i + 4 + len)])
            i += 4 + len
            switch key {
            case 1:
                var alpns: [String] = []
                var j = 0
                while j < v.count { let l = Int(v[j]); alpns.append(String(decoding: v[(j + 1)..<min(v.count, j + 1 + l)], as: UTF8.self)); j += 1 + l }
                parts.append("alpn=\(alpns.joined(separator: ","))")
            case 2: parts.append("no-default-alpn")
            case 3 where v.count == 2: parts.append("port=\(Int(v[0]) << 8 | Int(v[1]))")
            case 4:
                parts.append("ipv4hint=" + stride(from: 0, to: v.count - 3, by: 4).map { "\(v[$0]).\(v[$0 + 1]).\(v[$0 + 2]).\(v[$0 + 3])" }.joined(separator: ","))
            case 5: parts.append("ech=\(Data(v).base64EncodedString().prefix(24))…")
            case 6:
                parts.append("ipv6hint=" + stride(from: 0, to: v.count - 15, by: 16).map { o -> String in
                    var a = in6_addr()
                    withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: v[o..<o + 16]) }
                    var buf = [CChar](repeating: 0, count: 64)
                    inet_ntop(AF_INET6, &a, &buf, 64)
                    return String(cString: buf)
                }.joined(separator: ","))
            default: parts.append("key\(key)=\(v.count)b")
            }
        }
        return parts.joined(separator: " ")
    }

    static func typeBitmap(_ d: [UInt8]) -> [String] {
        var types: [String] = []
        var i = 0
        while i + 2 <= d.count {
            let window = Int(d[i]), len = Int(d[i + 1])
            for b in 0..<len where i + 2 + b < d.count {
                let byte = d[i + 2 + b]
                for bit in 0..<8 where byte & (0x80 >> bit) != 0 {
                    types.append(DNSType.name(UInt16(window * 256 + b * 8 + bit)))
                }
            }
            i += 2 + len
        }
        return types
    }

    static func dnssecAlg(_ a: UInt8) -> String {
        switch a {
        case 5: "RSASHA1"; case 7: "RSASHA1-NSEC3"; case 8: "RSASHA256"; case 10: "RSASHA512"
        case 13: "ECDSAP256SHA256"; case 14: "ECDSAP384SHA384"; case 15: "ED25519"; case 16: "ED448"
        default: "\(a)"
        }
    }

    /// RFC 4034 Appendix B key tag.
    static func keyTag(_ rdata: [UInt8]) -> Int {
        var ac: UInt32 = 0
        for (i, b) in rdata.enumerated() { ac += (i & 1) == 1 ? UInt32(b) : UInt32(b) << 8 }
        ac += (ac >> 16) & 0xFFFF
        return Int(ac & 0xFFFF)
    }

    static func parseEDNSOptions(_ d: [UInt8]) -> [String] {
        var out: [String] = []
        var i = 0
        while i + 4 <= d.count {
            let code = Int(d[i]) << 8 | Int(d[i + 1])
            let len = Int(d[i + 2]) << 8 | Int(d[i + 3])
            let v = Array(d[min(d.count, i + 4)..<min(d.count, i + 4 + len)])
            i += 4 + len
            switch code {
            case 3: out.append("NSID: \(String(decoding: v, as: UTF8.self))")
            case 8 where v.count >= 4:
                out.append("Client subnet: family \(Int(v[0]) << 8 | Int(v[1])), /\(v[2]) scope /\(v[3])")
            case 10: out.append("Cookie: \(v.prefix(8).map { String(format: "%02x", $0) }.joined())…")
            case 12: out.append("Padding: \(len) bytes")
            case 15 where v.count >= 2:
                let info = Int(v[0]) << 8 | Int(v[1])
                let text = String(decoding: v.dropFirst(2), as: UTF8.self)
                out.append("Extended error \(info)\(text.isEmpty ? "" : ": \(text)")")
            default: out.append("Option \(code) (\(len) bytes)")
            }
        }
        return out
    }

    // MARK: dig-style text

    func digText(server: String, transport: String, elapsedMs: Double, size: Int) -> String {
        var s = ";; ->>HEADER<<- opcode: \(opcode == 0 ? "QUERY" : String(opcode)), status: \(DNSRcode.name(rcode)), id: \(id)\n"
        s += ";; flags: \(flagNames.joined(separator: " ")); QUERY: \(questions.count), ANSWER: \(answers.count), AUTHORITY: \(authority.count), ADDITIONAL: \(additional.count)\n"
        if ednsPresent {
            s += "\n;; OPT PSEUDOSECTION:\n; EDNS: version: \(ednsVersion), flags:\(ednsDO ? " do" : ""); udp: \(ednsUDPSize)\n"
            for o in ednsOptions { s += "; \(o)\n" }
        }
        s += "\n;; QUESTION SECTION:\n"
        for q in questions { s += ";\(q.name)\t\tIN\t\(DNSType.name(q.type))\n" }
        func section(_ title: String, _ rs: [DNSRecord]) {
            let rows = rs.filter { !$0.isOPT }
            guard !rows.isEmpty else { return }
            s += "\n;; \(title) SECTION:\n"
            for r in rows { s += "\(r.name)\t\(r.ttl)\tIN\t\(r.typeName)\t\(r.data)\n" }
        }
        section("ANSWER", answers)
        section("AUTHORITY", authority)
        section("ADDITIONAL", additional)
        s += "\n;; Query time: \(String(format: "%.1f", elapsedMs)) msec\n;; SERVER: \(server) (\(transport))\n;; WHEN: \(Date())\n;; MSG SIZE  rcvd: \(size)\n"
        return s
    }
}
