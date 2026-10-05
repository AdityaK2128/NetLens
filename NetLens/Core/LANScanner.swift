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
    /// How NetLens learned about the device: "ARP", "ping", "tcp/443", "Bonjour"…
    var seenBy: [String] = []

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
    struct Hit: Hashable {
        let rtt: Double
        let method: String     // "ping" or "tcp/443"
    }

    /// TCP ports that most devices either accept or actively refuse — both prove the
    /// host is there, even when it ignores ping (routers, phones, Windows PCs).
    static let probePorts: [UInt16] = [80, 443, 22, 445, 62078]

    /// Finds live hosts in the local IPv4 subnet (capped at 1024 addresses): an ICMP echo
    /// to every address, then a quick TCP probe of the ones that stayed silent.
    static func run(address: String, netmask: String, progress: @escaping @MainActor (Double) -> Void) async -> [String: Hit] {
        let hosts = addresses(address: address, netmask: netmask)
        guard !hosts.isEmpty else { return [:] }
        var results: [String: Hit] = [:]
        var done = 0
        let batch = 48
        for chunk in stride(from: 0, to: hosts.count, by: batch) {
            let slice = hosts[chunk..<min(hosts.count, chunk + batch)]
            await withTaskGroup(of: (String, Double?).self) { g in
                for h in slice { g.addTask { (h, await Pinger.shared.ping(h, timeout: 0.9, payloadSize: 16).rtt) } }
                for await (h, rtt) in g {
                    if let rtt { results[h] = Hit(rtt: rtt, method: "ping") }
                    done += 1
                }
            }
            await progress(0.5 * Double(done) / Double(hosts.count))
        }
        let silent = hosts.filter { results[$0] == nil }
        let tcpBatch = 24
        for chunk in stride(from: 0, to: silent.count, by: tcpBatch) {
            let slice = Array(silent[chunk..<min(silent.count, chunk + tcpBatch)])
            for (h, hit) in await tcpProbe(slice, ports: probePorts, timeout: 1.2) { results[h] = hit }
            await progress(0.5 + 0.5 * Double(min(silent.count, chunk + tcpBatch)) / Double(silent.count))
        }
        await progress(1)
        return results
    }

    /// Every host address in the subnet except our own.
    static func addresses(address: String, netmask: String) -> [String] {
        guard let a = IP.v4Value(address), let m = IP.v4Value(netmask) else { return [] }
        let net = a & m
        let bcast = net | ~m
        guard bcast > net + 1, bcast - net <= 1025 else { return [] }
        return (net + 1..<bcast).filter { $0 != a }.map(IP.v4String)
    }

    /// Non-blocking connects to every (host, port) pair at once. A completed handshake
    /// or a refusal (RST) both mean "someone is home"; silence means nothing.
    static func tcpProbe(_ hosts: [String], ports: [UInt16], timeout: Double) async -> [String: Hit] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: tcpProbeSync(hosts, ports: ports, timeout: timeout))
            }
        }
    }

    private static func tcpProbeSync(_ hosts: [String], ports: [UInt16], timeout: Double) -> [String: Hit] {
        struct Probe { let fd: Int32; let host: String; let port: UInt16 }
        var probes: [Probe] = []
        let start = DispatchTime.now().uptimeNanoseconds
        for h in hosts {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, h, &sin.sin_addr) == 1 else { continue }
            for port in ports {
                let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard fd >= 0 else { continue }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var linger = Darwin.linger(l_onoff: 1, l_linger: 0)   // close with RST, no TIME_WAIT
                setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
                sin.sin_port = port.bigEndian
                let r = withUnsafePointer(to: &sin) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if r == 0 || errno == EINPROGRESS || errno == ECONNREFUSED {
                    probes.append(Probe(fd: fd, host: h, port: port))
                } else {
                    close(fd)
                }
            }
        }
        defer { probes.forEach { close($0.fd) } }

        var hits: [String: Hit] = [:]
        var pending = Set(probes.indices)
        let deadline = start + UInt64(timeout * 1e9)
        while !pending.isEmpty {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            let order = Array(pending)
            var fds = order.map { pollfd(fd: probes[$0].fd, events: Int16(POLLOUT), revents: 0) }
            let n = poll(&fds, nfds_t(fds.count), Int32((deadline - now) / 1_000_000) + 1)
            guard n > 0 else { break }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            for (k, pfd) in fds.enumerated() where pfd.revents != 0 {
                let i = order[k]
                pending.remove(i)
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(pfd.fd, SOL_SOCKET, SO_ERROR, &err, &len)
                guard err == 0 || err == ECONNREFUSED else { continue }
                let p = probes[i]
                if hits[p.host] == nil { hits[p.host] = Hit(rtt: ms, method: "tcp/\(p.port)") }
            }
        }
        return hits
    }
}
