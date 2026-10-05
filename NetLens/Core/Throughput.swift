import Foundation
import Observation

struct RateSample: Hashable {
    let time: Date
    let inBps: Double    // bytes/s
    let outBps: Double
}

/// Samples 64-bit interface counters once a second and keeps a rolling history.
@MainActor
@Observable
final class ThroughputMonitor {
    private(set) var history: [String: [RateSample]] = [:]
    private(set) var current: [String: RateSample] = [:]
    private(set) var counters: [String: InterfaceCounters] = [:]
    private(set) var peak: [String: Double] = [:]
    let capacity = 120

    @ObservationIgnored private var last: [String: InterfaceCounters] = [:]
    @ObservationIgnored private var lastTime: Date?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    private func sample() {
        let now = Date()
        let c = InterfaceReader.readCounters()
        if let lt = lastTime {
            let dt = max(now.timeIntervalSince(lt), 0.2)
            for (name, v) in c {
                guard let p = last[name] else { continue }
                let i = v.bytesIn >= p.bytesIn ? Double(v.bytesIn - p.bytesIn) / dt : 0
                let o = v.bytesOut >= p.bytesOut ? Double(v.bytesOut - p.bytesOut) / dt : 0
                let s = RateSample(time: now, inBps: i, outBps: o)
                current[name] = s
                var h = history[name] ?? []
                h.append(s)
                if h.count > capacity { h.removeFirst(h.count - capacity) }
                history[name] = h
                peak[name] = max(peak[name] ?? 0, i, o)
            }
        }
        last = c
        lastTime = now
        counters = c
    }

    func series(_ name: String?) -> [RateSample] {
        guard let name else { return [] }
        return history[name] ?? []
    }
}
