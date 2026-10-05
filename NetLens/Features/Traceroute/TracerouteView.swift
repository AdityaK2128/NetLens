import SwiftUI

struct TracerouteView: View {
    @Environment(AppModel.self) private var model
    @State private var session = TraceSession()
    @State private var host = "api.openai.com"
    @State private var continuous = false

    var body: some View {
        let hops = session.visibleHops
        let dest = hops.last(where: \.reachedDestination)
        Page(spacing: 18) {
            PageHeader(eyebrow: "Diagnose · traceroute / mtr", title: "Route tracer",
                       subtitle: "Probes every hop in parallel with ICMP TTL expiry, then annotates each router with its network (ASN), location and reverse DNS. Turn on MTR mode to keep probing and expose loss and jitter per hop.")

            HStack(spacing: 10) {
                InstrumentField(placeholder: "Host or IP", text: $host, icon: "scope") { start() }
                Toggle("Keep probing (MTR)", isOn: $continuous).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    .help("Repeats the trace every second to measure loss and jitter at each hop, like the mtr tool.")
                if session.state == .running || session.state == .resolving {
                    Button("Stop") { session.stop() }.buttonStyle(.bordered)
                } else {
                    Button("Trace") { start() }.buttonStyle(.borderedProminent)
                }
                Button {
                    model.open(.globe, target: host)
                } label: { Label("On globe", systemImage: "globe.americas") }
                    .buttonStyle(.bordered)
            }

            if case .failed(let msg) = session.state {
                Callout(kind: .warning, title: "Trace failed", message: msg)
            }

            if !hops.isEmpty {
                HStack(spacing: 12) {
                    Readout(label: "Destination", value: session.targetIP ?? "—", accent: Theme.ink, caption: session.target, size: 17)
                    Readout(label: "Hops", value: dest.map { "\($0.ttl)" } ?? "\(hops.count)…", accent: Theme.amber, info: .traceroute)
                    Readout(label: "Round trip", value: Fmt.msValue(dest?.avg), unit: "ms", accent: Theme.latency(dest?.avg),
                            caption: dest?.stdev.map { "σ \(Fmt.ms($0))" })
                    Readout(label: "Networks crossed", value: "\(Set(hops.compactMap { $0.geo?.asNumber }).count)", accent: Theme.violet, info: .asn)
                    Readout(label: "Rounds", value: "\(session.rounds)", accent: Theme.ink, caption: continuous ? "continuous" : "3-probe trace")
                }

                Panel("Path", icon: "point.3.filled.connected.trianglepath.dotted", info: .traceroute) {
                    if session.state == .running { HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("probing").font(.mono(10)).foregroundStyle(Theme.muted) } }
                } content: {
                    let scale = max(hops.compactMap(\.worst).max() ?? 1, 1)
                    VStack(spacing: 0) {
                        hopHeader
                        ForEach(Array(hops.enumerated()), id: \.element.id) { i, h in
                            HopLine(hop: h, previous: i > 0 ? hops[i - 1] : nil, scale: scale, isLast: i == hops.count - 1, mtr: continuous)
                        }
                    }
                }

                let notes = TraceInsights.analyse(hops, home: model.selfGeo, gateway: model.net.router)
                if !notes.isEmpty {
                    Panel("What the path tells us", icon: "lightbulb") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(notes, id: \.title) { n in
                                Callout(kind: n.kind, title: n.title, message: n.detail)
                            }
                        }
                    }
                }
            } else if session.state == .idle {
                EmptyState(icon: "point.3.filled.connected.trianglepath.dotted", title: "Trace a route",
                           message: "Enter any host. You'll see your router, your ISP's edge, the peering point, and the networks your packets cross to get there.")
            }
        }
        .onAppear {
            if let t = model.takeTarget(.traceroute) { host = t; start() }
        }
        .onDisappear { session.stop() }
    }

    private var hopHeader: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: 26, alignment: .trailing)
            Text("").frame(width: 14)
            Text("Router").frame(maxWidth: .infinity, alignment: .leading)
            Text("Network · location").frame(width: 230, alignment: .leading)
            Text("Latency (min – avg – max)").frame(width: 220, alignment: .leading)
            Text("Loss").frame(width: 50, alignment: .trailing)
        }
        .font(.mono(9.5, .medium))
        .foregroundStyle(Theme.faint)
        .padding(.bottom, 8)
    }

    private func start() {
        guard !host.trimmed.isEmpty else { return }
        session.start(host, continuous: continuous)
    }
}

private struct HopLine: View {
    let hop: TraceHop
    let previous: TraceHop?
    let scale: Double
    let isLast: Bool
    let mtr: Bool

    var body: some View {
        let h = hop
        let color: Color = h.isSilent ? Theme.faint : Theme.latency(h.avg)
        HStack(alignment: .center, spacing: 12) {
            Text("\(h.ttl)").font(.mono(11, .medium)).foregroundStyle(Theme.muted).frame(width: 26, alignment: .trailing)
            // spine
            ZStack {
                Rectangle().fill(Theme.line).frame(width: 1.5)
                    .padding(.top, h.ttl == 1 ? 18 : 0)
                    .padding(.bottom, isLast ? 18 : 0)
                Circle()
                    .fill(h.reachedDestination ? color : Theme.trough)
                    .overlay(Circle().strokeBorder(color, lineWidth: 1.5))
                    .frame(width: h.reachedDestination ? 12 : 9, height: h.reachedDestination ? 12 : 9)
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                if h.isSilent && h.address == nil {
                    Text("* * *  no reply").font(.mono(12)).foregroundStyle(Theme.faint)
                    Text("router doesn't answer TTL-expired probes").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                } else {
                    HStack(spacing: 6) {
                        Text(h.address ?? "…").font(.mono(12)).foregroundStyle(Theme.ink).textSelection(.enabled)
                        if h.addresses.count > 1 {
                            TermTag(text: "+\(h.addresses.count - 1) paths", term: .ecmp)
                                .help("Also answered: \(h.addresses.dropFirst().joined(separator: ", "))")
                        }
                        if let s = h.scope, s != .global {
                            TermTag(text: s == .cgnat ? "CGNAT range" : s == .privateNet ? "private" : s.rawValue.lowercased(), term: s == .cgnat ? .cgnat : .privateHop)
                        }
                    }
                    Text(h.hostname ?? " ").font(.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                if let g = h.geo {
                    Text("\(Fmt.flag(g.countryCode)) \(g.shortPlace)").font(.system(size: 11.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                    Text([g.asNumber, g.org ?? g.isp].compactMap { $0 }.joined(separator: " ")).font(.mono(9.5)).foregroundStyle(Theme.muted).lineLimit(1)
                } else {
                    Text(h.scope == .global || h.scope == nil ? " " : "local network").font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
            }
            .frame(width: 230, alignment: .leading)

            LatencyWhisker(hop: h, scale: scale, mtr: mtr)
                .frame(width: 220, height: 26)

            // A hop that never answers isn't "losing" packets — it just won't reply to probes.
            Text(h.sent == 0 || h.isSilent ? "—" : String(format: "%.0f%%", h.loss))
                .font(.mono(11))
                .foregroundStyle(h.sent == 0 || h.isSilent ? Theme.faint : Theme.loss(h.loss))
                .frame(width: 50, alignment: .trailing)
        }
        .frame(minHeight: 46)
        .contextMenu {
            if let a = h.address {
                Button("Copy \(a)") { copyToPasteboard(a) }
                if let n = h.hostname { Button("Copy \(n)") { copyToPasteboard(n) } }
            }
        }
    }
}

/// min–max whisker with avg marker, or a live sparkline in MTR mode.
private struct LatencyWhisker: View {
    let hop: TraceHop
    let scale: Double
    let mtr: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - 56
            let c = Theme.latency(hop.avg)
            ZStack(alignment: .leading) {
                if mtr && hop.samples.count > 3 {
                    Sparkline(values: hop.samples, color: c, lineWidth: 1.1, fill: false, markGaps: true, capacity: 60)
                        .frame(width: w)
                } else if let lo = hop.best, let hi = hop.worst, let avg = hop.avg {
                    let x0 = w * lo / scale, x1 = w * hi / scale, xa = w * avg / scale
                    Capsule().fill(Theme.trough).frame(width: w, height: 4)
                    Capsule().fill(c.opacity(0.45)).frame(width: max(2, x1 - x0), height: 4).offset(x: x0)
                    Circle().fill(c).frame(width: 7, height: 7).offset(x: xa - 3.5)
                }
                Text(Fmt.ms(hop.avg))
                    .font(.mono(11, .medium))
                    .foregroundStyle(hop.avg == nil ? Theme.faint : c)
                    .frame(width: 52, alignment: .trailing)
                    .offset(x: w + 4)
            }
            .frame(height: geo.size.height)
        }
    }
}

// MARK: - Insights

struct TraceNote {
    let kind: Callout.Kind
    let title: String
    let detail: String
}

enum TraceInsights {
    static func analyse(_ hops: [TraceHop], home: GeoInfo?, gateway: String?) -> [TraceNote] {
        var notes: [TraceNote] = []
        let responding = hops.filter { !$0.isSilent }

        // Private / CGNAT addressing past the first public hop.
        if let firstPublic = hops.firstIndex(where: { $0.scope == .global }) {
            let inner = hops[firstPublic...].filter { $0.scope == .privateNet || $0.scope == .cgnat }
            if !inner.isEmpty {
                notes.append(TraceNote(kind: .info, title: "Private addresses inside the ISP",
                                       detail: "Hops \(inner.map { String($0.ttl) }.joined(separator: ", ")) answer from private or shared space. Your ISP numbers its internal backbone (often MPLS) with non-routable addresses — harmless, but they can't be geolocated."))
            }
        }
        if let cg = hops.prefix(5).first(where: { $0.scope == .cgnat }) {
            notes.append(TraceNote(kind: .warning, title: "Carrier-grade NAT likely",
                                   detail: "Hop \(cg.ttl) (\(cg.address ?? "")) is in 100.64.0.0/10. You probably share a public IPv4 address with other customers, which breaks inbound port forwarding."))
        }

        // Internet exchanges.
        for h in responding {
            let name = (h.hostname ?? "").lowercased()
            let org = (h.geo?.org ?? h.geo?.isp ?? "").lowercased()
            let ixTokens = [".ix.", "-ix.", "ixp", "equinix", "de-cix", "decix", "linx", "ams-ix", "amsix", "megaport", "napafrica", "jpnap", "bbix"]
            if ixTokens.contains(where: { name.contains($0) }) || org.contains("internet exchange") || org.contains("exchange point") || org.contains(" ix ") {
                notes.append(TraceNote(kind: .tip, title: "Public peering at hop \(h.ttl)",
                                       detail: "\(h.hostname ?? h.address ?? "") belongs to an Internet Exchange (\(h.geo?.org ?? "IXP")). Your ISP hands traffic directly to the destination's network here, instead of paying a transit provider."))
                break
            }
        }

        // Long-haul jumps.
        for i in responding.indices.dropFirst() {
            let a = responding[i - 1], b = responding[i]
            guard let la = a.best, let lb = b.best, lb - la > 35 else { continue }
            var detail = "Latency rises by \(Fmt.ms(lb - la)) between hop \(a.ttl) and hop \(b.ttl)."
            if let ga = a.geo ?? (a.ttl <= 2 ? home : nil), let gb = b.geo {
                let d = GeoMath.distanceKm(ga, gb)
                if d > 1500 {
                    detail += " That's \(Fmt.km(d)) from \(ga.city ?? ga.countryCode ?? "?") to \(gb.city ?? gb.countryCode ?? "?") — light in fibre alone needs \(Fmt.ms(GeoMath.minRTTms(distanceKm: d))) round-trip. Likely a submarine or long-haul cable."
                }
            }
            notes.append(TraceNote(kind: .info, title: "Long-haul link at hop \(b.ttl)", detail: detail))
        }

        // Loss that doesn't propagate = ICMP rate limiting, not real loss.
        if let dest = hops.last(where: \.reachedDestination) {
            for h in responding where h.ttl < dest.ttl && h.loss > 15 && h.sent >= 3 {
                let later = responding.filter { $0.ttl > h.ttl }
                if !later.isEmpty && later.allSatisfy({ $0.loss < h.loss / 2 }) {
                    notes.append(TraceNote(kind: .tip, title: "Hop \(h.ttl) shows \(Fmt.percent(h.loss, digits: 0)) loss — but it's not real",
                                           detail: "Later hops answer fine, so packets are getting through. This router just de-prioritises generating ICMP replies to save CPU. Only loss that continues to the destination matters."))
                    break
                }
            }
            if dest.loss > 5 && dest.sent >= 5 {
                notes.append(TraceNote(kind: .warning, title: "Real loss to destination: \(Fmt.percent(dest.loss, digits: 0))",
                                       detail: "Find the first hop where loss starts and persists through to the end — that's where the problem lives."))
            }
        }

        if let un = hops.first(where: { $0.unreachableCode != nil }), let code = un.unreachableCode {
            let meaning: String
            switch code {
            case 0: meaning = "network unreachable"
            case 1: meaning = "host unreachable"
            case 3: meaning = "port unreachable"
            case 9, 10, 13: meaning = "administratively prohibited (firewall)"
            default: meaning = "code \(code)"
            }
            notes.append(TraceNote(kind: .warning, title: "Destination unreachable at hop \(un.ttl)", detail: "\(un.address ?? "A router") replied: \(meaning)."))
        }
        return notes
    }
}
