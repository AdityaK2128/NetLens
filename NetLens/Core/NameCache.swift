import Foundation
import Observation

/// Observable cache of reverse-DNS names and GeoIP for addresses on screen.
///
/// Views only *read* from it. Lookups are started from model code (after each
/// connection sample) and their answers are applied in batches, so a table full of
/// rows never mutates state while it is being laid out.
@MainActor
@Observable
final class NameCache {
    private(set) var names: [String: String] = [:]
    private(set) var geo: [String: GeoInfo] = [:]
    @ObservationIgnored private var requestedNames: Set<String> = []
    @ObservationIgnored private var requestedGeo: Set<String> = []
    @ObservationIgnored private var pendingNames: [String: String] = [:]
    @ObservationIgnored private var pendingGeo: [String: GeoInfo] = [:]
    @ObservationIgnored private var flushScheduled = false

    func name(_ ip: String?) -> String? { ip.flatMap { names[$0] } }
    func geoInfo(_ ip: String?) -> GeoInfo? { ip.flatMap { geo[$0] } }

    /// Start lookups for a batch of addresses (call from model code, never from a view body).
    func prefetch(_ ips: some Sequence<String>, geo wantGeo: Bool = false) {
        for ip in ips {
            request(ip)
            if wantGeo { requestGeo(ip) }
        }
    }

    func request(_ ip: String) {
        guard !requestedNames.contains(ip) else { return }
        requestedNames.insert(ip)
        Task {
            if let n = await ReverseDNS.shared.lookup(IP.stripScope(ip)) {
                pendingNames[ip] = n
                scheduleFlush()
            }
        }
    }

    func requestGeo(_ ip: String) {
        let key = IP.stripScope(ip)
        guard !requestedGeo.contains(key), IP.isGlobal(key) else { return }
        requestedGeo.insert(key)
        Task {
            if let g = await GeoIPService.shared.info(for: key) {
                pendingGeo[ip] = g
                scheduleFlush()
            }
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            flushScheduled = false
            if !pendingNames.isEmpty { names.merge(pendingNames) { _, new in new }; pendingNames = [:] }
            if !pendingGeo.isEmpty { geo.merge(pendingGeo) { _, new in new }; pendingGeo = [:] }
        }
    }
}

/// Well-known port → service name (IANA + macOS specifics).
enum Services {
    static let tcp: [UInt16: String] = [
        20: "ftp-data", 21: "ftp", 22: "ssh", 23: "telnet", 25: "smtp", 53: "dns", 80: "http", 88: "kerberos",
        110: "pop3", 123: "ntp", 137: "netbios-ns", 139: "netbios-ssn", 143: "imap", 389: "ldap", 443: "https",
        445: "smb", 465: "smtps", 548: "afp", 554: "rtsp", 587: "submission", 631: "ipp (CUPS)", 853: "dns-over-tls",
        993: "imaps", 995: "pop3s", 1080: "socks", 1194: "openvpn", 1433: "mssql", 1883: "mqtt", 1900: "ssdp",
        2049: "nfs", 3000: "dev server", 3283: "Apple Remote Desktop", 3306: "mysql", 3389: "rdp", 3689: "daap (Music sharing)",
        4000: "dev server", 4200: "angular dev", 5000: "AirPlay receiver", 5173: "vite dev", 5223: "Apple push (APNs)",
        5228: "Google push (FCM)", 5353: "mDNS", 5432: "postgres", 5672: "amqp", 5900: "VNC / Screen Sharing",
        6379: "redis", 6443: "kubernetes api", 7000: "AirPlay", 7100: "AirPlay video", 8000: "http-alt", 8008: "http-alt",
        8080: "http-proxy", 8443: "https-alt", 8888: "jupyter", 9000: "dev server", 9090: "prometheus", 9100: "node exporter",
        9200: "elasticsearch", 11434: "ollama", 27017: "mongodb", 41641: "tailscale", 49152: "dynamic", 62078: "iPhone sync (lockdownd)",
    ]
    static let udp: [UInt16: String] = [
        53: "dns", 67: "dhcp server", 68: "dhcp client", 123: "ntp", 137: "netbios-ns", 138: "netbios-dgm", 443: "quic / http3",
        500: "ike (ipsec)", 1900: "ssdp (UPnP)", 3478: "stun / turn", 4500: "ipsec nat-t", 5350: "nat-pmp", 5351: "nat-pmp / pcp",
        5353: "mDNS (Bonjour)", 41641: "tailscale (WireGuard)", 51820: "wireguard", 3702: "ws-discovery", 1194: "openvpn",
    ]

    static func name(_ port: UInt16?, tcp: Bool) -> String? {
        guard let port else { return nil }
        return (tcp ? Self.tcp : Self.udp)[port] ?? (tcp ? nil : Self.tcp[port])
    }
}
