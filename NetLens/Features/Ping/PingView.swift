import SwiftUI
import Charts

struct PingView: View {
    @Environment(AppModel.self) private var model
    @State private var newHost = ""
    @State private var window = 120
    @State private var hidden: Set<UUID> = []

    private let palette: [Color] = [.blue, .purple, .orange, .pink, .teal, .green, .indigo, .brown]

    var body: some View {
        let pings = model.pings
        Page(spacing: 18) {
            PageHeader(eyebrow: "Diagnose · ping", title: "Latency monitor",
                       subtitle: "Continuous ICMP echo to several targets at once. Watch jitter and loss build up — the things that make calls stutter and games rubber-band.") {
                HStack(spacing: 8) {
                    Text("Interval").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Segmented(options: [0.2, 0.5, 1.0, 2.0], selection: Binding(get: { pings.interval }, set: { pings.interval = $0 })) {
                        $0 < 1 ? "\(Int($0 * 1000))ms" : "\(Int($0))s"
                    }
                }
            }

            HStack(spacing: 10) {
                InstrumentField(placeholder: "Add a host or IP to ping (e.g. github.com, 192.168.1.10)", text: $newHost, icon: "plus") { add() }
                Button("Add target") { add() }.buttonStyle(.borderedProminent)
                Segmented(options: [60, 120, 300], selection: $window) { "\($0) probes" }
            }

            Panel("Round-trip time", icon: "waveform.path.ecg", info: .rtt) {
                HStack(spacing: 12) {
                    ForEach(Array(pings.targets.enumerated()), id: \.element.id) { i, t in
                        Button {
                            if hidden.contains(t.id) { hidden.remove(t.id) } else { hidden.insert(t.id) }
                        } label: {
                            HStack(spacing: 5) {
                                Circle().fill(color(i)).frame(width: 7, height: 7).opacity(hidden.contains(t.id) ? 0.25 : 1)
                                Text(t.label).font(.mono(10.5)).foregroundStyle(hidden.contains(t.id) ? Theme.faint : Theme.ink2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } content: {
                ScreenFrame(label: "Round-trip time (ms)", live: pings.running) {
                    chart
                        .padding(.top, 28)
                        .padding([.horizontal, .bottom], 12)
                        .frame(height: 280)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                ForEach(Array(pings.targets.enumerated()), id: \.element.id) { i, t in
                    PingTargetCard(target: t, color: color(i), window: window)
                }
            }
        }
        .onAppear {
            if let t = model.takeTarget(.ping) { pings.add(host: t) }
        }
    }

    private func color(_ i: Int) -> Color { palette[i % palette.count] }

    private func add() {
        model.pings.add(host: newHost)
        newHost = ""
    }

    private struct Point: Identifiable {
        let id: String
        let series: String
        let colorIndex: Int
        let time: Date
        let rtt: Double?
    }

    private var points: [Point] {
        var out: [Point] = []
        for (i, t) in model.pings.targets.enumerated() where !hidden.contains(t.id) {
            for s in t.samples.suffix(window) {
                out.append(Point(id: "\(i)-\(s.id)", series: t.label, colorIndex: i, time: s.time, rtt: s.rtt))
            }
        }
        return out
    }

    private var chart: some View {
        let pts = points
        let names = model.pings.targets.map(\.label)
        return Chart(pts) { p in
            if let r = p.rtt {
                LineMark(x: .value("Time", p.time), y: .value("RTT", r), series: .value("Target", p.series))
                    .foregroundStyle(by: .value("Target", p.series))
                    .lineStyle(StrokeStyle(lineWidth: 1.25))
            } else {
                PointMark(x: .value("Time", p.time), y: .value("RTT", 0))
                    .foregroundStyle(Theme.coral)
                    .symbolSize(14)
                    .symbol(.cross)
            }
        }
        .chartForegroundStyleScale(domain: names, range: names.indices.map { color($0) })
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Theme.line)
                AxisValueLabel().font(.mono(9.5)).foregroundStyle(Theme.muted)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Theme.line)
                AxisValueLabel(format: .dateTime.hour().minute().second()).font(.mono(9.5)).foregroundStyle(Theme.muted)
            }
        }
        .chartLegend(.hidden)
    }
}

private struct PingTargetCard: View {
    let target: PingTarget
    let color: Color
    let window: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = target.stats(window: window)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(target.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                        if target.viaTTLExpiry {
                            TermTag(text: "TTL probe", term: .ttlProbe)
                        }
                    }
                    Text(target.resolved ?? target.host).font(.mono(10.5)).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
                Spacer()
                Button { target.paused.toggle() } label: { Image(systemName: target.paused ? "play.fill" : "pause.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted)
                if !target.pinned {
                    Button { model.pings.remove(target) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.msValue(s.last)).font(.mono(30, .medium)).foregroundStyle(Theme.latency(s.last))
                    .contentTransition(.numericText())
                Text("ms").font(.mono(12)).foregroundStyle(Theme.muted)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 3) {
                        Text("MOS \(s.mos.map { String(format: "%.2f", $0) } ?? "—")").font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.ink2)
                        InfoButton(term: .mos, size: 10)
                    }
                    Text(s.mosLabel + " for voice").font(.mono(9.5)).foregroundStyle(Theme.faint)
                }
            }
            Sparkline(values: target.samples.suffix(window).map(\.rtt), color: color, markGaps: true, capacity: window)
                .frame(height: 40)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    stat("min", Fmt.ms(s.min)); stat("avg", Fmt.ms(s.avg)); stat("max", Fmt.ms(s.max))
                }
                GridRow {
                    stat("jitter", Fmt.ms(s.jitter), term: .jitter); stat("std dev", Fmt.ms(s.stdev))
                    stat("loss", Fmt.percent(s.loss), Theme.loss(s.loss), term: .packetLoss)
                }
            }
            if let (hops, os) = target.inferredHops {
                HStack(spacing: 3) {
                    Text("Reply TTL \(target.lastReplyTTL ?? 0) → about \(hops) hop\(hops == 1 ? "" : "s") away, likely \(os)")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    InfoButton(term: .replyTTL, size: 10)
                }
            }
            if let e = target.lastError, s.last == nil {
                Text(e).font(.mono(10)).foregroundStyle(Theme.coral)
            }
        }
        .padding(16)
        .background(PanelBackground())
    }

    private func stat(_ k: String, _ v: String, _ c: Color = Theme.ink, term: Glossary? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            TermLabel(text: k.capitalized, term: term, font: .system(size: 10.5), color: Theme.tertiary)
            Text(v).font(.mono(12)).foregroundStyle(c)
        }
    }
}
