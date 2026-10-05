import SwiftUI

struct RoutingView: View {
    @Environment(AppModel.self) private var model
    @State private var routes: [RouteEntry] = []
    @State private var family = "IPv4"
    @State private var lookupTarget = "1.1.1.1"
    @State private var lookup: Routes.Lookup?
    @State private var search = ""

    var body: some View {
        let shown = routes.filter { ($0.isV6 ? "IPv6" : "IPv4") == family }
            .filter { search.isEmpty || "\($0.destination) \($0.gateway) \($0.interface)".localizedCaseInsensitiveContains(search) }
        Page(spacing: 18) {
            PageHeader(eyebrow: "Local · netstat -rn", title: "Routing table",
                       subtitle: "How the kernel decides where every packet goes. The most specific matching route wins; VPNs work by inserting routes that beat your default.") {
                Button { Task { routes = await Routes.read() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered)
            }

            Panel("Where would a packet go?", icon: "signpost.right.and.left", info: .routeLookup) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        InstrumentField(placeholder: "Destination host or IP", text: $lookupTarget, icon: "arrow.triangle.turn.up.right.diamond") { runLookup() }
                        Button("Look up route") { runLookup() }.buttonStyle(.borderedProminent)
                    }
                    if let l = lookup {
                        if l.interface == nil {
                            Text(l.raw.trimmed).font(.mono(11)).foregroundStyle(Theme.coral)
                        } else {
                            HStack(alignment: .center, spacing: 12) {
                                hop("This Mac", model.primaryIPv4 ?? "", Theme.amber)
                                arrow
                                hop("Interface", l.interface ?? "—", (l.interface ?? "").hasPrefix("utun") ? Theme.violet : Theme.teal)
                                arrow
                                hop("Next hop", l.gateway ?? "on-link (direct)", Theme.teal)
                                arrow
                                hop("Destination", l.destination ?? lookupTarget, Theme.coral)
                            }
                            HStack(spacing: 8) {
                                if let f = l.flags { Chip(text: f, color: Theme.muted) }
                                if let m = l.mtu, m != "0" { Chip(text: "MTU \(m)") }
                                if let r = l.rtt, r != "0" { Chip(text: "cached RTT \(r) ms", color: Theme.teal).help("The kernel's route metrics cache smoothed RTT learned from previous TCP connections to this destination.") }
                                if let v = l.rttvar, v != "0" { Chip(text: "rttvar \(v)") }
                            }
                            if (l.interface ?? "").hasPrefix("utun") {
                                Text("This destination goes through a VPN tunnel (\(l.interface!)) — a more specific route installed by the VPN wins over your default route.")
                                    .font(.system(size: 11.5)).foregroundStyle(Theme.violet)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Segmented(options: ["IPv4", "IPv6"], selection: $family) { $0 }
                InstrumentField(placeholder: "Filter routes", text: $search)
                Text("\(shown.count) routes").font(.mono(10.5)).foregroundStyle(Theme.muted)
            }

            Panel {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Destination").frame(width: 230, alignment: .leading)
                        Text("Gateway").frame(width: 230, alignment: .leading)
                        Text("Flags").frame(width: 90, alignment: .leading)
                        Text("Interface").frame(width: 60, alignment: .leading)
                        Text("Kind").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.mono(9.5, .medium)).foregroundStyle(Theme.faint).padding(.bottom, 8)
                    ForEach(shown) { r in
                        HStack(spacing: 12) {
                            Text(r.destination).font(.mono(11.5, r.isDefault ? .semibold : .regular))
                                .foregroundStyle(r.isDefault ? Theme.amber : Theme.ink).frame(width: 230, alignment: .leading).lineLimit(1)
                                .textSelection(.enabled)
                            Text(r.gateway).font(.mono(11.5)).foregroundStyle(Theme.ink2).frame(width: 230, alignment: .leading).lineLimit(1)
                            Text(r.flags).font(.mono(11)).foregroundStyle(Theme.muted).frame(width: 90, alignment: .leading)
                                .help(Routes.explain(r.flags))
                            Text(r.interface).font(.mono(11)).foregroundStyle(r.isTunnel ? Theme.violet : Theme.teal).frame(width: 60, alignment: .leading)
                            Text(r.kind).font(.system(size: 11)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                        .background(r.isDefault ? Theme.amber.opacity(0.05) : .clear)
                        Hairline().opacity(0.4)
                    }
                }
            }

            Panel("Flag legend", icon: "flag") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(Routes.flagMeanings.prefix(15), id: \.0) { f, m in
                        HStack(spacing: 8) {
                            Text(String(f)).font(.mono(12, .semibold)).foregroundStyle(Theme.amber).frame(width: 16)
                            Text(m).font(.system(size: 11.5)).foregroundStyle(Theme.ink2)
                        }
                    }
                }
            }
        }
        .task { routes = await Routes.read(); runLookup() }
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.faint)
    }

    private func hop(_ label: String, _ value: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.mono(9, .medium)).foregroundStyle(Theme.faint)
            Text(value).font(.mono(12.5, .medium)).foregroundStyle(c).lineLimit(1)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.trough))
    }

    private func runLookup() {
        let t = lookupTarget
        Task { lookup = await Routes.lookup(t) }
    }
}
