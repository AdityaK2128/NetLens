import Foundation
import Observation

struct PingSample: Identifiable, Hashable {
    let id: Int
    let time: Date
    let rtt: Double?
}

struct PingStats {
    var last: Double?
    var min: Double?
    var avg: Double?
    var max: Double?
    var stdev: Double?
    var jitter: Double?
    var loss: Double = 0
    var sent = 0
    var received = 0

    /// ITU-T G.107 E-model, simplified — a 1…4.5 "how would a voice call feel" score.
    var mos: Double? {
        guard let avg else { return nil }
        let eff = avg + 2 * (jitter ?? 0) + 10
        var r = eff < 160 ? 93.2 - eff / 40 : 93.2 - (eff - 120) / 10
        r -= loss * 2.5
        r = Swift.max(0, Swift.min(100, r))
        return 1 + 0.035 * r + 0.000007 * r * (r - 60) * (100 - r)
    }

    var mosLabel: String {
        guard let m = mos else { return "—" }
        switch m {
        case 4.3...: return "Excellent"
        case 4.0...: return "Good"
        case 3.6...: return "Fair"
        case 3.1...: return "Poor"
        default: return "Bad"
        }
    }
}

@MainActor
@Observable
final class PingTarget: Identifiable {
    let id = UUID()
    var label: String
    var host: String
    var resolved: String?
    var pinned: Bool
    var samples: [PingSample] = []
    var lastError: String?
    var lastReplyTTL: UInt8?
    var paused = false
    /// The target ignores echo; we measure it via TTL-expiry from the first hop instead.
    var viaTTLExpiry = false
    let capacity = 300

    @ObservationIgnored private var counter = 0

    init(label: String, host: String, pinned: Bool = false) {
        self.label = label
        self.host = host
        self.pinned = pinned
    }

    func add(_ r: PingResult) {
        counter += 1
        samples.append(PingSample(id: counter, time: Date(), rtt: r.rtt))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        lastError = r.error
        if let t = r.replyTTL { lastReplyTTL = t }
    }

    func reset() { samples = []; lastError = nil; viaTTLExpiry = false }

    /// Initial TTL guess from reply TTL: hosts start at 64 (Unix/macOS), 128 (Windows) or 255 (network gear).
    var inferredHops: (hops: Int, os: String)? {
        guard let t = lastReplyTTL else { return nil }
        let initial: Int, os: String
        switch t {
        case ...64: (initial, os) = (64, "Linux/macOS/BSD")
        case ...128: (initial, os) = (128, "Windows")
        default: (initial, os) = (255, "router / network OS")
        }
        return (initial - Int(t), os)
    }

    func stats(window: Int? = nil) -> PingStats {
        var s = PingStats()
        let slice = window.map { Array(samples.suffix($0)) } ?? samples
        s.sent = slice.count
        let rtts = slice.compactMap(\.rtt)
        s.received = rtts.count
        s.last = slice.last?.rtt
        guard !rtts.isEmpty else { s.loss = s.sent > 0 ? 100 : 0; return s }
        s.min = rtts.min()
        s.max = rtts.max()
        let avg = rtts.reduce(0, +) / Double(rtts.count)
        s.avg = avg
        s.stdev = sqrt(rtts.reduce(0) { $0 + ($1 - avg) * ($1 - avg) } / Double(rtts.count))
        if rtts.count > 1 {
            var d = 0.0
            for i in 1..<rtts.count { d += abs(rtts[i] - rtts[i - 1]) }
            s.jitter = d / Double(rtts.count - 1)
        }
        s.loss = Double(s.sent - s.received) / Double(s.sent) * 100
        return s
    }
}

/// Continuous multi-target latency monitor (1 Hz ICMP echo).
@MainActor
@Observable
final class PingMonitor {
    var targets: [PingTarget] = []
    var interval: TimeInterval = 1
    private(set) var running = false

    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        targets = [
            PingTarget(label: "Router", host: "", pinned: true),
            PingTarget(label: "Cloudflare", host: "1.1.1.1", pinned: true),
            PingTarget(label: "Google DNS", host: "8.8.8.8", pinned: true),
        ]
    }

    var gateway: PingTarget { targets[0] }
    var internet: PingTarget { targets[1] }

    func setGateway(_ ip: String?) {
        guard gateway.host != (ip ?? "") else { return }
        gateway.host = ip ?? ""
        gateway.resolved = ip
        gateway.reset()
    }

    func add(host: String) {
        let h = host.trimmed
        guard !h.isEmpty, !targets.contains(where: { $0.host == h }) else { return }
        targets.append(PingTarget(label: h, host: h))
    }

    func remove(_ t: PingTarget) {
        guard !t.pinned else { return }
        targets.removeAll { $0.id == t.id }
    }

    func start() {
        guard task == nil else { return }
        running = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let started = Date()
                await self.tick()
                let elapsed = Date().timeIntervalSince(started)
                try? await Task.sleep(for: .seconds(max(0.05, self.interval - elapsed)))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
    }

    private func tick() async {
        let active = targets.filter { !$0.host.isEmpty && !$0.paused }
        await withTaskGroup(of: Void.self) { group in
            for t in active {
                group.addTask { @MainActor in
                    if t.resolved == nil {
                        let ips = await Resolver.resolve(t.host)
                        t.resolved = ips.first(where: IP.isV4) ?? ips.first
                        if t.resolved == nil { t.add(PingResult(rtt: nil, replyTTL: nil, from: nil, error: "Cannot resolve")); return }
                    }
                    let timeout = min(2, self.interval * 1.8)
                    if t.viaTTLExpiry {
                        var r = await Pinger.shared.probeFirstHop(timeout: timeout)
                        if let from = r.from, from != t.resolved {
                            r = PingResult(rtt: nil, replyTTL: nil, from: from, error: "First hop is \(from), not \(t.resolved!)")
                        }
                        t.add(r)
                        return
                    }
                    let r = await Pinger.shared.ping(t.resolved!, timeout: timeout)
                    t.add(r)
                    // Gateway silently drops echo? Switch to first-hop TTL probes.
                    if t === self.gateway, t.samples.count >= 4, t.samples.allSatisfy({ $0.rtt == nil }) {
                        let probe = await Pinger.shared.probeFirstHop(timeout: timeout)
                        if probe.ok, probe.from == t.resolved {
                            t.samples = []
                            t.viaTTLExpiry = true
                            t.add(probe)
                        }
                    }
                }
            }
        }
    }
}
