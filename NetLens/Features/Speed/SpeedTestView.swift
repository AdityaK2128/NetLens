import SwiftUI

struct SpeedResult: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var download: Double?      // bits/s
    var upload: Double?
    var rpm: Double?
    var baseRTT: Double?
    var dlRPM: Double?
    var ulRPM: Double?
    var interface: String?
    var dlFlows: Int?
    var ulFlows: Int?
    var raw: String = ""

    var loadedLatency: Double? { rpm.map { 60_000 / $0 } }
    var rpmRating: (String, Color) {
        guard let r = rpm else { return ("—", Theme.faint) }
        if r >= 1000 { return ("High", Theme.good) }
        if r >= 300 { return ("Medium", Theme.text) }
        return ("Low", Theme.coral)
    }

    static func parse(_ json: String) -> SpeedResult? {
        guard let start = json.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(json[start...].utf8)) as? [String: Any] else { return nil }
        func d(_ k: String) -> Double? { (obj[k] as? NSNumber)?.doubleValue }
        var r = SpeedResult()
        r.download = d("dl_throughput")
        r.upload = d("ul_throughput")
        r.rpm = d("responsiveness")
        r.baseRTT = d("base_rtt")
        r.dlRPM = d("dl_responsiveness")
        r.ulRPM = d("ul_responsiveness")
        r.interface = obj["interface_name"] as? String
        r.dlFlows = (obj["dl_flows"] as? NSNumber)?.intValue
        r.ulFlows = (obj["ul_flows"] as? NSNumber)?.intValue
        r.raw = json
        return r
    }
}

struct SpeedTestView: View {
    @Environment(AppModel.self) private var model
    @State private var running = false
    @State private var started: Date?
    @State private var current: SpeedResult?
    @State private var error: String?
    @State private var sequential = false
    @State private var proto = "auto"
    @State private var history: [SpeedResult] = SpeedTestView.loadHistory()

    var body: some View {
        Page(spacing: 18) {
            PageHeader(eyebrow: "Diagnose · networkQuality", title: "Speed & responsiveness",
                       subtitle: "Throughput is only half the story. Responsiveness (RPM) measures how many round trips your link can still do per minute while it's saturated — low RPM is bufferbloat, the reason video calls freeze when someone starts a download.")

            HStack(spacing: 12) {
                Segmented(options: ["auto", "h2", "h3"], selection: $proto) { $0 == "auto" ? "Auto" : $0 == "h2" ? "HTTP/2" : "HTTP/3" }
                Toggle("Sequential (download, then upload)", isOn: $sequential).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                Spacer()
                Button(running ? "Measuring…" : "Run test") { run() }.buttonStyle(.borderedProminent).disabled(running)
            }

            HStack(alignment: .top, spacing: 18) {
                SpeedDial(result: current, running: running, started: started)
                    .frame(width: 340, height: 300)
                    .padding(18)
                    .background(PanelBackground())
                VStack(spacing: 12) {
                    let r = current
                    HStack(spacing: 12) {
                        Readout(label: "Download", value: r?.download.map { Fmt.bitrateParts(bytesPerSecond: $0 / 8).0 } ?? "—",
                                unit: r?.download.map { Fmt.bitrateParts(bytesPerSecond: $0 / 8).1 }, accent: Theme.teal,
                                caption: r?.dlFlows.map { "\($0) parallel flows" })
                        Readout(label: "Upload", value: r?.upload.map { Fmt.bitrateParts(bytesPerSecond: $0 / 8).0 } ?? "—",
                                unit: r?.upload.map { Fmt.bitrateParts(bytesPerSecond: $0 / 8).1 }, accent: Theme.amber,
                                caption: r?.ulFlows.map { "\($0) parallel flows" })
                    }
                    HStack(spacing: 12) {
                        Readout(label: "Responsiveness", value: r?.rpm.map { String(format: "%.0f", $0) } ?? "—", unit: "RPM",
                                accent: r?.rpmRating.1 ?? Theme.faint, caption: r.map { "\($0.rpmRating.0) · ≈\(Fmt.ms($0.loadedLatency)) under load" }, info: .rpm)
                        Readout(label: "Idle latency", value: Fmt.msValue(r?.baseRTT), unit: "ms", accent: Theme.latency(r?.baseRTT),
                                caption: "base RTT to the test server", info: .rtt)
                    }
                    if let r, let base = r.baseRTT, let loaded = r.loadedLatency {
                        let bloat = loaded - base
                        HStack { Spacer(); InfoButton(term: .bufferbloat) }
                        Callout(kind: bloat > 100 ? .warning : bloat > 30 ? .tip : .info,
                                title: "Bufferbloat: +\(Fmt.ms(max(0, bloat))) when busy",
                                message: bloat > 100
                                ? "Your router or modem queues far too much data under load. Enabling SQM / smart queue (fq_codel or CAKE) on the router typically fixes this — or use NetLens' Bandwidth caps to keep bulk downloads below your link speed."
                                : bloat > 30 ? "Some queueing under load. Usually fine for browsing; noticeable in calls and games."
                                : "Latency barely rises under load — a well-behaved link.")
                    }
                    if let error { Callout(kind: .warning, title: "Test failed", message: error) }
                }
            }

            if !history.isEmpty {
                Panel("History", icon: "clock.arrow.circlepath") {
                    Button("Clear") { history = []; Self.save(history) }.buttonStyle(.plain).font(.mono(10.5)).foregroundStyle(Theme.muted)
                } content: {
                    VStack(spacing: 0) {
                        ForEach(history.reversed()) { h in
                            HStack(spacing: 14) {
                                Text(Fmt.dateTime.string(from: h.date)).font(.mono(11)).foregroundStyle(Theme.muted).frame(width: 170, alignment: .leading)
                                Text("↓ " + (h.download.map { Fmt.bitrate(bitsPerSecond: $0) } ?? "—")).font(.mono(11.5)).foregroundStyle(Theme.teal).frame(width: 120, alignment: .leading)
                                Text("↑ " + (h.upload.map { Fmt.bitrate(bitsPerSecond: $0) } ?? "—")).font(.mono(11.5)).foregroundStyle(Theme.amber).frame(width: 120, alignment: .leading)
                                Text(h.rpm.map { "\(Int($0)) RPM" } ?? "—").font(.mono(11.5)).foregroundStyle(h.rpmRating.1).frame(width: 100, alignment: .leading)
                                Text("idle \(Fmt.ms(h.baseRTT))").font(.mono(11)).foregroundStyle(Theme.ink2)
                                Spacer()
                                Text(h.interface ?? "").font(.mono(10.5)).foregroundStyle(Theme.faint)
                            }
                            .padding(.vertical, 5)
                            Hairline().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    private func run() {
        running = true
        error = nil
        started = Date()
        var args = ["-c"]
        if sequential { args.append("-s") }
        if proto != "auto" { args += ["-f", proto] }
        if let i = model.physicalInterface?.name { args += ["-I", i] }
        Task {
            let r = await Shell.run("/usr/bin/networkQuality", args, timeout: 120)
            if let parsed = SpeedResult.parse(r.stdout) {
                current = parsed
                history.append(parsed)
                if history.count > 50 { history.removeFirst(history.count - 50) }
                Self.save(history)
            } else {
                error = (r.stderr + r.stdout).trimmed.nilIfEmpty ?? "networkQuality returned no data"
            }
            running = false
        }
    }

    private static func loadHistory() -> [SpeedResult] {
        guard let d = UserDefaults.standard.data(forKey: "speed.history") else { return [] }
        return (try? JSONDecoder().decode([SpeedResult].self, from: d)) ?? []
    }

    private static func save(_ h: [SpeedResult]) {
        var trimmed = h
        for i in trimmed.indices { trimmed[i].raw = "" }
        if let d = try? JSONEncoder().encode(trimmed) { UserDefaults.standard.set(d, forKey: "speed.history") }
    }
}

private struct SpeedDial: View {
    let result: SpeedResult?
    let running: Bool
    let started: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !running)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let mbps = (result?.download ?? 0) / 1_000_000
            // log scale: 1 → 0, 10 → 1/3, 100 → 2/3, 1000 → 1
            let frac = running ? (0.5 + 0.45 * sin(t * 2.3)) * 0.85 : (mbps > 0 ? min(1, log10(max(1, mbps)) / 3) : 0)
            ZStack {
                DialArc(from: 0, to: 1).stroke(Theme.fill, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                DialArc(from: 0, to: frac)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                ForEach([1.0, 10, 100, 1000], id: \.self) { v in
                    let f = log10(v) / 3
                    let a = Angle.degrees(135 + 270 * f)
                    Text(v >= 1000 ? "1G" : "\(Int(v))")
                        .font(.mono(9.5))
                        .foregroundStyle(Theme.faint)
                        .offset(x: cos(a.radians) * 100, y: sin(a.radians) * 100)
                }
                VStack(spacing: 2) {
                    if running {
                        Text("\(Int(Date().timeIntervalSince(started ?? Date())))s").font(.mono(36, .medium)).foregroundStyle(Theme.amber)
                        Text("saturating the link…").font(.mono(10)).foregroundStyle(Theme.muted)
                    } else if let d = result?.download {
                        Text(String(format: d >= 100_000_000 ? "%.0f" : "%.1f", d / 1_000_000)).font(.mono(44, .medium)).foregroundStyle(Theme.teal)
                        Text("Mbps down").font(.mono(10.5)).foregroundStyle(Theme.muted)
                    } else {
                        Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.faint)
                        Text("ready").font(.mono(10.5)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .frame(width: 260, height: 260)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DialArc: Shape {
    var from: Double
    var to: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2 - 10,
                 startAngle: .degrees(135 + 270 * from), endAngle: .degrees(135 + 270 * to), clockwise: false)
        return p
    }
}
