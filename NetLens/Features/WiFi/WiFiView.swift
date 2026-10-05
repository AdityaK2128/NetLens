import SwiftUI
import Charts

struct WiFiView: View {
    @Environment(AppModel.self) private var model
    @State private var networks: [WiFiNetwork] = []
    @State private var scanning = false
    @State private var scanError: String?
    @State private var band: Double = 5
    @State private var lastScan: Date?

    var body: some View {
        let w = model.wifi
        Page(spacing: 18) {
            PageHeader(eyebrow: "Local · airport / wdutil", title: "Wi-Fi",
                       subtitle: "Your radio link in detail, and a spectrum view of every network around you — so you can see why the 2.4 GHz band is a parking lot.") {
                Button(scanning ? "Scanning…" : "Scan nearby networks") { scan() }
                    .buttonStyle(.borderedProminent).disabled(scanning || !w.powerOn)
            }

            if !w.powerOn {
                Callout(kind: .warning, title: "Wi-Fi is off")
            } else if w.ssid == nil && model.locationAuth != .authorizedAlways {
                HStack {
                    Callout(kind: .tip, title: "Network names are hidden by macOS",
                            message: "Since macOS 14.4, apps only see SSIDs and BSSIDs with Location access. NetLens uses it for nothing else and never stores your location.")
                    Button("Allow…") { model.requestLocation() }.buttonStyle(.bordered)
                }
            }

            HStack(alignment: .top, spacing: 18) {
                SignalGauge(rssi: w.rssi, noise: w.noise)
                    .frame(width: 260, height: 210)
                    .padding(16)
                    .background(PanelBackground())
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Readout(label: "Network", value: w.ssid ?? "hidden", accent: Theme.amber, caption: w.bssid.map { "BSSID \($0)" }, size: 20)
                        Readout(label: "Link rate", value: w.txRate.map { "\(Int($0))" } ?? "—", unit: "Mbps", accent: Theme.ink,
                                caption: w.phyMode, info: .phyRate)
                    }
                    HStack(spacing: 12) {
                        Readout(label: "Channel", value: w.channel.map(String.init) ?? "—", accent: Theme.ink,
                                caption: [w.band, w.channelWidth.map { "\($0) MHz" }, w.frequencyMHz.map { "\($0) MHz centre" }].compactMap { $0 }.joined(separator: " · "), info: .channelWidth)
                        Readout(label: "Security", value: w.security ?? "—", accent: (w.security ?? "").contains("WPA3") ? Theme.teal : Theme.ink,
                                caption: [w.countryCode.map { "country \($0)" }, w.txPower.flatMap { $0 < 1000 ? "tx \($0) mW" : nil }].compactMap { $0 }.joined(separator: " · "), size: 17, info: .wifiSecurity)
                    }
                    if let rssi = w.rssi, let f = w.frequencyMHz {
                        Text("Free-space estimate: the access point is roughly \(String(format: "%.0f", WiFiMath.estimatedDistanceMeters(rssi: rssi, frequencyMHz: f))) m away (walls make it closer than this).")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Panel("Signal history", icon: "chart.line.uptrend.xyaxis", info: .snr) {
                HStack(spacing: 12) {
                    legend(Theme.down, "RSSI"); legend(Theme.secondary, "Noise"); legend(Theme.up, "PHY rate")
                }
            } content: {
                historyChart.frame(height: 170)
            }

            Panel("Spectrum", icon: "waveform", info: .band) {
                Segmented(options: [2.4, 5, 6], selection: $band) { $0 == 2.4 ? "2.4 GHz" : "\(Int($0)) GHz" }
            } content: {
                if networks.isEmpty {
                    EmptyState(icon: "dot.radiowaves.left.and.right", title: scanning ? "Listening for beacons…" : "No scan yet",
                               message: scanError ?? "Scan to see nearby networks laid out across the band. Overlapping humps share airtime.")
                } else {
                    let inBand = networks.filter { abs($0.bandGHz - band) < 0.5 }
                    VStack(alignment: .leading, spacing: 12) {
                        SpectrumChart(networks: inBand, band: band)
                            .frame(height: 260)
                        if let rec = WiFiChannelAdvisor.recommend(networks: networks, band: band) {
                            Callout(kind: .tip, title: "Least congested \(band == 2.4 ? "2.4 GHz" : "\(Int(band)) GHz") channel: \(rec.channel)",
                                    message: rec.reason)
                        }
                    }
                }
            }

            if !networks.isEmpty {
                Panel("Nearby networks · \(networks.count)", icon: "list.bullet") {
                    if let t = lastScan { Text("scanned \(Fmt.clock.string(from: t))").font(.mono(10)).foregroundStyle(Theme.faint) }
                } content: {
                    VStack(spacing: 0) {
                        ForEach(networks) { n in
                            HStack(spacing: 12) {
                                SignalBars(rssi: n.rssi)
                                Text(n.ssid ?? "‹hidden›").font(.system(size: 12.5, weight: n.isCurrent ? .semibold : .regular))
                                    .foregroundStyle(n.isCurrent ? Theme.amber : n.ssid == nil ? Theme.faint : Theme.ink)
                                    .frame(width: 200, alignment: .leading).lineLimit(1)
                                Text(n.bssid ?? "—").font(.mono(10.5)).foregroundStyle(Theme.muted).frame(width: 140, alignment: .leading)
                                Text("\(n.rssi) dBm").font(.mono(11)).foregroundStyle(Theme.signal(n.rssi)).frame(width: 70, alignment: .trailing)
                                Text("ch \(n.channel)").font(.mono(11)).foregroundStyle(Theme.ink2).frame(width: 56, alignment: .trailing)
                                Text(n.bandGHz == 2.4 ? "2.4G" : "\(Int(n.bandGHz))G").font(.mono(11)).foregroundStyle(Theme.ink2).frame(width: 40)
                                Text("\(n.width) MHz").font(.mono(11)).foregroundStyle(Theme.ink2).frame(width: 64)
                                Chip(text: n.security, color: n.security.contains("WPA3") ? Theme.teal : n.security == "Open" ? Theme.coral : Theme.ink2)
                                Spacer()
                                if n.isCurrent { Chip(text: "Connected", color: Theme.amber, filled: true) }
                            }
                            .padding(.vertical, 6)
                            Hairline().opacity(0.5)
                        }
                    }
                }
            }
        }
        .onAppear {
            if let b = model.wifi.bandGHz { band = b }
            // `-NLWiFiAutoScan YES`: scan on launch (used for screenshots and testing).
            if UserDefaults.standard.bool(forKey: "NLWiFiAutoScan") && networks.isEmpty { scan() }
        }
    }

    private func legend(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 6, height: 6); Text(s).font(.mono(10)).foregroundStyle(Theme.muted) }
    }

    private var historyChart: some View {
        let h = model.wifiHistory
        return Chart {
            ForEach(Array(h.enumerated()), id: \.offset) { _, s in
                if let r = s.rssi {
                    LineMark(x: .value("t", s.time), y: .value("dBm", r), series: .value("s", "rssi"))
                        .foregroundStyle(Theme.down).interpolationMethod(.monotone)
                }
                if let n = s.noise {
                    LineMark(x: .value("t", s.time), y: .value("dBm", n), series: .value("s", "noise"))
                        .foregroundStyle(Theme.secondary).interpolationMethod(.monotone)
                }
                if let rate = s.rate {
                    // map PHY rate onto the dBm axis: 0 Mbps → -100, 1200 Mbps → -20
                    LineMark(x: .value("t", s.time), y: .value("dBm", -100 + rate / 15), series: .value("s", "rate"))
                        .foregroundStyle(Theme.up.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .chartYScale(domain: -100 ... -20)
        .chartYAxis {
            AxisMarks(position: .leading, values: [-90, -75, -67, -55, -40, -20]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Theme.line)
                AxisValueLabel().font(.mono(9.5)).foregroundStyle(Theme.muted)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute().second()).font(.mono(9.5)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func scan() {
        scanning = true
        scanError = nil
        Task {
            switch await model.scanWiFi() {
            case .success(let n): networks = n; lastScan = Date()
            case .failure(let e): scanError = e.localizedDescription
            }
            scanning = false
        }
    }
}

// MARK: - Gauge

private struct SignalGauge: View {
    let rssi: Int?
    let noise: Int?

    var body: some View {
        let value = rssi.map { Double(max(-95, min(-25, $0))) } ?? -95
        let frac = (value + 95) / 70
        let color = Theme.signal(rssi)
        VStack(spacing: 6) {
            ZStack {
                Arc(start: 0, end: 1).stroke(Theme.fill, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                Arc(start: 0, end: frac).stroke(color == Theme.text ? Theme.accent : color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                if let noise {
                    let nf = (Double(max(-95, min(-25, noise))) + 95) / 70
                    Arc(start: max(0, nf - 0.004), end: nf + 0.004).stroke(Theme.secondary, style: StrokeStyle(lineWidth: 16))
                }
                VStack(spacing: 0) {
                    Text(rssi.map(String.init) ?? "—").font(.system(size: 38, weight: .medium).monospacedDigit()).foregroundStyle(Theme.text)
                    Text("dBm RSSI").font(.mono(10)).foregroundStyle(Theme.muted)
                }
                .offset(y: 8)
            }
            .frame(height: 160)
            HStack(spacing: 18) {
                VStack(spacing: 1) {
                    Text(noise.map { "\($0)" } ?? "—").font(.mono(15, .medium)).foregroundStyle(Theme.text)
                    Text("Noise dBm").font(.mono(8.5)).foregroundStyle(Theme.faint)
                }
                VStack(spacing: 1) {
                    let snr = (rssi != nil && noise != nil) ? rssi! - noise! : nil
                    Text(snr.map { "\($0)" } ?? "—").font(.mono(15, .medium)).foregroundStyle(snr.map { $0 > 25 ? Theme.text : $0 > 15 ? Theme.warn : Theme.bad } ?? Theme.faint)
                    Text("SNR dB").font(.mono(8.5)).foregroundStyle(Theme.faint)
                }
                VStack(spacing: 1) {
                    Text(quality).font(.mono(15, .medium)).foregroundStyle(Theme.text)
                    Text("Quality").font(.mono(8.5)).foregroundStyle(Theme.faint)
                }
            }
        }
    }

    private var quality: String {
        guard let rssi else { return "—" }
        switch rssi {
        case (-55)...: return "Excellent"
        case (-67)...: return "Good"
        case (-75)...: return "Fair"
        default: return "Weak"
        }
    }
}

private struct Arc: Shape {
    var start: Double
    var end: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(rect.width, rect.height * 1.6) / 2 - 10
        let c = CGPoint(x: rect.midX, y: rect.midY + r * 0.3)
        p.addArc(center: c, radius: r, startAngle: .degrees(150 + 240 * start), endAngle: .degrees(150 + 240 * end), clockwise: false)
        return p
    }
}

// MARK: - Spectrum

enum WiFiMath2 {
    /// Centre channel of a bonded channel (CoreWLAN reports the primary channel).
    static func centreChannel(_ ch: Int, width: Int, bandGHz: Double) -> Double {
        guard width > 20 else { return Double(ch) }
        if bandGHz < 3 { return Double(ch) + (ch <= 7 ? 2 : -2) }
        let span = 4 * width / 20
        let base: Int = bandGHz > 5.9 ? 1 : (ch >= 149 ? 149 : 36)
        let b = (ch - base) / span
        return Double(base + b * span + (span - 4) / 2)
    }

    static func freq(_ ch: Double, bandGHz: Double) -> Double {
        if bandGHz < 3 { return 2407 + 5 * ch }
        if bandGHz < 5.9 { return 5000 + 5 * ch }
        return 5950 + 5 * ch
    }

    static func range(_ bandGHz: Double) -> ClosedRange<Double> {
        if bandGHz < 3 { return 2400...2495 }
        if bandGHz < 5.9 { return 5150...5895 }
        return 5925...7125
    }
}

private struct SpectrumChart: View {
    let networks: [WiFiNetwork]
    let band: Double
    @State private var hover: CGPoint?

    private let palette: [Color] = [.blue, .purple, .orange, .pink, .teal, .green, .indigo, .brown]

    /// Every network sharing a channel (and width) draws the same hump, so they're
    /// labelled and coloured as one group.
    private struct Group {
        let centre: Double          // MHz
        let width: Int
        var members: [WiFiNetwork]  // strongest first
        var peak: Int { members.first?.rssi ?? -100 }
        var hasCurrent: Bool { members.contains(where: \.isCurrent) }
        /// Distinct names with each one's strongest signal and how many access points use it.
        var names: [(name: String, rssi: Int, aps: Int, current: Bool)] {
            var seen: [String: (Int, Int, Bool)] = [:]
            var order: [String] = []
            for n in members {
                let k = n.ssid ?? "‹hidden›"
                if let e = seen[k] { seen[k] = (max(e.0, n.rssi), e.1 + 1, e.2 || n.isCurrent) }
                else { seen[k] = (n.rssi, 1, n.isCurrent); order.append(k) }
            }
            return order.map { (name: $0, rssi: seen[$0]!.0, aps: seen[$0]!.1, current: seen[$0]!.2) }
                .sorted { $0.current != $1.current ? $0.current : $0.rssi > $1.rssi }
        }
    }

    private var groups: [Group] {
        var byKey: [String: Group] = [:]
        for n in networks {
            let c = WiFiMath2.freq(WiFiMath2.centreChannel(n.channel, width: n.width, bandGHz: band), bandGHz: band)
            let k = "\(c)|\(n.width)"
            var g = byKey[k] ?? Group(centre: c, width: n.width, members: [])
            g.members.append(n)
            byKey[k] = g
        }
        return byKey.values.map { g in
            var g = g
            g.members.sort { $0.rssi > $1.rssi }
            return g
        }.sorted { $0.centre < $1.centre }
    }

    var body: some View {
        let groups = self.groups
        Canvas { ctx, size in
            let range = WiFiMath2.range(band)
            let plot = CGRect(x: 36, y: 8, width: size.width - 44, height: size.height - 30)
            func x(_ f: Double) -> CGFloat { plot.minX + plot.width * CGFloat((f - range.lowerBound) / (range.upperBound - range.lowerBound)) }
            func y(_ dbm: Double) -> CGFloat { plot.maxY - plot.height * CGFloat((dbm + 100) / 80) }

            // grid
            var grid = Path()
            for d in stride(from: -90.0, through: -30, by: 10) {
                grid.move(to: CGPoint(x: plot.minX, y: y(d))); grid.addLine(to: CGPoint(x: plot.maxX, y: y(d)))
                ctx.draw(Text(verbatim: "\(Int(d))").font(.mono(8.5)).foregroundStyle(Theme.faint), at: CGPoint(x: 16, y: y(d)))
            }
            ctx.stroke(grid, with: .color(Theme.line.opacity(0.6)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

            // channel ticks
            let ticks: [Int] = band < 3 ? Array(1...13) : band < 5.9 ? [36, 44, 52, 60, 100, 108, 116, 124, 132, 140, 149, 157, 165, 173] : Array(stride(from: 1, through: 233, by: 16))
            for t in ticks {
                let fx = x(WiFiMath2.freq(Double(t), bandGHz: band))
                ctx.draw(Text(verbatim: "\(t)").font(.mono(8.5)).foregroundStyle(Theme.muted), at: CGPoint(x: fx, y: plot.maxY + 10))
            }

            func hump(_ g: Group, _ rssi: Int) -> Path {
                let half = Double(g.width) / 2
                let x0 = x(g.centre - half), x1 = x(g.centre + half)
                let top = y(Double(rssi)), base = y(-100)
                var p = Path()
                p.move(to: CGPoint(x: x0, y: base))
                p.addCurve(to: CGPoint(x: (x0 + x1) / 2, y: top), control1: CGPoint(x: x0 + (x1 - x0) * 0.12, y: top), control2: CGPoint(x: x0 + (x1 - x0) * 0.25, y: top))
                p.addCurve(to: CGPoint(x: x1, y: base), control1: CGPoint(x: x1 - (x1 - x0) * 0.25, y: top), control2: CGPoint(x: x1 - (x1 - x0) * 0.12, y: top))
                return p
            }
            func color(_ i: Int, _ g: Group) -> Color { g.hasCurrent ? Theme.accent : palette[i % palette.count] }

            // Which group is under the pointer (the narrowest hump containing it wins).
            var hovered: Int?
            if let h = hover, plot.contains(h) {
                hovered = groups.indices.filter { i in
                    let half = Double(groups[i].width) / 2
                    return h.x >= x(groups[i].centre - half) && h.x <= x(groups[i].centre + half)
                }.min { groups[$0].width < groups[$1].width }
            }

            // humps: weakest groups first so strong ones sit on top; one colour per channel
            let order = groups.indices.sorted { groups[$0].peak < groups[$1].peak }
            for i in order {
                let g = groups[i]
                let c = color(i, g)
                let lit = hovered == i
                for n in g.members.reversed() {
                    let p = hump(g, n.rssi)
                    ctx.fill(p, with: .color(c.opacity(n.isCurrent ? 0.22 : (lit ? 0.12 : 0.05))))
                    ctx.stroke(p, with: .color(c.opacity(n.isCurrent || lit ? 1 : 0.65)), lineWidth: n.isCurrent || lit ? 2 : 1)
                }
            }

            // labels: strongest groups get first pick; collisions stack upward
            var placed: [CGRect] = []
            for i in groups.indices.sorted(by: { (groups[$0].hasCurrent ? 1 : 0, groups[$0].peak) > (groups[$1].hasCurrent ? 1 : 0, groups[$1].peak) }) {
                let g = groups[i]
                guard g.peak > -85 || g.hasCurrent, let first = g.names.first else { continue }
                let more = g.names.count - 1
                let label = Text(verbatim: first.name).font(.system(size: 10, weight: first.current ? .semibold : .regular)).foregroundStyle(color(i, g))
                    + Text(verbatim: more > 0 ? "  +\(more)" : "").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                let resolved = ctx.resolve(label)
                let sz = resolved.measure(in: CGSize(width: 400, height: 40))
                var r = CGRect(x: x(g.centre) - sz.width / 2, y: y(Double(g.peak)) - 8 - sz.height, width: sz.width, height: sz.height)
                r.origin.x = min(max(r.minX, plot.minX), plot.maxX - r.width)
                var tries = 0
                while placed.contains(where: { $0.insetBy(dx: -4, dy: -1).intersects(r) }) && tries < 6 {
                    r.origin.y -= sz.height + 2
                    tries += 1
                }
                guard r.minY >= 0, !placed.contains(where: { $0.insetBy(dx: -4, dy: -1).intersects(r) }) else { continue }
                placed.append(r)
                ctx.draw(resolved, in: r)
            }

            // hover card: everything on that channel
            if let i = hovered, let h = hover {
                let g = groups[i]
                let lines = g.names.prefix(9)
                var rows: [GraphicsContext.ResolvedText] = []
                let chs = Array(Set(g.members.map(\.channel))).sorted().map(String.init)
                rows.append(ctx.resolve(Text(verbatim: "Channel\(chs.count == 1 ? "" : "s") \(chs.joined(separator: ", ")) · \(g.width) MHz · \(g.members.count) access point\(g.members.count == 1 ? "" : "s")")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text)))
                for l in lines {
                    rows.append(ctx.resolve(Text(verbatim: "\(l.rssi) dBm   ").font(.mono(10.5)).foregroundStyle(Theme.secondary)
                        + Text(verbatim: l.name).font(.system(size: 10.5, weight: l.current ? .semibold : .regular)).foregroundStyle(l.current ? Theme.accent : Theme.text)
                        + Text(verbatim: l.aps > 1 ? "  ×\(l.aps)" : "").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)))
                }
                if g.names.count > lines.count {
                    rows.append(ctx.resolve(Text(verbatim: "+\(g.names.count - lines.count) more").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)))
                }
                let sizes = rows.map { $0.measure(in: CGSize(width: 500, height: 30)) }
                let w = (sizes.map(\.width).max() ?? 0) + 20
                let ht = sizes.reduce(0) { $0 + $1.height + 3 } + 14
                var box = CGRect(x: h.x + 14, y: h.y - ht / 2, width: w, height: ht)
                if box.maxX > size.width - 4 { box.origin.x = h.x - 14 - w }
                box.origin.y = min(max(box.minY, 2), size.height - ht - 2)
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous).path(in: box)
                ctx.fill(shape, with: .color(Theme.card))
                ctx.stroke(shape, with: .color(Theme.separator), lineWidth: 0.5)
                var yy = box.minY + 7
                for (k, r) in rows.enumerated() {
                    ctx.draw(r, in: CGRect(x: box.minX + 10, y: yy, width: sizes[k].width, height: sizes[k].height))
                    yy += sizes[k].height + 3
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hover = p
            case .ended: hover = nil
            }
        }
    }
}

enum WiFiChannelAdvisor {
    struct Recommendation { let channel: Int; let reason: String }

    static func recommend(networks: [WiFiNetwork], band: Double) -> Recommendation? {
        let candidates: [Int]
        if band < 3 { candidates = [1, 6, 11] }
        else if band < 5.9 { candidates = [36, 40, 44, 48, 149, 153, 157, 161, 165] }   // non-DFS
        else { candidates = Array(stride(from: 5, through: 93, by: 8)) }
        let inBand = networks.filter { abs($0.bandGHz - band) < 0.5 }
        guard !inBand.isEmpty else { return nil }
        var best: (Int, Double)?
        for c in candidates {
            let cf = WiFiMath2.freq(Double(c), bandGHz: band)
            var load = 0.0
            for n in inBand where !n.isCurrent {
                let nf = WiFiMath2.freq(WiFiMath2.centreChannel(n.channel, width: n.width, bandGHz: band), bandGHz: band)
                let overlap = max(0, min(cf + 10, nf + Double(n.width) / 2) - max(cf - 10, nf - Double(n.width) / 2)) / 20
                load += overlap * pow(10, Double(n.rssi) / 10)
            }
            if best == nil || load < best!.1 { best = (c, load) }
        }
        guard let (ch, _) = best else { return nil }
        let crowd = inBand.filter { n in
            let nf = WiFiMath2.freq(WiFiMath2.centreChannel(n.channel, width: n.width, bandGHz: band), bandGHz: band)
            return abs(nf - WiFiMath2.freq(Double(ch), bandGHz: band)) < Double(n.width) / 2 + 10
        }.count
        return Recommendation(channel: ch, reason: "Weighted by each neighbour's signal power and channel overlap, channel \(ch) has the least competition (\(crowd) overlapping network\(crowd == 1 ? "" : "s"))\(band >= 5 && band < 5.9 ? " among non-DFS channels" : ""). Change it in your router's settings if you control it.")
    }
}
