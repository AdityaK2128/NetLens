import Foundation
import Observation
import AppKit

/// One socket as reported by the kernel's network statistics (via `nettop`).
struct SocketRecord: Identifiable, Hashable {
    let id: String
    let proto: String              // tcp4 / tcp6 / udp4 / udp6
    let localAddress: String?
    let localPort: UInt16?
    let remoteAddress: String?
    let remotePort: UInt16?
    var interface: String
    var state: String
    var bytesIn: UInt64
    var bytesOut: UInt64
    var rxDupe: UInt64
    var rxOutOfOrder: UInt64
    var retransmits: UInt64
    var rttMs: Double?
    var rcvBuffer: Int?
    var txWindow: Int?
    var trafficClass: String
    var ccAlgo: String
    let pid: Int32
    let processName: String
    var rateIn: Double = 0
    var rateOut: Double = 0
    var firstSeen: Date = Date()
    /// Set when this socket belongs to a transparent proxy (e.g. a VPN's "threat
    /// protection" system extension) and is carrying a flow for another app.
    var originPid: Int32?

    var isTCP: Bool { proto.hasPrefix("tcp") }
    var isV6: Bool { proto.hasSuffix("6") }
    var isListening: Bool { isTCP ? state == "Listen" : remoteAddress == nil }
    var remoteScope: IPScope? { remoteAddress.map(IP.scope) }
    var totalBytes: UInt64 { bytesIn + bytesOut }
    var totalRate: Double { rateIn + rateOut }

    var localDisplay: String { Self.endpoint(localAddress, localPort, v6: isV6) }
    var remoteDisplay: String { Self.endpoint(remoteAddress, remotePort, v6: isV6) }

    static func endpoint(_ a: String?, _ p: UInt16?, v6: Bool) -> String {
        let addr = a ?? "*"
        let port = p.map(String.init) ?? "*"
        return v6 && a != nil ? "[\(addr)]:\(port)" : "\(addr):\(port)"
    }

    /// Human meaning of nettop's traffic-class column (SO_TRAFFIC_CLASS service classes).
    var trafficClassName: String {
        switch trafficClass {
        case "BK_SYS": "Background (system)"
        case "BK": "Background"
        case "BE": "Best effort"
        case "RD": "Responsive data"
        case "OAM": "Operations & management"
        case "AV": "Multimedia streaming"
        case "RV": "Responsive multimedia"
        case "VI": "Interactive video"
        case "VO": "Interactive voice"
        case "CTL": "Network control"
        default: trafficClass
        }
    }
}

struct ProcessTraffic: Identifiable, Hashable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    var bytesIn: UInt64
    var bytesOut: UInt64
    var rateIn: Double = 0
    var rateOut: Double = 0
    var sockets: Int = 0
    var established: Int = 0
}

/// A remote host this Mac is talking to, aggregated across sockets — what the globe draws.
struct RemoteEndpoint: Identifiable, Hashable {
    var id: String { ip }
    let ip: String
    var ports: Set<UInt16> = []
    var processes: Set<String> = []
    var sockets = 0
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var rateIn: Double = 0
    var rateOut: Double = 0
    var rttMs: Double?
    var firstSeen = Date()
    var lastSeen = Date()
    var active = true
    var protocols: Set<String> = []
}

@MainActor
@Observable
final class ConnectionMonitor {
    private(set) var sockets: [SocketRecord] = []
    private(set) var processes: [ProcessTraffic] = []
    private(set) var endpoints: [String: RemoteEndpoint] = [:]
    private(set) var geo: [String: GeoInfo] = [:]
    private(set) var lastUpdate: Date?
    private(set) var isRunning = false
    private(set) var error: String?
    var interval: TimeInterval = 2
    @ObservationIgnored var onSample: (() -> Void)?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var previous: [String: (UInt64, UInt64, Date)] = [:]
    @ObservationIgnored private var previousProc: [Int32: (UInt64, UInt64, Date)] = [:]
    @ObservationIgnored private var firstSeen: [String: Date] = [:]
    @ObservationIgnored private var geoRequested: Set<String> = []

    var activeSockets: [SocketRecord] { sockets.filter { !$0.isListening } }
    var listeners: [SocketRecord] { sockets.filter { $0.isListening } }
    var established: Int { sockets.filter { $0.state == "Established" }.count }
    var totalRateIn: Double { processes.reduce(0) { $0 + $1.rateIn } }
    var totalRateOut: Double { processes.reduce(0) { $0 + $1.rateOut } }

    func start() {
        guard task == nil else { return }
        isRunning = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                let i = self?.interval ?? 2
                try? await Task.sleep(for: .seconds(i))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    func refreshNow() { Task { await sample() } }

    private func sample() async {
        let result = await Shell.run("/usr/bin/nettop", ["-L", "1", "-n", "-x"], timeout: 10)
        guard result.ok else {
            error = "nettop failed: \(result.stderr.prefix(200))"
            return
        }
        error = nil
        let now = Date()
        let parsed = await Task.detached(priority: .utility) { NettopParser.parse(result.stdout) }.value

        var socks = parsed.sockets
        for i in socks.indices {
            let s = socks[i]
            if let (pin, pout, pt) = previous[s.id] {
                let dt = max(now.timeIntervalSince(pt), 0.25)
                socks[i].rateIn = s.bytesIn >= pin ? Double(s.bytesIn - pin) / dt : 0
                socks[i].rateOut = s.bytesOut >= pout ? Double(s.bytesOut - pout) / dt : 0
            }
            if let f = firstSeen[s.id] { socks[i].firstSeen = f } else { firstSeen[s.id] = now }
        }
        attributeRelays(&socks, processes: parsed.processes)
        previous = Dictionary(socks.map { ($0.id, ($0.bytesIn, $0.bytesOut, now)) }, uniquingKeysWith: { a, _ in a })
        let live = Set(socks.map(\.id))
        firstSeen = firstSeen.filter { live.contains($0.key) }

        var procs = parsed.processes
        for i in procs.indices {
            let p = procs[i]
            if let (pin, pout, pt) = previousProc[p.pid] {
                let dt = max(now.timeIntervalSince(pt), 0.25)
                procs[i].rateIn = p.bytesIn >= pin ? Double(p.bytesIn - pin) / dt : 0
                procs[i].rateOut = p.bytesOut >= pout ? Double(p.bytesOut - pout) / dt : 0
            }
            let mine = socks.filter { $0.pid == p.pid }
            procs[i].sockets = mine.count
            procs[i].established = mine.filter { $0.state == "Established" || (!$0.isTCP && $0.remoteAddress != nil) }.count
        }
        previousProc = Dictionary(procs.map { ($0.pid, ($0.bytesIn, $0.bytesOut, now)) }, uniquingKeysWith: { a, _ in a })

        sockets = socks
        processes = procs.sorted { a, b in
            let ra = a.rateIn + a.rateOut, rb = b.rateIn + b.rateOut
            if ra != rb { return ra > rb }
            return a.bytesIn + a.bytesOut > b.bytesIn + b.bytesOut
        }
        updateEndpoints(socks, now: now)
        lastUpdate = now
        onSample?()
    }

    /// Transparent proxies (NETransparentProxyProvider system extensions) re-originate
    /// other apps' connections: the app keeps a stub socket, the proxy owns the real one.
    /// Match them up by remote endpoint so traffic is credited to the app that asked for it.
    private(set) var relayPids: Set<Int32> = []

    private func attributeRelays(_ socks: inout [SocketRecord], processes: [ProcessTraffic]) {
        var relays = Set<Int32>()
        for p in processes {
            if let path = ProcessCatalog.shared.identity(pid: p.pid, fallbackName: p.name).path,
               path.hasPrefix("/Library/SystemExtensions/") {
                relays.insert(p.pid)
            }
        }
        relayPids = relays
        guard !relays.isEmpty else { return }
        var origin: [String: Int32] = [:]
        for s in socks where !relays.contains(s.pid) {
            guard let r = s.remoteAddress, let port = s.remotePort else { continue }
            origin["\(r)|\(port)"] = s.pid
        }
        for i in socks.indices where relays.contains(socks[i].pid) {
            guard let r = socks[i].remoteAddress, let port = socks[i].remotePort else { continue }
            socks[i].originPid = origin["\(r)|\(port)"]
        }
    }

    private func updateEndpoints(_ socks: [SocketRecord], now: Date) {
        var fresh: [String: RemoteEndpoint] = [:]
        for s in socks {
            guard let ip = s.remoteAddress, IP.isGlobal(ip) else { continue }
            guard s.isTCP ? (s.state != "Listen" && s.state != "Closed") : true else { continue }
            let key = IP.stripScope(ip)
            var e = fresh[key] ?? endpoints[key] ?? RemoteEndpoint(ip: key, firstSeen: now)
            if fresh[key] == nil {
                // reset per-sample aggregates
                e.sockets = 0; e.bytesIn = 0; e.bytesOut = 0; e.rateIn = 0; e.rateOut = 0
                e.processes = []; e.ports = []; e.protocols = []; e.rttMs = nil
            }
            e.sockets += 1
            e.bytesIn += s.bytesIn
            e.bytesOut += s.bytesOut
            e.rateIn += s.rateIn
            e.rateOut += s.rateOut
            if let p = s.remotePort { e.ports.insert(p) }
            if let o = s.originPid {
                e.processes.insert(ProcessCatalog.shared.identity(pid: o, fallbackName: "").name)
            } else {
                e.processes.insert(ProcessCatalog.shared.identity(pid: s.pid, fallbackName: s.processName).name)
            }
            e.protocols.insert(s.isTCP ? "TCP" : "UDP")
            if let r = s.rttMs, r > 0 { e.rttMs = min(e.rttMs ?? r, r) }
            e.lastSeen = now
            e.active = true
            fresh[key] = e
        }
        // Keep recently-closed endpoints around (fading on the globe) for 3 minutes.
        for (k, var e) in endpoints where fresh[k] == nil {
            if now.timeIntervalSince(e.lastSeen) < 180 {
                e.active = false
                e.rateIn = 0; e.rateOut = 0
                fresh[k] = e
            }
        }
        endpoints = fresh

        let need = fresh.keys.filter { geo[$0] == nil && !geoRequested.contains($0) }
        guard !need.isEmpty else { return }
        geoRequested.formUnion(need)
        Task { [weak self] in
            let found = await GeoIPService.shared.infos(for: Array(need))
            guard let self else { return }
            for (k, v) in found { self.geo[k] = v }
        }
    }
}

enum NettopParser {
    struct Output {
        var sockets: [SocketRecord] = []
        var processes: [ProcessTraffic] = []
    }

    /// Parses `nettop -L 1 -n -x` CSV. Process rows ("name.pid") are followed by
    /// their socket rows ("tcp4 a:p<->b:q").
    static func parse(_ text: String) -> Output {
        var out = Output()
        var currentPid: Int32 = 0
        var currentName = ""
        var seen: [String: Int] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = rawLine.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 10, f[0] != "time" else { continue }
            let name = f[1]
            if name.hasPrefix("tcp4 ") || name.hasPrefix("tcp6 ") || name.hasPrefix("udp4 ") || name.hasPrefix("udp6 ") {
                let proto = String(name.prefix(4))
                let rest = name.dropFirst(5)
                let ends = rest.components(separatedBy: "<->")
                guard ends.count == 2 else { continue }
                let v6 = proto.hasSuffix("6")
                let (la, lp) = endpoint(ends[0], v6: v6)
                let (ra, rp) = endpoint(ends[1], v6: v6)
                func u(_ i: Int) -> UInt64 { i < f.count ? UInt64(f[i]) ?? 0 : 0 }
                func int(_ i: Int) -> Int? { i < f.count ? Int(f[i]) : nil }
                var rtt: Double? = nil
                if f.count > 9, !f[9].isEmpty {
                    rtt = Double(f[9].replacingOccurrences(of: " ms", with: ""))
                }
                // Several unconnected UDP sockets can share the same tuple — disambiguate.
                let base = "\(currentPid)|\(proto)|\(ends[0])|\(ends[1])"
                let n = seen[base, default: 0]
                seen[base] = n + 1
                let rec = SocketRecord(
                    id: n == 0 ? base : "\(base)#\(n)",
                    proto: proto, localAddress: la, localPort: lp, remoteAddress: ra, remotePort: rp,
                    interface: f[2], state: f[3],
                    bytesIn: u(4), bytesOut: u(5), rxDupe: u(6), rxOutOfOrder: u(7), retransmits: u(8),
                    rttMs: rtt, rcvBuffer: int(10), txWindow: int(11),
                    trafficClass: f.count > 12 ? f[12] : "", ccAlgo: f.count > 14 ? f[14] : "",
                    pid: currentPid, processName: currentName)
                out.sockets.append(rec)
            } else if let dot = name.lastIndex(of: "."), let pid = Int32(name[name.index(after: dot)...]) {
                currentPid = pid
                currentName = String(name[..<dot])
                let bin = UInt64(f[4]) ?? 0
                let bout = UInt64(f[5]) ?? 0
                out.processes.append(ProcessTraffic(pid: pid, name: currentName, bytesIn: bin, bytesOut: bout))
            }
        }
        return out
    }

    /// "1.2.3.4:443", "*:*", "fe80::1%en0.5353", "*.*", "::1.8021"
    static func endpoint(_ s: String, v6: Bool) -> (String?, UInt16?) {
        let sepChar: Character = v6 ? "." : ":"
        guard let i = s.lastIndex(of: sepChar) else { return (s == "*" ? nil : s, nil) }
        let addr = String(s[..<i])
        let port = String(s[s.index(after: i)...])
        return (addr == "*" ? nil : addr, UInt16(port))
    }
}
