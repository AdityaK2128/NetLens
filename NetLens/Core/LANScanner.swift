import Foundation
import Observation
import Darwin

struct BonjourService: Identifiable, Hashable {
    var id: String { "\(name)|\(type)" }
    let name: String
    let type: String          // "_airplay._tcp."
    var hostName: String?
    var addresses: [String] = []
    var port: Int = 0
    var txt: [String: String] = [:]

    var shortType: String {
        type.replacingOccurrences(of: "._tcp.", with: "").replacingOccurrences(of: "._udp.", with: "").replacingOccurrences(of: "_", with: "")
    }
}

struct LANDevice: Identifiable, Hashable {
    var id: String { mac ?? ips.first ?? name }
    var name: String
    var ips: [String] = []
    var mac: String?
    var vendor: String?
    var hostname: String?
    var services: [BonjourService] = []
    var rtt: Double?
    var isRouter = false
    var isSelf = false
    var randomizedMAC = false
    var model: String?

    var kind: (String, String) {
        let t = Set(services.map(\.shortType))
        if isSelf { return ("This Mac", "laptopcomputer") }
        if isRouter { return ("Router", "wifi.router") }
        if t.contains("ipp") || t.contains("printer") || t.contains("pdl-datastream") || t.contains("uscan") { return ("Printer / scanner", "printer") }
        if t.contains("googlecast") { return ("Chromecast / Google TV", "tv") }
        if t.contains("amzn-wplay") { return ("Fire TV", "tv") }
        if t.contains("androidtvremote2") { return ("Android TV", "tv") }
        if t.contains("sonos") || t.contains("spotify-connect") { return ("Speaker", "hifispeaker") }
        if t.contains("hue") { return ("Hue bridge", "lightbulb") }
        if t.contains("hap") || t.contains("matter") || t.contains("matterc") { return ("Smart-home accessory", "homekit") }
        if t.contains("home-assistant") { return ("Home Assistant", "house") }
        if t.contains("esphomelib") { return ("ESPHome device", "cpu") }
        if t.contains("airplay") || t.contains("raop") {
            if let m = model?.lowercased() {
                if m.contains("appletv") { return ("Apple TV", "appletv") }
                if m.contains("audioaccessory") { return ("HomePod", "homepod") }
                if m.contains("mac") { return ("Mac", "desktopcomputer") }
            }
            return ("AirPlay receiver", "airplayvideo")
        }
        if t.contains("smb") || t.contains("afpovertcp") || t.contains("adisk") || t.contains("nfs") { return ("File server / NAS", "externaldrive.connected.to.line.below") }
        if t.contains("companion-link") || t.contains("apple-mobdev2") { return ("Apple device", "iphone") }
        if t.contains("ssh") || t.contains("sftp-ssh") || t.contains("rfb") || t.contains("workstation") { return ("Computer", "desktopcomputer") }
        if vendor?.contains("Raspberry") == true { return ("Raspberry Pi", "cpu") }
        if vendor?.contains("Espressif") == true { return ("IoT (ESP32/8266)", "sensor") }
        if vendor?.contains("VMware") == true || vendor?.contains("Parallels") == true || vendor?.contains("QEMU") == true { return ("Virtual machine", "shippingbox") }
        if randomizedMAC { return ("Phone / tablet (private MAC)", "iphone.gen3") }
        return ("Device", "questionmark.square.dashed")
    }
}

/// Browses every advertised Bonjour service type on the LAN and resolves each instance.
@MainActor
@Observable
final class BonjourScanner: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private(set) var services: [String: BonjourService] = [:]
    private(set) var types: Set<String> = []
    private(set) var running = false

    @ObservationIgnored private var typeBrowser: NetServiceBrowser?
    @ObservationIgnored private var browsers: [String: NetServiceBrowser] = [:]
    @ObservationIgnored private var pending: [NetService] = []

    func start() {
        guard !running else { return }
        running = true
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: "_services._dns-sd._udp.", inDomain: "local.")
        typeBrowser = b
    }

    func stop() {
        typeBrowser?.stop()
        browsers.values.forEach { $0.stop() }
        pending.forEach { $0.stop() }
        typeBrowser = nil
        browsers = [:]
        pending = []
        running = false
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let name = service.name, type = service.type
        MainActor.assumeIsolated {
            if browser === typeBrowser {
                // meta-query result: name="_airplay", type="_tcp.local." → "_airplay._tcp."
                let proto = type.hasPrefix("_tcp") ? "_tcp." : "_udp."
                let full = "\(name).\(proto)"
                guard !types.contains(full) else { return }
                types.insert(full)
                let b = NetServiceBrowser()
                b.delegate = self
                b.searchForServices(ofType: full, inDomain: "local.")
                browsers[full] = b
            } else {
                let key = "\(name)|\(type)"
                if services[key] == nil { services[key] = BonjourService(name: name, type: type) }
                service.delegate = self
                pending.append(service)
                service.resolve(withTimeout: 5)
            }
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let key = "\(service.name)|\(service.type)"
        MainActor.assumeIsolated { _ = services.removeValue(forKey: key) }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let key = "\(sender.name)|\(sender.type)"
        let host = sender.hostName
        let port = sender.port
        let addrs: [String] = (sender.addresses ?? []).compactMap { data -> String? in
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
                guard let base = raw.baseAddress else { return nil }
                return SockAddr.string(base.assumingMemoryBound(to: sockaddr.self))
            }
        }
        var txt: [String: String] = [:]
        if let d = sender.txtRecordData() {
            for (k, v) in NetService.dictionary(fromTXTRecord: d) { txt[k] = String(decoding: v, as: UTF8.self) }
        }
        MainActor.assumeIsolated {
            var s = services[key] ?? BonjourService(name: sender.name, type: sender.type)
            s.hostName = host
            s.port = port
            s.addresses = addrs
            s.txt = txt
            services[key] = s
            pending.removeAll { $0 === sender }
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        MainActor.assumeIsolated { pending.removeAll { $0 === sender } }
    }
}

enum SubnetSweep {
    /// ICMP-echo every host in the local IPv4 subnet (capped at 1024 hosts). Also has
    /// the side-effect of populating the ARP cache, so firewalled hosts appear too.
    static func run(address: String, netmask: String, progress: @escaping @MainActor (Double) -> Void) async -> [String: Double] {
        guard let a = IP.v4Value(address), let m = IP.v4Value(netmask) else { return [:] }
        let net = a & m
        let bcast = net | ~m
        guard bcast > net + 1, bcast - net <= 1025 else { return [:] }
        let hosts = (net + 1..<bcast).filter { $0 != a }.map(IP.v4String)
        var results: [String: Double] = [:]
        var done = 0
        let batch = 48
        for chunk in stride(from: 0, to: hosts.count, by: batch) {
            let slice = hosts[chunk..<min(hosts.count, chunk + batch)]
            await withTaskGroup(of: (String, Double?).self) { g in
                for h in slice { g.addTask { (h, await Pinger.shared.ping(h, timeout: 0.9, payloadSize: 16).rtt) } }
                for await (h, rtt) in g {
                    if let rtt { results[h] = rtt }
                    done += 1
                }
            }
            let p = Double(done) / Double(hosts.count)
            await progress(p)
        }
        return results
    }
}
