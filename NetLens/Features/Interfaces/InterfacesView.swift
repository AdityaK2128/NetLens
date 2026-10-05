import SwiftUI

struct InterfacesView: View {
    @Environment(AppModel.self) private var model
    @State private var showInactive = false
    @State private var lease: DHCPLease?

    var body: some View {
        // Idle system tunnels (Apple services create several) only clutter the list.
        let ifaces = model.interfaces.filter { i in
            if showInactive { return true }
            let traffic = (model.throughput.counters[i.name] ?? i.counters).bytesIn + (model.throughput.counters[i.name] ?? i.counters).bytesOut
            return i.isActive || i.kind == .wifi || i.kind == .ethernet || traffic > 1_000_000
        }
        Page(spacing: 18) {
            PageHeader(eyebrow: "Local · ifconfig", title: "Interfaces",
                       subtitle: "Every network interface the kernel knows about — physical radios, VPN tunnels, AirDrop's peer-to-peer link — with 64-bit traffic counters and what each one is actually for.") {
                Toggle("Show idle interfaces", isOn: $showInactive).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            }

            if let p = model.primaryInterface {
                PrimaryCard(iface: p, lease: lease)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 16, alignment: .top)], spacing: 16) {
                ForEach(ifaces) { i in
                    InterfaceCard(iface: i, primary: i.name == model.net.primaryInterface)
                }
            }
        }
        .task(id: model.net.primaryInterface) {
            if let p = model.physicalInterface?.name ?? model.net.primaryInterface {
                lease = await DHCPLease.read(interface: p)
            }
        }
    }
}

private struct PrimaryCard: View {
    let iface: NetInterface
    let lease: DHCPLease?
    @Environment(AppModel.self) private var model

    var body: some View {
        let v4 = model.physicalInterface?.ipv4.first ?? iface.ipv4.first
        let net = v4.flatMap { a in a.netmask.flatMap { IP.v4Network(address: a.address, netmask: $0) } }
        HStack(alignment: .top, spacing: 18) {
            Panel("Subnet", icon: "square.grid.3x3") {
                if let a = v4, let net {
                    VStack(spacing: 0) {
                        KV(key: "Address", value: a.cidr, color: Theme.amber)
                        KV(key: "Network", value: "\(net.network)/\(a.prefix ?? 0)")
                        KV(key: "Netmask", value: a.netmask ?? "—")
                        KV(key: "Broadcast", value: net.broadcast)
                        KV(key: "Usable hosts", value: "\(net.first) – \(net.last)")
                        KV(key: "Host count", value: Fmt.count(Int(net.hosts)))
                        KV(key: "Gateway", value: model.net.router ?? "—")
                    }
                } else {
                    Text("No IPv4 address").foregroundStyle(Theme.muted)
                }
            }
            Panel("DHCP lease", icon: "clock.badge.checkmark", info: .dhcp) {
                if let l = lease {
                    VStack(spacing: 0) {
                        KV(key: "Server", value: l.server ?? "—")
                        KV(key: "State", value: (l.state ?? l.messageType ?? "—").capitalized)
                        KV(key: "Lease length", value: l.leaseSeconds.map { Fmt.duration(TimeInterval($0)) } ?? "—")
                        KV(key: "Obtained", value: l.leaseStart.map { Fmt.dateTime.string(from: $0) } ?? "—")
                        if let exp = l.leaseExpires {
                            KV(key: "Renews / expires", value: "\(Fmt.dateTime.string(from: exp)) (in \(Fmt.duration(max(0, exp.timeIntervalSinceNow))))")
                        }
                        KV(key: "DNS offered", value: l.dns.joined(separator: ", ").nilIfEmpty ?? "—")
                        if let d = l.domain { KV(key: "Domain", value: d) }
                        let other = l.options.filter { !["server_identifier", "router", "subnet_mask", "domain_name_server", "domain_name", "lease_time", "dhcp_message_type"].contains($0.0) }
                        ForEach(other, id: \.0) { k, v in KV(key: DHCPLease.optionName(k), value: v) }
                    }
                } else {
                    Text("No DHCP lease (static address, VPN, or not yet bound)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

private struct InterfaceCard: View {
    let iface: NetInterface
    let primary: Bool
    @Environment(AppModel.self) private var model
    @State private var expanded = false

    var body: some View {
        let i = iface
        let series = model.throughput.series(i.name)
        let counters = model.throughput.counters[i.name] ?? i.counters
        let accent: Color = i.isActive ? (primary ? Theme.amber : Theme.teal) : Theme.faint
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.trough)
                    Image(systemName: i.kind.symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(accent)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(i.name).font(.mono(15, .semibold)).foregroundStyle(Theme.ink)
                        Text(i.displayName).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                        if primary { Chip(text: "Default route", color: Theme.amber, filled: true) }
                    }
                    HStack(spacing: 6) {
                        StatusDot(color: i.isActive ? Theme.good : i.isUp ? Theme.amber : Theme.faint, size: 6)
                        Text(i.isActive ? "active" : i.isUp ? "up, no address" : "down").font(.mono(10.5)).foregroundStyle(Theme.muted)
                        if counters.mtu > 0 { Text(verbatim: "· MTU \(counters.mtu)").font(.mono(10.5)).foregroundStyle(Theme.muted) }
                        if counters.baudrate > 0 { Text("· \(Fmt.bitrate(bitsPerSecond: Double(counters.baudrate)))").font(.mono(10.5)).foregroundStyle(Theme.muted) }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("↓ \(Fmt.bitrate(bytesPerSecond: series.last?.inBps ?? 0))").font(.mono(11)).foregroundStyle(Theme.teal)
                    Text("↑ \(Fmt.bitrate(bytesPerSecond: series.last?.outBps ?? 0))").font(.mono(11)).foregroundStyle(Theme.amber)
                }
            }

            Text(i.explanation).font(.system(size: 11.5)).foregroundStyle(Theme.ink2.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            if !i.ipv4.isEmpty || !i.ipv6.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(i.ipv4 + i.ipv6) { a in
                        HStack(spacing: 8) {
                            Text(a.isV6 ? "inet6" : "inet").font(.mono(10)).foregroundStyle(Theme.faint).frame(width: 36, alignment: .leading)
                            Text(a.cidr).font(.mono(11.5)).foregroundStyle(Theme.ink).textSelection(.enabled).lineLimit(1)
                            Spacer()
                            Chip(text: a.scope.rawValue, color: a.scope == .global ? Theme.amber : a.scope == .cgnat ? Theme.violet : Theme.muted)
                        }
                    }
                }
            }

            if !series.isEmpty, i.isActive {
                DualTrace(down: series.map(\.inBps), up: series.map(\.outBps), capacity: model.throughput.capacity)
                    .frame(height: 36)
            }

            HStack(spacing: 14) {
                stat("rx", Fmt.bytes(counters.bytesIn))
                stat("tx", Fmt.bytes(counters.bytesOut))
                stat("pkts", Fmt.count(Int(counters.packetsIn + counters.packetsOut)))
                stat("errs", "\(counters.errorsIn + counters.errorsOut)", counters.errorsIn + counters.errorsOut > 0 ? Theme.coral : Theme.ink2)
                stat("drops", "\(counters.dropsIn)", counters.dropsIn > 0 ? Theme.amber : Theme.ink2)
                Spacer()
                Button(expanded ? "Less" : "More") { withAnimation(.snappy) { expanded.toggle() } }
                    .buttonStyle(.plain).font(.mono(10.5)).foregroundStyle(Theme.amber)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    KV(key: "MAC", value: i.mac.map { Neighbors.isLocallyAdministered($0) ? "\($0) (private)" : $0 } ?? "—", info: .privateMAC)
                    KV(key: "Index", value: "\(i.index)")
                    KV(key: "Multicast", value: "in \(Fmt.count(Int(counters.multicastIn))) · out \(Fmt.count(Int(counters.multicastOut)))")
                    KV(key: "Collisions", value: "\(counters.collisions)")
                    FlowChips() {
                        ForEach(i.flagNames, id: \.self) { Chip(text: $0, color: Theme.muted) }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(16)
        .background(PanelBackground())
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(primary ? Theme.amber.opacity(0.35) : .clear))
        .opacity(i.isActive || i.hasAddresses ? 1 : 0.6)
    }

    private func stat(_ k: String, _ v: String, _ c: Color = Theme.ink2) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.mono(8.5, .medium)).foregroundStyle(Theme.faint)
            Text(v).font(.mono(11)).foregroundStyle(c)
        }
    }
}
