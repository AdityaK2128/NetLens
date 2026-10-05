import Foundation
import Observation

struct TraceHop: Identifiable, Equatable {
    let ttl: Int
    var id: Int { ttl }
    var addresses: [String] = []           // >1 means ECMP / load-balanced path
    var sent = 0
    var received = 0
    var last: Double?
    var best: Double?
    var worst: Double?
    var sum: Double = 0
    var sumSq: Double = 0
    var samples: [Double?] = []            // recent RTTs (nil = lost), for sparklines
    var hostname: String?
    var geo: GeoInfo?
    var reachedDestination = false
    var unreachableCode: UInt8?

    var address: String? { addresses.first }
    var avg: Double? { received > 0 ? sum / Double(received) : nil }
    var stdev: Double? {
        guard received > 1, let a = avg else { return nil }
        return sqrt(max(0, sumSq / Double(received) - a * a))
    }
    var loss: Double { sent > 0 ? Double(sent - received) / Double(sent) * 100 : 0 }
    var isSilent: Bool { received == 0 && sent > 0 }
    var scope: IPScope? { address.map(IP.scope) }

    mutating func record(_ rtt: Double?) {
        sent += 1
        samples.append(rtt)
        if samples.count > 60 { samples.removeFirst(samples.count - 60) }
        guard let rtt else { return }
        received += 1
        last = rtt
        best = min(best ?? rtt, rtt)
        worst = max(worst ?? rtt, rtt)
        sum += rtt
        sumSq += rtt * rtt
    }
}

/// ICMP-echo traceroute that probes every TTL in parallel each round (like mtr),
/// so a full path appears in ~1.5s and continuous mode yields per-hop loss/jitter.
@MainActor
@Observable
final class TraceSession {
    enum State: Equatable { case idle, resolving, running, finished, failed(String) }

    var target: String = ""
    var targetIP: String?
    var state: State = .idle
    var hops: [TraceHop] = []
    var rounds = 0
    var continuous = false
    var maxHops = 30
    var destinationTTL: Int?

    @ObservationIgnored private var socket: ICMPSocket?
    @ObservationIgnored private var sentAt: [UInt16: UInt64] = [:]
    @ObservationIgnored private var answered: Set<UInt16> = []
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var enriched: Set<String> = []
    @ObservationIgnored var probeTimeout: TimeInterval = 1.5

    var visibleHops: [TraceHop] {
        guard let d = destinationTTL else {
            // Trim trailing silent hops while still discovering.
            var h = hops
            while let last = h.last, last.received == 0, h.count > 1 { h.removeLast() }
            return h
        }
        return Array(hops.prefix(d))
    }

    func start(_ host: String, continuous: Bool = false) {
        stop()
        target = host.trimmed
        self.continuous = continuous
        hops = []
        rounds = 0
        destinationTTL = nil
        targetIP = nil
        sentAt = [:]
        answered = []
        state = .resolving

        runTask = Task { [weak self] in
            guard let self else { return }
            let ips = await Resolver.resolve(self.target)
            guard let ip = ips.first(where: IP.isV4) ?? ips.first else {
                self.state = .failed("Could not resolve \(self.target)")
                return
            }
            self.targetIP = ip
            guard let sock = ICMPSocket(v6: IP.isV6(ip)) else {
                self.state = .failed("Could not open ICMP socket")
                return
            }
            sock.onReply = { [weak self] reply in
                Task { @MainActor in self?.handle(reply) }
            }
            self.socket = sock
            self.hops = (1...self.maxHops).map { TraceHop(ttl: $0) }
            self.state = .running

            var round: UInt16 = 0
            repeat {
                await self.sendRound(round, to: ip)
                round &+= 1
                self.rounds += 1
                try? await Task.sleep(for: .milliseconds(Int(self.probeTimeout * 1000)))
                self.expire(round: round &- 1)
                if Task.isCancelled { break }
                if !self.continuous && self.rounds >= 3 { break }
            } while !Task.isCancelled

            if !Task.isCancelled { self.state = .finished }
            self.socket = nil
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        socket = nil
        if state == .running || state == .resolving { state = .finished }
    }

    private func sendRound(_ round: UInt16, to ip: String) async {
        guard let socket else { return }
        let limit = destinationTTL ?? maxHops
        for ttl in 1...limit {
            let seq = (round & 0xFF) << 8 | UInt16(ttl)
            socket.setTTL(ttl)
            if let t = socket.sendEcho(to: ip, sequence: seq, payloadSize: 32) {
                sentAt[seq] = t
            }
            // Gentle pacing: routers rate-limit ICMP time-exceeded generation.
            try? await Task.sleep(for: .milliseconds(4))
        }
    }

    /// Any probe from this round without an answer counts as lost.
    private func expire(round: UInt16) {
        let limit = destinationTTL ?? maxHops
        for ttl in 1...limit {
            let seq = (round & 0xFF) << 8 | UInt16(ttl)
            guard sentAt.removeValue(forKey: seq) != nil else { continue }
            if !answered.contains(seq) {
                hops[ttl - 1].record(nil)
            }
            answered.remove(seq)
        }
    }

    private func handle(_ r: ICMPReply) {
        guard let socket, r.identifier == socket.identifier else { return }
        let seq = r.sequence
        guard let t0 = sentAt[seq], !answered.contains(seq) else { return }
        let ttl = Int(seq & 0xFF)
        guard ttl >= 1, ttl <= hops.count else { return }
        answered.insert(seq)
        let rtt = Double(r.receivedAt &- t0) / 1_000_000

        var hop = hops[ttl - 1]
        if !hop.addresses.contains(r.from) { hop.addresses.append(r.from) }
        hop.record(rtt)
        switch r.kind {
        case .echoReply:
            hop.reachedDestination = true
            if destinationTTL == nil || ttl < destinationTTL! { destinationTTL = ttl }
        case .unreachable(let code):
            hop.unreachableCode = code
            if destinationTTL == nil || ttl < destinationTTL! { destinationTTL = ttl }
        default: break
        }
        hops[ttl - 1] = hop
        enrich(r.from)
    }

    private func enrich(_ ip: String) {
        guard !enriched.contains(ip) else { return }
        enriched.insert(ip)
        Task { [weak self] in
            async let name = ReverseDNS.shared.lookup(ip)
            async let geo = GeoIPService.shared.info(for: ip)
            let (n, g) = await (name, geo)
            guard let self else { return }
            for i in self.hops.indices where self.hops[i].addresses.first == ip {
                self.hops[i].hostname = n
                self.hops[i].geo = g
            }
        }
    }
}
