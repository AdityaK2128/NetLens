import SwiftUI

/// What's listening, and who can reach it.
struct PortsView: View {
    @Environment(AppModel.self) private var model
    @State private var includeUDP = false
    @State private var sortOrder = [KeyPathComparator(\ListenerRow.port)]

    var body: some View {
        let rows = listeners
        let exposed = rows.filter { $0.exposure == .network }
        Page(spacing: 18) {
            PageHeader(eyebrow: "Live · lsof -i", title: "Listening ports",
                       subtitle: "Servers on this Mac waiting for connections. Anything bound to all interfaces is reachable by other devices on your network — unless the firewall says otherwise.")

            HStack(spacing: 12) {
                Readout(label: "TCP listeners", value: "\(rows.filter { $0.proto.hasPrefix("tcp") }.count)", accent: Theme.ink)
                Readout(label: "Exposed to network", value: "\(exposed.count)", accent: exposed.isEmpty ? Theme.teal : Theme.amber,
                        caption: "bound to * or a LAN address", info: .listeningExposure)
                Readout(label: "Local only", value: "\(rows.filter { $0.exposure == .loopback }.count)", accent: Theme.teal, caption: "127.0.0.1 / ::1")
                Readout(label: "Apps serving", value: "\(Set(rows.map(\.app)).count)", accent: Theme.ink)
            }

            if !exposed.isEmpty {
                Callout(kind: .tip, title: "\(exposed.count) port\(exposed.count == 1 ? " is" : "s are") reachable from your network",
                        message: "Most are macOS services (AirPlay receiver on 5000/7000, Rapport/Continuity, Screen Sharing). Development servers bound to 0.0.0.0 are the usual surprise — bind them to 127.0.0.1 if they shouldn't be visible to others on this Wi-Fi.")
            }

            Panel("Listeners", icon: "door.left.hand.open", info: .listeningExposure) {
                Toggle("Include UDP", isOn: $includeUDP).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            } content: {
                Table(rows.sorted(using: sortOrder), sortOrder: $sortOrder) {
                    TableColumn("Port", value: \.port) { r in
                        Text(verbatim: String(r.port)).font(.mono(12, .medium)).foregroundStyle(Theme.amber)
                    }
                    .width(min: 36, ideal: 60)
                    TableColumn("Service", value: \.service) { r in
                        Text(r.service.isEmpty ? "—" : r.service).font(.system(size: 12)).foregroundStyle(r.service.isEmpty ? Theme.faint : Theme.ink)
                    }
                    .width(min: 120, ideal: 160)
                    TableColumn("App", value: \.app) { r in
                        HStack(spacing: 6) {
                            ProcessIcon(image: r.icon, size: 16)
                            Text(r.app).font(.system(size: 12)).foregroundStyle(Theme.ink)
                        }
                    }
                    .width(min: 140, ideal: 200)
                    TableColumn("Proto", value: \.proto) { r in
                        Text(r.proto.uppercased()).font(.mono(11)).foregroundStyle(Theme.secondary)
                    }
                    .width(min: 36, ideal: 52)
                    TableColumn("Bound to", value: \.bind) { r in
                        Text(r.bind).font(.mono(11)).foregroundStyle(Theme.ink2)
                    }
                    .width(min: 110, ideal: 150)
                    TableColumn("Reachable from", value: \.exposure.rawValue) { r in
                        Chip(text: r.exposure.rawValue, color: r.exposure == .network ? Theme.amber : r.exposure == .loopback ? Theme.teal : Theme.violet)
                    }
                    .width(min: 36, ideal: 130)
                    TableColumn("PID", value: \.pid) { r in
                        Text(verbatim: String(r.pid)).font(.mono(11)).foregroundStyle(Theme.muted)
                    }
                    .width(min: 36, ideal: 56)
                }
                .scrollContentBackground(.hidden)
                .frame(height: CGFloat(min(max(rows.count, 6), 28)) * 26 + 34)
            }
        }
    }

    private var listeners: [ListenerRow] {
        var seen = Set<String>()
        var out: [ListenerRow] = []
        for s in model.connections.listeners {
            guard s.isTCP || includeUDP, let port = s.localPort else { continue }
            let ident = ProcessCatalog.shared.identity(pid: s.pid, fallbackName: s.processName)
            let bind = s.localAddress ?? "*"
            let key = "\(s.pid)|\(s.proto.prefix(3))|\(bind)|\(port)"
            guard seen.insert(key).inserted else { continue }
            let exposure: ListenerRow.Exposure
            if let a = s.localAddress {
                switch IP.scope(a) {
                case .loopback: exposure = .loopback
                case .linkLocal: exposure = .link
                default: exposure = .network
                }
            } else {
                exposure = .network
            }
            out.append(ListenerRow(id: key, port: Int(port), service: Services.name(port, tcp: s.isTCP) ?? "",
                                   app: ident.name, icon: ident.icon, proto: s.proto, bind: s.isV6 ? (s.localAddress.map { "[\($0)]" } ?? "[::]") : bind,
                                   exposure: exposure, pid: Int(s.pid)))
        }
        return out
    }
}

struct ListenerRow: Identifiable {
    enum Exposure: String { case network = "Network", loopback = "This Mac only", link = "Link-local" }
    let id: String
    let port: Int
    let service: String
    let app: String
    let icon: NSImage?
    let proto: String
    let bind: String
    let exposure: Exposure
    let pid: Int
}
