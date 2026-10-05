import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page(spacing: 20) {
            PageHeader(eyebrow: "Overview · live", title: "Your path to the Internet", subtitle: summary) {
                Button {
                    model.refreshLocal()
                    Task { await model.refreshPublic() }
                } label: {
                    Label(model.refreshingPublic ? "Probing…" : "Re-probe", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.refreshingPublic)
            }

            ReadoutStrip()

            HStack(alignment: .top, spacing: 20) {
                PathSpine()
                    .frame(minWidth: 480, maxWidth: .infinity)
                VStack(spacing: 18) {
                    ThroughputPanel()
                    LatencyPanel()
                    DNSPanel()
                    TopTalkersPanel()
                }
                .frame(width: 380)
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let p = model.physicalInterface {
            if p.kind == .wifi {
                parts.append("Wi-Fi" + (model.wifi.ssid.map { " “\($0)”" } ?? ""))
            } else {
                parts.append(p.displayName)
            }
        }
        if let gw = model.net.router {
            let rtt = model.pings.gateway.stats(window: 10).avg
            parts.append("router \(gw)" + (rtt.map { " (\(Fmt.ms($0)))" } ?? ""))
        }
        if let g = model.selfGeo { parts.append(g.isp ?? g.operatorName) }
        if let rtt = model.pings.internet.stats(window: 10).avg {
            parts.append("Internet in \(Fmt.ms(rtt))")
        }
        return parts.isEmpty ? "Waiting for network…" : parts.joined(separator: "  →  ")
    }
}

// MARK: - Readouts

private struct ReadoutStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let iface = model.net.primaryInterface ?? ""
        let cur = model.throughput.current[iface]
        let (dv, du) = Fmt.bitrateParts(bytesPerSecond: cur?.inBps ?? 0)
        let (uv, uu) = Fmt.bitrateParts(bytesPerSecond: cur?.outBps ?? 0)
        let gw = model.pings.gateway.stats(window: 30)
        let inet = model.pings.internet.stats(window: 30)
        HStack(spacing: 12) {
            Readout(label: "Download", value: dv, unit: du, accent: Theme.teal, caption: iface.isEmpty ? nil : "on \(iface)")
            Readout(label: "Upload", value: uv, unit: uu, accent: Theme.amber, caption: iface.isEmpty ? nil : "on \(iface)")
            Readout(label: "Router round trip", value: Fmt.msValue(gw.last ?? gw.avg), unit: "ms", accent: Theme.latency(gw.avg),
                    caption: gw.jitter.map { "jitter \(Fmt.ms($0))" }, info: .rtt)
            Readout(label: "Internet round trip", value: Fmt.msValue(inet.last ?? inet.avg), unit: "ms", accent: Theme.latency(inet.avg),
                    caption: "to 1.1.1.1" + (inet.jitter.map { " · jitter \(Fmt.ms($0))" } ?? ""), info: .jitter)
            Readout(label: "Packet loss", value: String(format: "%.1f", inet.loss), unit: "%", accent: Theme.loss(inet.loss),
                    caption: "last \(inet.sent) probes", info: .packetLoss)
            Readout(label: "Sockets", value: "\(model.connections.activeSockets.count)", accent: Theme.ink,
                    caption: "\(model.connections.established) established")
        }
    }
}

// MARK: - The path spine

private struct PathSpine: View {
    @Environment(AppModel.self) private var model
    @State private var destination = ""
    @State private var dnsMs: Double?

    private var hops: [TraceHop] { model.pathTrace.visibleHops }
    private var firstPublic: TraceHop? { hops.first { $0.scope == .global } }
    private var destHop: TraceHop? { hops.last { $0.reachedDestination } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            macNode
            linkToRouter
            routerNode
            PathLink(color: Theme.violet, speed: 1.0) {
                linkLabel(title: model.viaTunnel ? "Encrypted tunnel" : "NAT boundary",
                          detail: model.viaTunnel
                            ? "Traffic is wrapped by \(model.net.primaryInterface ?? "a VPN") before it leaves the router."
                            : "Your private address is rewritten to the router's WAN address here.",
                          latency: delta(from: hops.first, to: firstPublic),
                          term: model.viaTunnel ? .vpnExit : .nat)
            }
            ispNode
            PathLink(color: Theme.lime, speed: 1.3) {
                linkLabel(title: "\(transitHops.count) transit hop\(transitHops.count == 1 ? "" : "s")",
                          detail: asPathDescription,
                          latency: delta(from: firstPublic, to: destHop),
                          term: .asn)
            }
            internetNode
            PathLink(color: Theme.amber, speed: 1.6) {
                linkLabel(title: "Last mile to destination", detail: destHop?.hostname ?? destHop?.address ?? "", latency: nil)
            }
            destinationNode
        }
        .onAppear { if destination.isEmpty { destination = model.pathTrace.target.isEmpty ? "1.1.1.1" : model.pathTrace.target } }
    }

    // MARK: nodes

    private var macNode: some View {
        let iface = model.primaryInterface
        let phys = model.physicalInterface
        return PathNode(icon: "laptopcomputer", accent: Theme.amber, eyebrow: "This Mac",
                        title: model.net.computerName,
                        subtitle: [model.net.hardwareModel, ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: "macOS ")]
                            .filter { !$0.isEmpty }.joined(separator: " · ")) {
            NodeGrid {
                NodeField("Interface", iface.map { "\($0.name) · \($0.displayName)" } ?? "—")
                NodeField("IPv4", iface?.ipv4.first?.cidr ?? phys?.ipv4.first?.cidr ?? "none")
                NodeField("IPv6", ipv6Summary(iface ?? phys), info: .linkLocal)
                NodeField("MAC", macSummary(phys), color: Theme.ink2, info: .privateMAC)
                NodeField("MTU", (iface ?? phys).map { "\($0.counters.mtu) bytes" } ?? "—", info: .mtu)
                NodeField("Bonjour name", model.net.localHostName.map { "\($0).local" } ?? "—", info: .bonjour)
            }
        }
    }

    @ViewBuilder private var linkToRouter: some View {
        let phys = model.physicalInterface
        if phys?.kind == .wifi {
            let w = model.wifi
            PathLink(color: Theme.signal(w.rssi), speed: 0.8) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SignalBars(rssi: w.rssi)
                        Text(w.ssid.map { "Wi-Fi · \($0)" } ?? "Wi-Fi")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        if w.ssid == nil {
                            Button("Show network name") { model.requestLocation() }
                                .buttonStyle(.link)
                                .font(.system(size: 11.5))
                            InfoButton(term: .ssidPrivacy)
                        }
                    }
                    FlowChips() {
                        if let r = w.rssi { Chip(text: "\(r) dBm", color: Theme.signal(r)) }
                        if let snr = w.snr { Chip(text: "SNR \(snr) dB", color: snr > 25 ? Theme.teal : Theme.amber) }
                        if let ch = w.channel { Chip(text: "ch \(ch)" + (w.band.map { " · \($0)" } ?? "") + (w.channelWidth.map { " · \($0) MHz" } ?? "")) }
                        if let p = w.phyMode { Chip(text: p) }
                        if let tx = w.txRate { Chip(text: "PHY \(Int(tx)) Mbps", color: Theme.teal) }
                        if let s = w.security { Chip(text: s, color: s.contains("WPA3") ? Theme.teal : Theme.ink2, icon: "lock.fill") }
                        if let b = w.bssid { Chip(text: "BSSID \(b)", color: Theme.muted) }
                        InfoButton(term: .snr)
                    }
                }
            }
        } else if let phys {
            PathLink(color: Theme.teal, speed: 0.8) {
                linkLabel(title: phys.displayName,
                          detail: phys.counters.baudrate > 0 ? "Link speed \(Fmt.bitrate(bitsPerSecond: Double(phys.counters.baudrate)))" : "Wired link",
                          latency: nil)
            }
        } else {
            PathLink(color: Theme.faint, speed: 0) { linkLabel(title: "No physical link", detail: "", latency: nil) }
        }
    }

    private var routerNode: some View {
        let gw = model.pings.gateway
        let st = gw.stats(window: 60)
        return PathNode(icon: "wifi.router", accent: Theme.teal, eyebrow: "Default gateway",
                        title: model.net.router ?? "No router",
                        subtitle: model.gatewayMAC.flatMap(Neighbors.vendor) ?? "Router") {
            VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                NodeGrid {
                    NodeField(gw.viaTTLExpiry ? "Round trip (TTL probe)" : "Round trip", Fmt.ms(st.avg), color: Theme.latency(st.avg),
                              info: gw.viaTTLExpiry ? .ttlProbe : .rtt)
                    NodeField("Jitter", Fmt.ms(st.jitter), info: .jitter)
                    NodeField("Loss", Fmt.percent(st.loss), color: Theme.loss(st.loss), info: .packetLoss)
                    NodeField("MAC", model.gatewayMAC ?? "—", color: Theme.ink2)
                    NodeField("WAN address", model.natWAN ?? "not shared by router", color: model.natWAN == nil ? Theme.muted : Theme.ink, info: .natPMP)
                    NodeField("Route", "\(model.net.primaryInterface ?? "—") → \(model.net.router ?? "—")")
                }
                Sparkline(values: gw.samples.suffix(60).map(\.rtt), color: Theme.accent, markGaps: true, capacity: 60)
                    .frame(width: 120, height: 56)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.trough))
            }
            if model.localNetwork == .denied {
                HStack(spacing: 6) {
                    Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Text("Router details are hidden until you allow Local Network access for NetLens.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    Button("Open Settings") { LocalNetworkAccess.openSettings() }.buttonStyle(.link).font(.system(size: 11.5))
                }
                .padding(.top, 10)
            }
            }
        }
    }

    private var ispNode: some View {
        let g = model.selfGeo
        let verdict = model.nat.verdict
        return PathNode(icon: "building.2", accent: Theme.violet, eyebrow: model.viaTunnel ? "VPN exit" : "Your ISP",
                        title: g?.operatorName ?? "Discovering…",
                        subtitle: [g?.asn, g?.place].compactMap { $0 }.joined(separator: " · "),
                        info: model.viaTunnel ? .vpnExit : .isp) {
            VStack(alignment: .leading, spacing: 10) {
                NodeGrid {
                    NodeField("Public IPv4", model.publicV4 ?? "—", info: .publicIP)
                    NodeField("Public IPv6", model.publicV6 ?? "none (IPv4 only)", color: model.publicV6 == nil ? Theme.muted : Theme.ink)
                    NodeField("First ISP router", firstPublic.map { "\($0.address ?? "?") · hop \($0.ttl)" } ?? "—", info: .isp)
                    NodeField("Connection type", [g?.hosting == true ? "data centre" : nil, g?.mobile == true ? "cellular" : nil].compactMap { $0 }.joined(separator: ", ").nilIfEmpty ?? "residential")
                }
                NATVerdictView(analysis: model.nat, verdict: verdict)
            }
        }
    }

    private var internetNode: some View {
        PathNode(icon: "globe.europe.africa", accent: Theme.lime, eyebrow: "Internet",
                 title: asPath.isEmpty ? "Backbone" : "\(asPath.count) network\(asPath.count == 1 ? "" : "s") on the way",
                 subtitle: "The independent networks your packets cross",
                 info: .asn) {
            if asPath.isEmpty {
                Text(model.pathTrace.state == .running ? "Tracing…" : "No transit data yet")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else {
                FlowChips() {
                    ForEach(Array(asPath.enumerated()), id: \.offset) { i, a in
                        HStack(spacing: 4) {
                            if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.faint) }
                            Chip(text: a, color: Theme.lime)
                        }
                    }
                }
            }
        }
    }

    private var destinationNode: some View {
        let d = destHop
        let g = d?.geo
        var distance: Double? = nil
        if let a = model.selfGeo, let b = g { distance = GeoMath.distanceKm(a, b) }
        let minRTT = distance.map(GeoMath.minRTTms(distanceKm:))
        return PathNode(icon: "scope", accent: Theme.coral, eyebrow: "Destination",
                        title: model.pathTrace.target.isEmpty ? "—" : model.pathTrace.target,
                        subtitle: g.map { "\($0.operatorName) · \($0.shortPlace)" } ?? (model.pathTrace.targetIP ?? "")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    InstrumentField(placeholder: "host or IP — e.g. api.openai.com", text: $destination, icon: "scope") { trace() }
                    Button("Trace") { trace() }.buttonStyle(.borderedProminent)
                }
                NodeGrid {
                    NodeField("Address", model.pathTrace.targetIP ?? "—")
                    NodeField("DNS lookup", Fmt.ms(dnsMs))
                    NodeField("Round trip", Fmt.ms(d?.avg), color: Theme.latency(d?.avg), info: .rtt)
                    NodeField("Hops", d.map { "\($0.ttl)" } ?? (model.pathTrace.state == .running ? "…" : "—"))
                    NodeField("Distance", distance.map(Fmt.km) ?? "—")
                    NodeField("Fastest physically possible", minRTT.map { Fmt.ms($0) } ?? "—", info: .pathStretch)
                }
                if let minRTT, let rtt = d?.avg, rtt > 0 {
                    PathEfficiency(minRTT: minRTT, actual: rtt)
                }
            }
        }
    }

    // MARK: helpers

    private func trace() {
        let host = destination.trimmed
        guard !host.isEmpty else { return }
        Task {
            let t0 = Date()
            _ = await Resolver.resolve(host)
            dnsMs = IP.isIP(host) ? nil : Date().timeIntervalSince(t0) * 1000
            model.pathTrace.start(host)
        }
    }

    private var transitHops: [TraceHop] {
        guard let fp = firstPublic else { return [] }
        return hops.filter { $0.ttl > fp.ttl && !$0.reachedDestination }
    }

    private var asPath: [String] {
        var out: [String] = []
        for h in hops where h.ttl >= (firstPublic?.ttl ?? 99) {
            guard let g = h.geo else { continue }
            let label = [g.asNumber, g.org ?? g.isp].compactMap { $0 }.joined(separator: " ")
            if out.last != label, !label.isEmpty { out.append(label) }
        }
        return out
    }

    private var asPathDescription: String {
        asPath.isEmpty ? "Crossing peering points and backbone routers" : asPath.joined(separator: " → ")
    }

    private func delta(from a: TraceHop?, to b: TraceHop?) -> Double? {
        guard let x = a?.avg, let y = b?.avg else { return nil }
        return max(0, y - x)
    }

    private func linkLabel(title: String, detail: String, latency: Double?, term: Glossary? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                if let term { InfoButton(term: term) }
                if let latency {
                    Text(latency < 0.1 ? "+<0.1 ms" : "+\(Fmt.ms(latency))")
                        .font(.mono(11, .medium))
                        .foregroundStyle(Theme.latency(latency))
                }
            }
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(2)
            }
        }
    }

    private func ipv6Summary(_ i: NetInterface?) -> String {
        guard let i else { return "—" }
        let global = i.ipv6.filter { $0.scope == .global }
        if let g = global.first { return global.count > 1 ? "\(g.address) +\(global.count - 1)" : g.address }
        if i.ipv6.contains(where: { $0.scope == .uniqueLocal }) { return "ULA only" }
        return i.ipv6.isEmpty ? "disabled" : "link-local only"
    }

    private func macSummary(_ i: NetInterface?) -> String {
        guard let mac = i?.mac else { return "—" }
        return Neighbors.isLocallyAdministered(mac) ? "\(mac) · private" : mac
    }
}

// MARK: - Path building blocks

private struct PathNode<Content: View>: View {
    let icon: String
    let accent: Color
    let eyebrow: String
    let title: String
    var subtitle: String = ""
    var info: Glossary? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Theme.card)
                Circle().strokeBorder(Theme.separator, lineWidth: 1)
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(width: 44, height: 44)
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    TermLabel(text: eyebrow, term: info, font: .system(size: 11, weight: .medium))
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanelBackground())
        }
    }
}

private struct PathLink<Content: View>: View {
    let color: Color
    var speed: Double = 1
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            PacketWire(color: color, speed: speed)
                .frame(width: 46)
            content
                .padding(.vertical, 14)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 70)
    }
}

/// A vertical wire with packets streaming down it.
struct PacketWire: View {
    let color: Color
    var speed: Double = 1
    var vertical = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: speed == 0)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let length = vertical ? size.height : size.width
                var line = Path()
                if vertical {
                    line.move(to: CGPoint(x: size.width / 2, y: 0))
                    line.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                } else {
                    line.move(to: CGPoint(x: 0, y: size.height / 2))
                    line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                ctx.stroke(line, with: .color(Theme.separator), lineWidth: 1)
                guard speed > 0 else { return }
                let count = 3
                for i in 0..<count {
                    let phase = (t * 0.55 * speed + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
                    let p = length * phase
                    let center = vertical ? CGPoint(x: size.width / 2, y: p) : CGPoint(x: p, y: size.height / 2)
                    let fade = sin(phase * .pi)
                    ctx.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)), with: .color(Theme.accent.opacity(fade)))
                }
            }
        }
    }
}

struct NodeGrid<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 18, alignment: .topLeading), GridItem(.flexible(), spacing: 18, alignment: .topLeading)],
                  alignment: .leading, spacing: 10) {
            content
        }
    }
}

struct NodeField: View {
    let key: String
    let value: String
    var color: Color = Theme.ink
    var info: Glossary?

    init(_ key: String, _ value: String, color: Color = Theme.ink, info: Glossary? = nil) {
        self.key = key
        self.value = value
        self.color = color
        self.info = info
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TermLabel(text: key, term: info, font: .system(size: 11), color: Theme.secondary)
            Text(value)
                .font(.mono(12))
                .foregroundStyle(color)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Simple wrapping layout for chips.
struct FlowChips: Layout {
    var spacing: CGFloat = 6

    init(spacing: CGFloat = 6) { self.spacing = spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

private struct NATVerdictView: View {
    let analysis: NATAnalysis
    let verdict: NATAnalysis.Verdict
    @State private var expanded = false

    private var color: Color {
        switch verdict {
        case .cgnat, .double: Theme.coral
        case .likelyCGNAT: Theme.amber
        case .single, .none: Theme.teal
        case .vpn: Theme.violet
        case .unknown: Theme.muted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    StatusDot(color: color, size: 7)
                    Text(verdict.rawValue)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(color)
                    InfoButton(term: verdict == .cgnat || verdict == .likelyCGNAT ? .cgnat : verdict == .vpn ? .vpnExit : .nat)
                    Spacer()
                    Text(expanded ? "Hide evidence" : "Evidence")
                        .font(.mono(10))
                        .foregroundStyle(Theme.muted)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(analysis.evidence, id: \.self) { e in
                        HStack(alignment: .top, spacing: 6) {
                            Text("›").font(.mono(11)).foregroundStyle(color)
                            Text(e).font(.system(size: 11.5)).foregroundStyle(Theme.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill))
    }
}

/// How close is the measured RTT to the physical limit of light in fibre?
struct PathEfficiency: View {
    let minRTT: Double
    let actual: Double

    var body: some View {
        let ratio = actual / max(minRTT, 0.01)
        let eff = min(1, minRTT / actual)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TermLabel(text: "Path stretch", term: .pathStretch, font: .system(size: 11))
                Spacer()
                Text(String(format: "%.1f× the speed-of-light minimum", ratio))
                    .font(.mono(11)).foregroundStyle(Theme.ink2)
            }
            Meter(value: eff, color: eff > 0.5 ? Theme.teal : eff > 0.25 ? Theme.amber : Theme.coral)
            Text(ratio < 2.2
                 ? "Close to physics — the route is direct and the server is near its geolocated spot."
                 : "Extra delay comes from indirect routing, queueing, or a CDN/anycast node that isn't where the IP database thinks it is.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Right column panels

private struct ThroughputPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let iface = model.net.primaryInterface
        let series = model.throughput.series(iface)
        let c = iface.flatMap { model.throughput.counters[$0] }
        Panel("Throughput · \(iface ?? "—")", icon: "chart.xyaxis.line") {
            HStack(spacing: 10) {
                legend(Theme.down, "down", series.last?.inBps ?? 0)
                legend(Theme.up, "up", series.last?.outBps ?? 0)
                Spacer()
                Text("peak \(Fmt.bitrate(bytesPerSecond: model.throughput.peak[iface ?? ""] ?? 0))")
                    .font(.mono(10)).foregroundStyle(Theme.faint)
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ScreenFrame(label: "Last 2 minutes", live: true) {
                    ZStack {
                        Graticule(columns: 12, rows: 4)
                        DualTrace(down: series.map(\.inBps), up: series.map(\.outBps), capacity: model.throughput.capacity)
                            .padding(.vertical, 6)
                    }
                    .frame(height: 110)
                }
                if let c {
                    HStack {
                        Text("since boot  ↓ \(Fmt.bytes(c.bytesIn))  ↑ \(Fmt.bytes(c.bytesOut))")
                        Spacer()
                        Text("\(Fmt.count(Int(c.packetsIn + c.packetsOut))) pkts")
                    }
                    .font(.mono(10.5))
                    .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func legend(_ c: Color, _ label: String, _ v: Double) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text("\(label) \(Fmt.bitrate(bytesPerSecond: v))").font(.mono(10)).foregroundStyle(Theme.ink2)
        }
    }
}

private struct LatencyPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Panel("Latency", icon: "waveform.path.ecg", info: .rtt) {
            VStack(alignment: .leading, spacing: 12) {
                row(model.pings.gateway, Theme.accent)
                Hairline()
                row(model.pings.internet, Theme.accent)
                Hairline()
                row(model.pings.targets[2], Theme.accent)
                TermLabel(text: "MOS estimates how a voice call would sound", term: .mos, font: .system(size: 11), color: Theme.tertiary)
            }
        }
    }

    private func row(_ t: PingTarget, _ color: Color) -> some View {
        let s = t.stats(window: 60)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                Text(t.host.isEmpty ? "—" : t.host).font(.mono(10)).foregroundStyle(Theme.muted)
            }
            .frame(width: 92, alignment: .leading)
            Sparkline(values: t.samples.suffix(60).map(\.rtt), color: color, lineWidth: 1.2, markGaps: true, capacity: 60)
                .frame(height: 30)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.ms(s.last)).font(.mono(12, .medium)).foregroundStyle(Theme.latency(s.last))
                Text("MOS " + (s.mos.map { String(format: "%.1f", $0) } ?? "—")).font(.mono(9.5)).foregroundStyle(Theme.faint)
            }
            .frame(width: 64, alignment: .trailing)
        }
    }
}

private struct DNSPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Panel("DNS resolvers", icon: "character.book.closed", info: .dnsResolver) {
            VStack(alignment: .leading, spacing: 8) {
                if model.net.dnsServers.isEmpty {
                    Text("No DNS servers configured").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                ForEach(model.net.dnsServers, id: \.self) { s in
                    HStack {
                        Text(s).font(.mono(12)).foregroundStyle(Theme.ink).textSelection(.enabled)
                        Spacer()
                        if let n = KnownHosts.resolverName(s, gateway: model.net.router) {
                            Chip(text: n, color: Theme.teal)
                        }
                    }
                }
                if !model.net.searchDomains.isEmpty {
                    Hairline()
                    KV(key: "Search domains", value: model.net.searchDomains.joined(separator: ", "))
                }
                if !model.net.proxies.isEmpty {
                    KV(key: "Proxies", value: model.net.proxies.joined(separator: "\n"), color: Theme.amber)
                }
                let tunnels = model.interfaces.filter { $0.kind == .tunnel && !$0.ipv4.isEmpty }
                if !tunnels.isEmpty {
                    KV(key: "Tunnels up", value: tunnels.map { "\($0.name) \($0.ipv4.first?.address ?? "")" }.joined(separator: "\n"), color: Theme.violet)
                }
            }
        }
    }
}

private struct TopTalkersPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let top = Array(model.connections.processes.filter { $0.rateIn + $0.rateOut > 0 || $0.established > 0 }.prefix(6))
        let peak = max(top.map { $0.rateIn + $0.rateOut }.max() ?? 1, 1)
        Panel("Top talkers", icon: "person.2.wave.2") {
            if top.isEmpty {
                Text("Gathering per-process traffic…").font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else {
                VStack(spacing: 9) {
                    ForEach(top) { p in
                        let ident = ProcessCatalog.shared.identity(pid: p.pid, fallbackName: p.name)
                        HStack(spacing: 8) {
                            ProcessIcon(image: ident.icon, size: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(ident.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                                    Spacer()
                                    Text("↓\(Fmt.bitrate(bytesPerSecond: p.rateIn)) ↑\(Fmt.bitrate(bytesPerSecond: p.rateOut))")
                                        .font(.mono(10)).foregroundStyle(Theme.ink2)
                                }
                                Meter(value: (p.rateIn + p.rateOut) / peak, color: Theme.accent, height: 3)
                            }
                        }
                    }
                }
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
