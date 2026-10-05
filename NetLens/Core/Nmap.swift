import Foundation
import Observation

// MARK: - Results

struct NmapScript: Hashable {
    let id: String
    let output: String
}

struct NmapPort: Identifiable, Hashable {
    var id: String { "\(proto)/\(port)" }
    let port: Int
    let proto: String
    var state = ""
    var reason: String?
    var service: String?
    var product: String?
    var version: String?
    var extra: String?
    var tunnel: String?
    var scripts: [NmapScript] = []

    var versionText: String {
        [product, version, extra.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }
    var serviceText: String {
        (tunnel == "ssl" ? "ssl/" : "") + (service ?? "unknown")
    }
}

struct NmapHost: Identifiable, Hashable {
    var id: String { address }
    var address = ""
    var mac: String?
    var vendor: String?
    var hostnames: [String] = []
    var status = "unknown"
    var reason: String?
    var latencyMs: Double?
    var ports: [NmapPort] = []
    var hiddenPorts: [String: Int] = [:]   // "closed": 995 — ports nmap summarised
    var osMatches: [(name: String, accuracy: Int)] = []
    var distance: Int?
    var scripts: [NmapScript] = []

    var isUp: Bool { status == "up" }
    /// With -Pn nmap reports every target as "up" (reason "user-set") even if nothing
    /// ever answered. Such a host only counts once some port or its MAC replied.
    var responded: Bool {
        guard isUp else { return false }
        if reason != "user-set" || mac != nil { return true }
        return ports.contains { $0.state != "filtered" } || hiddenPorts.keys.contains { $0 != "filtered" }
    }
    var openPorts: [NmapPort] { ports.filter { $0.state.hasPrefix("open") } }

    static func == (a: NmapHost, b: NmapHost) -> Bool { a.address == b.address && a.ports == b.ports && a.status == b.status }
    func hash(into h: inout Hasher) { h.combine(address) }
}

struct NmapRun {
    var hosts: [NmapHost] = []
    var args: String?
    var version: String?
    var elapsed: Double?
    var summary: String?
    var up = 0, down = 0, total = 0
    var truncated = false
}

/// Reads nmap's `-oX` XML. Tolerates a file cut short by a stopped scan: everything
/// parsed before the break is kept.
final class NmapXMLParser: NSObject, XMLParserDelegate {
    private var run = NmapRun()
    private var host: NmapHost?
    private var port: NmapPort?

    static func parse(_ data: Data) -> NmapRun {
        let p = NmapXMLParser()
        let x = XMLParser(data: data)
        x.delegate = p
        if !x.parse() {
            if let h = p.host, !h.address.isEmpty { p.run.hosts.append(h) }
            p.run.truncated = true
        }
        return p.run
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch name {
        case "nmaprun":
            run.args = a["args"]
            run.version = a["version"]
        case "host":
            host = NmapHost()
        case "status":
            host?.status = a["state"] ?? "unknown"
            host?.reason = a["reason"]
        case "address":
            if a["addrtype"] == "mac" {
                host?.mac = a["addr"]?.lowercased()
                host?.vendor = a["vendor"]
            } else if host?.address.isEmpty == true {
                host?.address = a["addr"] ?? ""
            }
        case "hostname":
            if let n = a["name"], host?.hostnames.contains(n) == false { host?.hostnames.append(n) }
        case "extraports":
            if let s = a["state"], let c = Int(a["count"] ?? "") { host?.hiddenPorts[s, default: 0] += c }
        case "port":
            port = NmapPort(port: Int(a["portid"] ?? "") ?? 0, proto: a["protocol"] ?? "tcp")
        case "state":
            port?.state = a["state"] ?? ""
            port?.reason = a["reason"]
        case "service":
            port?.service = a["name"]
            port?.product = a["product"]
            port?.version = a["version"]
            port?.extra = a["extrainfo"]
            port?.tunnel = a["tunnel"]
        case "script":
            let s = NmapScript(id: a["id"] ?? "", output: (a["output"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            if port != nil { port?.scripts.append(s) } else { host?.scripts.append(s) }
        case "osmatch":
            if let n = a["name"] { host?.osMatches.append((n, Int(a["accuracy"] ?? "") ?? 0)) }
        case "distance":
            host?.distance = Int(a["value"] ?? "")
        case "times":
            if let srtt = Double(a["srtt"] ?? ""), srtt > 0 { host?.latencyMs = srtt / 1000 }
        case "finished":
            run.elapsed = Double(a["elapsed"] ?? "")
            run.summary = a["summary"]
        case "hosts":
            run.up = Int(a["up"] ?? "") ?? 0
            run.down = Int(a["down"] ?? "") ?? 0
            run.total = Int(a["total"] ?? "") ?? 0
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "port":
            if let p = port { host?.ports.append(p) }
            port = nil
        case "host":
            if let h = host, !h.address.isEmpty { run.hosts.append(h) }
            host = nil
        default:
            break
        }
    }
}

// MARK: - Profiles

struct NmapProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let args: [String]
    var needsRoot = false
    var setsPorts = false

    static let all: [NmapProfile] = [
        NmapProfile(id: "discover", name: "Find hosts", summary: "Ping sweep: which addresses are up. No ports are scanned.", args: ["-sn"]),
        NmapProfile(id: "quick", name: "Quick scan", summary: "The 100 most common TCP ports.", args: ["-F"], setsPorts: true),
        NmapProfile(id: "standard", name: "Top 1,000 ports", summary: "nmap's default selection of the 1,000 most common TCP ports.", args: []),
        NmapProfile(id: "services", name: "Services & versions", summary: "Top 1,000 ports, then asks every open port what software and version is answering.", args: ["-sV"]),
        NmapProfile(id: "full", name: "All TCP ports", summary: "Every port from 1 to 65,535. Thorough, and slow across a whole network.", args: ["-p-"], setsPorts: true),
        NmapProfile(id: "aggressive", name: "OS & deep scan", summary: "OS fingerprinting, service versions, default scripts and traceroute (-A). Needs administrator rights.", args: ["-A"], needsRoot: true),
        NmapProfile(id: "udp", name: "Common UDP", summary: "The 50 most common UDP services — DNS, DHCP, SNMP, mDNS, NTP… Needs administrator rights.", args: ["-sU", "--top-ports", "50"], needsRoot: true, setsPorts: true),
        NmapProfile(id: "custom", name: "Custom", summary: "Your own nmap arguments.", args: []),
    ]
}

// MARK: - Scanner

@MainActor
@Observable
final class NmapScanner {
    enum State: Equatable { case idle, running, finished, failed(String) }
    enum Install: Equatable { case idle, running, failed(String) }

    private(set) var path: String?
    private(set) var version: String?
    private(set) var brewPath: String?
    private(set) var checked = false

    private(set) var state = State.idle
    private(set) var progress: Double?
    private(set) var phase: String?
    private(set) var remaining: String?
    private(set) var log: [String] = []
    private(set) var result: NmapRun?
    private(set) var discovered: [String] = []      // "22/tcp on 192.168.1.1", live while scanning
    private(set) var command = ""
    private(set) var startedAt: Date?
    private(set) var asRoot = false
    private(set) var xmlData: Data?

    private(set) var install = Install.idle
    private(set) var installLog: [String] = []

    @ObservationIgnored private var process: StreamingProcess?
    @ObservationIgnored private var installer: StreamingProcess?
    @ObservationIgnored private var workDir: URL?
    @ObservationIgnored private var tailTask: Task<Void, Never>?

    nonisolated static let searchPaths = ["/opt/homebrew/bin/nmap", "/usr/local/bin/nmap", "/opt/local/bin/nmap", "/usr/bin/nmap"]
    nonisolated static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    var isRunning: Bool { state == .running }

    // MARK: locate & install

    func locate() async {
        let fm = FileManager.default
        let custom = UserDefaults.standard.string(forKey: "nmap.path")
        path = ([custom].compactMap { $0 } + Self.searchPaths).first { fm.isExecutableFile(atPath: $0) }
        brewPath = Self.brewPaths.first { fm.isExecutableFile(atPath: $0) }
        if let path {
            let r = await Shell.run(path, ["--version"], timeout: 10)
            // "Nmap version 7.95 ( https://nmap.org )"
            version = r.stdout.split(separator: "\n").first.flatMap { line in
                line.components(separatedBy: "version ").dropFirst().first?.split(separator: " ").first.map(String.init)
            }
        } else {
            version = nil
        }
        checked = true
    }

    func useBinary(at url: URL) async {
        UserDefaults.standard.set(url.path, forKey: "nmap.path")
        await locate()
    }

    /// `brew install nmap` as the current user — Homebrew never needs root.
    func installWithHomebrew() {
        guard let brewPath, install != .running else { return }
        install = .running
        installLog = ["$ brew install nmap"]
        let bin = (brewPath as NSString).deletingLastPathComponent
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(bin):/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NONINTERACTIVE"] = "1"
        let p = StreamingProcess(brewPath, ["install", "nmap"], environment: env)
        p.onLine = { [weak self] line in
            Task { @MainActor in
                guard let self else { return }
                self.installLog.append(line)
                if self.installLog.count > 400 { self.installLog.removeFirst(self.installLog.count - 400) }
            }
        }
        p.onExit = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.installer = nil
                await self.locate()
                if self.path != nil { self.install = .idle }
                else { self.install = .failed(status == 0 ? "Homebrew finished but nmap wasn't found." : "Homebrew exited with status \(status).") }
            }
        }
        do {
            try p.start()
            installer = p
        } catch {
            install = .failed(error.localizedDescription)
        }
    }

    // MARK: scanning

    /// Builds the full argument list shown in the preview and actually run.
    nonisolated static func arguments(profile: NmapProfile, custom: String, timing: Int, ports: String,
                          skipDiscovery: Bool, targets: [String]) -> [String] {
        var a: [String]
        if profile.id == "custom" {
            a = tokenize(custom)
        } else {
            a = profile.args
            if !ports.trimmingCharacters(in: .whitespaces).isEmpty && profile.id != "discover" {
                if profile.setsPorts {   // the explicit port list replaces the profile's own selection
                    if let i = a.firstIndex(of: "--top-ports") { a.removeSubrange(i...min(i + 1, a.count - 1)) }
                    a.removeAll { $0 == "-F" || $0 == "-p-" }
                }
                a += ["-p", ports.replacingOccurrences(of: " ", with: "")]
            }
            a.insert("-T\(timing)", at: 0)
            if skipDiscovery && profile.id != "discover" { a.append("-Pn") }
        }
        return a + targets
    }

    /// Splits a command line on spaces, honouring single and double quotes.
    nonisolated static func tokenize(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        var hasToken = false
        for c in s {
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c; hasToken = true
            } else if c.isWhitespace {
                if hasToken || !cur.isEmpty { out.append(cur); cur = ""; hasToken = false }
            } else {
                cur.append(c)
            }
        }
        if hasToken || !cur.isEmpty { out.append(cur) }
        return out.first == "nmap" ? Array(out.dropFirst()) : out
    }

    /// Hostnames, addresses, CIDR blocks and nmap ranges ("192.168.1.1-20"). Anything
    /// that looks like an option is refused so a target can't smuggle in arguments.
    nonisolated static func targets(from s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" }).map(String.init).filter { t in
            !t.hasPrefix("-") && !t.hasPrefix("/") && t.allSatisfy { $0.isLetter || $0.isNumber || ".:/-_*[]%".contains($0) }
        }
    }

    func start(arguments: [String], asRoot root: Bool) {
        guard let path, !isRunning else { return }
        cleanup()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("netlens-nmap-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        workDir = dir
        let xml = dir.appendingPathComponent("scan.xml").path
        var extra = ["--stats-every", "2s", "-oX", xml]
        if !arguments.contains(where: { $0.hasPrefix("-v") || $0.hasPrefix("-d") }) { extra.insert("-v", at: 0) }
        let full = extra + arguments

        command = "nmap " + arguments.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
        state = .running
        progress = nil
        phase = "Starting"
        remaining = nil
        log = [(root ? "# " : "$ ") + command]
        discovered = []
        result = nil
        xmlData = nil
        startedAt = Date()
        asRoot = root

        if root {
            startPrivileged(path: path, args: full, dir: dir)
        } else {
            let p = StreamingProcess(path, full)
            p.onLine = { [weak self] line in Task { @MainActor in self?.ingest(line) } }
            p.onExit = { [weak self] status in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))   // let the last lines drain
                    self?.finish(status: status)
                }
            }
            do {
                try p.start()
                process = p
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Runs nmap as root through the standard administrator prompt. Output goes to a log
    /// file that the app tails; a "stop" file lets the app end the scan without a second
    /// password prompt.
    private func startPrivileged(path: String, args: [String], dir: URL) {
        let logFile = dir.appendingPathComponent("scan.log").path
        let stopFile = dir.appendingPathComponent("stop").path
        let xml = dir.appendingPathComponent("scan.xml").path
        let script = """
        \(Shell.quote(path)) \(args.map(Shell.quote).joined(separator: " ")) > \(Shell.quote(logFile)) 2>&1 &
        pid=$!
        while kill -0 $pid 2>/dev/null; do
          if [ -f \(Shell.quote(stopFile)) ]; then kill -INT $pid; fi
          sleep 0.5
        done
        wait $pid; rc=$?
        chown \(getuid()) \(Shell.quote(logFile)) \(Shell.quote(xml)) 2>/dev/null
        exit $rc
        """
        let scriptURL = dir.appendingPathComponent("run.sh")
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)

        tailTask = Task { [weak self] in
            var offset: UInt64 = 0
            var partial = Data()
            while !Task.isCancelled {
                if let h = FileHandle(forReadingAtPath: logFile) {
                    try? h.seek(toOffset: offset)
                    let d = h.readDataToEndOfFile()
                    try? h.close()
                    offset += UInt64(d.count)
                    partial.append(d)
                    while let nl = partial.firstIndex(of: 0x0A) {
                        let line = String(decoding: partial[partial.startIndex..<nl], as: UTF8.self)
                        partial.removeSubrange(partial.startIndex...nl)
                        self?.ingest(line)
                    }
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        Task {
            let r = await Shell.runAsAdmin("/bin/sh \(Shell.quote(scriptURL.path))", timeout: 6 * 3600)
            try? await Task.sleep(for: .milliseconds(500))
            tailTask?.cancel()
            if r.stderr.contains("User canceled") || r.stderr.contains("-128") {
                state = .failed("Cancelled — administrator rights are needed for this scan type.")
                return
            }
            finish(status: r.status)
        }
    }

    func stop() {
        guard isRunning else { return }
        phase = "Stopping"
        if asRoot, let dir = workDir {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("stop").path, contents: nil)
        } else {
            process?.interrupt()
        }
    }

    private func ingest(_ line: String) {
        log.append(line)
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
        // "SYN Stealth Scan Timing: About 42.10% done; ETC: 14:02 (0:00:12 remaining)"
        if let r = line.range(of: " Timing: About ") {
            phase = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rest = line[r.upperBound...]
            if let pct = Double(rest.prefix { $0.isNumber || $0 == "." }) { progress = pct / 100 }
            if let open = rest.range(of: "("), let close = rest.range(of: " remaining)") {
                remaining = String(rest[open.upperBound..<close.lowerBound])
            }
        } else if line.hasPrefix("Initiating ") {
            phase = line.dropFirst("Initiating ".count).components(separatedBy: " at ").first
            progress = nil
            remaining = nil
        } else if line.hasPrefix("Discovered open port ") {
            discovered.append(String(line.dropFirst("Discovered open port ".count)))
        }
    }

    private func finish(status: Int32) {
        process = nil
        let xml = workDir.map { $0.appendingPathComponent("scan.xml") }
        if let xml, let data = try? Data(contentsOf: xml), !data.isEmpty {
            xmlData = data
            result = NmapXMLParser.parse(data)
        }
        if result == nil || (status != 0 && (result?.hosts.isEmpty ?? true) && phase != "Stopping") {
            let reason = log.reversed().first { $0.contains("QUITTING") || $0.contains("Failed") || $0.lowercased().contains("error") || $0.contains("requires root") }
            state = .failed(reason ?? "nmap exited with status \(status).")
        } else {
            state = .finished
        }
        progress = nil
        remaining = nil
        phase = nil
        cleanup()
    }

    private func cleanup() {
        tailTask?.cancel()
        tailTask = nil
        if let dir = workDir { try? FileManager.default.removeItem(at: dir) }
        workDir = nil
    }
}
