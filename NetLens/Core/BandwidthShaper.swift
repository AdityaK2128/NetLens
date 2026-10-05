import Foundation
import Observation
import AppKit
import Darwin

/// One application as the user thinks of it (helpers folded into their app).
struct AppTraffic: Identifiable, Hashable {
    let id: String              // bundle path, or executable name for daemons
    var name: String
    var pids: Set<Int32> = []
    var rateIn: Double = 0      // bytes/s
    var rateOut: Double = 0
    var sockets = 0
    var established = 0
    var ports: Set<Int> = []
    /// Ports owned by a transparent proxy but carrying this app's flows.
    var relayedPorts: Set<Int> = []
    var relayName: String?
    var isRelay = false
    var isApp: Bool

    var shapedPorts: Set<Int> { ports.union(relayedPorts) }

    static func == (a: AppTraffic, b: AppTraffic) -> Bool { a.id == b.id && a.rateIn == b.rateIn && a.rateOut == b.rateOut && a.sockets == b.sockets }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct BandwidthLimit: Codable, Hashable {
    var downKBps: Int = 0   // 0 = unlimited
    var upKBps: Int = 0
    var name: String = ""
    var isActive: Bool { downKBps > 0 || upKBps > 0 }
}

/// Per-app bandwidth caps, enforced by the privileged `netlens-shaper` helper using
/// dummynet pipes. The app supplies each limited app's *current* local ports every
/// sample; the helper rewrites the pf anchor so new connections are caught within
/// one sampling interval.
@MainActor
@Observable
final class BandwidthShaper {
    enum HelperState: Equatable {
        case unknown, notInstalled, running(activeRules: Int), error(String)
    }

    private(set) var apps: [AppTraffic] = []
    private(set) var history: [String: [RateSample]] = [:]
    private(set) var helper: HelperState = .unknown
    private(set) var busy = false
    var limits: [String: BandwidthLimit] = [:] {
        didSet { persist(); Task { await push() } }
    }
    var paused = false { didSet { Task { await push() } } }

    nonisolated static let helperLabel = "app.netlens.shaper"
    nonisolated static let helperPath = "/Library/PrivilegedHelperTools/app.netlens.shaper"
    nonisolated static let plistPath = "/Library/LaunchDaemons/app.netlens.shaper.plist"
    nonisolated static let socketPath = "/var/run/app.netlens.shaper.sock"

    @ObservationIgnored private var idMap: [String: Int] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: "bandwidth.limits"),
           let l = try? JSONDecoder().decode([String: BandwidthLimit].self, from: data) {
            limits = l
        }
        Task { await refreshHelperState() }
    }

    var activeLimitCount: Int { limits.values.filter(\.isActive).count }

    private func persist() {
        if let d = try? JSONEncoder().encode(limits) { UserDefaults.standard.set(d, forKey: "bandwidth.limits") }
    }

    // MARK: sampling

    /// Called after each connection-monitor sample.
    func ingest(_ monitor: ConnectionMonitor) {
        var byApp: [String: AppTraffic] = [:]
        var portOwners: [Int: Set<String>] = [:]
        for p in monitor.processes {
            let ident = ProcessCatalog.shared.identity(pid: p.pid, fallbackName: p.name)
            let key = ident.bundlePath ?? ident.path ?? ident.executable
            var a = byApp[key] ?? AppTraffic(id: key, name: ident.name, isApp: ident.isApp)
            a.pids.insert(p.pid)
            a.rateIn += p.rateIn
            a.rateOut += p.rateOut
            a.sockets += p.sockets
            a.established += p.established
            byApp[key] = a
        }
        let pidToKey = Dictionary(byApp.values.flatMap { a in a.pids.map { ($0, a.id) } }, uniquingKeysWith: { a, _ in a })
        for s in monitor.sockets {
            guard let key = pidToKey[s.pid], let port = s.localPort else { continue }
            byApp[key]?.ports.insert(Int(port))
            portOwners[Int(port), default: []].insert(key)
            if let origin = s.originPid, let okey = pidToKey[origin], okey != key {
                let relayName = byApp[key]?.name
                byApp[okey]?.relayedPorts.insert(Int(port))
                byApp[okey]?.relayName = relayName
            }
        }
        for pid in monitor.relayPids { if let k = pidToKey[pid] { byApp[k]?.isRelay = true } }
        // A port claimed by several apps (SO_REUSEPORT, e.g. mDNS 5353) can't be attributed — skip it.
        let shared = Set(portOwners.filter { $0.value.count > 1 }.keys)
        for k in byApp.keys { byApp[k]!.ports.subtract(shared); byApp[k]!.relayedPorts.subtract(shared) }

        let now = Date()
        for a in byApp.values {
            var h = history[a.id] ?? []
            h.append(RateSample(time: now, inBps: a.rateIn, outBps: a.rateOut))
            if h.count > 60 { h.removeFirst(h.count - 60) }
            history[a.id] = h
        }
        // Keep limited apps visible even when not running.
        for (k, l) in limits where byApp[k] == nil && l.isActive {
            byApp[k] = AppTraffic(id: k, name: l.name, isApp: k.hasSuffix(".app"))
        }
        apps = byApp.values.sorted { a, b in
            let la = limits[a.id]?.isActive == true, lb = limits[b.id]?.isActive == true
            if la != lb { return la }
            let ra = a.rateIn + a.rateOut, rb = b.rateIn + b.rateOut
            if ra != rb { return ra > rb }
            return a.sockets > b.sockets
        }
        Task { await push() }
    }

    func setLimit(_ app: AppTraffic, down: Int? = nil, up: Int? = nil) {
        var l = limits[app.id] ?? BandwidthLimit(name: app.name)
        if let down { l.downKBps = down }
        if let up { l.upKBps = up }
        l.name = app.name
        limits[app.id] = l.isActive ? l : nil
    }

    func removeAll() { limits = [:] }

    // MARK: helper communication

    private func ruleID(for key: String) -> Int {
        if let i = idMap[key] { return i }
        let next = (idMap.values.max() ?? 0) + 1
        idMap[key] = next
        return next
    }

    private func push() async {
        guard case .running = helper else { return }
        var rules: [[String: Any]] = []
        if !paused {
            for a in apps {
                guard let l = limits[a.id], l.isActive, !a.shapedPorts.isEmpty else { continue }
                rules.append(["id": ruleID(for: a.id), "downKBps": l.downKBps, "upKBps": l.upKBps, "ports": a.shapedPorts.sorted()])
            }
        }
        let resp = await Self.send(["cmd": "apply", "rules": rules])
        if let resp, resp["ok"] as? Bool == true {
            helper = .running(activeRules: resp["activeRules"] as? Int ?? rules.count)
        } else if let resp {
            helper = .error(resp["message"] as? String ?? "helper error")
        } else {
            helper = FileManager.default.fileExists(atPath: Self.helperPath) ? .error("helper not responding") : .notInstalled
        }
    }

    func refreshHelperState() async {
        if let resp = await Self.send(["cmd": "status"]), resp["ok"] as? Bool == true {
            helper = .running(activeRules: resp["activeRules"] as? Int ?? 0)
        } else {
            helper = FileManager.default.fileExists(atPath: Self.helperPath) ? .error("installed but not responding") : .notInstalled
        }
    }

    /// Newline-delimited JSON over the helper's Unix socket.
    nonisolated static func send(_ obj: [String: Any]) async -> [String: Any]? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: sendSync(obj))
            }
        }
    }

    nonisolated private static func sendSync(_ obj: [String: Any]) -> [String: Any]? {
        guard var payload = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        payload.append(0x0A)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(socketPath.utf8) + [0]) }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, payload.count) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if buf[0..<n].contains(0x0A) { break }
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: install / uninstall (explicit user action, standard admin prompt)

    func install() async {
        busy = true
        defer { busy = false }
        guard let helperBinary = Bundle.main.url(forAuxiliaryExecutable: "netlens-shaper")?.path else {
            helper = .error("helper binary missing from app bundle")
            return
        }
        let uid = getuid()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("netlens-install-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(Self.helperLabel)</string>
            <key>ProgramArguments</key>
            <array><string>\(Self.helperPath)</string><string>--uid</string><string>\(uid)</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardErrorPath</key><string>/var/log/netlens-shaper.log</string>
        </dict>
        </plist>
        """
        let plistTmp = tmp.appendingPathComponent("helper.plist")
        try? plist.write(to: plistTmp, atomically: true, encoding: .utf8)
        let script = """
        set -e
        mkdir -p /Library/PrivilegedHelperTools
        launchctl bootout system/\(Self.helperLabel) 2>/dev/null || true
        cp '\(helperBinary)' '\(Self.helperPath)'
        chown root:wheel '\(Self.helperPath)'
        chmod 755 '\(Self.helperPath)'
        cp '\(plistTmp.path)' '\(Self.plistPath)'
        chown root:wheel '\(Self.plistPath)'
        chmod 644 '\(Self.plistPath)'
        launchctl bootstrap system '\(Self.plistPath)'
        """
        let scriptURL = tmp.appendingPathComponent("install.sh")
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let r = await Shell.runAsAdmin("/bin/sh '\(scriptURL.path)'")
        try? FileManager.default.removeItem(at: tmp)
        if !r.ok {
            helper = .error(r.stderr.contains("User canceled") ? "Installation cancelled" : r.stderr.trimmed)
            return
        }
        try? await Task.sleep(for: .seconds(1))
        await refreshHelperState()
        await push()
    }

    func uninstall() async {
        busy = true
        defer { busy = false }
        _ = await Self.send(["cmd": "clear"])
        let script = "launchctl bootout system/\(Self.helperLabel) 2>/dev/null; rm -f '\(Self.plistPath)' '\(Self.helperPath)' '\(Self.socketPath)'; true"
        let r = await Shell.runAsAdmin(script)
        if r.ok { helper = .notInstalled } else { await refreshHelperState() }
    }
}
