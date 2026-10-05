import Foundation
import Darwin

/// What came back for a probe.
struct ICMPReply {
    enum Kind: Equatable {
        case echoReply
        case timeExceeded
        case unreachable(code: UInt8)
        case other(type: UInt8, code: UInt8)
    }
    let kind: Kind
    let from: String
    let identifier: UInt16
    let sequence: UInt16
    let replyTTL: UInt8?
    let size: Int
    let receivedAt: UInt64   // CLOCK_UPTIME_RAW ns
}

@inline(__always) func monotonicNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// Unprivileged ICMP socket (SOCK_DGRAM + IPPROTO_ICMP). macOS lets any user send
/// echo requests this way and delivers echo replies *and* ICMP errors (time-exceeded,
/// unreachable) back to it — enough for both ping and traceroute without root.
final class ICMPSocket {
    let isV6: Bool
    let identifier: UInt16
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    var onReply: ((ICMPReply) -> Void)?

    init?(v6: Bool, identifier: UInt16 = UInt16.random(in: 1...0xFFFE)) {
        self.isV6 = v6
        self.identifier = identifier
        let fd = v6 ? socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6) : socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        queue = DispatchQueue(label: "icmp.\(v6 ? 6 : 4).\(identifier)", qos: .userInteractive)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }

    func setTTL(_ ttl: Int) {
        var t = Int32(ttl)
        if isV6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &t, socklen_t(4))
        } else {
            setsockopt(fd, IPPROTO_IP, IP_TTL, &t, socklen_t(4))
        }
    }

    /// Sends an echo request. Returns the send timestamp, or nil on failure.
    @discardableResult
    func sendEcho(to address: String, sequence: UInt16, payloadSize: Int = 56) -> UInt64? {
        guard let (storage, len) = SockAddr.make(address) else { return nil }
        var pkt = [UInt8](repeating: 0, count: 8 + payloadSize)
        pkt[0] = isV6 ? 128 : 8           // echo request
        pkt[1] = 0
        pkt[4] = UInt8(identifier >> 8); pkt[5] = UInt8(identifier & 0xFF)
        pkt[6] = UInt8(sequence >> 8);   pkt[7] = UInt8(sequence & 0xFF)
        // Payload: "NetLens" marker followed by a pattern, like BSD ping's.
        let marker = Array("NetLens!".utf8)
        for i in 0..<payloadSize { pkt[8 + i] = i < marker.count ? marker[i] : UInt8(truncatingIfNeeded: i) }
        if !isV6 {
            let c = Self.checksum(pkt)
            pkt[2] = UInt8(c >> 8); pkt[3] = UInt8(c & 0xFF)
        } // ICMPv6 checksum is computed by the kernel (needs the pseudo-header)
        let t = monotonicNanos()
        var st = storage
        let sent = withUnsafePointer(to: &st) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, pkt, pkt.count, 0, $0, len) }
        }
        return sent == pkt.count ? t : nil
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            var from = sockaddr_storage()
            var flen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &flen) }
            }
            if n <= 0 { return }
            let now = monotonicNanos()
            let fromString = withUnsafePointer(to: &from) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { SockAddr.string($0) }
            } ?? "?"
            if let reply = parse(Array(buf[0..<n]), from: fromString, at: now) {
                onReply?(reply)
            }
        }
    }

    private func parse(_ data: [UInt8], from: String, at: UInt64) -> ICMPReply? {
        var icmp = data[...]
        var ttl: UInt8? = nil
        if !isV6 {
            // DGRAM ICMP sockets on macOS deliver the IPv4 header too.
            guard data.count >= 20, data[0] >> 4 == 4 else { return nil }
            let ihl = Int(data[0] & 0x0F) * 4
            guard data.count >= ihl + 8 else { return nil }
            ttl = data[8]
            icmp = data[ihl...]
        }
        let b = Array(icmp)
        guard b.count >= 8 else { return nil }
        let type = b[0], code = b[1]
        let echoReply: UInt8 = isV6 ? 129 : 0
        if type == echoReply {
            let id = UInt16(b[4]) << 8 | UInt16(b[5])
            let seq = UInt16(b[6]) << 8 | UInt16(b[7])
            return ICMPReply(kind: .echoReply, from: from, identifier: id, sequence: seq, replyTTL: ttl, size: b.count, receivedAt: at)
        }
        let timeExceeded: UInt8 = isV6 ? 3 : 11
        let unreachable: UInt8 = isV6 ? 1 : 3
        guard type == timeExceeded || type == unreachable else { return nil }
        // Quoted original datagram: IP header + first 8 bytes of our echo request.
        let inner = Array(b[8...])
        var innerICMP: ArraySlice<UInt8>
        if isV6 {
            guard inner.count >= 48 else { return nil }
            innerICMP = inner[40...]
        } else {
            guard inner.count >= 28, inner[0] >> 4 == 4 else { return nil }
            let ihl = Int(inner[0] & 0x0F) * 4
            guard inner.count >= ihl + 8 else { return nil }
            innerICMP = inner[ihl...]
        }
        let q = Array(innerICMP)
        let id = UInt16(q[4]) << 8 | UInt16(q[5])
        let seq = UInt16(q[6]) << 8 | UInt16(q[7])
        let kind: ICMPReply.Kind = type == timeExceeded ? .timeExceeded : .unreachable(code: code)
        return ICMPReply(kind: kind, from: from, identifier: id, sequence: seq, replyTTL: ttl, size: b.count, receivedAt: at)
    }

    static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count { sum &+= UInt32(data[i]) << 8 | UInt32(data[i + 1]); i += 2 }
        if i < data.count { sum &+= UInt32(data[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        return ~UInt16(truncatingIfNeeded: sum)
    }
}

// MARK: - Ping

struct PingResult {
    let rtt: Double?          // ms
    let replyTTL: UInt8?
    let from: String?
    let error: String?
    var ok: Bool { rtt != nil }
}

/// Shared echo engine: one socket per family, replies matched by (identifier, sequence).
final class Pinger: @unchecked Sendable {
    static let shared = Pinger()

    private let lock = NSLock()
    private var v4: ICMPSocket?
    private var v6: ICMPSocket?
    private var hop1: ICMPSocket?
    private var seq: UInt16 = 0
    private var pending: [UInt16: (sentAt: UInt64, cont: CheckedContinuation<PingResult, Never>)] = [:]
    private var hop1Pending: [UInt16: (sentAt: UInt64, cont: CheckedContinuation<PingResult, Never>)] = [:]

    private func socket(v6 wantV6: Bool) -> ICMPSocket? {
        lock.lock(); defer { lock.unlock() }
        if wantV6 {
            if v6 == nil { v6 = ICMPSocket(v6: true); v6?.onReply = { [weak self] in self?.handle($0) } }
            return v6
        } else {
            if v4 == nil { v4 = ICMPSocket(v6: false); v4?.onReply = { [weak self] in self?.handle($0) } }
            return v4
        }
    }

    /// Many routers firewall echo requests but still emit ICMP Time Exceeded. Sending an
    /// echo toward any Internet host with TTL=1 makes the first-hop router answer for itself.
    func probeFirstHop(toward target: String = "1.1.1.1", timeout: TimeInterval = 2) async -> PingResult {
        let sock: ICMPSocket? = lock.withLock {
            if hop1 == nil {
                hop1 = ICMPSocket(v6: false)
                hop1?.setTTL(1)
                hop1?.onReply = { [weak self] r in self?.handleHop1(r) }
            }
            return hop1
        }
        guard let sock else { return PingResult(rtt: nil, replyTTL: nil, from: nil, error: "ICMP socket unavailable") }
        return await withCheckedContinuation { cont in
            lock.lock()
            seq &+= 1
            if seq == 0 { seq = 1 }
            let s = seq
            hop1Pending[s] = (monotonicNanos(), cont)
            lock.unlock()
            if sock.sendEcho(to: target, sequence: s, payloadSize: 32) == nil {
                lock.lock(); let e = hop1Pending.removeValue(forKey: s); lock.unlock()
                e?.cont.resume(returning: PingResult(rtt: nil, replyTTL: nil, from: nil, error: "Send failed"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let e = self.hop1Pending.removeValue(forKey: s); self.lock.unlock()
                e?.cont.resume(returning: PingResult(rtt: nil, replyTTL: nil, from: nil, error: "Timeout"))
            }
        }
    }

    private func handleHop1(_ r: ICMPReply) {
        guard r.identifier == hop1?.identifier else { return }
        lock.lock()
        let entry = hop1Pending.removeValue(forKey: r.sequence)
        lock.unlock()
        guard let entry else { return }
        let ms = Double(r.receivedAt &- entry.sentAt) / 1_000_000
        entry.cont.resume(returning: PingResult(rtt: ms, replyTTL: r.replyTTL, from: r.from, error: nil))
    }

    private func handle(_ r: ICMPReply) {
        let isOurs = r.identifier == v4?.identifier || r.identifier == v6?.identifier
        guard isOurs else { return }
        lock.lock()
        let entry = pending.removeValue(forKey: r.sequence)
        lock.unlock()
        guard let entry else { return }
        switch r.kind {
        case .echoReply:
            let ms = Double(r.receivedAt &- entry.sentAt) / 1_000_000
            entry.cont.resume(returning: PingResult(rtt: ms, replyTTL: r.replyTTL, from: r.from, error: nil))
        case .timeExceeded:
            entry.cont.resume(returning: PingResult(rtt: nil, replyTTL: nil, from: r.from, error: "TTL exceeded at \(r.from)"))
        case .unreachable(let code):
            entry.cont.resume(returning: PingResult(rtt: nil, replyTTL: nil, from: r.from, error: "Unreachable (code \(code)) from \(r.from)"))
        case .other:
            entry.cont.resume(returning: PingResult(rtt: nil, replyTTL: nil, from: r.from, error: "Unexpected ICMP"))
        }
    }

    func ping(_ address: String, timeout: TimeInterval = 2, payloadSize: Int = 56) async -> PingResult {
        let wantV6 = IP.isV6(address)
        guard let sock = socket(v6: wantV6) else {
            return PingResult(rtt: nil, replyTTL: nil, from: nil, error: "ICMP socket unavailable")
        }
        return await withCheckedContinuation { cont in
            lock.lock()
            seq &+= 1
            if seq == 0 { seq = 1 }
            let s = seq
            // Timestamp before sendto so a lightning-fast reply (loopback) can't race us.
            pending[s] = (monotonicNanos(), cont)
            lock.unlock()

            if sock.sendEcho(to: address, sequence: s, payloadSize: payloadSize) == nil {
                lock.lock(); let e = pending.removeValue(forKey: s); lock.unlock()
                e?.cont.resume(returning: PingResult(rtt: nil, replyTTL: nil, from: nil, error: "Send failed (no route?)"))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let e = self.pending.removeValue(forKey: s); self.lock.unlock()
                e?.cont.resume(returning: PingResult(rtt: nil, replyTTL: nil, from: nil, error: "Timeout"))
            }
        }
    }
}
