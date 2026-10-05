import SwiftUI
import AppKit

/// Remote endpoints that geolocate to (nearly) the same place, drawn as one arc.
struct EndpointCluster: Identifiable, Hashable {
    let id: String
    var lat: Double
    var lon: Double
    var geo: GeoInfo
    var endpoints: [RemoteEndpoint] = []
    var rateIn: Double = 0
    var rateOut: Double = 0
    var bytes: UInt64 = 0
    var rtt: Double?
    var sockets = 0
    var processes: Set<String> = []
    var active = false
    var distanceKm: Double?

    /// RTT faster than light could cover the geolocated distance → the address is
    /// anycast / CDN and is really served from much closer than the IP database says.
    var isAnycastLikely: Bool {
        guard let rtt, let d = distanceKm, d > 400 else { return false }
        return rtt < GeoMath.minRTTms(distanceKm: d) * 0.85
    }
    /// Upper bound on the real server distance implied by the RTT.
    var maxPlausibleKm: Double? { rtt.map { $0 * GeoMath.fibreKmPerMs / 2 } }
}

@MainActor
@Observable
final class GlobeModel {
    enum Mode: String, CaseIterable { case live = "Live traffic", trace = "Traceroute" }
    var mode: Mode = .live
    var clusters: [EndpointCluster] = []
    var selected: String?
    var hovered: String?
    var showLabels = true
    var autoRotate = true
    let trace = TraceSession()
    var traceHost = "api.openai.com"
    @ObservationIgnored var focusedHomeOnce = false
}

struct GlobeScreen: View {
    @Environment(AppModel.self) private var model
    @State private var controller = GlobeController()
    @State private var globe = GlobeModel()

    var body: some View {
        ZStack {
            GlobeViewRepresentable(controller: controller)
                .ignoresSafeArea()

            // HUD
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    header
                    Spacer()
                    controls
                }
                Spacer()
                HStack(alignment: .bottom) {
                    legend
                    Spacer()
                }
            }
            .padding(20)
            .padding(.top, 40)

            if LandMask.status.generating {
                VStack(spacing: 8) {
                    ProgressView(value: LandMask.status.progress).frame(width: 180)
                    Text("Drawing continents from Apple Maps — first launch only")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                }
                .padding(14)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack {
                Spacer()
                sidePanel
                    .frame(width: 330)
                    .padding(.top, 140).padding(.bottom, 76)
                    .padding(.trailing, 20)
            }
        }
        .background(Theme.bg)
        .ignoresSafeArea(edges: .top)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear {
            controller.onSelect = { id in
                globe.selected = id
                controller.select(id)
                if let id, let c = globe.clusters.first(where: { $0.id == id }) {
                    controller.focus(lat: c.lat, lon: c.lon)
                }
            }
            controller.onHover = { globe.hovered = $0 }
            if let t = model.takeTarget(.globe) {
                globe.traceHost = t
                globe.mode = .trace
                globe.trace.start(t)
            }
            rebuild()
            if let g = model.selfGeo { controller.focus(lat: g.lat * 0.8, lon: g.lon, distance: 5.0) }
        }
        .onChange(of: model.connections.lastUpdate) { rebuild() }
        .onChange(of: model.connections.geo.count) { rebuild() }
        .onChange(of: model.selfGeo) { _, g in
            rebuild()
            if let g, !globe.focusedHomeOnce { globe.focusedHomeOnce = true; controller.focus(lat: g.lat * 0.8, lon: g.lon) }
        }
        .onChange(of: globe.trace.hops) { if globe.mode == .trace { rebuild() } }
        .onChange(of: globe.mode) { _, m in
            globe.selected = nil
            controller.select(nil)
            if m == .trace, globe.trace.state == .idle { globe.trace.start(globe.traceHost) }
            rebuild()
        }
        .onChange(of: globe.showLabels) { _, v in controller.container.labels.maxLabels = v ? 14 : 0 }
        .onChange(of: globe.autoRotate) { _, v in controller.autoRotate = v }
        .onDisappear { globe.trace.stop() }
    }

    // MARK: - HUD pieces

    private var header: some View {
        let real = globe.clusters.filter { !$0.isAnycastLikely }
        let active = real.filter(\.active)
        let nearby = globe.clusters.filter(\.isAnycastLikely).count
        let countries = Set(real.compactMap { $0.geo.countryCode }).count
        let asns = Set(globe.clusters.flatMap { c in c.endpoints.compactMap { model.connections.geo[$0.ip]?.asNumber } }).count
        let rtts = globe.clusters.compactMap(\.rtt).sorted()
        let median = rtts.isEmpty ? nil : rtts[rtts.count / 2]
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                                Text(globe.mode == .live ? "Where your packets go" : "How packets reach \(globe.trace.target)")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                if let g = model.selfGeo {
                    HStack(spacing: 4) {
                        Text("You appear online as \(g.ip) · \(g.shortPlace)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.muted)
                        InfoButton(term: model.viaTunnel ? .vpnExit : .publicIP)
                    }
                }
            }
            if globe.mode == .live {
                HStack(spacing: 18) {
                    stat("\(active.count)", "places now", Theme.text)
                    stat("\(countries)", "countries", Theme.text)
                    stat("\(asns)", "networks", Theme.text)
                    stat("\(nearby)", "served nearby", Theme.text)
                    stat(median.map { Fmt.msValue($0) } ?? "—", "median ms", Theme.text)
                }
            } else {
                HStack(spacing: 18) {
                    let hops = globe.trace.visibleHops
                    stat("\(hops.count)", "hops", Theme.text)
                    stat("\(Set(hops.compactMap { $0.geo?.asNumber }).count)", "networks", Theme.text)
                    stat(Fmt.msValue(hops.last(where: \.reachedDestination)?.avg), "RTT, ms", Theme.text)
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func stat(_ v: String, _ label: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.system(size: 20, weight: .semibold).monospacedDigit()).foregroundStyle(c)
                .contentTransition(.numericText())
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }

    private var controls: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Segmented(options: GlobeModel.Mode.allCases, selection: $globe.mode) { $0.rawValue }
            if globe.mode == .trace {
                HStack(spacing: 8) {
                    InstrumentField(placeholder: "host to trace", text: $globe.traceHost, icon: "scope") { runTrace() }
                        .frame(width: 220)
                    Button(globe.trace.state == .running ? "Tracing…" : "Trace") { runTrace() }
                        .buttonStyle(.borderedProminent)
                }
            }
            HStack(spacing: 8) {
                iconButton("plus.magnifyingglass", "Zoom in") { controller.zoom(0.8) }
                iconButton("minus.magnifyingglass", "Zoom out") { controller.zoom(1.25) }
                iconButton("location", "Center on me") { controller.resetView(lat: model.selfGeo?.lat, lon: model.selfGeo?.lon) }
                iconButton(globe.autoRotate ? "pause.circle" : "rotate.3d", globe.autoRotate ? "Stop rotation" : "Auto-rotate") { globe.autoRotate.toggle() }
                iconButton(globe.showLabels ? "tag.fill" : "tag", "Labels") { globe.showLabels.toggle() }
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .foregroundStyle(Theme.ink2)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([(Theme.latencyTrace(10), "< 50 ms"), (Theme.latencyTrace(100), "< 150"), (Theme.latencyTrace(200), "< 300"), (Theme.latencyTrace(400), "≥ 300")], id: \.1) { c, l in
                HStack(spacing: 5) {
                    Capsule().fill(c).frame(width: 12, height: 3)
                    Text(l).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.ink2)
                }
            }
            Divider().frame(height: 12)
            Text(globe.mode == .live ? "Colour = measured round trip · thickness = throughput · moving dots = live data" : "Each hop placed by its IP location · colour = round trip at that hop")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            InfoButton(term: .rtt)
            Divider().frame(height: 12)
            Text("Shading = live day / night")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: Capsule())
    }

    // MARK: - Side panel

    @ViewBuilder private var sidePanel: some View {
        VStack(spacing: 12) {
            if globe.mode == .live {
                if let id = globe.selected, let c = globe.clusters.first(where: { $0.id == id }) {
                    ClusterDetail(cluster: c, home: model.selfGeo, geo: model.connections.geo) {
                        globe.selected = nil
                        controller.select(nil)
                    } onTrace: { ip in
                        globe.traceHost = ip
                        globe.mode = .trace
                        runTrace()
                    }
                }
                destinationList
            } else {
                traceList
            }
        }
    }

    private var destinationList: some View {
        let sorted = globe.clusters.sorted { a, b in
            if a.active != b.active { return a.active }
            let ra = a.rateIn + a.rateOut, rb = b.rateIn + b.rateOut
            if ra != rb { return ra > rb }
            return a.bytes > b.bytes
        }
        let far = sorted.filter { !$0.isAnycastLikely }
        let nearby = sorted.filter(\.isAnycastLikely)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Destinations").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Text("\(sorted.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Hairline()
            if sorted.isEmpty {
                Text(GeoIPService.isEnabled ? "Locating remote hosts…" : "Geolocation is off (Settings).")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(14)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(far) { c in
                        ClusterRow(cluster: c, selected: c.id == globe.selected, hovered: c.id == globe.hovered)
                            .contentShape(Rectangle())
                            .onTapGesture { controller.onSelect?(c.id) }
                    }
                    if !nearby.isEmpty {
                        HStack(spacing: 4) {
                            Text("Served nearby").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                            InfoButton(term: .anycast)
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 2)
                        Text("Anycast addresses: their listed location is far away, but the round trip proves the server you reach is close. Not drawn on the globe.")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.bottom, 6)
                        ForEach(nearby) { c in
                            ClusterRow(cluster: c, selected: c.id == globe.selected, hovered: c.id == globe.hovered)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    globe.selected = c.id
                                    controller.select(c.id)
                                }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var traceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Hops").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                if globe.trace.state == .running { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(globe.trace.visibleHops) { h in
                        HopRow(hop: h)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let g = h.geo { controller.focus(lat: g.lat, lon: g.lon); controller.select("hop-\(h.ttl)") }
                            }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func runTrace() {
        globe.trace.start(globe.traceHost)
    }

    // MARK: - Scene building

    private func rebuild() {
        guard let home = model.selfGeo else { controller.setScene(GlobeSceneSpec()); return }
        let homeV = GeoMath.unitVector(lat: home.lat, lon: home.lon)
        var spec = GlobeSceneSpec()
        spec.markers.append(GlobeMarkerSpec(id: "home", pos: homeV, color: SIMD4(NSColor.controlAccentColor), size: 22, pulse: 0.01,
                                            kind: 1, label: "You · \(home.city ?? home.countryCode ?? "")", labelColor: .labelColor))
        if globe.mode == .live {
            globe.clusters = buildClusters(home: home)
            let peak = max(globe.clusters.map { $0.rateIn + $0.rateOut }.max() ?? 1, 1)
            // Anycast endpoints are physically near you; drawing them at their registered
            // location would be wrong, so they're listed but not plotted.
            for (i, c) in globe.clusters.enumerated() where !c.isAnycastLikely {
                let v = GeoMath.unitVector(lat: c.lat, lon: c.lon)
                let color = NSColor(Theme.latencyTrace(c.rtt))
                let rate = c.rateIn + c.rateOut
                if (c.distanceKm ?? 0) > 40 {
                    spec.arcs.append(GlobeArcSpec(
                        id: c.id, from: homeV, to: v, color: SIMD4(color),
                        width: Float(0.9 + min(2.2, log10(1 + rate / 512) * 0.8)),
                        down: Float(min(1, log10(1 + c.rateIn) / 5.5)),
                        up: Float(min(1, log10(1 + c.rateOut) / 5.5)),
                        intensity: c.active ? 1 : 0.28))
                }
                let label = "\(Fmt.flag(c.geo.countryCode)) \(c.geo.city ?? c.geo.countryCode ?? "?") · \(Fmt.ms(c.rtt))" 
                spec.markers.append(GlobeMarkerSpec(
                    id: c.id, pos: v, color: SIMD4(color, alpha: c.active ? 1 : 0.45),
                    size: Float(9 + min(10, Double(c.sockets) * 0.9)), pulse: c.active && rate > 0 ? Float(i) * 0.13 + 0.05 : 0,
                    kind: 0, label: label, labelColor: color, labelPriority: Int(rate / peak * 1000) + Int(min(c.bytes / 1_000_000, 900))))
            }
        } else {
            var prev = homeV
            var prevGeo: GeoInfo? = home
            for h in globe.trace.visibleHops {
                guard let g = h.geo else { continue }
                let v = GeoMath.unitVector(lat: g.lat, lon: g.lon)
                let color = NSColor(Theme.latencyTrace(h.avg))
                let moved = prevGeo.map { GeoMath.distanceKm($0, g) > 40 } ?? true
                if moved {
                    spec.arcs.append(GlobeArcSpec(id: "hop-\(h.ttl)", from: prev, to: v, color: SIMD4(color), width: 1.6, down: 0.5, up: 0.5, intensity: 1))
                }
                spec.markers.append(GlobeMarkerSpec(
                    id: "hop-\(h.ttl)", pos: v, color: SIMD4(color), size: h.reachedDestination ? 16 : 10, pulse: h.reachedDestination ? 0.2 : 0,
                    kind: 2, label: "#\(h.ttl) \(g.city ?? g.countryCode ?? "") \(Fmt.ms(h.avg))", labelColor: color,
                    labelPriority: 1000 - h.ttl))
                prev = v
                prevGeo = g
            }
        }
        controller.setScene(spec)
    }

    private func buildClusters(home: GeoInfo) -> [EndpointCluster] {
        var byKey: [String: EndpointCluster] = [:]
        for e in model.connections.endpoints.values {
            guard let g = model.connections.geo[e.ip] else { continue }
            let key = String(format: "%.1f,%.1f", g.lat, g.lon)
            var c = byKey[key] ?? EndpointCluster(id: key, lat: g.lat, lon: g.lon, geo: g)
            c.endpoints.append(e)
            c.rateIn += e.rateIn
            c.rateOut += e.rateOut
            c.bytes += e.bytesIn + e.bytesOut
            c.sockets += e.sockets
            c.processes.formUnion(e.processes)
            if let r = e.rttMs { c.rtt = min(c.rtt ?? r, r) }
            c.active = c.active || e.active
            c.distanceKm = GeoMath.distanceKm(home, g)
            byKey[key] = c
        }
        return Array(byKey.values)
    }
}

// MARK: - Rows & detail

private struct ClusterRow: View {
    let cluster: EndpointCluster
    let selected: Bool
    let hovered: Bool

    var body: some View {
        let c = cluster
        HStack(spacing: 10) {
            Text(Fmt.flag(c.geo.countryCode)).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(c.isAnycastLikely ? c.geo.operatorName : (c.geo.city ?? c.geo.country ?? "Unknown"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(c.active ? Theme.ink : Theme.muted)
                    .lineLimit(1)
                Text(c.isAnycastLikely ? "listed in \(c.geo.city ?? c.geo.country ?? "?")" : c.geo.operatorName)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.ms(c.rtt)).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.latency(c.rtt))
                Text(c.rateIn + c.rateOut > 0 ? Fmt.bitrate(bytesPerSecond: c.rateIn + c.rateOut) : "\(c.sockets) connection\(c.sockets == 1 ? "" : "s")")
                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(selected ? Theme.accent.opacity(0.12) : hovered ? Theme.fill : .clear)
        .overlay(alignment: .leading) {
            EmptyView()
        }
    }
}

private struct HopRow: View {
    let hop: TraceHop
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(hop.ttl)")
                .font(.mono(11, .medium))
                .foregroundStyle(Theme.faint)
                .frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(hop.address ?? "* * *")
                    .font(.mono(11.5))
                    .foregroundStyle(hop.address == nil ? Theme.faint : Theme.ink)
                Text([hop.geo.map { "\(Fmt.flag($0.countryCode)) \($0.shortPlace)" }, hop.geo?.asNumber, hop.scope.flatMap { $0 == .global ? nil : $0.rawValue }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.mono(9.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text(Fmt.ms(hop.avg)).font(.mono(11)).foregroundStyle(Theme.latency(hop.avg))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

private struct ClusterDetail: View {
    let cluster: EndpointCluster
    let home: GeoInfo?
    let geo: [String: GeoInfo]
    let onClose: () -> Void
    let onTrace: (String) -> Void

    var body: some View {
        let c = cluster
        let minRTT = c.distanceKm.map(GeoMath.minRTTms(distanceKm:))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.isAnycastLikely ? "Anycast · listed in \(c.geo.place)" : "\(Fmt.flag(c.geo.countryCode))  \(c.geo.place)").eyebrowStyle()
                    Text(c.geo.operatorName).font(.display(17, .semibold)).foregroundStyle(Theme.ink)
                    if let asn = c.geo.asn {
                        HStack(spacing: 3) {
                            Text(asn).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                            InfoButton(term: .asn, size: 10)
                        }
                    }
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted)
            }
            HStack(spacing: 10) {
                Readout(label: "Round trip", value: Fmt.msValue(c.rtt), unit: "ms", accent: Theme.latency(c.rtt), size: 20, info: .rtt)
                Readout(label: c.isAnycastLikely ? "Listed distance" : "Distance", value: c.distanceKm.map { String(format: "%.0f", $0) } ?? "—", unit: "km", accent: Theme.ink, size: 20,
                        info: c.isAnycastLikely ? .anycast : .pathStretch)
            }
            if c.isAnycastLikely, let rtt = c.rtt, let maxKm = c.maxPlausibleKm {
                Callout(kind: .info, title: "Anycast: this server is near you",
                        message: "A \(Fmt.ms(rtt)) round trip means the server is at most \(Fmt.km(maxKm)) away, yet the IP database places it \(Fmt.km(c.distanceKm ?? 0)) away in \(c.geo.city ?? "another city"). This address is anycast or a CDN edge: the same IP is announced from many places and you're reaching a nearby copy.")
            } else if let minRTT, let rtt = c.rtt {
                PathEfficiency(minRTT: minRTT, actual: rtt)
            }
            VStack(spacing: 0) {
                KV(key: "Apps", value: c.processes.sorted().joined(separator: ", "), mono: false)
                KV(key: "Traffic", value: "↓ \(Fmt.bitrate(bytesPerSecond: c.rateIn))  ↑ \(Fmt.bitrate(bytesPerSecond: c.rateOut))")
                KV(key: "Transferred", value: Fmt.bytes(c.bytes))
                KV(key: "Sockets", value: "\(c.sockets)")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Addresses").font(.mono(9.5, .medium)).foregroundStyle(Theme.faint)
                ForEach(c.endpoints.prefix(6)) { e in
                    HStack {
                        Text(e.ip).font(.mono(11)).foregroundStyle(Theme.ink2).textSelection(.enabled)
                        Spacer()
                        Text(e.ports.sorted().prefix(3).map(String.init).joined(separator: ","))
                            .font(.mono(10)).foregroundStyle(Theme.faint)
                        Button { onTrace(e.ip) } label: { Image(systemName: "point.3.filled.connected.trianglepath.dotted") }
                            .buttonStyle(.plain).foregroundStyle(Theme.amber).help("Trace the route to \(e.ip)")
                    }
                }
                if c.endpoints.count > 6 {
                    Text("+\(c.endpoints.count - 6) more").font(.mono(10)).foregroundStyle(Theme.faint)
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}
