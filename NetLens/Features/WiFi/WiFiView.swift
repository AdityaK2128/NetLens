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

    private let palette: [Color] = [.blue, .purple, .orange, .pink, .teal, .green, .indigo, .brown]

    var body: some View {
        Canvas { ctx, size in
            let range = WiFiMath2.range(band)
            let plot = CGRect(x: 36, y: 8, width: size.width - 44, height: size.height - 30)
            func x(_ f: Double) -> CGFloat { plot.minX + plot.width * CGFloat((f - range.lowerBound) / (range.upperBound - range.lowerBound)) }
            func y(_ dbm: Double) -> CGFloat { plot.maxY - plot.height * CGFloat((dbm + 100) / 80) }

            // grid
            var grid = Path()
            for d in stride(from: -90.0, through: -30, by: 10) {
                grid.move(to: CGPoint(x: plot.minX, y: y(d))); grid.addLine(to: CGPoint(x: plot.maxX, y: y(d)))
                ctx.draw(Text("\(Int(d))").font(.mono(8.5)).foregroundStyle(Theme.faint), at: CGPoint(x: 16, y: y(d)))
            }
            ctx.stroke(grid, with: .color(Theme.line.opacity(0.6)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

            // channel ticks
            let ticks: [Int] = band < 3 ? Array(1...13) : band < 5.9 ? [36, 44, 52, 60, 100, 108, 116, 124, 132, 140, 149, 157, 165, 173] : Array(stride(from: 1, through: 233, by: 16))
            for t in ticks {
                let fx = x(WiFiMath2.freq(Double(t), bandGHz: band))
                ctx.draw(Text("\(t)").font(.mono(8.5)).foregroundStyle(Theme.muted), at: CGPoint(x: fx, y: plot.maxY + 10))
            }

            // humps, weakest first so strong ones sit on top
            for (i, n) in networks.sorted(by: { $0.rssi < $1.rssi }).enumerated() {
                let centre = WiFiMath2.freq(WiFiMath2.centreChannel(n.channel, width: n.width, bandGHz: band), bandGHz: band)
                let half = Double(n.width) / 2
                let x0 = x(centre - half), x1 = x(centre + half)
                let top = y(Double(n.rssi)), base = y(-100)
                var p = Path()
                p.move(to: CGPoint(x: x0, y: base))
                p.addCurve(to: CGPoint(x: (x0 + x1) / 2, y: top), control1: CGPoint(x: x0 + (x1 - x0) * 0.12, y: top), control2: CGPoint(x: x0 + (x1 - x0) * 0.25, y: top))
                p.addCurve(to: CGPoint(x: x1, y: base), control1: CGPoint(x: x1 - (x1 - x0) * 0.25, y: top), control2: CGPoint(x: x1 - (x1 - x0) * 0.12, y: top))
                let c = n.isCurrent ? Theme.accent : palette[i % palette.count].opacity(0.75)
                ctx.fill(p, with: .color(c.opacity(n.isCurrent ? 0.22 : 0.08)))
                ctx.stroke(p, with: .color(c.opacity(n.isCurrent ? 1 : 0.7)), lineWidth: n.isCurrent ? 2 : 1)
                if n.rssi > -82 || n.isCurrent {
                    ctx.draw(Text(n.ssid ?? "hidden").font(.mono(9, n.isCurrent ? .bold : .regular)).foregroundStyle(c),
                             at: CGPoint(x: (x0 + x1) / 2, y: top - 8))
                }
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
