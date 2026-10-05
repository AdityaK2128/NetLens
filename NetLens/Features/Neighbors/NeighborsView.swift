import SwiftUI

struct NeighborsView: View {
    @Environment(AppModel.self) private var model
    @State private var bonjour = BonjourScanner()
    @State private var arp: [Neighbor] = []
    @State private var ndp: [Neighbor] = []
    @State private var sweepRTT: [String: Double] = [:]
    @State private var sweeping = false
    @State private var progress = 0.0
    @State private var selected: String?
    @State private var showRaw = false

    var body: some View {
        let devices = buildDevices()
        Page(spacing: 18) {
            PageHeader(eyebrow: "Local · arp / ndp / dns-sd", title: "LAN & neighbors",
                       subtitle: "Who else is on your network: the ARP and NDP caches, Bonjour advertisements, and an optional ICMP sweep of your subnet — merged into one list of devices.") {
                HStack(spacing: 8) {
                    if sweeping {
                        ProgressView(value: progress).frame(width: 120)
                        Text("\(Int(progress * 100))%").font(.mono(10.5)).foregroundStyle(Theme.muted)
                    }
                    Button(sweeping ? "Sweeping…" : "Sweep subnet") { sweep() }.buttonStyle(.borderedProminent).disabled(sweeping)
                }
            }

            if model.localNetwork == .denied || (arp.filter { $0.mac != nil }.isEmpty && bonjour.services.isEmpty && !sweeping) {
                HStack(spacing: 12) {
                    Callout(kind: model.localNetwork == .denied ? .warning : .info,
                            title: model.localNetwork == .denied ? "macOS is hiding your local network from NetLens" : "Not seeing your devices?",
                            message: "Other devices, Bonjour services and the ARP table are only visible to apps you allow under System Settings → Privacy & Security → Local Network. Turn NetLens on there, then come back.")
                    Button("Open Settings") { LocalNetworkAccess.openSettings() }.buttonStyle(.bordered)
                    Button("Check again") { Task { await model.checkLocalNetwork(); await refreshCaches() } }.buttonStyle(.bordered)
                }
            }

            HStack(spacing: 12) {
                Readout(label: "Devices", value: "\(devices.count)", accent: Theme.amber)
                Readout(label: "Bonjour services", value: "\(bonjour.services.count)", accent: Theme.ink, caption: "\(bonjour.types.count) types", info: .bonjour)
                Readout(label: "ARP entries", value: "\(arp.filter { $0.mac != nil && !$0.isMulticast }.count)", accent: Theme.ink, info: .arp)
                Readout(label: "IPv6 neighbors", value: "\(ndp.filter { $0.mac != nil && $0.mac != "02:00:00:00:00:00" && $0.interface == (model.physicalInterface?.name ?? "en0") }.count)", accent: Theme.ink,
                        caption: ndp.contains { $0.isRouter } ? "router advertising" : nil)
                Readout(label: "Private MACs", value: "\(devices.filter(\.randomizedMAC).count)", accent: Theme.violet, caption: "randomised by OS", info: .privateMAC)
            }

            if devices.isEmpty {
                EmptyState(icon: "house", title: sweeping ? "Looking for devices…" : "No other devices visible yet",
                           message: "Press Sweep subnet to ping every address on your network, which also fills the ARP table. Devices that announce themselves with Bonjour appear automatically.")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 14, alignment: .top)], spacing: 14) {
                ForEach(devices) { d in
                    DeviceCard(device: d, expanded: selected == d.id)
                        .onTapGesture { withAnimation(.snappy) { selected = selected == d.id ? nil : d.id } }
                }
            }

            Toggle("Show raw ARP / NDP tables", isOn: $showRaw).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            if showRaw {
                Panel("ARP cache (IPv4)", icon: "tablecells") {
                    VStack(spacing: 0) {
                        ForEach(arp) { n in
                            HStack {
                                Text(n.ip).font(.mono(11.5)).frame(width: 150, alignment: .leading)
                                Text(n.mac ?? "(incomplete)").font(.mono(11.5)).foregroundStyle(n.mac == nil ? Theme.faint : Theme.ink2).frame(width: 160, alignment: .leading)
                                Text(n.interface).font(.mono(11)).foregroundStyle(Theme.muted).frame(width: 60, alignment: .leading)
                                Text(n.permanent ? "permanent" : (n.expires.map { "expires \($0)" } ?? "")).font(.mono(10.5)).foregroundStyle(Theme.muted)
                                Spacer()
                                if let v = n.vendor { Text(v).font(.system(size: 11)).foregroundStyle(Theme.ink2) }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                Panel("Neighbor cache (IPv6 NDP)", icon: "tablecells") {
                    VStack(spacing: 0) {
                        ForEach(ndp) { n in
                            HStack {
                                Text(n.ip).font(.mono(11)).frame(width: 300, alignment: .leading).lineLimit(1)
                                Text(n.mac ?? "(incomplete)").font(.mono(11)).foregroundStyle(Theme.ink2).frame(width: 150, alignment: .leading)
                                Text(n.interface).font(.mono(11)).foregroundStyle(Theme.muted).frame(width: 60, alignment: .leading)
                                Text(n.state ?? "").font(.mono(10.5)).foregroundStyle(Theme.muted)
                                if n.isRouter { Chip(text: "router", color: Theme.amber) }
                                Spacer()
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
        .task {
            bonjour.start()
            await refreshCaches()
        }
        .onDisappear { bonjour.stop() }
    }

    private func refreshCaches() async {
        async let a = Neighbors.arp()
        async let n = Neighbors.ndp()
        (arp, ndp) = await (a, n)
        for x in arp where x.mac != nil { model.names.request(x.ip) }
    }

    private func sweep() {
        guard let a = model.physicalInterface?.ipv4.first, let mask = a.netmask else { return }
        sweeping = true
        progress = 0
        Task {
            sweepRTT = await SubnetSweep.run(address: a.address, netmask: mask) { p in progress = p }
            await refreshCaches()
            sweeping = false
        }
    }

    private func buildDevices() -> [LANDevice] {
        var byKey: [String: LANDevice] = [:]
        let selfIPs = Set(model.interfaces.flatMap { $0.ipv4.map(\.address) + $0.ipv6.map { IP.stripScope($0.address) } })
        let selfMACs = Set(model.interfaces.compactMap(\.mac))
        func key(mac: String?, ip: String) -> String { mac ?? ip }
        let lanIfaces: Set<String> = Set([model.physicalInterface?.name].compactMap { $0 })
        func isLAN(_ iface: String) -> Bool { lanIfaces.isEmpty ? !["lo0", "utun", "awdl", "llw", "anpi", "ipsec"].contains { iface.hasPrefix($0) } : lanIfaces.contains(iface) }

        for n in arp where n.mac != nil && !n.isMulticast && isLAN(n.interface) {
            let k = key(mac: n.mac, ip: n.ip)
            var d = byKey[k] ?? LANDevice(name: n.ip, mac: n.mac, vendor: n.vendor, randomizedMAC: n.isRandomizedMAC)
            if !d.ips.contains(n.ip) { d.ips.append(n.ip) }
            d.isRouter = d.isRouter || n.ip == model.net.router
            d.isSelf = d.isSelf || selfIPs.contains(n.ip) || selfMACs.contains(n.mac ?? "")
            d.rtt = sweepRTT[n.ip] ?? d.rtt
            d.hostname = d.hostname ?? model.names.names[n.ip]
            byKey[k] = d
        }
        for n in ndp where n.mac != nil && n.mac != "02:00:00:00:00:00" && isLAN(n.interface) {
            let k = key(mac: n.mac, ip: n.ip)
            var d = byKey[k] ?? LANDevice(name: n.ip, mac: n.mac, vendor: n.vendor, randomizedMAC: n.isRandomizedMAC)
            let ip = IP.stripScope(n.ip)
            if !d.ips.contains(ip) { d.ips.append(ip) }
            d.isRouter = d.isRouter || n.isRouter
            d.isSelf = d.isSelf || selfMACs.contains(n.mac ?? "") || selfIPs.contains(ip)
            byKey[k] = d
        }
        // Attach Bonjour services by address.
        for s in bonjour.services.values {
            let addrs = s.addresses.map(IP.stripScope)
            var matched = false
            for (k, d) in byKey where d.ips.contains(where: { addrs.contains($0) }) {
                var dev = d
                dev.services.append(s)
                dev.hostname = dev.hostname ?? s.hostName
                if let m = s.txt["model"] ?? s.txt["md"] ?? s.txt["am"] { dev.model = dev.model ?? m }
                byKey[k] = dev
                matched = true
                break
            }
            if !matched, let host = s.hostName {
                // Device seen only via Bonjour (e.g. IPv6-only advertisement): key by hostname.
                var dev = byKey[host] ?? LANDevice(name: host, ips: addrs.filter(IP.isV4))
                dev.services.append(s)
                dev.hostname = host
                if let m = s.txt["model"] ?? s.txt["md"] { dev.model = dev.model ?? m }
                dev.isSelf = dev.isSelf || addrs.contains(where: selfIPs.contains)
                byKey[host] = dev
            }
        }
        for k in byKey.keys {
            var d = byKey[k]!
            let bonjourName = d.services.first(where: { !$0.name.isEmpty && !$0.name.hasPrefix("_") })?.name
            d.name = d.isSelf ? model.net.computerName : (bonjourName ?? d.hostname?.replacingOccurrences(of: ".local.", with: "") ?? d.ips.first ?? "Unknown")
            d.services.sort { $0.shortType < $1.shortType }
            byKey[k] = d
        }
        return byKey.values.sorted { a, b in
            if a.isSelf != b.isSelf { return a.isSelf }
            if a.isRouter != b.isRouter { return a.isRouter }
            if a.services.count != b.services.count { return a.services.count > b.services.count }
            return (a.ips.first.flatMap(IP.v4Value) ?? .max) < (b.ips.first.flatMap(IP.v4Value) ?? .max)
        }
    }
}

private struct DeviceCard: View {
    let device: LANDevice
    let expanded: Bool

    var body: some View {
        let d = device
        let (kind, symbol) = d.kind
        let accent: Color = d.isSelf ? Theme.amber : d.isRouter ? Theme.teal : d.services.isEmpty ? Theme.ink2 : Theme.violet
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.trough)
                    Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(accent)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text([kind, d.model].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                if let rtt = d.rtt { Text(Fmt.ms(rtt)).font(.mono(11)).foregroundStyle(Theme.latency(rtt)) }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(d.ips.prefix(expanded ? 8 : 2), id: \.self) { ip in
                    Text(ip).font(.mono(11)).foregroundStyle(IP.isV4(ip) ? Theme.ink : Theme.ink2).lineLimit(1).textSelection(.enabled)
                }
                if let mac = d.mac {
                    HStack(spacing: 6) {
                        Text(mac).font(.mono(10.5)).foregroundStyle(Theme.muted)
                        if d.randomizedMAC { TermTag(text: "private MAC", term: .privateMAC) }
                        if let v = d.vendor { Chip(text: v, color: Theme.ink2) }
                    }
                }
            }
            if !d.services.isEmpty {
                FlowChips() {
                    ForEach(d.services.prefix(expanded ? 30 : 6)) { s in
                        Chip(text: s.shortType + (s.port > 0 && expanded ? ":\(s.port)" : ""), color: Theme.teal)
                            .help("\(s.name)\n\(s.type) port \(s.port)\n" + s.txt.map { "\($0)=\($1)" }.sorted().joined(separator: "\n"))
                    }
                    if !expanded && d.services.count > 6 { Chip(text: "+\(d.services.count - 6)", color: Theme.muted) }
                }
            }
            if expanded {
                ForEach(d.services.filter { !$0.txt.isEmpty }.prefix(4)) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(s.shortType) · \(s.name)").font(.mono(10, .medium)).foregroundStyle(Theme.amber)
                        Text(s.txt.map { "\($0)=\($1)" }.sorted().prefix(8).joined(separator: "  ")).font(.mono(9.5)).foregroundStyle(Theme.muted).lineLimit(3)
                    }
                }
            }
        }
        .padding(14)
        .background(PanelBackground())
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(expanded ? accent.opacity(0.5) : .clear))
        .contentShape(Rectangle())
    }
}
