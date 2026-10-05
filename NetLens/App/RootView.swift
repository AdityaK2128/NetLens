import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar(selection: $model.selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 300)
        } detail: {
            DetailView(section: model.selection ?? .overview)
                .id(model.selection)
        }
        .background(Theme.bg)
    }
}

struct DetailView: View {
    let section: NavSection

    var body: some View {
        Group {
            switch section {
            case .overview: OverviewView()
            case .globe: GlobeScreen()
            case .connections: ConnectionsView()
            case .bandwidth: BandwidthView()
            case .ports: PortsView()
            case .ping: PingView()
            case .traceroute: TracerouteView()
            case .dns: DNSView()
            case .http: HTTPInspectorView()
            case .speed: SpeedTestView()
            case .interfaces: InterfacesView()
            case .wifi: WiFiView()
            case .routing: RoutingView()
            case .neighbors: NeighborsView()
            case .capture: CaptureView()
            case .nmap: NmapView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(InkBackground())
        .navigationTitle(section.title)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Binding var selection: NavSection?
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: $selection) {
            ForEach(NavSection.groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { s in
                        SidebarRow(section: s)
                            .tag(s)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarStatus()
                .padding(10)
        }
    }
}

private struct SidebarRow: View {
    let section: NavSection
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Label(section.title, systemImage: section.symbol)
            Spacer(minLength: 4)
            badge
        }
    }

    @ViewBuilder private var badge: some View {
        switch section {
        case .overview:
            if let rtt = model.pings.internet.samples.last?.rtt {
                badgeText(Fmt.msValue(rtt) + " ms", Theme.secondary)
            }
        case .globe:
            let n = model.connections.endpoints.values.filter(\.active).count
            if n > 0 { badgeText("\(n)", Theme.ink2) }
        case .connections:
            let n = model.connections.activeSockets.count
            if n > 0 { badgeText("\(n)", Theme.ink2) }
        case .bandwidth:
            let n = model.shaper.activeLimitCount
            if n > 0 { badgeText("\(n) capped", Theme.secondary) }
        case .ports:
            let n = model.connections.listeners.filter(\.isTCP).count
            if n > 0 { badgeText("\(n)", Theme.ink2) }
        case .ping:
            if let rtt = model.pings.gateway.samples.last?.rtt {
                badgeText(Fmt.msValue(rtt) + " ms", Theme.secondary)
            }
        case .wifi:
            if let rssi = model.wifi.rssi { badgeText("\(rssi) dBm", Theme.secondary) }
        case .nmap:
            if model.nmap.isRunning { ProgressView().controlSize(.mini) }
        default:
            EmptyView()
        }
    }

    private func badgeText(_ s: String, _ c: Color) -> some View {
        Text(s)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(c)
    }
}

private struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cur = model.throughput.current[model.net.primaryInterface ?? ""]
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                StatusDot(color: model.isOnline ? Theme.good : Theme.bad, size: 6)
                Text(statusLine)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            Text("↓ \(Fmt.bitrate(bytesPerSecond: cur?.inBps ?? 0))   ↑ \(Fmt.bitrate(bytesPerSecond: cur?.outBps ?? 0))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.secondary)
            if let ip = model.publicV4 {
                Text(ip)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLine: String {
        guard let iface = model.net.primaryInterface else { return "Offline" }
        if let ssid = model.wifi.ssid, model.physicalInterface?.kind == .wifi { return ssid }
        if model.viaTunnel { return "VPN · \(iface)" }
        return model.primaryInterface?.displayName ?? iface
    }
}

struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 8, weight: .bold))
            configuration.title
        }
    }
}
