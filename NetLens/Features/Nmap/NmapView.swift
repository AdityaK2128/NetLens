import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NmapView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("nmap.target") private var target = ""
    @AppStorage("nmap.profile") private var profileID = "quick"
    @AppStorage("nmap.custom") private var customArgs = "-sV -p 22,80,443"
    @AppStorage("nmap.timing") private var timing = 4
    @AppStorage("nmap.ports") private var ports = ""
    @AppStorage("nmap.pn") private var skipDiscovery = false
    @AppStorage("nmap.root") private var wantsRoot = false
    @State private var showRaw = false
    @State private var expanded: Set<String> = []

    private var scanner: NmapScanner { model.nmap }
    private var profile: NmapProfile { NmapProfile.all.first { $0.id == profileID } ?? NmapProfile.all[1] }
    private var runAsRoot: Bool { profile.needsRoot || wantsRoot }
    private var targets: [String] { NmapScanner.targets(from: target) }
    private var args: [String] {
        NmapScanner.arguments(profile: profile, custom: customArgs, timing: timing, ports: ports,
                              skipDiscovery: skipDiscovery, targets: targets)
    }

    var body: some View {
        Page(spacing: 18) {
            PageHeader(eyebrow: "Advanced · nmap", title: "Nmap scanner",
                       subtitle: "Find the hosts on a network, their open ports, the software behind each port and even the operating system — using nmap, the standard open-source scanner. Every scan shows its exact command, so you can learn it and reuse it in Terminal.") {
                if let v = scanner.version { Chip(text: "nmap \(v)") }
            }

            if !scanner.checked {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            } else if scanner.path == nil {
                NmapInstallPanel()
            } else {
                scanPanel
                statusSection
                if let run = scanner.result { results(run) }
            }
        }
        .task {
            if !scanner.checked { await scanner.locate() }
            if let t = model.takeTarget(.nmap) { target = t }
            else if target.isEmpty { target = thisNetwork ?? "" }
            // `-NLNmapAutoRun YES`: start a scan on launch (used for screenshots and testing).
            if UserDefaults.standard.bool(forKey: "NLNmapAutoRun") && scanner.state == .idle { run() }
        }
    }

    // MARK: scan setup

    private var thisNetwork: String? {
        guard let a = model.physicalInterface?.ipv4.first, let m = a.netmask,
              let net = IP.v4Network(address: a.address, netmask: m), let len = IP.prefixLength(netmask: m) else { return nil }
        return "\(net.network)/\(len)"
    }

    private var scanPanel: some View {
        Panel("Scan", icon: "scope") {
            VStack(alignment: .leading, spacing: 14) {
                row("Target") {
                    VStack(alignment: .leading, spacing: 8) {
                        InstrumentField(placeholder: "Host, address, range or CIDR — e.g. 192.168.1.0/24, 10.0.0.1-20, example.com",
                                        text: $target, icon: "scope") { run() }
                        HStack(spacing: 6) {
                            if let n = thisNetwork { quickTarget("This network", n) }
                            if let r = model.lanRouter { quickTarget("Router", r) }
                            if let me = model.physicalInterface?.ipv4.first?.address { quickTarget("This Mac", me) }
                            quickTarget("scanme.nmap.org", "scanme.nmap.org")
                                .help("A host the nmap project runs so anyone can practise scanning it.")
                        }
                    }
                }
                row("Scan type") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $profileID) {
                            ForEach(NmapProfile.all) { p in
                                Text(p.name + (p.needsRoot ? "  (admin)" : "")).tag(p.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                        Text(profile.summary).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
                if profile.id == "custom" {
                    row("Arguments") {
                        InstrumentField(placeholder: "e.g. -sV -p 22,80,443 --script banner", text: $customArgs, icon: "terminal") { run() }
                    }
                } else {
                    row("Timing") {
                        HStack(spacing: 6) {
                            Segmented(options: [2, 3, 4], selection: $timing) { ["", "", "Polite", "Normal", "Aggressive"][$0] }
                            InfoButton(term: .nmapTiming)
                        }
                    }
                    if profile.id != "discover" {
                        row("Ports") {
                            HStack(spacing: 14) {
                                InstrumentField(placeholder: profile.setsPorts ? "profile default" : "default (top 1,000)", text: $ports, icon: "number")
                                    .frame(width: 220)
                                Text("e.g. 22,80,443 or 1-1024").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                                Toggle("Treat all hosts as up (-Pn)", isOn: $skipDiscovery).toggleStyle(.checkbox).font(.system(size: 12))
                                    .help("Scan every target even if it doesn't answer pings — needed for hosts behind firewalls that drop ping.")
                            }
                        }
                    }
                }
                row("Privileges") {
                    HStack(spacing: 8) {
                        Toggle("Run as administrator", isOn: Binding(get: { runAsRoot }, set: { wantsRoot = $0 }))
                            .toggleStyle(.checkbox).font(.system(size: 12))
                            .disabled(profile.needsRoot)
                        Text(profile.needsRoot ? "Required for this scan type." : "Enables faster SYN scans, OS detection, UDP and MAC addresses. Asks for your password on each scan.")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                }

                Hairline()

                HStack(spacing: 10) {
                    Text(verbatim: (runAsRoot ? "sudo " : "") + "nmap " + args.joined(separator: " "))
                        .font(.code(12))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fill))
                    Button { copyToPasteboard((runAsRoot ? "sudo " : "") + "nmap " + args.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")) } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .help("Copy command")
                    if scanner.isRunning {
                        Button { scanner.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(.bordered)
                    } else {
                        Button { run() } label: { Label("Scan", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(targets.isEmpty && profile.id != "custom")
                    }
                }
                Text("Only scan networks and hosts you own or have permission to test.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                .frame(width: 80, alignment: .leading)
            content()
        }
    }

    private func quickTarget(_ title: String, _ value: String) -> some View {
        Button(title) { target = value }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(value)
    }

    private func run() {
        guard !scanner.isRunning, !args.isEmpty else { return }
        expanded = []
        scanner.start(arguments: args, asRoot: runAsRoot)
    }

    // MARK: progress & errors

    @ViewBuilder private var statusSection: some View {
        if scanner.isRunning {
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text(scanner.phase ?? "Scanning").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                        if let r = scanner.remaining { Text("about \(r) left").font(.mono(12)).foregroundStyle(Theme.secondary) }
                        Spacer()
                        if let s = scanner.startedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Text(Fmt.duration(ctx.date.timeIntervalSince(s))).font(.mono(12)).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                    if let p = scanner.progress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
                    if !scanner.discovered.isEmpty {
                        Text("Found so far: " + scanner.discovered.suffix(12).joined(separator: " · "))
                            .font(.mono(11)).foregroundStyle(Theme.secondary).lineLimit(2)
                    }
                    rawLog(height: 160)
                }
            }
        } else if case .failed(let msg) = scanner.state {
            Callout(kind: .warning, title: "The scan didn't finish", message: msg)
        }
    }

    private func rawLog(height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(scanner.log.enumerated()), id: \.offset) { i, line in
                        Text(verbatim: line).font(.code(11)).foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .textSelection(.enabled)
                .padding(10)
            }
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fill))
            .onChange(of: scanner.log.count) { _, n in if scanner.isRunning { proxy.scrollTo(n - 1, anchor: .bottom) } }
        }
    }

    // MARK: results

    @ViewBuilder private func results(_ run: NmapRun) -> some View {
        let up = run.hosts.filter(\.responded)
        let silent = run.hosts.filter { $0.isUp && !$0.responded }.count
        let open = up.reduce(0) { $0 + $1.openPorts.count }
        HStack(spacing: 12) {
            Readout(label: "Hosts up", value: "\(up.count)", caption: run.total > 0 ? "of \(run.total) scanned" + (silent > 0 ? " · \(silent) silent" : "") : nil)
            Readout(label: "Open ports", value: "\(open)", info: .portStates)
            Readout(label: "Duration", value: run.elapsed.map { Fmt.duration($0) } ?? "—", caption: run.truncated ? "stopped early" : nil)
            Readout(label: "Services identified", value: "\(up.reduce(0) { $0 + $1.openPorts.filter { $0.product != nil }.count })", info: .osDetection)
        }
        HStack {
            Segmented(options: [false, true], selection: $showRaw) { $0 ? "Raw output" : "Hosts" }
            Spacer()
            if let data = scanner.xmlData {
                Button { save(data) } label: { Label("Save XML…", systemImage: "square.and.arrow.down") }.buttonStyle(.bordered)
            }
        }
        if showRaw {
            rawLog(height: 420)
        } else if up.isEmpty && run.truncated {
            EmptyState(icon: "stop.circle", title: "Scan stopped",
                       message: "It was stopped before nmap reported any host. Raw output shows how far it got.")
        } else if up.isEmpty {
            EmptyState(icon: "scope", title: "No hosts answered",
                       message: "Nothing replied to nmap's discovery probes. If you know a host is there, it may be dropping pings — turn on “Treat all hosts as up (-Pn)” and scan again.")
        } else {
            VStack(spacing: 12) {
                ForEach(up) { h in
                    HostCard(host: h, expanded: expanded.contains(h.id)) {
                        if expanded.contains(h.id) { expanded.remove(h.id) } else { expanded.insert(h.id) }
                    } onScan: { target = h.address }
                }
            }
        }
    }

    private func save(_ data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        panel.nameFieldStringValue = "nmap-\(Int(Date().timeIntervalSince1970)).xml"
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }
}

// MARK: - Host card

private struct HostCard: View {
    let host: NmapHost
    let expanded: Bool
    let toggle: () -> Void
    let onScan: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let h = host
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StatusDot(color: Theme.good, size: 7)
                Text(verbatim: h.address).font(.mono(13.5, .semibold)).foregroundStyle(Theme.text).textSelection(.enabled)
                if let name = h.hostnames.first {
                    Text(name).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
                if let v = h.vendor { Chip(text: v) }
                if let os = h.osMatches.first { Chip(text: "\(os.name) · \(os.accuracy)%", icon: "desktopcomputer") }
                if let ms = h.latencyMs { Text(Fmt.ms(ms)).font(.mono(11.5)).foregroundStyle(Theme.latency(ms)) }
                Menu {
                    Button("Scan this host") { onScan() }
                    Button("Ping") { model.open(.ping, target: h.address) }
                    Button("Traceroute") { model.open(.traceroute, target: h.address) }
                    Divider()
                    Button("Copy address") { copyToPasteboard(h.address) }
                    if let mac = h.mac { Button("Copy MAC address") { copyToPasteboard(mac) } }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
            if let mac = h.mac {
                Text(verbatim: mac).font(.mono(11)).foregroundStyle(Theme.tertiary)
            }

            if !h.ports.isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Port").frame(width: 80, alignment: .leading)
                        Text("State").frame(width: 90, alignment: .leading)
                        Text("Service").frame(width: 130, alignment: .leading)
                        Text("Version").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.vertical, 5)
                    Hairline()
                    let shown = expanded ? h.ports : Array(h.ports.prefix(12))
                    ForEach(shown) { p in
                        PortRow(port: p, showScripts: expanded)
                        Hairline().opacity(0.5)
                    }
                }
            }
            let hidden = h.hiddenPorts.sorted { $0.value > $1.value }.map { "\(Fmt.count($0.value)) \($0.key)" }
            let more = h.ports.count > 12 && !expanded
            let hasDetail = h.ports.contains { !$0.scripts.isEmpty } || !h.scripts.isEmpty || h.osMatches.count > 1
            if !hidden.isEmpty || more || hasDetail {
                HStack(spacing: 10) {
                    if !hidden.isEmpty {
                        Text(hidden.joined(separator: ", ") + " port\(h.hiddenPorts.values.reduce(0, +) == 1 ? "" : "s") not shown")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                    Spacer()
                    if more || hasDetail {
                        Button(expanded ? "Show less" : (more ? "Show all \(h.ports.count) ports" : "Show details")) { withAnimation(.snappy) { toggle() } }
                            .buttonStyle(.link).font(.system(size: 11.5))
                    }
                }
            }
            if expanded {
                if h.osMatches.count > 1 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Other OS guesses").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                        ForEach(Array(h.osMatches.dropFirst().prefix(5).enumerated()), id: \.offset) { _, m in
                            Text("\(m.name) · \(m.accuracy)%").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                        }
                    }
                }
                ForEach(h.scripts, id: \.self) { s in ScriptOutput(script: s) }
                if let d = h.distance { Text("\(d) network hop\(d == 1 ? "" : "s") away").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
            }
        }
        .padding(16)
        .background(PanelBackground())
        .contextMenu {
            Button("Scan this host") { onScan() }
            Button("Copy address") { copyToPasteboard(h.address) }
        }
    }
}

private struct PortRow: View {
    let port: NmapPort
    let showScripts: Bool

    var body: some View {
        let p = port
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(verbatim: "\(p.port)/\(p.proto)").font(.mono(12, .medium)).foregroundStyle(Theme.text)
                    .frame(width: 80, alignment: .leading)
                Text(p.state).font(.system(size: 12)).foregroundStyle(stateColor)
                    .frame(width: 90, alignment: .leading)
                Text(p.serviceText).font(.system(size: 12)).foregroundStyle(Theme.text)
                    .frame(width: 130, alignment: .leading).lineLimit(1)
                Text(p.versionText.isEmpty ? "—" : p.versionText).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    .help(p.versionText)
            }
            if showScripts {
                ForEach(p.scripts, id: \.self) { s in ScriptOutput(script: s).padding(.leading, 92) }
            }
        }
        .padding(.vertical, 5)
        .textSelection(.enabled)
    }

    private var stateColor: Color {
        if p.state.hasPrefix("open") && p.state != "open|filtered" { return Theme.text }
        if p.state == "closed" { return Theme.tertiary }
        return Theme.secondary
    }
    private var p: NmapPort { port }
}

private struct ScriptOutput: View {
    let script: NmapScript
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(script.id).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            Text(verbatim: script.output).font(.code(11)).foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(30)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fill))
    }
}

// MARK: - Install

private struct NmapInstallPanel: View {
    @Environment(AppModel.self) private var model
    private var scanner: NmapScanner { model.nmap }

    var body: some View {
        Panel {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "shippingbox").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.secondary)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nmap isn't installed").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("This screen is a front end for nmap, the free, open-source scanner network administrators have relied on for over 25 years. NetLens doesn't bundle it — install it once and every scan here works.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                            .frame(maxWidth: 620, alignment: .leading)
                    }

                    if scanner.brewPath != nil {
                        HStack(spacing: 12) {
                            Button(scanner.install == .running ? "Installing…" : "Install with Homebrew") { scanner.installWithHomebrew() }
                                .buttonStyle(.borderedProminent)
                                .disabled(scanner.install == .running)
                            Text("Runs “brew install nmap” — no password needed, usually under a minute.")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    if scanner.install == .running || !scanner.installLog.isEmpty {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(scanner.installLog.suffix(8).enumerated()), id: \.offset) { _, l in
                                Text(verbatim: l).font(.code(11)).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fill))
                    }
                    if case .failed(let msg) = scanner.install {
                        Callout(kind: .warning, title: "Installation didn't complete", message: msg)
                    }

                    Hairline()
                    Text(scanner.brewPath == nil ? "Ways to install" : "Other ways to install")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                    method("Official installer", detail: "Download the macOS disk image from the nmap project and run the installer inside.") {
                        Link("nmap.org/download", destination: URL(string: "https://nmap.org/download.html#macosx")!).font(.system(size: 12))
                    }
                    if scanner.brewPath == nil {
                        method("Homebrew", detail: "If you use Homebrew (brew.sh), run this in Terminal:") { command("brew install nmap") }
                    }
                    method("MacPorts", detail: "If you use MacPorts:") { command("sudo port install nmap") }

                    HStack(spacing: 8) {
                        Button("Check again") { Task { await scanner.locate() } }.buttonStyle(.bordered)
                        Button("Choose nmap binary…") { choose() }.buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func method<C: View>(_ title: String, detail: String, @ViewBuilder _ trailing: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).frame(width: 120, alignment: .leading)
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            trailing()
        }
    }

    private func command(_ c: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: c).font(.code(11.5)).foregroundStyle(Theme.text).textSelection(.enabled)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.fill))
            Button { copyToPasteboard(c) } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                .buttonStyle(.borderless).help("Copy")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the nmap executable"
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        if panel.runModal() == .OK, let url = panel.url { Task { await scanner.useBinary(at: url) } }
    }
}
