import Foundation
import Observation
import CoreBluetooth

// MARK: - Controller & paired devices (system_profiler)

struct BTController: Equatable {
    var poweredOn = false
    var discoverable = false
    var address: String?
    var chipset: String?
    var firmware: String?
    var transport: String?
    var vendorID: String?
    var productID: String?
    var profiles: [String] = []
}

struct BTBattery: Hashable {
    let label: String       // "Left", "Right", "Case", "Battery"
    let percent: Int
}

struct BTDevice: Identifiable, Hashable {
    var id: String { address ?? name }
    let name: String
    var address: String?
    var connected = false
    var minorType: String?
    var vendorID: Int?
    var productID: Int?
    var firmware: String?
    var rssi: Int?
    var profiles: [String] = []
    var batteries: [BTBattery] = []

    var vendor: String? { vendorID.flatMap(BluetoothNames.company) }

    var symbol: String {
        let t = (minorType ?? "").lowercased(), n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("watch") { return "applewatch" }
        if n.contains("iphone") { return "iphone" }
        if n.contains("ipad") { return "ipad" }
        if n.contains("macbook") || n.contains("imac") || n.contains("mac mini") || n.contains("mac studio") { return "laptopcomputer" }
        if t.contains("headphone") || t.contains("headset") { return "headphones" }
        if t.contains("speaker") || t.contains("audio") { return "hifispeaker" }
        if t.contains("mouse") { return "computermouse" }
        if t.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if t.contains("keyboard") { return "keyboard" }
        if t.contains("game") || t.contains("joystick") { return "gamecontroller" }
        if t.contains("phone") { return "iphone" }
        if t.contains("computer") || t.contains("laptop") { return "laptopcomputer" }
        return "dot.radiowaves.right"
    }
}

enum BluetoothSystem {
    /// `system_profiler SPBluetoothDataType -json` — the same data as System Information:
    /// controller details, every paired device, battery levels and signal strength.
    static func read() async -> (BTController, [BTDevice])? {
        let r = await Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json", "-detailLevel", "basic"], timeout: 25)
        guard r.ok, let data = r.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let top = (root["SPBluetoothDataType"] as? [[String: Any]])?.first else { return nil }
        return parse(top)
    }

    static func parse(_ top: [String: Any]) -> (BTController, [BTDevice]) {
        var c = BTController()
        if let p = top["controller_properties"] as? [String: Any] {
            c.poweredOn = (p["controller_state"] as? String) == "attrib_on"
            c.discoverable = (p["controller_discoverable"] as? String) == "attrib_on"
            c.address = p["controller_address"] as? String
            c.chipset = (p["controller_chipset"] as? String)?.replacingOccurrences(of: "_", with: " ")
            c.firmware = p["controller_firmwareVersion"] as? String
            c.transport = p["controller_transport"] as? String
            c.vendorID = p["controller_vendorID"] as? String
            c.productID = p["controller_productID"] as? String
            c.profiles = profiles(p["controller_supportedServices"] as? String)
        }
        var devices: [BTDevice] = []
        for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
            for entry in top[key] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let d = value as? [String: Any] else { continue }
                    var dev = BTDevice(name: name)
                    dev.connected = connected
                    dev.address = d["device_address"] as? String
                    dev.minorType = d["device_minorType"] as? String
                    dev.vendorID = hex(d["device_vendorID"] as? String)
                    dev.productID = hex(d["device_productID"] as? String)
                    dev.firmware = d["device_firmwareVersion"] as? String
                    dev.rssi = (d["device_rssi"] as? String).flatMap { Int($0) } ?? d["device_rssi"] as? Int
                    dev.profiles = profiles(d["device_services"] as? String)
                    for (k, v) in d where k.hasPrefix("device_batteryLevel") {
                        guard let s = v as? String, let pct = Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { continue }
                        let suffix = String(k.dropFirst("device_batteryLevel".count))
                        dev.batteries.append(BTBattery(label: suffix.isEmpty || suffix == "Main" ? "Battery" : suffix, percent: pct))
                    }
                    let order = ["Left": 0, "Right": 1, "Case": 2, "Battery": 3]
                    dev.batteries.sort { (order[$0.label] ?? 9) < (order[$1.label] ?? 9) }
                    devices.append(dev)
                }
            }
        }
        return (c, devices)
    }

    /// "0x980019 < HFP AVRCP A2DP AACP GATT ACL >" → ["HFP", "AVRCP", …]
    static func profiles(_ s: String?) -> [String] {
        guard let s, let a = s.firstIndex(of: "<"), let b = s.lastIndex(of: ">"), a < b else { return [] }
        return s[s.index(after: a)..<b].split(separator: " ").map(String.init)
    }

    static func hex(_ s: String?) -> Int? {
        guard let s else { return nil }
        return Int(s.hasPrefix("0x") ? String(s.dropFirst(2)) : s, radix: 16)
    }
}

// MARK: - Names

enum BluetoothNames {
    /// Bluetooth SIG company identifiers (also used for BLE manufacturer data). Deliberately
    /// short — unknown is better than wrong.
    static func company(_ id: Int) -> String? {
        switch id {
        case 0x0002: "Intel"
        case 0x0006: "Microsoft"
        case 0x000A: "Qualcomm (CSR)"
        case 0x000D: "Texas Instruments"
        case 0x000F: "Broadcom"
        case 0x001D: "Qualcomm"
        case 0x0046: "MediaTek"
        case 0x004C: "Apple"
        case 0x0057: "Harman"
        case 0x0059: "Nordic Semiconductor"
        case 0x0075: "Samsung"
        case 0x0087: "Garmin"
        case 0x009E: "Bose"
        case 0x00C4: "LG Electronics"
        case 0x00E0: "Google"
        case 0x012D: "Sony"
        case 0x0171: "Amazon"
        case 0x027D: "Huawei"
        case 0x02E5: "Espressif"
        case 0x038F: "Xiaomi"
        case 0x046D: "Logitech"       // USB vendor ID, reported by Logitech's devices
        case 0x0499: "Ruuvi"
        case 0x05A7: "Sonos"
        default: nil
        }
    }

    /// What a profile abbreviation means, for chips and tooltips.
    static func profile(_ p: String) -> String? {
        switch p {
        case "A2DP": "High-quality stereo audio streaming"
        case "AVRCP": "Remote control — play, pause, volume"
        case "HFP": "Hands-free calls (microphone + mono audio)"
        case "HSP": "Headset (basic calls)"
        case "HID": "Keyboards, mice and game controllers"
        case "LEA": "LE Audio — the newer low-energy audio standard (LC3 codec)"
        case "GATT": "Bluetooth Low Energy attribute protocol — sensors, batteries, settings"
        case "AACP": "Apple's accessory protocol (AirPods features)"
        case "SerialPort": "Serial port emulation"
        case "SCO": "Synchronous voice link used for calls"
        case "ACL": "Asynchronous data link"
        case "BLE": "Bluetooth Low Energy"
        case "PAN": "Personal area networking"
        case "OBEX", "FTP": "File transfer"
        default: nil
        }
    }

    /// Well-known 16-bit GATT service UUIDs seen in advertisements.
    static func service(_ uuid: CBUUID) -> String? {
        switch uuid.uuidString.uppercased() {
        case "180F": "Battery"
        case "180A": "Device information"
        case "1812": "HID"
        case "180D": "Heart rate"
        case "1816": "Cycling speed"
        case "1818": "Cycling power"
        case "1826": "Fitness machine"
        case "1809": "Thermometer"
        case "181A": "Environmental sensing"
        case "1810": "Blood pressure"
        case "181C": "User data"
        case "FE2C": "Google Fast Pair"
        case "FEAA": "Eddystone beacon"
        case "FD6F": "Exposure Notification"
        case "FEED", "FEEC": "Tile"
        case "FE95": "Xiaomi"
        case "FE9F": "Google"
        default: nil
        }
    }
}

// MARK: - Nearby devices (CoreBluetooth scan)

struct BLEAdvertiser: Identifiable {
    let id: UUID                      // macOS hides the radio address; this is a stable per-Mac ID
    var name: String?
    var rssi: Double                  // smoothed
    var lastRSSI: Int
    var txPower: Int?
    var connectable: Bool?
    var companyID: Int?
    var manufacturerData: Data?
    var services: [CBUUID] = []
    var firstSeen: Date
    var lastSeen: Date
    var packets = 1

    var company: String? { companyID.flatMap(BluetoothNames.company) }

    /// A best-effort description from the advertisement contents.
    var kind: (label: String, symbol: String) {
        if let d = manufacturerData, d.count >= 3, companyID == 0x004C {
            switch d[2] {
            case 0x02: return ("iBeacon", "sensor.tag.radiowaves.forward")
            case 0x05: return ("AirDrop", "airplayaudio")
            case 0x07: return ("AirPods / Beats", "airpodspro")
            case 0x09: return ("AirPlay target", "airplayvideo")
            case 0x0A: return ("AirPlay source", "airplayvideo")
            case 0x0C: return ("Handoff", "arrow.left.arrow.right")
            case 0x0D: return ("Instant Hotspot (target)", "personalhotspot")
            case 0x0E: return ("Instant Hotspot", "personalhotspot")
            case 0x0F: return ("Nearby Action", "iphone.radiowaves.left.and.right")
            case 0x10: return ("Apple device nearby", "iphone")
            case 0x12: return ("Find My network", "location.circle")
            default: return ("Apple device", "applelogo")
            }
        }
        if companyID == 0x0006 { return ("Microsoft device (Swift Pair)", "pc") }
        let s = Set(services.map { $0.uuidString.uppercased() })
        if s.contains("FEAA") { return ("Eddystone beacon", "sensor.tag.radiowaves.forward") }
        if s.contains("FE2C") { return ("Google Fast Pair", "headphones") }
        if s.contains("FEED") || s.contains("FEEC") { return ("Tile tracker", "tag") }
        if s.contains("FD6F") { return ("Exposure Notification", "cross.case") }
        if s.contains("180D") { return ("Heart-rate sensor", "heart") }
        if s.contains("1812") { return ("Keyboard / mouse / controller", "keyboard") }
        if companyID == 0x0075 { return ("Samsung device", "iphone") }
        if companyID == 0x00E0 { return ("Google device", "iphone") }
        return (name == nil ? "Unknown device" : "Device", "dot.radiowaves.right")
    }

    /// Log-distance estimate from a 1 m reference of −59 dBm (or the advertised Tx power).
    var distanceMeters: Double {
        let ref = Double(txPower.map { $0 - 41 } ?? -59)
        return pow(10, (ref - rssi) / 20)
    }
}

/// Scans for Bluetooth Low Energy advertisements. Created only when the user starts a
/// scan — that's when macOS asks for Bluetooth permission.
@MainActor
@Observable
final class BLEScanner: NSObject, CBCentralManagerDelegate {
    enum State: Equatable { case idle, starting, scanning, poweredOff, denied, unsupported }

    private(set) var state = State.idle
    private(set) var devices: [UUID: BLEAdvertiser] = [:]
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var pending: [UUID: BLEAdvertiser] = [:]
    @ObservationIgnored private var flush: Timer?

    var isScanning: Bool { state == .scanning || state == .starting }
    /// Started, but macOS is still showing (or about to show) the permission dialog.
    var awaitingPermission: Bool { state == .starting && CBManager.authorization == .notDetermined }

    static var permissionDenied: Bool {
        CBManager.authorization == .denied || CBManager.authorization == .restricted
    }

    func start() {
        if Self.permissionDenied { state = .denied; return }
        state = .starting
        if let central, central.state == .poweredOn { begin(central); return }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
    }

    func stop() {
        central?.stopScan()
        flush?.invalidate()
        flush = nil
        if state == .scanning || state == .starting { state = .idle }
    }

    func clear() { devices = [:]; pending = [:] }

    private func begin(_ c: CBCentralManager) {
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        state = .scanning
        // Advertisements arrive many times a second; publish them in batches.
        flush?.invalidate()
        flush = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let cutoff = Date().addingTimeInterval(-90)
                var d = self.devices
                for (k, v) in self.pending { d[k] = v }
                self.pending = [:]
                d = d.filter { $0.value.lastSeen > cutoff }
                self.devices = d
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let s = central.state
        MainActor.assumeIsolated {
            switch s {
            case .poweredOn: if state == .starting { begin(central) }
            case .poweredOff: state = .poweredOff; flush?.invalidate()
            case .unauthorized: state = .denied
            case .unsupported: state = .unsupported
            default: break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        guard rssi < 0, rssi > -110 else { return }     // 127 = "not available"
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + ((advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?.keys.map { $0 } ?? [])
        let tx = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        MainActor.assumeIsolated {
            let now = Date()
            var a = pending[id] ?? devices[id] ?? BLEAdvertiser(id: id, rssi: Double(rssi), lastRSSI: rssi, firstSeen: now, lastSeen: now, packets: 0)
            a.rssi = a.packets == 0 ? Double(rssi) : a.rssi * 0.8 + Double(rssi) * 0.2
            a.lastRSSI = rssi
            a.lastSeen = now
            a.packets += 1
            if let name { a.name = name }
            if let mfg, mfg.count >= 2 {
                a.manufacturerData = mfg
                a.companyID = Int(mfg[0]) | Int(mfg[1]) << 8
            }
            if !services.isEmpty { a.services = Array(Set(a.services + services)) }
            if let tx { a.txPower = tx }
            if let connectable { a.connectable = connectable }
            pending[id] = a
        }
    }
}
