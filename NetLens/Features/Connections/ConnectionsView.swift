import SwiftUI

struct ConnectionsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var proto: ProtoFilter = .all
    @State private var establishedOnly = false
    @State private var selection: SocketRecord.ID?
    @State private var sortOrder = [KeyPathComparator(\SocketRecord.totalRate, order: .reverse)]
    @State private var showInspector = false

    enum ProtoFilter: String, CaseIterable { case all = "All", tcp = "TCP", udp = "UDP", v6 = "IPv6" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(eyebrow: "Live · netstat / ss", title: "Connections",
                       subtitle: "Every socket on this Mac with the kernel's own per-flow TCP statistics — RTT, retransmits, windows, congestion control.") {
                HStack(spacing: 8) {
                    Chip(text: "\(model.connections.established) established", color: Theme.teal)
                    Chip(text: "\(rows.count) shown", color: Theme.ink2)
                    if let t = model.connections.lastUpdate {
                        Text("updated \(Fmt.clock.string(from: t))").font(.mono(10)).foregroundStyle(Theme.faint)
                    }
                }
            }
            HStack(spacing: 10) {
                InstrumentField(placeholder: "Filter by app, address, host, port, country…", text: $search)
                Segmented(options: ProtoFilter.allCases, selection: $proto) { $0.rawValue }
                Toggle("Established only", isOn: $establishedOnly)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.bordered)
            }

            HStack(alignment: .top, spacing: 14) {
                table
                    .frame(minHeight: 240, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
                if showInspector, let id = selection, let s = model.connections.sockets.first(where: { $0.id == id }) {
                    SocketInspector(socket: s)
                        .frame(width: 320)
                        .frame(maxHeight: .infinity)
                        .background(PanelBackground())
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .onChange(of: selection) { _, id in showInspector = id != nil }
    }

    private var rows: [SocketRecord] {
        let q = search.lowercased()
        return model.connections.activeSockets.filter { s in
            switch proto {
            case .all: break
            case .tcp: if !s.isTCP { return false }
            case .udp: if s.isTCP { return false }
            case .v6: if !s.isV6 { return false }
            }
            if establishedOnly && s.state != "Established" { return false }
            if s.isTCP && s.state == "Closed" && s.totalBytes == 0 { return false }
            guard !q.isEmpty else { return true }
            let ident = ProcessCatalog.shared.identity(pid: s.pid, fallbackName: s.processName)
            let g = model.names.geo[s.remoteAddress ?? ""]
            let hay = [ident.name, s.processName, s.localDisplay, s.remoteDisplay, model.names.names[s.remoteAddress ?? ""] ?? "",
                       g?.country ?? "", g?.city ?? "", g?.operatorName ?? "", s.interface, s.state].joined(separator: " ").lowercased()
            return hay.contains(q)
        }
        .sorted(using: sortOrder)
    }

    private var table: some View {
        // Table cells are hosted by NSTableView and don't reliably inherit the SwiftUI
        // environment — capture plain values here and pass them in.
        let names = model.names.names
        let geos = model.connections.geo
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("App", value: \SocketRecord.processName) { s in
                ProcessCell(socket: s)
            }
            .width(min: 90, ideal: 160)
            TableColumn("Proto", value: \SocketRecord.proto) { s in
                Text(s.proto.uppercased()).font(.mono(11)).foregroundStyle(Theme.secondary)
            }
            .width(min: 36, ideal: 48)
            TableColumn("Remote", value: \SocketRecord.remoteDisplay) { s in
                RemoteCell(socket: s,
                           host: s.remoteAddress.flatMap { names[$0] },
                           geo: s.remoteAddress.flatMap { geos[IP.stripScope($0)] })
            }
            .width(min: 120, ideal: 220)
            TableColumn("Local", value: \SocketRecord.localDisplay) { s in
                Text(s.localDisplay).font(.mono(11)).foregroundStyle(Theme.ink2)
            }
            .width(min: 80, ideal: 130)
            TableColumn("State", value: \SocketRecord.state) { s in
                StateBadge(state: s.isTCP ? s.state : (s.remoteAddress == nil ? "Unbound" : "Connected"))
            }
            .width(min: 36, ideal: 90)
            Group {
            TableColumn("RTT", value: \SocketRecord.rttSort) { s in
                Text(Fmt.ms(s.rttMs)).font(.mono(11)).foregroundStyle(Theme.latency(s.rttMs))
            }
            .width(min: 36, ideal: 64)
            TableColumn("↓ Rate", value: \SocketRecord.rateIn) { s in
                Text(s.rateIn > 0 ? Fmt.bitrate(bytesPerSecond: s.rateIn) : "·").font(.mono(11)).foregroundStyle(s.rateIn > 0 ? Theme.teal : Theme.faint)
            }
            .width(min: 36, ideal: 78)
            TableColumn("↑ Rate", value: \SocketRecord.rateOut) { s in
                Text(s.rateOut > 0 ? Fmt.bitrate(bytesPerSecond: s.rateOut) : "·").font(.mono(11)).foregroundStyle(s.rateOut > 0 ? Theme.amber : Theme.faint)
            }
            .width(min: 36, ideal: 78)
            TableColumn("Bytes", value: \SocketRecord.totalBytes) { s in
                Text(Fmt.bytes(s.totalBytes)).font(.mono(11)).foregroundStyle(Theme.ink2)
            }
            .width(min: 36, ideal: 70)
            TableColumn("ReTx", value: \SocketRecord.retransmits) { s in
                Text(s.retransmits > 0 ? Fmt.bytes(s.retransmits) : "·").font(.mono(11))
                    .foregroundStyle(s.retransmits > 0 ? Theme.coral : Theme.faint)
            }
            .width(min: 36, ideal: 60)
            TableColumn("If", value: \SocketRecord.interface) { s in
                Text(s.interface).font(.mono(11)).foregroundStyle(s.interface.hasPrefix("utun") ? Theme.violet : Theme.muted)
            }
            .width(min: 36, ideal: 52)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
    }
}

extension SocketRecord {
    var rttSort: Double { rttMs ?? .infinity }
}

struct ProcessCell: View {
    let socket: SocketRecord
    var body: some View {
        let ident = ProcessCatalog.shared.identity(pid: socket.pid, fallbackName: socket.processName)
        let origin = socket.originPid.map { ProcessCatalog.shared.identity(pid: $0, fallbackName: "") }
        HStack(spacing: 6) {
            ProcessIcon(image: origin?.icon ?? ident.icon, size: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(origin?.name ?? ident.name).font(.system(size: 12)).foregroundStyle(Theme.ink).lineLimit(1)
                if origin != nil {
                    Text("via \(ident.name)").font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
        }
        .help("\(ident.path ?? ident.executable) — pid \(socket.pid)")
    }
}

private struct RemoteCell: View {
    let socket: SocketRecord
    let host: String?
    let geo: GeoInfo?

    var body: some View {
        HStack(spacing: 6) {
            if let g = geo { Text(Fmt.flag(g.countryCode)).font(.system(size: 11)) }
            VStack(alignment: .leading, spacing: 0) {
                Text(socket.remoteDisplay).font(.mono(11)).foregroundStyle(Theme.ink).lineLimit(1)
                let sub = host ?? geo?.operatorName ?? socket.remoteScope.flatMap { $0 == .global ? nil : $0.rawValue }
                if let sub {
                    Text(sub).font(.mono(9.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
        }
        .help(Services.name(socket.remotePort, tcp: socket.isTCP).map { "Service: \($0)" } ?? "")
    }
}

struct StateBadge: View {
    let state: String
    var body: some View {
        Text(state)
            .font(.mono(10, .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.1)))
    }
    private var color: Color {
        switch state {
        case "Established", "Connected": Theme.teal
        case "Listen": Theme.violet
        case "SynSent", "SynReceived": Theme.amber
        case "CloseWait", "FinWait1", "FinWait2", "TimeWait", "LastAck", "Closing": Theme.coral
        default: Theme.muted
        }
    }
}

private struct SocketInspector: View {
    let socket: SocketRecord
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = socket
        let ident = ProcessCatalog.shared.identity(pid: s.pid, fallbackName: s.processName)
        let origin = s.originPid.map { ProcessCatalog.shared.identity(pid: $0, fallbackName: "") }
        let geo = s.remoteAddress.flatMap { model.connections.geo[IP.stripScope($0)] ?? model.names.geo[$0] }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    ProcessIcon(image: origin?.icon ?? ident.icon, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(origin?.name ?? ident.name).font(.display(16)).foregroundStyle(Theme.ink)
                        HStack(spacing: 3) {
                            Text(origin != nil ? "relayed by \(ident.name)" : "pid \(s.pid) · \(ident.executable)")
                                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                            if origin != nil { InfoButton(term: .transparentProxy, size: 10) }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    TermLabel(text: "Connection", term: .socketStates, font: .system(size: 11, weight: .medium))
                    Text("\(s.localDisplay)\n→ \(s.remoteDisplay)")
                        .font(.mono(12))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Chip(text: s.proto.uppercased(), color: s.isTCP ? Theme.teal : Theme.violet)
                        StateBadge(state: s.state.isEmpty ? "—" : s.state)
                        if let svc = Services.name(s.remotePort, tcp: s.isTCP) { Chip(text: svc, color: Theme.amber) }
                        Chip(text: s.interface.isEmpty ? "—" : s.interface)
                    }
                }

                if let ip = s.remoteAddress {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Remote host").eyebrowStyle()
                        KV(key: "Address", value: ip)
                        KV(key: "Reverse DNS", value: model.names.name(ip) ?? "—")
                        KV(key: "Scope", value: IP.scope(ip).rawValue)
                        if let g = geo {
                            KV(key: "Location", value: "\(Fmt.flag(g.countryCode)) \(g.place)", mono: false)
                            KV(key: "Network", value: g.operatorName, mono: false)
                            KV(key: "Network (ASN)", value: g.asn ?? "—", info: .asn)
                            if g.hosting == true { KV(key: "Type", value: "Datacenter / hosting", color: Theme.amber, mono: false) }
                            if let home = model.selfGeo, let rtt = s.rttMs {
                                let d = GeoMath.distanceKm(home, g)
                                KV(key: "Distance", value: Fmt.km(d))
                                if d > 400, rtt < GeoMath.minRTTms(distanceKm: d) * 0.85 {
                                    Callout(kind: .info, title: "Anycast: served from nearby",
                                            message: "\(Fmt.ms(rtt)) is faster than light could travel \(Fmt.km(d)) and back — you're talking to a nearby copy of this address.")
                                }
                            }
                        }
                    }
                }

                if s.isTCP {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TCP internals").eyebrowStyle()
                        KV(key: "Smoothed RTT", value: Fmt.ms(s.rttMs), color: Theme.latency(s.rttMs), info: .rtt)
                        KV(key: "Retransmitted", value: Fmt.bytes(s.retransmits), color: s.retransmits > 0 ? Theme.coral : Theme.ink,
                           help: "Bytes sent again because they were lost or ACKed too late", info: .retransmits)
                        KV(key: "Duplicate rx", value: Fmt.bytes(s.rxDupe), help: "Bytes received more than once")
                        KV(key: "Out-of-order rx", value: Fmt.bytes(s.rxOutOfOrder), help: "Bytes that arrived ahead of a gap")
                        KV(key: "Receive buffer", value: s.rcvBuffer.map { Fmt.bytes($0) } ?? "—", info: .tcpWindow)
                        KV(key: "Send window", value: s.txWindow.map { Fmt.bytes($0) } ?? "—")
                        KV(key: "Congestion control", value: s.ccAlgo.isEmpty ? "—" : s.ccAlgo, info: .congestionControl)
                        if s.totalBytes > 0 {
                            let lossPct = Double(s.retransmits) / Double(max(s.bytesOut, 1)) * 100
                            KV(key: "Retransmit ratio", value: Fmt.percent(lossPct, digits: 2), color: Theme.loss(lossPct))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Traffic").eyebrowStyle()
                    KV(key: "Received", value: Fmt.bytes(s.bytesIn))
                    KV(key: "Sent", value: Fmt.bytes(s.bytesOut))
                    KV(key: "Rate", value: "↓ \(Fmt.bitrate(bytesPerSecond: s.rateIn))  ↑ \(Fmt.bitrate(bytesPerSecond: s.rateOut))")
                    KV(key: "Service class", value: s.trafficClass.isEmpty ? "—" : s.trafficClassName, mono: false, info: .trafficClass)
                    KV(key: "Age", value: Fmt.duration(Date().timeIntervalSince(s.firstSeen)) + "+")
                }

                if let ip = s.remoteAddress {
                    HStack(spacing: 8) {
                        Button("Traceroute") { model.open(.traceroute, target: ip) }.buttonStyle(.borderedProminent)
                        Button("Ping") { model.open(.ping, target: ip) }.buttonStyle(.bordered)
                        Button("Copy") { copyToPasteboard(ip) }.buttonStyle(.bordered)
                    }
                }
            }
            .padding(18)
        }
    }
}
