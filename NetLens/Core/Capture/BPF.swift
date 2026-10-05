import Foundation
import Darwin

struct RawPacket {
    let seconds: UInt32
    let micros: UInt32
    let caplen: Int
    let wirelen: Int
    let data: [UInt8]
    var timestamp: Double { Double(seconds) + Double(micros) / 1_000_000 }
}

/// Berkeley Packet Filter capture — the same kernel tap tcpdump and Wireshark use.
final class BPFCapture: @unchecked Sendable {
    enum CaptureError: Error, CustomStringConvertible {
        case permission, noDevice, ioctl(String), helper(String)
        var description: String {
            switch self {
            case .permission: "No permission to open /dev/bpf*"
            case .noDevice: "No free BPF device"
            case .ioctl(let s): "BPF setup failed: \(s)"
            case .helper(let s): "Helper: \(s)"
            }
        }
    }

    // ioctl request codes (_IOW/_IOR/_IOWR from <net/bpf.h>, computed — Swift can't import the macros).
    private static func ioc(_ dir: UInt32, _ num: UInt32, _ len: Int) -> UInt {
        UInt(dir | ((UInt32(len) & 0x1FFF) << 16) | (UInt32(0x42) << 8) | num)
    }
    private static let IN: UInt32 = 0x8000_0000, OUT: UInt32 = 0x4000_0000, VOID: UInt32 = 0x2000_0000
    static let BIOCSBLEN = ioc(IN | OUT, 102, 4)
    static let BIOCGBLEN = ioc(OUT, 102, 4)
    static let BIOCPROMISC = ioc(VOID, 105, 0)
    static let BIOCGDLT = ioc(OUT, 106, 4)
    static let BIOCSETIF = ioc(IN, 108, MemoryLayout<ifreq>.size)
    static let BIOCSRTIMEOUT = ioc(IN, 109, MemoryLayout<timeval>.size)
    static let BIOCIMMEDIATE = ioc(IN, 112, 4)
    static let BIOCSSEESENT = ioc(IN, 119, 4)

    let interface: String
    private(set) var dlt: UInt32 = 1
    private var fd: Int32 = -1
    private var bufferSize = 1 << 20
    private var running = false
    private let lock = NSLock()
    var onPackets: (([RawPacket]) -> Void)?
    var onStop: ((String?) -> Void)?

    init(interface: String) { self.interface = interface }

    /// Try opening a BPF device directly (works when ChmodBPF or similar granted access).
    static func openDirect() -> Result<Int32, CaptureError> {
        var sawPermission = false
        for i in 0..<256 {
            let path = "/dev/bpf\(i)"
            let fd = open(path, O_RDWR)
            if fd >= 0 { return .success(fd) }
            switch errno {
            case EBUSY: continue
            case EACCES, EPERM: sawPermission = true; continue
            case ENOENT: return .failure(sawPermission ? .permission : .noDevice)
            default: continue
            }
        }
        return .failure(sawPermission ? .permission : .noDevice)
    }

    static var canOpenDirectly: Bool {
        if case .success(let fd) = openDirect() { close(fd); return true }
        return false
    }

    func start(fd providedFD: Int32? = nil) throws {
        let fd: Int32
        if let providedFD {
            fd = providedFD
        } else {
            switch Self.openDirect() {
            case .success(let f): fd = f
            case .failure(let e): throw e
            }
        }
        var blen = UInt32(bufferSize)
        _ = ioctl(fd, Self.BIOCSBLEN, &blen)
        var ifr = ifreq()
        withUnsafeMutableBytes(of: &ifr.ifr_name) { raw in
            let bytes = Array(interface.utf8.prefix(15)) + [0]
            raw.copyBytes(from: bytes)
        }
        guard ioctl(fd, Self.BIOCSETIF, &ifr) == 0 else {
            let e = String(cString: strerror(errno))
            close(fd)
            throw CaptureError.ioctl("BIOCSETIF \(interface): \(e)")
        }
        var on: UInt32 = 1
        _ = ioctl(fd, Self.BIOCIMMEDIATE, &on)
        _ = ioctl(fd, Self.BIOCSSEESENT, &on)
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        _ = ioctl(fd, Self.BIOCSRTIMEOUT, &tv)
        var d: UInt32 = 0
        if ioctl(fd, Self.BIOCGDLT, &d) == 0 { dlt = d }
        var actual: UInt32 = 0
        if ioctl(fd, Self.BIOCGBLEN, &actual) == 0, actual > 0 { bufferSize = Int(actual) }

        self.fd = fd
        lock.lock(); running = true; lock.unlock()
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "bpf.\(interface)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func loop() {
        var buf = [UInt8](repeating: 0, count: bufferSize)
        var error: String?
        while isRunning {
            let n = read(fd, &buf, bufferSize)
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                error = String(cString: strerror(errno))
                break
            }
            if n == 0 { continue }
            var packets: [RawPacket] = []
            var off = 0
            while off + 18 <= n {
                // struct bpf_hdr { timeval32 tstamp; u32 caplen; u32 datalen; u16 hdrlen; }
                let sec = buf.loadLE32(off)
                let usec = buf.loadLE32(off + 4)
                let caplen = Int(buf.loadLE32(off + 8))
                let datalen = Int(buf.loadLE32(off + 12))
                let hdrlen = Int(UInt16(buf[off + 16]) | UInt16(buf[off + 17]) << 8)
                let start = off + hdrlen
                guard caplen > 0, start + caplen <= n else { break }
                packets.append(RawPacket(seconds: sec, micros: usec, caplen: caplen, wirelen: datalen, data: Array(buf[start..<start + caplen])))
                off += (hdrlen + caplen + 3) & ~3     // BPF_WORDALIGN
            }
            if !packets.isEmpty { onPackets?(packets) }
        }
        close(fd)
        fd = -1
        onStop?(error)
    }
}

extension Array where Element == UInt8 {
    @inline(__always) func loadLE32(_ i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
    @inline(__always) func be16(_ i: Int) -> Int {
        i + 1 < count ? Int(self[i]) << 8 | Int(self[i + 1]) : 0
    }
    @inline(__always) func be32(_ i: Int) -> UInt32 {
        i + 3 < count ? UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3]) : 0
    }
}

/// Asks the privileged helper to open a BPF device and pass us the descriptor
/// (SCM_RIGHTS over its Unix socket) — capture without chmod-ing /dev/bpf*.
enum HelperBPF {
    static func requestFD() -> Result<Int32, BPFCapture.CaptureError> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.helper("socket")) }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(BandwidthShaper.socketPath.utf8) + [0]) }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return .failure(.helper("not running")) }
        let req = Array("{\"cmd\":\"bpf\"}\n".utf8)
        _ = write(fd, req, req.count)

        var payload = [UInt8](repeating: 0, count: 512)
        var control = [UInt8](repeating: 0, count: 64)
        let received: Int = payload.withUnsafeMutableBytes { pbuf in
            control.withUnsafeMutableBytes { cbuf in
                var iov = iovec(iov_base: pbuf.baseAddress, iov_len: pbuf.count)
                return withUnsafeMutablePointer(to: &iov) { iovp in
                    var msg = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovp, msg_iovlen: 1,
                                     msg_control: cbuf.baseAddress, msg_controllen: socklen_t(cbuf.count), msg_flags: 0)
                    return recvmsg(fd, &msg, 0)
                }
            }
        }
        guard received > 0 else { return .failure(.helper("no reply")) }
        // cmsghdr { u32 len; i32 level; i32 type; } followed by the fd
        let level = Int32(bitPattern: control.loadLE32(4))
        let type = Int32(bitPattern: control.loadLE32(8))
        if level == SOL_SOCKET && type == SCM_RIGHTS {
            return .success(Int32(bitPattern: control.loadLE32(12)))
        }
        let text = String(decoding: payload.prefix(received), as: UTF8.self)
        return .failure(.helper(text.contains("unknown command") ? "helper is outdated — reinstall it from the Bandwidth tab" : text))
    }
}

/// Minimal libpcap file writer (Wireshark/tcpdump compatible).
enum PcapWriter {
    static func linktype(forDLT dlt: UInt32) -> UInt32 {
        switch dlt {
        case 12, 14: return 101   // DLT_RAW → LINKTYPE_RAW
        default: return dlt       // EN10MB (1), NULL (0), LOOP (108) map 1:1
        }
    }

    static func data(packets: [RawPacket], dlt: UInt32) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        u32(0xA1B2C3D4); u16(2); u16(4); u32(0); u32(0); u32(262_144); u32(linktype(forDLT: dlt))
        for p in packets {
            u32(p.seconds); u32(p.micros); u32(UInt32(p.data.count)); u32(UInt32(p.wirelen))
            d.append(contentsOf: p.data)
        }
        return d
    }
}
