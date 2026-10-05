// netlens-shaper — NetLens's privileged traffic-shaping helper.
//
// Runs as root (LaunchDaemon), listens on a Unix socket, and turns per-app
// {ports, KB/s} requests into dummynet pipes + pf rules in its own anchor.
// Design constraints:
//   • Accepts only validated integers (ports, rates, ids) — never shell text.
//   • Only the installing user (and root) may connect (getpeereid).
//   • Watchdog: if the app stops refreshing for 30 s, every limit is removed,
//     so a crashed or quit app can never leave the machine throttled.
import Foundation
import Darwin

let helperVersion = 1
let socketPath = "/var/run/app.netlens.shaper.sock"
let anchor = "com.apple/250.NetLensShaper"
let pipeBase = 47000
let pfctl = "/sbin/pfctl"
let dnctl = "/usr/sbin/dnctl"

struct Rule: Codable {
    let id: Int
    let downKBps: Int     // 0 = unlimited
    let upKBps: Int       // 0 = unlimited
    let ports: [Int]
}

struct Request: Codable {
    let cmd: String
    let rules: [Rule]?
}

struct Response: Codable {
    var ok: Bool
    var version: Int = helperVersion
    var message: String?
    var activeRules: Int = 0
    var pfEnabled: Bool = false
}

var allowedUID: uid_t = 0
var pfToken: String?
var lastApply = Date()
var activeRules: [Rule] = []
var installedPipes: Set<Int> = []
let queue = DispatchQueue(label: "shaper")

// MARK: - Process helpers

@discardableResult
func run(_ path: String, _ args: [String], input: String? = nil) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    let inPipe = Pipe()
    p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
    do { try p.run() } catch { return (-1, "\(error)") }
    if let input {
        inPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
        try? inPipe.fileHandleForWriting.close()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func log(_ s: String) {
    FileHandle.standardError.write("[netlens-shaper] \(s)\n".data(using: .utf8)!)
}

// MARK: - Shaping

func validate(_ rules: [Rule]) -> String? {
    if rules.count > 64 { return "too many rules" }
    var ids = Set<Int>()
    for r in rules {
        guard (1...200).contains(r.id), ids.insert(r.id).inserted else { return "bad id \(r.id)" }
        for k in [r.downKBps, r.upKBps] where k != 0 && !(1...10_000_000).contains(k) { return "bad rate \(k)" }
        guard r.ports.count <= 4000, r.ports.allSatisfy({ (1...65535).contains($0) }) else { return "bad ports" }
    }
    return nil
}

func ensurePFEnabled() {
    guard pfToken == nil else { return }
    let (_, out) = run(pfctl, ["-E"])
    // "Token : 1234567890"
    for line in out.split(separator: "\n") where line.contains("Token") {
        pfToken = line.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

func releasePF() {
    if let t = pfToken, t.allSatisfy(\.isNumber) { run(pfctl, ["-X", t]) }
    pfToken = nil
}

func apply(_ rules: [Rule]) -> Response {
    if let err = validate(rules) { return Response(ok: false, message: err) }
    lastApply = Date()
    let effective = rules.filter { !$0.ports.isEmpty && ($0.downKBps > 0 || $0.upKBps > 0) }
    if effective.isEmpty {
        clearAll()
        return Response(ok: true, message: "no active limits")
    }

    var wantedPipes = Set<Int>()
    var pf = ""
    for r in effective {
        let ports = r.ports.map(String.init).joined(separator: " ")
        if r.downKBps > 0 {
            let pipe = pipeBase + r.id * 2
            wantedPipes.insert(pipe)
            run(dnctl, ["pipe", "\(pipe)", "config", "bw", "\(r.downKBps)KByte/s"])
            pf += "dummynet in quick proto { tcp udp } from any to any port { \(ports) } pipe \(pipe)\n"
        }
        if r.upKBps > 0 {
            let pipe = pipeBase + r.id * 2 + 1
            wantedPipes.insert(pipe)
            run(dnctl, ["pipe", "\(pipe)", "config", "bw", "\(r.upKBps)KByte/s"])
            pf += "dummynet out quick proto { tcp udp } from any port { \(ports) } to any pipe \(pipe)\n"
        }
    }
    ensurePFEnabled()
    let (status, out) = run(pfctl, ["-a", anchor, "-f", "-"], input: pf)
    for stale in installedPipes.subtracting(wantedPipes) { run(dnctl, ["pipe", "delete", "\(stale)"]) }
    installedPipes = wantedPipes
    activeRules = effective
    if status != 0 { log("pfctl load failed: \(out)") }
    return Response(ok: status == 0, message: status == 0 ? nil : out, activeRules: effective.count, pfEnabled: pfToken != nil)
}

func clearAll() {
    run(pfctl, ["-a", anchor, "-F", "all"])
    for p in installedPipes { run(dnctl, ["pipe", "delete", "\(p)"]) }
    installedPipes = []
    activeRules = []
    releasePF()
}

// MARK: - BPF descriptor passing

/// Opens a free /dev/bpfN as root and hands the descriptor to the client with
/// SCM_RIGHTS. The client configures and reads it; the helper keeps nothing.
func sendBPF(to client: Int32) -> Bool {
    var bpf: Int32 = -1
    for i in 0..<256 {
        let fd = open("/dev/bpf\(i)", O_RDWR)
        if fd >= 0 { bpf = fd; break }
        if errno == ENOENT { break }
    }
    guard bpf >= 0 else { return false }
    defer { close(bpf) }
    var payload = Array("{\"ok\":true}\n".utf8)
    // CMSG_SPACE(sizeof(int)) on Darwin = 12-byte header + 4-byte fd
    var control = [UInt8](repeating: 0, count: 16)
    func put32(_ v: Int32, _ at: Int) { withUnsafeBytes(of: v.littleEndian) { for (k, b) in $0.enumerated() { control[at + k] = b } } }
    put32(16, 0); put32(SOL_SOCKET, 4); put32(SCM_RIGHTS, 8); put32(bpf, 12)
    let sent = payload.withUnsafeMutableBytes { pbuf in
        control.withUnsafeMutableBytes { cbuf in
            var iov = iovec(iov_base: pbuf.baseAddress, iov_len: pbuf.count)
            return withUnsafeMutablePointer(to: &iov) { iovp in
                var msg = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovp, msg_iovlen: 1,
                                 msg_control: cbuf.baseAddress, msg_controllen: 16, msg_flags: 0)
                return sendmsg(client, &msg, 0)
            }
        }
    }
    return sent > 0
}

// MARK: - Socket server

func handle(client fd: Int32) {
    defer { close(fd) }
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == 0 || uid == allowedUID else {
        log("rejected peer uid \(uid)")
        return
    }
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while data.count < 1_000_000 {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        data.append(buf, count: n)
        if buf[0..<n].contains(0x0A) { break }
    }
    var resp = Response(ok: false, message: "bad request")
    if let req = try? JSONDecoder().decode(Request.self, from: data), req.cmd == "bpf" {
        if sendBPF(to: fd) { return }
        resp = Response(ok: false, message: "no free BPF device")
    } else if let req = try? JSONDecoder().decode(Request.self, from: data) {
        queue.sync {
            switch req.cmd {
            case "status":
                resp = Response(ok: true, activeRules: activeRules.count, pfEnabled: pfToken != nil)
            case "apply":
                resp = apply(req.rules ?? [])
            case "clear":
                clearAll()
                resp = Response(ok: true)
            default:
                resp = Response(ok: false, message: "unknown command")
            }
        }
    }
    if var out = try? JSONEncoder().encode(resp) {
        out.append(0x0A)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
    }
}

// MARK: - main

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--uid"), i + 1 < args.count, let u = UInt32(args[i + 1]) { allowedUID = u }
guard getuid() == 0 else {
    log("must run as root")
    exit(1)
}

for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { queue.sync { clearAll() }; unlink(socketPath); exit(0) }
    src.resume()
    _ = Unmanaged.passRetained(src as AnyObject)
}

queue.sync { clearAll() }   // stale state from a previous run

unlink(socketPath)
let server = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    let bytes = Array(socketPath.utf8)
    raw.copyBytes(from: bytes + [0])
}
let bound = withUnsafePointer(to: &addr) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard bound == 0 else { log("bind failed errno \(errno)"); exit(1) }
chmod(socketPath, 0o666)        // access is enforced per-connection with getpeereid
listen(server, 8)
log("listening (uid \(allowedUID) allowed)")

let acceptSource = DispatchSource.makeReadSource(fileDescriptor: server, queue: DispatchQueue.global())
acceptSource.setEventHandler {
    let client = accept(server, nil, nil)
    if client >= 0 { DispatchQueue.global().async { handle(client: client) } }
}
acceptSource.resume()

// Watchdog: the app re-applies every few seconds; silence means it's gone.
let watchdog = DispatchSource.makeTimerSource(queue: queue)
watchdog.schedule(deadline: .now() + 10, repeating: 10)
watchdog.setEventHandler {
    if !activeRules.isEmpty, Date().timeIntervalSince(lastApply) > 30 {
        log("app went quiet — clearing limits")
        clearAll()
    }
}
watchdog.resume()

dispatchMain()
