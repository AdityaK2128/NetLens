import Foundation
import Observation
import CoreLocation
import SwiftUI

enum NavSection: String, CaseIterable, Identifiable, Hashable {
    case overview, globe
    case connections, bandwidth, ports
    case ping, traceroute, dns, http, speed
    case interfaces, wifi, routing, neighbors
    case capture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .globe: "Globe"
        case .connections: "Connections"
        case .bandwidth: "Bandwidth"
        case .ports: "Listening Ports"
        case .ping: "Ping"
        case .traceroute: "Traceroute"
        case .dns: "DNS"
        case .http: "HTTP & TLS"
        case .speed: "Speed & Quality"
        case .interfaces: "Interfaces"
        case .wifi: "Wi-Fi"
        case .routing: "Routing Table"
        case .neighbors: "LAN & Neighbors"
        case .capture: "Packet Capture"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "point.topleft.down.to.point.bottomright.curvepath"
        case .globe: "globe.americas"
        case .connections: "arrow.left.arrow.right"
        case .bandwidth: "dial.medium"
        case .ports: "door.left.hand.open"
        case .ping: "waveform.path.ecg"
        case .traceroute: "point.3.filled.connected.trianglepath.dotted"
        case .dns: "character.book.closed"
        case .http: "lock.shield"
        case .speed: "gauge.with.dots.needle.67percent"
        case .interfaces: "rectangle.connected.to.line.below"
        case .wifi: "wifi"
        case .routing: "signpost.right.and.left"
        case .neighbors: "house"
        case .capture: "waveform.badge.magnifyingglass"
        }
    }

    static let groups: [(String, [NavSection])] = [
        ("See", [.overview, .globe]),
        ("Live", [.connections, .bandwidth, .ports]),
        ("Diagnose", [.ping, .traceroute, .dns, .http, .speed]),
        ("Local network", [.interfaces, .wifi, .routing, .neighbors]),
        ("Capture", [.capture]),
    ]
}

/// Root state: owns the always-on monitors and the shared picture of "where am I on
/// the network" that several screens draw from.
@MainActor
@Observable
final class AppModel {
    var selection: NavSection? = .overview {
        didSet { UserDefaults.standard.set(selection?.rawValue, forKey: "lastSection") }
    }

    private(set) var net = GlobalNetState()
    private(set) var interfaces: [NetInterface] = []
    private(set) var wifi = WiFiStatus()
    private(set) var wifiHistory: [(time: Date, rssi: Int?, noise: Int?, rate: Double?)] = []
    private(set) var locationAuth: CLAuthorizationStatus = .notDetermined
    private(set) var publicV4: String?
    private(set) var publicV6: String?
    private(set) var selfGeo: GeoInfo?
    private(set) var natWAN: String?
    private(set) var natPMPError: String?
    private(set) var nat = NATAnalysis()
    private(set) var gatewayMAC: String?
    private(set) var lastNetworkChange = Date()
    private(set) var refreshingPublic = false
    private(set) var localNetwork: LocalNetworkAccess.Status = .unknown

    let pings = PingMonitor()
    let connections = ConnectionMonitor()
    let throughput = ThroughputMonitor()
    let pathTrace = TraceSession()
    let shaper = BandwidthShaper()
    let names = NameCache()

    /// Cross-screen hand-off: "trace this", "ping that", "look this up".
    var pendingTarget: [NavSection: String] = [:]

    func open(_ section: NavSection, target: String? = nil) {
        if let target { pendingTarget[section] = target }
        selection = section
    }

    func takeTarget(_ section: NavSection) -> String? {
        pendingTarget.removeValue(forKey: section)
    }

    @ObservationIgnored private let wifiService = WiFiService()
    @ObservationIgnored private var watcher: NetworkChangeWatcher?
    @ObservationIgnored private var wifiTask: Task<Void, Never>?
    @ObservationIgnored private var booted = false

    var primaryInterface: NetInterface? {
        guard let name = net.primaryInterface else { return nil }
        return interfaces.first { $0.name == name }
    }
    var primaryIPv4: String? { primaryInterface?.ipv4.first?.address }
    var primaryIPv6: String? { primaryInterface?.ipv6.first { $0.scope == .global }?.address }
    var viaTunnel: Bool { net.primaryInterface?.hasPrefix("utun") == true || net.primaryInterface?.hasPrefix("ipsec") == true }
    var isOnline: Bool { net.primaryInterface != nil }

    /// The physical link actually carrying traffic (Wi-Fi vs Ethernet), even under a VPN.
    var physicalInterface: NetInterface? {
        if let p = primaryInterface, p.kind == .wifi || p.kind == .ethernet { return p }
        return interfaces.first { ($0.kind == .wifi || $0.kind == .ethernet) && $0.isActive && !$0.ipv4.isEmpty }
    }

    func bootstrap() {
        guard !booted else { return }
        booted = true
        // `-NLSection globe` on the command line, else the last section used.
        if let s = UserDefaults.standard.string(forKey: "NLSection") ?? UserDefaults.standard.string(forKey: "lastSection"),
           let sec = NavSection(rawValue: s) {
            selection = sec
            if let t = UserDefaults.standard.string(forKey: "NLTarget") { pendingTarget[sec] = t }
        }
        wifiService.onAuthorizationChange = { [weak self] status in
            Task { @MainActor in
                self?.locationAuth = status
                self?.refreshWiFi()
            }
        }
        locationAuth = wifiService.authorization
        watcher = NetworkChangeWatcher { [weak self] in
            Task { @MainActor in self?.networkChanged() }
        }
        connections.onSample = { [weak self] in
            guard let self else { return }
            self.shaper.ingest(self.connections)
            // Reverse-DNS for every remote address currently on screen in Connections.
            let remotes = Set(self.connections.activeSockets.compactMap(\.remoteAddress))
            self.names.prefetch(remotes.prefix(400))
        }
        refreshLocal()
        throughput.start()
        pings.start()
        connections.start()
        wifiTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshWiFi()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        Task { await refreshPublic() }
        Task { await checkLocalNetwork() }
    }

    func checkLocalNetwork() async {
        localNetwork = await LocalNetworkAccess.check()
    }

    func requestLocation() { wifiService.requestLocationAccess() }

    private func networkChanged() {
        lastNetworkChange = Date()
        refreshLocal()
        Task { await refreshPublic() }
    }

    func refreshLocal() {
        net = SystemNetwork.read()
        interfaces = InterfaceReader.read()
        pings.setGateway(net.router)
        refreshWiFi()
        Task { await refreshGatewayMAC() }
    }

    func refreshWiFi() {
        let s = wifiService.status()
        if s != wifi { wifi = s }
        if s.powerOn {
            wifiHistory.append((Date(), s.rssi, s.noise, s.txRate))
            if wifiHistory.count > 300 { wifiHistory.removeFirst(wifiHistory.count - 300) }
        }
    }

    /// CoreWLAN active scan (takes a few seconds; runs off the main thread).
    func scanWiFi() async -> Result<[WiFiNetwork], Error> {
        let service = wifiService
        return await Task.detached(priority: .userInitiated) {
            do { return .success(try service.scan()) } catch { return .failure(error) }
        }.value
    }

    private func refreshGatewayMAC() async {
        guard let gw = net.router else { gatewayMAC = nil; return }
        let table = await Neighbors.arp()
        gatewayMAC = table.first { $0.ip == gw && $0.mac != nil }?.mac
    }

    func refreshPublic() async {
        refreshingPublic = true
        defer { refreshingPublic = false }
        async let v4 = PublicIP.fetch(v6: false)
        async let v6 = PublicIP.fetch(v6: true)
        async let geo = GeoIPService.shared.selfLocation(force: true)
        var pmp: Result<String, PublicIP.NATPMPError>? = nil
        if let gw = net.router { pmp = await PublicIP.natPMPExternalAddress(gateway: gw) }
        let (a, b, g) = await (v4, v6, geo)
        publicV4 = a ?? g?.ip
        publicV6 = b
        selfGeo = g
        switch pmp {
        case .success(let ip): natWAN = ip; natPMPError = nil
        case .failure(let e): natWAN = nil; natPMPError = e.description
        case nil: natWAN = nil; natPMPError = "no gateway"
        }
        // Background trace to a well-known anycast address for the path view + NAT heuristics.
        if pathTrace.state != .running && pathTrace.state != .resolving {
            pathTrace.start("1.1.1.1")
            try? await Task.sleep(for: .seconds(2.5))
        }
        analyseNAT()
    }

    func analyseNAT() {
        let hops = pathTrace.visibleHops.compactMap(\.address)
        nat = NATAnalysis.analyse(localIP: primaryIPv4, gateway: net.router, publicIP: publicV4,
                                  natPMP: natWAN, earlyHops: hops, viaTunnel: viaTunnel)
    }
}
