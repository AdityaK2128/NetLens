import SwiftUI

struct BandwidthView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var activeOnly = true

    private var shaper: BandwidthShaper { model.shaper }

    var body: some View {
        Page(spacing: 18) {
            PageHeader(eyebrow: "Traffic shaping", title: "Bandwidth control",
                       subtitle: "Cap how fast each app may download and upload. A big Chrome download can crawl along in the background while your calls, games and SSH sessions stay snappy.")

            HelperCard()

            // Wire rate of the primary interface (app counters double-count proxied flows).
            let wire = model.throughput.current[model.net.primaryInterface ?? ""]
            let total = (wire?.inBps ?? 0, wire?.outBps ?? 0)
            HStack(spacing: 12) {
                Readout(label: "Downloading now", value: Fmt.bytesParts(total.0).0, unit: Fmt.bytesParts(total.0).1 + "/s", accent: Theme.ink)
                Readout(label: "Uploading now", value: Fmt.bytesParts(total.1).0, unit: Fmt.bytesParts(total.1).1 + "/s", accent: Theme.ink)
                Readout(label: "Capped apps", value: "\(shaper.activeLimitCount)", accent: shaper.activeLimitCount > 0 ? Theme.amber : Theme.ink,
                        caption: shaper.paused ? "paused" : nil)
                Readout(label: "Apps on network", value: "\(shaper.apps.filter { $0.sockets > 0 }.count)", accent: Theme.ink)
            }

            Panel("Applications", icon: "square.stack.3d.up") {
                HStack(spacing: 10) {
                    Toggle("Active only", isOn: $activeOnly).toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: 11))
                    InstrumentField(placeholder: "Filter apps", text: $search).frame(width: 200)
                }
            } content: {
                VStack(spacing: 0) {
                    header
                    Hairline()
                    let rows = filtered
                    if rows.isEmpty {
                        EmptyState(icon: "app.dashed", title: "No apps match", message: activeOnly ? "Turn off “Active only” to see every process with a socket." : nil)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { app in
                            AppBandwidthRow(app: app)
                            Hairline().opacity(0.6)
                        }
                    }
                }
            }

            Callout(kind: .info, title: "How the limits work",
                    message: "NetLens watches which local ports each app owns (refreshed every 2 s) and hands them to its helper, which steers those packets through a kernel dummynet pipe sized to your cap — the same machinery behind Apple's Network Link Conditioner. Downloads are paced by delaying inbound packets so TCP/QUIC slows its sender; uploads are queued on the way out. Traffic inside a VPN tunnel is shaped before encryption. A new connection is caught within one refresh. If NetLens quits, the helper removes every limit within 30 seconds.")
        }
    }

    private var filtered: [AppTraffic] {
        shaper.apps.filter { a in
            let limited = shaper.limits[a.id]?.isActive == true
            if activeOnly && !limited && a.established == 0 && a.rateIn + a.rateOut < 1 { return false }
            if !search.isEmpty && !a.name.localizedCaseInsensitiveContains(search) { return false }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("App").frame(maxWidth: .infinity, alignment: .leading)
            Text("Live ↓ / ↑").frame(width: 170, alignment: .trailing)
            Text("Last 2 min").frame(width: 120, alignment: .center)
            Text("Download cap").frame(width: 130, alignment: .leading)
            Text("Upload cap").frame(width: 130, alignment: .leading)
        }
        .font(.mono(9.5, .medium))
        .foregroundStyle(Theme.faint)
        .padding(.vertical, 8)
    }
}

private struct HelperCard: View {
    @Environment(AppModel.self) private var model
    private var shaper: BandwidthShaper { model.shaper }

    var body: some View {
        @Bindable var shaper = model.shaper
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(Theme.trough)
                Circle().strokeBorder(color.opacity(0.8), lineWidth: 1.5)
                Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(color)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            switch shaper.helper {
            case .notInstalled, .unknown:
                Button(shaper.busy ? "Installing…" : "Install helper…") { Task { await shaper.install() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(shaper.busy)
            case .running:
                Toggle("Pause all limits", isOn: $shaper.paused).toggleStyle(.switch).controlSize(.small)
                    .font(.system(size: 12))
                Menu {
                    Button("Remove all limits") { shaper.removeAll() }
                    Divider()
                    Button("Uninstall helper…", role: .destructive) { Task { await shaper.uninstall() } }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 15))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            case .error:
                Button("Retry") { Task { await shaper.refreshHelperState() } }.buttonStyle(.bordered)
                Button("Reinstall…") { Task { await shaper.install() } }.buttonStyle(.borderedProminent).disabled(shaper.busy)
            }
        }
        .padding(16)
        .background(PanelBackground())
    }

    private var color: Color {
        switch shaper.helper {
        case .running: shaper.paused ? Theme.warn : Theme.good
        case .error: Theme.coral
        default: Theme.secondary
        }
    }
    private var icon: String {
        switch shaper.helper {
        case .running: "checkmark.shield"
        case .error: "exclamationmark.shield"
        default: "lock.shield"
        }
    }
    private var title: String {
        switch shaper.helper {
        case .running(let n): shaper.paused ? "Shaper paused — limits lifted" : n > 0 ? "Shaper active · \(n) app\(n == 1 ? "" : "s") capped right now" : "Shaper ready"
        case .error(let e): "Shaper problem: \(e)"
        case .notInstalled: "Enable the traffic shaper"
        case .unknown: "Checking shaper…"
        }
    }
    private var message: String {
        switch shaper.helper {
        case .running: "Kernel dummynet pipes are in place for every capped app with open sockets. Caps you set are remembered."
        case .error: "The privileged helper isn't answering. Reinstalling usually fixes it."
        default: "Shaping happens in the kernel, so it needs a small privileged helper, installed once with your admin password. It accepts only port numbers and rates from NetLens, and removes every limit if NetLens quits."
        }
    }
}

private struct AppBandwidthRow: View {
    let app: AppTraffic
    @Environment(AppModel.self) private var model

    var body: some View {
        let shaper = model.shaper
        let limit = shaper.limits[app.id] ?? BandwidthLimit()
        let ident = app.pids.first.map { ProcessCatalog.shared.identity(pid: $0, fallbackName: app.name) }
        let hist = shaper.history[app.id] ?? []
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                ProcessIcon(image: ident?.icon ?? (app.id.hasSuffix(".app") ? NSWorkspace.shared.icon(forFile: app.id) : nil), size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                        if limit.isActive {
                            Chip(text: "Capped", color: Theme.amber, filled: true)
                        }
                    }
                    Text(app.pids.isEmpty ? "not running" : "\(app.pids.count) process\(app.pids.count == 1 ? "" : "es") · \(app.sockets) sockets · \(app.shapedPorts.count) ports")
                        .font(.mono(10))
                        .foregroundStyle(Theme.muted)
                    if let relay = app.relayName, !app.relayedPorts.isEmpty {
                        HStack(spacing: 3) {
                            Text("Routed through \(relay)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            InfoButton(term: .transparentProxy, size: 10)
                        }
                    } else if app.isRelay {
                        HStack(spacing: 3) {
                            Text("Carries other apps' traffic").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            InfoButton(term: .transparentProxy, size: 10)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                rate("↓", app.rateIn, Theme.down, cap: limit.downKBps)
                rate("↑", app.rateOut, Theme.up, cap: limit.upKBps)
            }
            .frame(width: 170, alignment: .trailing)

            DualTrace(down: hist.map(\.inBps), up: hist.map(\.outBps), capacity: 60)
                .frame(width: 120, height: 30)

            LimitMenu(kbps: limit.downKBps, color: Theme.accent) { shaper.setLimit(app, down: $0) }
                .frame(width: 130, alignment: .leading)
            LimitMenu(kbps: limit.upKBps, color: Theme.accent) { shaper.setLimit(app, up: $0) }
                .frame(width: 130, alignment: .leading)
        }
        .padding(.vertical, 9)
    }

    private func rate(_ arrow: String, _ v: Double, _ c: Color, cap: Int) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("\(arrow) \(Fmt.bytes(v))/s").font(.mono(11.5, .medium)).foregroundStyle(v > 0 ? c : Theme.faint)
            if cap > 0 {
                Meter(value: v / Double(cap * 1024), color: v > Double(cap * 1024) * 0.9 ? Theme.coral : c, height: 3)
                    .frame(width: 90)
            }
        }
    }
}

/// Download/upload cap picker with presets and a custom value.
private struct LimitMenu: View {
    let kbps: Int
    let color: Color
    let onChange: (Int) -> Void
    @State private var customOpen = false
    @State private var customValue = ""
    @State private var customMB = true

    static let presets = [64, 128, 256, 512, 1024, 2048, 5120, 10240, 25600]

    static func label(_ k: Int) -> String {
        if k == 0 { return "Unlimited" }
        if k >= 1024 { return k % 1024 == 0 ? "\(k / 1024) MB/s" : String(format: "%.1f MB/s", Double(k) / 1024) }
        return "\(k) KB/s"
    }

    var body: some View {
        Menu {
            Button("Unlimited") { onChange(0) }
            Divider()
            ForEach(Self.presets, id: \.self) { p in
                Button(Self.label(p)) { onChange(p) }
            }
            Divider()
            Button("Custom…") { customValue = ""; customOpen = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: kbps > 0 ? "gauge.with.dots.needle.33percent" : "infinity")
                    .font(.system(size: 10, weight: .semibold))
                Text(Self.label(kbps)).font(.mono(11, .medium))
            }
            .foregroundStyle(kbps > 0 ? color : Theme.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(kbps > 0 ? color.opacity(0.1) : Theme.trough)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(kbps > 0 ? color.opacity(0.5) : Theme.line))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .popover(isPresented: $customOpen) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Custom cap").font(.system(size: 13, weight: .semibold))
                HStack {
                    TextField("e.g. 3", text: $customValue).frame(width: 80).textFieldStyle(.roundedBorder)
                    Picker("", selection: $customMB) {
                        Text("MB/s").tag(true)
                        Text("KB/s").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                HStack {
                    Spacer()
                    Button("Set") {
                        if let v = Double(customValue.replacingOccurrences(of: ",", with: ".")), v > 0 {
                            onChange(max(1, Int(customMB ? v * 1024 : v)))
                        }
                        customOpen = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }
}
