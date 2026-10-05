import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("menubar.showRates") private var showRates = true

    var body: some View {
        let cur = model.throughput.current[model.net.primaryInterface ?? ""]
        if showRates, let cur {
            Text("\(Image(systemName: "network")) \(compact(cur.inBps))↓ \(compact(cur.outBps))↑")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
        } else {
            Image(systemName: model.isOnline ? "network" : "network.slash")
        }
    }

    /// 3-4 character rate for the menu bar, bytes per second.
    private func compact(_ v: Double) -> String {
        switch v {
        case ..<1000: return String(format: "%.0fB", v)
        case ..<1_000_000: return String(format: v < 10_000 ? "%.1fK" : "%.0fK", v / 1000)
        case ..<1_000_000_000: return String(format: v < 10_000_000 ? "%.1fM" : "%.0fM", v / 1_000_000)
        default: return String(format: "%.1fG", v / 1_000_000_000)
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let iface = model.net.primaryInterface ?? ""
        let series = model.throughput.series(iface)
        let gw = model.pings.gateway.stats(window: 30)
        let inet = model.pings.internet.stats(window: 30)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatusDot(color: model.isOnline ? Theme.good : Theme.coral, pulsing: true, size: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("NetLens").font(.display(15, .bold)).foregroundStyle(Theme.ink)
                    Text(statusLine).font(.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                if let rssi = model.wifi.rssi { SignalBars(rssi: rssi, height: 12) }
            }

            HStack(spacing: 8) {
                mini("↓", Fmt.bitrate(bytesPerSecond: series.last?.inBps ?? 0), Theme.teal)
                mini("↑", Fmt.bitrate(bytesPerSecond: series.last?.outBps ?? 0), Theme.amber)
            }
            ScreenFrame {
                DualTrace(down: series.map(\.inBps), up: series.map(\.outBps), capacity: model.throughput.capacity)
                    .padding(.vertical, 4)
                    .frame(height: 54)
            }

            HStack(spacing: 8) {
                mini("router", Fmt.ms(gw.last ?? gw.avg), Theme.latency(gw.avg))
                mini("internet", Fmt.ms(inet.last ?? inet.avg), Theme.latency(inet.avg))
                mini("loss", Fmt.percent(inet.loss, digits: 0), Theme.loss(inet.loss))
            }
            Sparkline(values: model.pings.internet.samples.suffix(60).map(\.rtt), color: Theme.accent, lineWidth: 1.2, markGaps: true, capacity: 60)
                .frame(height: 26)

            VStack(spacing: 4) {
                ipRow("Public", model.publicV4)
                ipRow("Local", model.primaryIPv4)
                ipRow("Gateway", model.net.router)
            }

            let top = Array(model.connections.processes.filter { $0.rateIn + $0.rateOut > 0 }.prefix(4))
            if !top.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Top talkers").eyebrowStyle(Theme.muted)
                    ForEach(top) { p in
                        let ident = ProcessCatalog.shared.identity(pid: p.pid, fallbackName: p.name)
                        HStack(spacing: 6) {
                            ProcessIcon(image: ident.icon, size: 14)
                            Text(ident.name).font(.system(size: 11.5)).foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer()
                            Text(Fmt.bitrate(bytesPerSecond: p.rateIn + p.rateOut)).font(.mono(10.5)).foregroundStyle(Theme.ink2)
                        }
                    }
                }
            }

            if model.shaper.activeLimitCount > 0 {
                @Bindable var shaper = model.shaper
                Toggle("Bandwidth caps paused", isOn: $shaper.paused).toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 11.5))
            }

            HStack {
                Button("Open NetLens") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(width: 330)
        .background(InkBackground())
    }

    private var statusLine: String {
        guard let iface = model.net.primaryInterface else { return "Offline" }
        if let ssid = model.wifi.ssid { return "\(ssid) · \(iface)" }
        return "\(model.primaryInterface?.displayName ?? iface) · \(iface)"
    }

    private func mini(_ label: String, _ value: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.mono(8.5, .medium)).foregroundStyle(Theme.faint)
            Text(value).font(.mono(13, .medium)).foregroundStyle(c).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.trough))
    }

    private func ipRow(_ k: String, _ v: String?) -> some View {
        HStack {
            Text(k).font(.system(size: 11)).foregroundStyle(Theme.muted)
            Spacer()
            Text(v ?? "—").font(.mono(11)).foregroundStyle(Theme.ink)
            if let v {
                Button { copyToPasteboard(v) } label: { Image(systemName: "doc.on.doc").font(.system(size: 9.5)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.faint).help("Copy")
            }
        }
    }
}
