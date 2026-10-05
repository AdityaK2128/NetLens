// netlens-shaper — NetLens's privileged traffic-shaping helper.
//
// Runs as root (LaunchDaemon), listens on a Unix socket, and turns per-app
// {ports, KB/s} requests into dummynet pipes + pf rules in its own anchor.
// Also reads the ARP cache for NetLens's LAN view (macOS hides it from apps).
// Design constraints:
//   • Accepts only validated integers (ports, rates, ids) — never shell text.
//   • Only the installing user (and root) may connect (getpeereid).
//   • Watchdog: if the app stops refreshing for 30 s, every limit is removed,
//     so a crashed or quit app can never leave the machine throttled.
import Foundation
import Darwin

let helperVersion = 3
let socketPath = "/var/run/app.netlens.shaper.sock"
/// Our rules live in a child of whichever wildcard `dummynet-anchor "X/*"` the live main
/// ruleset evaluates — normally Apple's stock "com.apple/*" (the hook Network Link
/// Conditioner uses), but a VPN kill switch or firewall app may have swapped in its own
/// ruleset with a different one (NordVPN uses "main/*"). The main ruleset is never edited,
/// and dummynet rules only pace packets — they can't pass or block anything.
let defaultAnchor = "com.apple/250.NetLensShaper"
var anchor = defaultAnchor
var usedAnchors: Set<String> = [defaultAnchor]
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

/// Packets/bytes the kernel has steered into a rule's pipes — proof a cap is working.
struct Counter: Codable {
    let id: Int
    var downPackets = 0, downBytes = 0, upPackets = 0, upBytes = 0
}

struct Response: Codable {
    var ok: Bool
    var version: Int = helperVersion
    var message: String?
    var activeRules: Int = 0
    var pfEnabled: Bool = false
    var attached: Bool?
    var counters: [Counter]?
    var arp: String?
}

var allowedUID: uid_t = 0
var pfToken: String?
var lastApply = Date()
var activeRules: [Rule] = []
var loadedRules = ""                    // anchor text currently in the kernel
var pipeRates: [Int: Int] = [:]         // pipe → configured KB/s
var counterBase: [Int: (Int, Int)] = [:] // pipe → counts carried over anchor reloads
var attachProblem: String?
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
    let text = String(decoding: data, as: UTF8.self)
    if p.terminationStatus != 0 {
        log("\((path as NSString).lastPathComponent) \(args.joined(separator: " ")) → exit \(p.terminationStatus): \(text.prefix(400))")
    }
    return (p.terminationStatus, text)
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

func pfIsEnabled() -> Bool { run(pfctl, ["-s", "info"]).1.contains("Status: Enabled") }

/// Takes an enable reference (pf stays on while anyone holds one). Re-takes it if
/// something switched pf off underneath us.
func ensurePFEnabled() {
    if pfToken != nil, pfIsEnabled() { return }
    releasePF()
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

/// Main-ruleset dummynet lines, e.g. `dummynet-anchor "com.apple/*" all`.
func mainDummynet() -> String { run(pfctl, ["-s", "dummynet"]).1 }

/// Parents of the wildcard dummynet anchors the live main ruleset evaluates.
func dummynetParents() -> [String] {
    mainDummynet().split(separator: "\n").compactMap { line -> String? in
        let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
        guard line.trimmingCharacters(in: .whitespaces).hasPrefix("dummynet-anchor"), parts.count >= 3 else { return nil }
        let name = String(parts[1])
        guard name.hasSuffix("/*"), name.count > 2,
              name.allSatisfy({ $0.isLetter || $0.isNumber || "._-/*".contains($0) }) else { return nil }
        return String(name.dropLast(2))
    }
}

/// Is any anchor of ours reachable from the live main ruleset?
func isAttached() -> Bool { !dummynetParents().isEmpty }

/// The live main ruleset's own lines (anchors included), minus pfctl's chatter.
func mainRulesetLines() -> [String] {
    (run(pfctl, ["-s", "rules"]).1 + run(pfctl, ["-s", "nat"]).1 + mainDummynet())
        .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("No ALTQ") && !$0.hasPrefix("ALTQ") && !$0.hasPrefix("DUMMYNET") }
}

/// Where our rules must live for the kernel to evaluate them, or nil if the live
/// ruleset offers no hook. If the main ruleset lost Apple's anchors (flushed, or never
/// loaded) it is restored from /etc/pf.conf — exactly what macOS does at boot. A ruleset
/// another app installed is never modified.
func resolveAnchor() -> String? {
    var parents = dummynetParents()
    if parents.isEmpty {
        guard mainRulesetLines().allSatisfy({ $0.contains("\"com.apple/*\"") }) else {
            attachProblem = "Another app has replaced macOS's firewall rules (often a VPN kill switch or a firewall app) with a ruleset that has no hook for traffic shaping, and NetLens won't modify it."
            return nil
        }
        log("main ruleset has no dummynet anchor — reloading /etc/pf.conf")
        run(pfctl, ["-f", "/etc/pf.conf"])
        parents = dummynetParents()
        guard !parents.isEmpty else {
            attachProblem = "macOS's firewall configuration (/etc/pf.conf) has no dummynet anchor."
            return nil
        }
    }
    attachProblem = nil
    return parents.contains("com.apple") ? defaultAnchor : (parents[0] + "/NetLensShaper")
}

/// Sums the per-rule packet/byte counters of our anchor by pipe; also returns how many
/// rules are loaded, so a flush by another app is noticed.
func readCounters() -> (byPipe: [Int: (Int, Int)], rules: Int) {
    var out: [Int: (Int, Int)] = [:]
    var rules = 0
    var pipe: Int?
    func int(after key: String, in line: Substring) -> Int {
        guard let r = line.range(of: key) else { return 0 }
        return Int(line[r.upperBound...].trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }) ?? 0
    }
    for line in run(pfctl, ["-a", anchor, "-s", "dummynet", "-v"]).1.split(separator: "\n") {
        if line.hasPrefix("dummynet"), let r = line.range(of: " pipe ") {
            pipe = Int(line[r.upperBound...].prefix { $0.isNumber })
            rules += 1
        } else if line.contains("Packets:"), let p = pipe {
            let cur = out[p] ?? (0, 0)
            out[p] = (cur.0 + int(after: "Packets:", in: line), cur.1 + int(after: "Bytes:", in: line))
        }
    }
    return (out, rules)
}

func counters(for rules: [Rule], live now: [Int: (Int, Int)]) -> [Counter] {
    func total(_ pipe: Int) -> (Int, Int) {
        let a = counterBase[pipe] ?? (0, 0), b = now[pipe] ?? (0, 0)
        return (a.0 + b.0, a.1 + b.1)
    }
    return rules.map { r in
        let d = total(pipeBase + r.id * 2), u = total(pipeBase + r.id * 2 + 1)
        return Counter(id: r.id, downPackets: d.0, downBytes: d.1, upPackets: u.0, upBytes: u.1)
    }
}

func diagnostics() -> String {
    var out = "helper v\(helperVersion), anchor \(anchor), hooks \(dummynetParents()), pf token \(pfToken ?? "none")\n"
    let cmds: [(String, [String])] = [
        (pfctl, ["-s", "info"]), (pfctl, ["-s", "References"]), (pfctl, ["-s", "Anchors"]),
        (pfctl, ["-s", "rules"]), (pfctl, ["-s", "nat"]), (pfctl, ["-s", "dummynet"]),
        (pfctl, ["-a", "com.apple", "-s", "Anchors"]),
    ] + dummynetParents().map { (pfctl, ["-a", $0, "-s", "Anchors"]) } + [
        (pfctl, ["-a", anchor, "-s", "dummynet", "-v"]),
        (dnctl, ["list"]),
    ]
    for (path, a) in cmds {
        let (st, text) = run(path, a)
        out += "\n$ \((path as NSString).lastPathComponent) \(a.joined(separator: " ")) [\(st)]\n" + text.prefix(4000)
    }
    return String(out.prefix(60_000))
}

func apply(_ rules: [Rule]) -> Response {
    if let err = validate(rules) { return Response(ok: false, message: err) }
    lastApply = Date()
    let effective = rules.filter { !$0.ports.isEmpty && ($0.downKBps > 0 || $0.upKBps > 0) }
    if effective.isEmpty {
        if !activeRules.isEmpty || !loadedRules.isEmpty || pfToken != nil { clearAll() }
        return Response(ok: true, message: "no active limits")
    }

    var wanted: [Int: Int] = [:]
    var pf = ""
    for r in effective {
        let ports = r.ports.sorted().map(String.init).joined(separator: " ")
        if r.downKBps > 0 {
            let pipe = pipeBase + r.id * 2
            wanted[pipe] = r.downKBps
            pf += "dummynet in quick proto { tcp udp } from any to any port { \(ports) } pipe \(pipe)\n"
        }
        if r.upKBps > 0 {
            let pipe = pipeBase + r.id * 2 + 1
            wanted[pipe] = r.upKBps
            pf += "dummynet out quick proto { tcp udp } from any port { \(ports) } to any pipe \(pipe)\n"
        }
    }
    for (pipe, kbps) in wanted where pipeRates[pipe] != kbps {
        run(dnctl, ["pipe", "\(pipe)", "config", "bw", "\(kbps)KByte/s"])
        pipeRates[pipe] = kbps
    }
    ensurePFEnabled()
    let target = resolveAnchor()
    var status: Int32 = 0, out = ""
    var liveCounts: [Int: (Int, Int)] = [:]   // zero right after a reload
    if let target {
        if target != anchor {
            log("shaping hook moved: \(anchor) → \(target)")
            run(pfctl, ["-a", anchor, "-F", "all"])
            anchor = target
            usedAnchors.insert(target)
            loadedRules = ""
            counterBase = [:]
        }
        let live = readCounters()
        if !loadedRules.isEmpty && live.rules == 0 { loadedRules = "" }   // flushed by someone else
        if pf != loadedRules {
            // Rule counters reset on reload; carry them over so totals keep growing.
            for (pipe, c) in live.byPipe {
                let b = counterBase[pipe] ?? (0, 0)
                counterBase[pipe] = (b.0 + c.0, b.1 + c.1)
            }
            (status, out) = run(pfctl, ["-a", anchor, "-f", "-"], input: pf)
            loadedRules = status == 0 ? pf : ""
            if status != 0 { log("pfctl load failed: \(out)") }
        } else {
            liveCounts = live.byPipe
        }
    }
    for stale in Set(pipeRates.keys).subtracting(wanted.keys) {
        run(dnctl, ["pipe", "delete", "\(stale)"])
        pipeRates[stale] = nil
        counterBase[stale] = nil
    }
    activeRules = effective
    return Response(ok: status == 0, message: status == 0 ? attachProblem : out, activeRules: effective.count,
                    pfEnabled: pfToken != nil, attached: target != nil, counters: counters(for: effective, live: liveCounts))
}

func clearAll() {
    for p in dummynetParents() where p != "com.apple" { usedAnchors.insert(p + "/NetLensShaper") }
    for a in usedAnchors { run(pfctl, ["-a", a, "-F", "all"]) }
    for p in pipeRates.keys { run(dnctl, ["pipe", "delete", "\(p)"]) }
    pipeRates = [:]
    counterBase = [:]
    loadedRules = ""
    activeRules = []
    releasePF()
}

/// Pipes in our number range left behind by a previous run (e.g. after a crash).
func deleteStalePipes() {
    for line in run(dnctl, ["list"]).1.split(separator: "\n") {
        guard let n = Int(line.prefix { $0.isNumber }), line.dropFirst(String(n).count).hasPrefix(":"),
              (pipeBase...(pipeBase + 401)).contains(n) else { continue }
        run(dnctl, ["pipe", "delete", "\(n)"])
    }
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
                resp = Response(ok: true, activeRules: activeRules.count, pfEnabled: pfToken != nil, attached: isAttached())
            case "diag":
                resp = Response(ok: true, message: diagnostics(), activeRules: activeRules.count, pfEnabled: pfToken != nil)
            case "neighbors":
                // macOS hides the ARP cache from apps; a launchd daemon can still read it.
                resp = Response(ok: true, arp: String(run("/usr/sbin/arp", ["-an"]).1.prefix(200_000)))
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

queue.sync { clearAll(); deleteStalePipes() }   // stale state from a previous run

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
