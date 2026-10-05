import SwiftUI
import AppKit

struct BluetoothView: View {
    @Environment(AppModel.self) private var model
    @State private var controller: BTController?
    @State private var devices: [BTDevice] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var scanner = BLEScanner()
    @State private var namedOnly = false

    private var connected: [BTDevice] { devices.filter(\.connected) }
    private var paired: [BTDevice] { devices.filter { !$0.connected }.sorted { ($0.rssi != nil ? 0 : 1, $0.name) < ($1.rssi != nil ? 0 : 1, $1.name) } }
    private var nearby: [BLEAdvertiser] {
        scanner.devices.values
            .filter { !namedOnly || $0.name != nil }
            .sorted { $0.rssi > $1.rssi }
    }

    var body: some View {
        Page(spacing: 18) {
            PageHeader(eyebrow: "Local · Bluetooth", title: "Bluetooth",
                       subtitle: "Your Bluetooth controller, every paired device with its battery and signal, and a live scan of the low-energy devices advertising around you — phones, earbuds, watches, trackers and beacons.") {
                Button("Refresh") { Task { await refresh() } }.buttonStyle(.bordered)
            }

            if !loaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            } else if failed || controller == nil {
                Callout(kind: .warning, title: "Couldn't read Bluetooth information",
                        message: "macOS didn't return Bluetooth details (system_profiler SPBluetoothDataType). Try Refresh in a moment.")
            } else if let c = controller {
                HStack(spacing: 12) {
                    Readout(label: "Bluetooth", value: c.poweredOn ? "On" : "Off", accent: c.poweredOn ? Theme.text : Theme.warn,
                            caption: c.discoverable ? "discoverable" : "not discoverable")
                    Readout(label: "Connected", value: "\(connected.count)")
                    Readout(label: "Paired", value: "\(devices.count)", caption: "\(paired.filter { $0.rssi != nil }.count) in range")
                    Readout(label: "Nearby (BLE)", value: scanner.isScanning || !scanner.devices.isEmpty ? "\(scanner.devices.count)" : "—",
                            caption: scanner.awaitingPermission ? "waiting for permission" : scanner.isScanning ? "scanning" : "not scanning", info: .bleAdvertising)
                }
                if !c.poweredOn {
                    Callout(kind: .warning, title: "Bluetooth is turned off",
                            message: "Turn it on in Control Center or System Settings → Bluetooth to see devices and scan.")
                }

                Panel("Connected", icon: "link", info: .bluetoothProfiles) {
                    if connected.isEmpty {
                        EmptyState(icon: "link", title: "Nothing connected right now")
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)], spacing: 14) {
                            ForEach(connected) { ConnectedCard(device: $0) }
                        }
                    }
                }

                if !paired.isEmpty {
                    Panel("Paired, not connected · \(paired.count)", icon: "list.bullet") {
                        VStack(spacing: 0) {
                            ForEach(paired) { d in
                                PairedRow(device: d)
                                if d.id != paired.last?.id { Hairline().opacity(0.6) }
                            }
                        }
                    }
                }

                nearbyPanel
                controllerPanel(c)
            }
        }
        .task {
            // `-NLBLEAutoScan YES`: start the nearby scan on launch (used for screenshots and testing).
            if UserDefaults.standard.bool(forKey: "NLBLEAutoScan") { scanner.start() }
            await refresh()
            // Battery and signal change slowly; re-read while the screen is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                await refresh()
            }
        }
        .onDisappear { scanner.stop() }
    }

    private func refresh() async {
        if let (c, d) = await BluetoothSystem.read() {
            controller = c
            devices = d
            failed = false
        } else {
            failed = controller == nil
        }
        loaded = true
    }

    // MARK: nearby

    private var nearbyPanel: some View {
        Panel("Nearby · Bluetooth Low Energy", icon: "dot.radiowaves.left.and.right", info: .bleAdvertising) {
            HStack(spacing: 10) {
                if scanner.isScanning || !scanner.devices.isEmpty {
                    Toggle("Named only", isOn: $namedOnly).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                }
                if scanner.isScanning {
                    Button("Stop") { scanner.stop() }.buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button(scanner.devices.isEmpty ? "Start scan" : "Resume") { scanner.start() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                switch scanner.state {
                case .denied:
                    HStack(spacing: 12) {
                        Callout(kind: .warning, title: "NetLens isn't allowed to use Bluetooth",
                                message: "Turn NetLens on under System Settings → Privacy & Security → Bluetooth, then start the scan again.")
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
                        }.buttonStyle(.bordered)
                    }
                case .poweredOff:
                    Callout(kind: .info, title: "Bluetooth is off", message: "Turn Bluetooth on to scan for nearby devices.")
                case .unsupported:
                    Callout(kind: .info, title: "This Mac can't scan for Bluetooth Low Energy devices")
                default:
                    EmptyView()
                }

                if scanner.devices.isEmpty && !scanner.isScanning && scanner.state == .idle {
                    EmptyState(icon: "dot.radiowaves.left.and.right", title: "Listen for nearby devices",
                               message: "Start a scan to hear the low-energy advertisements around you. Nothing is connected to or changed — NetLens only listens. macOS asks for Bluetooth permission the first time.")
                } else if scanner.awaitingPermission {
                    EmptyState(icon: "lock", title: "Waiting for Bluetooth permission",
                               message: "macOS is asking whether NetLens may use Bluetooth — look for the dialog and choose Allow. NetLens only listens; it never connects to or pairs with anything.")
                } else if nearby.isEmpty && scanner.isScanning {
                    EmptyState(icon: "dot.radiowaves.left.and.right", title: "Listening…")
                } else if !nearby.isEmpty {
                    nearbyHeader
                    Hairline()
                    LazyVStack(spacing: 0) {
                        ForEach(nearby.prefix(200)) { a in
                            NearbyRow(ad: a)
                            Hairline().opacity(0.5)
                        }
                    }
                    Text("macOS only delivers scan results while NetLens is the active app, so the list pauses when you switch away.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    HStack(spacing: 4) {
                        Text("Distances are rough guesses from signal strength — walls and bodies make devices look further away.")
                        InfoButton(term: .blePrivacy, size: 10)
                        Text("Why the same phone can appear twice")
                    }
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    private var nearbyHeader: some View {
        HStack(spacing: 12) {
            Text("Signal").frame(width: 110, alignment: .leading)
            Text("Device").frame(maxWidth: .infinity, alignment: .leading)
            Text("Maker").frame(width: 150, alignment: .leading)
            Text("Distance").frame(width: 70, alignment: .trailing)
            Text("Seen").frame(width: 60, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.tertiary)
    }

    // MARK: controller

    private func controllerPanel(_ c: BTController) -> some View {
        Panel("Controller", icon: "cpu", info: .bluetoothKinds) {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    GridRow {
                        KV(key: "Chipset", value: c.chipset ?? "—")
                        KV(key: "Firmware", value: c.firmware ?? "—")
                        KV(key: "Transport", value: c.transport ?? "—")
                    }
                    GridRow {
                        KV(key: "Address", value: c.address ?? "—")
                        KV(key: "Vendor / product", value: [c.vendorID, c.productID].compactMap { $0 }.joined(separator: " / "))
                        KV(key: "Discoverable", value: c.discoverable ? "Yes" : "No", mono: false)
                    }
                }
                if !c.profiles.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Supports").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                        FlowChips {
                            ForEach(c.profiles, id: \.self) { p in
                                Chip(text: p).help(BluetoothNames.profile(p) ?? p)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Rows & cards

private struct ConnectedCard: View {
    let device: BTDevice

    var body: some View {
        let d = device
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill)
                    Image(systemName: d.symbol).font(.system(size: 18)).foregroundStyle(Theme.accent)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text([d.minorType, d.vendor].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
                if let r = d.rssi {
                    HStack(spacing: 5) {
                        SignalBars(rssi: r, height: 11)
                        Text(verbatim: "\(r) dBm").font(.mono(11)).foregroundStyle(Theme.secondary)
                    }
                    .help("Received signal strength")
                }
            }
            if !d.batteries.isEmpty {
                HStack(spacing: 16) {
                    ForEach(d.batteries, id: \.self) { b in BatteryGauge(battery: b) }
                }
            }
            if !d.profiles.isEmpty {
                FlowChips {
                    ForEach(d.profiles, id: \.self) { p in Chip(text: p).help(BluetoothNames.profile(p) ?? p) }
                }
            }
            HStack(spacing: 10) {
                if let a = d.address { Text(verbatim: a).font(.mono(10.5)).foregroundStyle(Theme.tertiary).textSelection(.enabled) }
                if let f = d.firmware { Text(verbatim: "firmware \(f)").font(.mono(10.5)).foregroundStyle(Theme.tertiary) }
            }
        }
        .padding(14)
        .background(PanelBackground())
    }
}

private struct BatteryGauge: View {
    let battery: BTBattery

    var body: some View {
        let p = battery.percent
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(p <= 15 ? Theme.bad : p <= 30 ? Theme.warn : Theme.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "\(p)%").font(.mono(12, .medium)).foregroundStyle(Theme.text)
                Text(battery.label).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var symbol: String {
        switch battery.percent {
        case 88...: "battery.100percent"
        case 63...: "battery.75percent"
        case 38...: "battery.50percent"
        case 13...: "battery.25percent"
        default: "battery.0percent"
        }
    }
}

private struct PairedRow: View {
    let device: BTDevice

    var body: some View {
        let d = device
        HStack(spacing: 12) {
            Image(systemName: d.symbol).font(.system(size: 14)).foregroundStyle(Theme.secondary).frame(width: 22)
            Text(d.name).font(.system(size: 12.5)).foregroundStyle(Theme.text).lineLimit(1)
            Text([d.minorType, d.vendor].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
            Spacer()
            if let r = d.rssi {
                Text("in range").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                SignalBars(rssi: r, height: 10)
                Text(verbatim: "\(r) dBm").font(.mono(11)).foregroundStyle(Theme.secondary).frame(width: 58, alignment: .trailing)
            }
            if let a = d.address { Text(verbatim: a).font(.mono(10.5)).foregroundStyle(Theme.tertiary).frame(width: 130, alignment: .trailing) }
        }
        .padding(.vertical, 7)
    }
}

private struct NearbyRow: View {
    let ad: BLEAdvertiser

    var body: some View {
        let a = ad
        let kind = a.kind
        let age = Date().timeIntervalSince(a.lastSeen)
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                SignalBars(rssi: Int(a.rssi), height: 11)
                Text(verbatim: "\(Int(a.rssi.rounded())) dBm").font(.mono(11.5)).foregroundStyle(Theme.text)
            }
            .frame(width: 110, alignment: .leading)
            HStack(spacing: 8) {
                Image(systemName: kind.symbol).font(.system(size: 13)).foregroundStyle(Theme.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.name ?? kind.label).font(.system(size: 12.5, weight: a.name == nil ? .regular : .medium))
                        .foregroundStyle(a.name == nil ? Theme.secondary : Theme.text).lineLimit(1)
                    let detail = [a.name == nil ? nil : kind.label,
                                  // a service name only adds information when it didn't already decide the kind
                                  kind.symbol == "dot.radiowaves.right" ? a.services.compactMap(BluetoothNames.service).first : nil,
                                  a.connectable == false ? "broadcast only" : nil].compactMap { $0 }
                    if !detail.isEmpty {
                        Text(detail.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(a.company ?? a.companyID.map { String(format: "0x%04X", $0) } ?? "—")
                .font(.system(size: 12)).foregroundStyle(a.company == nil ? Theme.tertiary : Theme.secondary)
                .frame(width: 150, alignment: .leading).lineLimit(1)
            Text(distance(a.distanceMeters)).font(.mono(11.5)).foregroundStyle(Theme.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(age < 2 ? "now" : "\(Int(age))s ago").font(.mono(11)).foregroundStyle(age > 20 ? Theme.tertiary : Theme.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .opacity(age > 30 ? 0.55 : 1)
        .help(tooltip)
    }

    private func distance(_ m: Double) -> String {
        if m < 1 { return "< 1 m" }
        if m < 10 { return String(format: "≈ %.0f m", m) }
        if m < 50 { return String(format: "≈ %.0f m", (m / 5).rounded() * 5) }
        return "> 50 m"
    }

    private var tooltip: String {
        var lines = ["ID \(ad.id.uuidString)", "\(ad.packets) advertisements"]
        if let tx = ad.txPower { lines.append("Tx power \(tx) dBm") }
        if !ad.services.isEmpty { lines.append("Services: " + ad.services.map { BluetoothNames.service($0) ?? $0.uuidString }.joined(separator: ", ")) }
        if let d = ad.manufacturerData { lines.append("Manufacturer data: " + d.map { String(format: "%02x", $0) }.joined()) }
        return lines.joined(separator: "\n")
    }
}
