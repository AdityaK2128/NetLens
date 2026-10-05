import Foundation
import Darwin

enum PublicIP {
    static func fetch(v6: Bool) async -> String? {
        let url = URL(string: v6 ? "https://api6.ipify.org" : "https://api.ipify.org")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmed
        return IP.isIP(s) ? s : nil
    }

    /// NAT-PMP (RFC 6886) "external address" request to the default gateway.
    /// If the router answers, we learn its WAN address — the key to spotting CGNAT.
    static func natPMPExternalAddress(gateway: String) async -> Result<String, NATPMPError> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: natPMPSync(gateway: gateway))
            }
        }
    }

    enum NATPMPError: Error, CustomStringConvertible {
        case noSocket, noResponse, refused(UInt16), malformed
        var description: String {
            switch self {
            case .noSocket: "socket error"
            case .noResponse: "router did not answer (NAT-PMP disabled or unsupported)"
            case .refused(let c): "router refused (result code \(c))"
            case .malformed: "malformed response"
            }
        }
    }

    private static func natPMPSync(gateway: String) -> Result<String, NATPMPError> {
        guard IP.isV4(gateway), let (storage, len) = SockAddr.make(gateway, port: 5351) else { return .failure(.noSocket) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .failure(.noSocket) }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 600_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let req: [UInt8] = [0, 0]
        var st = storage
        for _ in 0..<3 {
            _ = withUnsafePointer(to: &st) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, req, 2, 0, $0, len) }
            }
            var buf = [UInt8](repeating: 0, count: 64)
            let n = recv(fd, &buf, buf.count, 0)
            if n >= 12 {
                guard buf[0] == 0, buf[1] == 128 else { return .failure(.malformed) }
                let code = UInt16(buf[2]) << 8 | UInt16(buf[3])
                guard code == 0 else { return .failure(.refused(code)) }
                return .success("\(buf[8]).\(buf[9]).\(buf[10]).\(buf[11])")
            }
        }
        return .failure(.noResponse)
    }
}

/// Where does NAT happen on the way out? Combines several independent signals and
/// reports evidence rather than a single guess.
struct NATAnalysis: Equatable {
    enum Verdict: String {
        case none = "No NAT — public address on this Mac"
        case single = "Single NAT (home router)"
        case cgnat = "Carrier-grade NAT (CGNAT)"
        case likelyCGNAT = "Likely carrier-grade NAT"
        case double = "Double NAT"
        case vpn = "VPN tunnel — traffic exits elsewhere"
        case unknown = "Undetermined"
    }
    var verdict: Verdict = .unknown
    var evidence: [String] = []
    var wanAddress: String?

    static func analyse(localIP: String?, gateway: String?, publicIP: String?, natPMP: String?,
                        earlyHops: [String], viaTunnel: Bool) -> NATAnalysis {
        var a = NATAnalysis()
        a.wanAddress = natPMP
        if viaTunnel {
            a.verdict = .vpn
            a.evidence.append("Default route goes through a tunnel interface; the public IP belongs to the VPN exit.")
        }
        if let localIP, let publicIP, IP.stripScope(localIP) == publicIP {
            a.verdict = .none
            a.evidence.append("This Mac's own address \(localIP) is the public address.")
            return a
        }
        if let local = localIP {
            a.evidence.append("This Mac uses \(IP.scope(local).rawValue.lowercased()) address \(local) → translated before reaching the Internet.")
        }
        if let wan = natPMP {
            let scope = IP.scope(wan)
            a.evidence.append("Router reports WAN address \(wan) via NAT-PMP (\(scope.rawValue)).")
            if !viaTunnel {
                switch scope {
                case .cgnat:
                    a.verdict = .cgnat
                    a.evidence.append("\(wan) is in 100.64.0.0/10 — space reserved for ISP carrier-grade NAT (RFC 6598).")
                case .privateNet:
                    a.verdict = .double
                    a.evidence.append("The router's WAN side is itself a private address — another NAT sits upstream.")
                case .global:
                    if let pub = publicIP, pub != wan {
                        a.verdict = .likelyCGNAT
                        a.evidence.append("Router's WAN \(wan) differs from the address the Internet sees (\(pub)) — something upstream translates again.")
                    } else {
                        a.verdict = .single
                        a.evidence.append("Router's WAN address matches your public IP — one layer of NAT, at your router.")
                    }
                default: break
                }
            }
        } else if !viaTunnel {
            a.evidence.append("Router did not answer NAT-PMP; falling back to path heuristics.")
        }

        // Path heuristics: addresses seen on the first hops past the gateway.
        let beyond = earlyHops.drop { $0 == gateway }.prefix(4)
        if let cg = beyond.first(where: { IP.scope($0) == .cgnat }) {
            a.evidence.append("Hop \(cg) on the way out is in 100.64.0.0/10 (CGNAT range).")
            if a.verdict == .unknown || a.verdict == .single { a.verdict = .likelyCGNAT }
        } else if let firstBeyond = beyond.first, IP.scope(firstBeyond) == .privateNet, a.verdict == .unknown {
            a.evidence.append("The first hop past your router (\(firstBeyond)) is private — either double NAT or an ISP using private addressing internally.")
        } else if let firstBeyond = beyond.first, IP.isGlobal(firstBeyond), a.verdict == .unknown {
            a.verdict = .single
            a.evidence.append("The first hop past your router (\(firstBeyond)) is public — consistent with a single NAT at the router.")
        }
        return a
    }
}
