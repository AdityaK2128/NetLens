import SwiftUI

struct DNSView: View {
    enum Mode: String, CaseIterable { case lookup = "Lookup", compare = "Compare resolvers", trace = "Trace delegation" }

    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .lookup
    @State private var name = "openai.com"
    @State private var type: DNSType = .A
    @State private var serverID: String = ""
    @State private var transport: DNSTransport = .udp
    @State private var dnssec = false
    @State private var running = false
    @State private var result: DNSResult?
    @State private var showRaw = false
    @State private var compare: [DNSResult] = []
    @State private var steps: [DelegationStep] = []

    private var servers: [DNSServer] {
        let system = model.net.dnsServers.map { ip in
            DNSServer(name: "System · " + (KnownHosts.resolverName(ip, gateway: model.net.router) ?? ip), address: ip)
        }
        return system + DNSServer.wellKnown
    }

    private var server: DNSServer { servers.first { $0.id == serverID } ?? servers.first ?? DNSServer.wellKnown[0] }

    var body: some View {
        Page(spacing: 18) {
            PageHeader(eyebrow: "Diagnose · dig", title: "DNS workbench",
                       subtitle: "Raw DNS over UDP, TCP, DNS-over-TLS and DNS-over-HTTPS, with every flag, TTL and EDNS option. Race resolvers against each other, or walk the delegation chain from the root like dig +trace.") {
                Segmented(options: Mode.allCases, selection: $mode) { $0.rawValue }
            }

            queryBar

            switch mode {
            case .lookup: lookupResult
            case .compare: compareResult
            case .trace: traceResult
            }
        }
        .onAppear {
            if serverID.isEmpty { serverID = servers.first?.id ?? "" }
            if let t = model.takeTarget(.dns) { name = t; run() }
        }
    }

    // MARK: query bar

    private var queryBar: some View {
        HStack(spacing: 10) {
            InstrumentField(placeholder: "Name or IP (an IP becomes a PTR lookup)", text: $name, icon: "character.cursor.ibeam") { run() }
            Picker("", selection: $type) {
                ForEach(DNSType.common) { t in Text(t.name).tag(t) }
            }
            .labelsHidden()
            .frame(width: 100)
            if mode == .lookup {
                Picker("", selection: $serverID) {
                    ForEach(servers) { s in Text("\(s.name)  \(s.address)").tag(s.id) }
                }
                .labelsHidden()
                .frame(width: 250)
                Segmented(options: DNSTransport.allCases.filter { server.supports($0) }, selection: $transport) { $0.rawValue }
                InfoButton(term: transport == .doh ? .doh : .dot)
            }
            Toggle("DNSSEC", isOn: $dnssec).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            InfoButton(term: .dnssec)
                .help("Set the DO bit to receive RRSIG/DNSSEC records and the AD (authenticated data) flag")
            Button(running ? "Querying…" : "Query") { run() }.buttonStyle(.borderedProminent).disabled(running)
        }
        .onChange(of: serverID) { if !server.supports(transport) { transport = .udp } }
    }

    // MARK: run

    private func run() {
        var qname = name.trimmed
        guard !qname.isEmpty else { return }
        var qtype = type
        if IP.isIP(qname), let rev = IP.reverseName(qname) { qname = rev; qtype = .PTR; type = .PTR }
        running = true
        switch mode {
        case .lookup:
            let srv = server, tr = transport, ds = dnssec
            Task {
                result = await DNSClient.query(qname, type: qtype.rawValue, server: srv, transport: tr, dnssec: ds)
                running = false
            }
        case .compare:
            compare = []
            let all = servers
            let ds = dnssec
            Task {
                await withTaskGroup(of: DNSResult.self) { g in
                    for s in all { g.addTask { await DNSClient.query(qname, type: qtype.rawValue, server: s, transport: .udp, dnssec: ds) } }
                    for await r in g { compare.append(r); compare.sort { ($0.message == nil ? 1e9 : $0.elapsedMs) < ($1.message == nil ? 1e9 : $1.elapsedMs) } }
                }
                running = false
            }
        case .trace:
            steps = []
            Task {
                await DNSTrace.run(qname, type: qtype.rawValue) { step in steps.append(step) }
                running = false
            }
        }
    }

    // MARK: lookup

    @ViewBuilder private var lookupResult: some View {
        if let r = result {
            if let m = r.message {
                HStack(spacing: 12) {
                    Readout(label: "Status", value: DNSRcode.name(m.rcode), accent: m.rcode == 0 ? Theme.teal : Theme.coral,
                            caption: DNSRcode.meaning(m.rcode), size: 20)
                    Readout(label: "Query time", value: String(format: "%.1f", r.elapsedMs), unit: "ms", accent: Theme.latency(r.elapsedMs),
                            caption: "\(r.transport.rawValue)\(r.fellBackToTCP ? " (TC → TCP)" : "") · \(r.server.address)")
                    Readout(label: "Answers", value: "\(m.answers.count)", accent: Theme.amber, caption: "\(m.authority.count) authority · \(m.additional.filter { !$0.isOPT }.count) additional")
                    Readout(label: "Response size", value: "\(r.size)", unit: "bytes", accent: Theme.ink,
                            caption: m.ednsPresent ? "EDNS udp \(m.ednsUDPSize)\(m.ednsDO ? " · DO" : "")" : "no EDNS")
                }
                HStack(spacing: 6) {
                    Text("Flags").font(.mono(9.5, .medium)).foregroundStyle(Theme.faint)
                    ForEach(m.flagNames, id: \.self) { f in
                        Chip(text: f, color: f == "ad" ? Theme.teal : f == "aa" ? Theme.amber : f == "tc" ? Theme.coral : Theme.ink2)
                            .help(flagHelp(f))
                    }
                    if m.ad { Text("validated by resolver (DNSSEC)").font(.mono(10)).foregroundStyle(Theme.teal) }
                    if m.aa { Text("authoritative answer").font(.mono(10)).foregroundStyle(Theme.amber) }
                    Spacer()
                    Toggle("dig output", isOn: $showRaw).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                }
                if !m.ednsOptions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(m.ednsOptions, id: \.self) { Chip(text: $0, color: Theme.violet) }
                    }
                }
                if showRaw {
                    ScreenFrame(label: "dig") {
                        ScrollView(.horizontal) {
                            Text(m.digText(server: r.server.address, transport: r.transport.rawValue, elapsedMs: r.elapsedMs, size: r.size))
                                .font(.code(11.5))
                                .foregroundStyle(Theme.ink2)
                                .textSelection(.enabled)
                                .padding(.top, 30).padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    RecordSection(title: "Answer", records: m.answers)
                    RecordSection(title: "Authority", records: m.authority)
                    RecordSection(title: "Additional", records: m.additional.filter { !$0.isOPT })
                }
            } else {
                Callout(kind: .warning, title: "No response from \(r.server.name) over \(r.transport.rawValue)", message: r.error)
            }
        } else {
            EmptyState(icon: "character.book.closed", title: "Ask any DNS server anything",
                       message: "Try HTTPS records for cloudflare.com (they advertise HTTP/3), TXT for google.com (SPF + verification tokens), or DNSKEY with DNSSEC on.")
        }
    }

    private func flagHelp(_ f: String) -> String {
        switch f {
        case "qr": "Query response"
        case "aa": "Authoritative answer — the server owns this zone"
        case "tc": "Truncated — didn't fit in UDP"
        case "rd": "Recursion desired (we asked the resolver to do the legwork)"
        case "ra": "Recursion available on this server"
        case "ad": "Authentic data — the resolver validated DNSSEC signatures"
        case "cd": "Checking disabled"
        default: ""
        }
    }

    // MARK: compare

    @ViewBuilder private var compareResult: some View {
        if compare.isEmpty && !running {
            EmptyState(icon: "flag.checkered", title: "Resolver race", message: "Sends the same query to your configured resolvers and the big public ones simultaneously. Different answers usually mean geo-DNS steering you to a nearby CDN node.")
        } else {
            let best = compare.compactMap { $0.message == nil ? nil : $0.elapsedMs }.max() ?? 1
            let reference = compare.first?.message.map(answerSet)
            Panel("Results", icon: "flag.checkered") {
                VStack(spacing: 10) {
                    ForEach(compare) { r in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.server.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink)
                                Text(r.server.address).font(.mono(10)).foregroundStyle(Theme.muted)
                            }
                            .frame(width: 220, alignment: .leading)
                            if let m = r.message {
                                GeometryReader { g in
                                    Capsule()
                                        .fill(Theme.latency(r.elapsedMs))
                                        .frame(width: max(4, g.size.width * r.elapsedMs / best), height: 6)
                                        .frame(maxHeight: .infinity)
                                }
                                .frame(height: 20)
                                Text(String(format: "%.1f ms", r.elapsedMs)).font(.mono(12, .medium)).foregroundStyle(Theme.latency(r.elapsedMs))
                                    .frame(width: 70, alignment: .trailing)
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(m.answers.first(where: { $0.type == type.rawValue })?.data ?? DNSRcode.name(m.rcode))
                                        .font(.mono(10.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                                    if let reference, answerSet(m) != reference {
                                        Text("different answer").font(.mono(9)).foregroundStyle(Theme.amber)
                                    } else if m.ad {
                                        Text("DNSSEC validated").font(.mono(9)).foregroundStyle(Theme.teal)
                                    }
                                }
                                .frame(width: 220, alignment: .trailing)
                            } else {
                                Text(r.error ?? "failed").font(.mono(11)).foregroundStyle(Theme.coral)
                                Spacer()
                            }
                        }
                    }
                    if running { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    private func answerSet(_ m: DNSMessage) -> Set<String> {
        Set(m.answers.filter { $0.type == type.rawValue }.map(\.data))
    }

    // MARK: trace

    @ViewBuilder private var traceResult: some View {
        if steps.isEmpty && !running {
            EmptyState(icon: "arrow.triangle.branch", title: "Walk the DNS tree",
                       message: "Starts at a root server and follows each referral (no recursion) — root → TLD → the domain's own nameservers — exactly how a recursive resolver finds an answer.")
        } else {
            Panel("Delegation chain", icon: "arrow.triangle.branch", info: .delegation) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                        HStack(alignment: .top, spacing: 14) {
                            VStack(spacing: 0) {
                                Circle().fill(s.answers.isEmpty ? Theme.trough : Theme.teal)
                                    .overlay(Circle().strokeBorder(s.error == nil ? Theme.amber : Theme.coral, lineWidth: 1.5))
                                    .frame(width: 12, height: 12)
                                if i < steps.count - 1 || running {
                                    Rectangle().fill(Theme.line).frame(width: 1.5).frame(minHeight: 50)
                                }
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text(s.zone == "." ? "Root zone (.)" : s.zone).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                                    Text(String(format: "%.1f ms", s.elapsedMs)).font(.mono(11)).foregroundStyle(Theme.latency(s.elapsedMs))
                                    if s.signed { Chip(text: "DS · signed delegation", color: Theme.teal, icon: "lock.fill") }
                                    if s.authoritative { Chip(text: "authoritative", color: Theme.amber) }
                                }
                                Text("asked \(s.serverName) (\(s.serverIP))").font(.mono(10.5)).foregroundStyle(Theme.muted)
                                if let e = s.error {
                                    Text(e).font(.mono(10.5)).foregroundStyle(Theme.coral)
                                } else if !s.answers.isEmpty {
                                    ForEach(s.answers) { a in
                                        Text("\(a.typeName)  \(a.data)").font(.mono(11.5)).foregroundStyle(Theme.teal).textSelection(.enabled)
                                    }
                                } else if !s.nameservers.isEmpty {
                                    Text("→ referral to " + s.nameservers.prefix(4).joined(separator: ", ") + (s.nameservers.count > 4 ? " +\(s.nameservers.count - 4)" : ""))
                                        .font(.mono(10.5)).foregroundStyle(Theme.ink2)
                                } else {
                                    Text(DNSRcode.name(s.rcode)).font(.mono(11)).foregroundStyle(s.rcode == 0 ? Theme.ink2 : Theme.coral)
                                }
                            }
                            .padding(.bottom, 14)
                        }
                    }
                    if running { HStack { ProgressView().controlSize(.small); Text("following referral…").font(.mono(10.5)).foregroundStyle(Theme.muted) } }
                }
            }
        }
    }
}

private struct RecordSection: View {
    let title: String
    let records: [DNSRecord]

    var body: some View {
        if !records.isEmpty {
            Panel(title, icon: "list.bullet.rectangle", info: .dnsTTL) {
                VStack(spacing: 0) {
                    ForEach(records) { r in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(r.name).font(.mono(11.5)).foregroundStyle(Theme.ink2).frame(width: 230, alignment: .leading).lineLimit(1)
                            Text(ttl(r.ttl)).font(.mono(11)).foregroundStyle(Theme.muted).frame(width: 70, alignment: .trailing)
                                .help("\(r.ttl) seconds")
                            Text(r.typeName).font(.mono(11.5, .semibold)).foregroundStyle(Theme.amber).frame(width: 70, alignment: .leading)
                            Text(r.data).font(.mono(11.5)).foregroundStyle(Theme.ink).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 6)
                        Hairline().opacity(0.5)
                    }
                }
            }
        }
    }

    private func ttl(_ t: UInt32) -> String {
        if t >= 86400 { return "\(t / 86400)d" }
        if t >= 3600 { return "\(t / 3600)h\(t % 3600 / 60 > 0 ? "\(t % 3600 / 60)m" : "")" }
        if t >= 60 { return "\(t / 60)m\(t % 60 > 0 ? "\(t % 60)s" : "")" }
        return "\(t)s"
    }
}
