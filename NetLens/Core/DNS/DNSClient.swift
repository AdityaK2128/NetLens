import Foundation
import Network
import Darwin

enum DNSTransport: String, CaseIterable, Identifiable {
    case udp = "UDP", tcp = "TCP", dot = "DoT", doh = "DoH"
    var id: String { rawValue }
}

struct DNSServer: Hashable, Identifiable {
    var id: String { name + address }
    let name: String
    let address: String
    var dohURL: String? = nil
    var dotHost: String? = nil

    func supports(_ t: DNSTransport) -> Bool {
        switch t {
        case .udp, .tcp: true
        case .doh: dohURL != nil
        case .dot: dotHost != nil
        }
    }

    static let wellKnown: [DNSServer] = [
        DNSServer(name: "Cloudflare", address: "1.1.1.1", dohURL: "https://cloudflare-dns.com/dns-query", dotHost: "cloudflare-dns.com"),
        DNSServer(name: "Google", address: "8.8.8.8", dohURL: "https://dns.google/dns-query", dotHost: "dns.google"),
        DNSServer(name: "Quad9", address: "9.9.9.9", dohURL: "https://dns.quad9.net/dns-query", dotHost: "dns.quad9.net"),
        DNSServer(name: "OpenDNS", address: "208.67.222.222", dohURL: "https://doh.opendns.com/dns-query"),
        DNSServer(name: "AdGuard", address: "94.140.14.14", dohURL: "https://dns.adguard-dns.com/dns-query", dotHost: "dns.adguard-dns.com"),
    ]
}

struct DNSResult: Identifiable {
    let id = UUID()
    let server: DNSServer
    let transport: DNSTransport
    var message: DNSMessage?
    var error: String?
    var elapsedMs: Double = 0
    var size = 0
    var fellBackToTCP = false
}

enum DNSClient {
    static func query(_ name: String, type: UInt16, server: DNSServer, transport: DNSTransport,
                      dnssec: Bool = false, recursion: Bool = true, timeout: TimeInterval = 4) async -> DNSResult {
        let q = DNSMessage.query(name: name, type: type, recursionDesired: recursion, dnssecOK: dnssec)
        var result = DNSResult(server: server, transport: transport)
        let t0 = monotonicNanos()
        let raw: Result<[UInt8], Error>
        switch transport {
        case .udp: raw = await udp(q, to: server.address, timeout: timeout)
        case .tcp: raw = await stream(q, host: server.address, port: 53, tls: nil, timeout: timeout)
        case .dot: raw = await stream(q, host: server.address, port: 853, tls: server.dotHost ?? server.address, timeout: timeout)
        case .doh: raw = await doh(q, url: server.dohURL ?? "", timeout: timeout)
        }
        result.elapsedMs = Double(monotonicNanos() - t0) / 1_000_000
        switch raw {
        case .success(let bytes):
            result.size = bytes.count
            do {
                let m = try DNSMessage.parse(bytes)
                if m.tc && transport == .udp {
                    // Truncated: retry over TCP like a real resolver.
                    var r = await query(name, type: type, server: server, transport: .tcp, dnssec: dnssec, recursion: recursion, timeout: timeout)
                    r.fellBackToTCP = true
                    return r
                }
                result.message = m
            } catch {
                result.error = "Malformed response (\(bytes.count) bytes)"
            }
        case .failure(let e):
            result.error = (e as? DNSClientError)?.description ?? e.localizedDescription
        }
        return result
    }

    enum DNSClientError: Error, CustomStringConvertible {
        case timeout, socket, badURL, http(Int)
        var description: String {
            switch self {
            case .timeout: "Timed out"
            case .socket: "Socket error"
            case .badURL: "Bad DoH URL"
            case .http(let c): "HTTP \(c)"
            }
        }
    }

    // MARK: UDP (BSD socket — simplest path with precise timing)

    static func udp(_ q: [UInt8], to address: String, port: UInt16 = 53, timeout: TimeInterval) async -> Result<[UInt8], Error> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let (storage, len) = SockAddr.make(address, port: port) else { cont.resume(returning: .failure(DNSClientError.socket)); return }
                let fd = socket(IP.isV6(address) ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard fd >= 0 else { cont.resume(returning: .failure(DNSClientError.socket)); return }
                defer { close(fd) }
                var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var st = storage
                let sent = withUnsafePointer(to: &st) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, q, q.count, 0, $0, len) }
                }
                guard sent == q.count else { cont.resume(returning: .failure(DNSClientError.socket)); return }
                var buf = [UInt8](repeating: 0, count: 65535)
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    let n = recv(fd, &buf, buf.count, 0)
                    if n <= 0 { break }
                    // ignore stray datagrams with the wrong id
                    if n >= 2, buf[0] == q[0], buf[1] == q[1] {
                        cont.resume(returning: .success(Array(buf[0..<n])))
                        return
                    }
                }
                cont.resume(returning: .failure(DNSClientError.timeout))
            }
        }
    }

    // MARK: TCP / TLS (Network.framework)

    static func stream(_ q: [UInt8], host: String, port: UInt16, tls serverName: String?, timeout: TimeInterval) async -> Result<[UInt8], Error> {
        let params: NWParameters
        if let serverName {
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, serverName)
            sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, "dot")
            params = NWParameters(tls: tlsOptions)
        } else {
            params = .tcp
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        return await withCheckedContinuation { cont in
            let lock = NSLock()
            var finished = false
            func finish(_ r: Result<[UInt8], Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                conn.cancel()
                cont.resume(returning: r)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var framed = [UInt8(q.count >> 8), UInt8(q.count & 0xFF)]
                    framed += q
                    conn.send(content: Data(framed), completion: .contentProcessed { err in
                        if let err { finish(.failure(err)) }
                    })
                    conn.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, err in
                        guard let data, data.count == 2 else { finish(.failure(err ?? DNSClientError.socket)); return }
                        let len = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
                        conn.receive(minimumIncompleteLength: len, maximumLength: len) { body, _, _, err in
                            if let body { finish(.success(Array(body))) } else { finish(.failure(err ?? DNSClientError.socket)) }
                        }
                    }
                case .failed(let e): finish(.failure(e))
                case .waiting(let e): finish(.failure(e))
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.failure(DNSClientError.timeout)) }
        }
    }

    // MARK: DoH (RFC 8484)

    static func doh(_ q: [UInt8], url: String, timeout: TimeInterval) async -> Result<[UInt8], Error> {
        guard let u = URL(string: url) else { return .failure(DNSClientError.badURL) }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        req.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        req.httpBody = Data(q)
        req.timeoutInterval = timeout
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 { return .failure(DNSClientError.http(http.statusCode)) }
            return .success(Array(data))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - Iterative resolution (dig +trace)

struct DelegationStep: Identifiable {
    let id = UUID()
    let zone: String
    let serverName: String
    let serverIP: String
    let elapsedMs: Double
    let nameservers: [String]
    let answers: [DNSRecord]
    let rcode: Int
    let authoritative: Bool
    let signed: Bool       // DS present for the child → DNSSEC chain continues
    let error: String?
}

enum DNSTrace {
    static let roots: [(String, String)] = [
        ("a.root-servers.net", "198.41.0.4"), ("b.root-servers.net", "170.247.170.2"), ("c.root-servers.net", "192.33.4.12"),
        ("d.root-servers.net", "199.7.91.13"), ("e.root-servers.net", "192.203.230.10"), ("f.root-servers.net", "192.5.5.241"),
        ("i.root-servers.net", "192.36.148.17"), ("j.root-servers.net", "192.58.128.30"), ("k.root-servers.net", "193.0.14.129"),
        ("l.root-servers.net", "199.7.83.42"), ("m.root-servers.net", "202.12.27.33"),
    ]

    static func run(_ name: String, type: UInt16, onStep: @escaping @MainActor (DelegationStep) -> Void) async {
        let root = roots.randomElement()!
        var server = (name: root.0, ip: root.1)
        var zone = "."
        for _ in 0..<14 {
            let srv = DNSServer(name: server.name, address: server.ip)
            let r = await DNSClient.query(name, type: type, server: srv, transport: .udp, dnssec: true, recursion: false, timeout: 3)
            guard let m = r.message else {
                await onStep(DelegationStep(zone: zone, serverName: server.name, serverIP: server.ip, elapsedMs: r.elapsedMs,
                                            nameservers: [], answers: [], rcode: -1, authoritative: false, signed: false, error: r.error))
                return
            }
            let ns = m.authority.filter { $0.type == DNSType.NS.rawValue }
            let hasDS = m.authority.contains { $0.type == DNSType.DS.rawValue }
            let step = DelegationStep(zone: zone, serverName: server.name, serverIP: server.ip, elapsedMs: r.elapsedMs,
                                      nameservers: ns.map(\.data), answers: m.answers.filter { !$0.isOPT }, rcode: m.rcode,
                                      authoritative: m.aa, signed: hasDS, error: nil)
            await onStep(step)
            if !m.answers.isEmpty || m.rcode != 0 || ns.isEmpty { return }
            // Follow the referral: prefer a nameserver with glue.
            let child = ns.first?.name ?? zone
            var next: (String, String)?
            for n in ns {
                if let glue = m.additional.first(where: { $0.name == n.data && $0.type == DNSType.A.rawValue }) {
                    next = (n.data, glue.data)
                    break
                }
            }
            if next == nil, let first = ns.first {
                let ips = await Resolver.resolve(String(first.data.dropLast()), family: AF_INET)
                if let ip = ips.first { next = (first.data, ip) }
            }
            guard let n = next else { return }
            server = (n.0, n.1)
            zone = child
        }
    }
}
