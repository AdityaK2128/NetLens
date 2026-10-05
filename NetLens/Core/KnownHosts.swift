import Foundation

/// Friendly names for well-known infrastructure addresses.
enum KnownHosts {
    static let resolvers: [String: String] = [
        "1.1.1.1": "Cloudflare", "1.0.0.1": "Cloudflare", "2606:4700:4700::1111": "Cloudflare", "2606:4700:4700::1001": "Cloudflare",
        "8.8.8.8": "Google", "8.8.4.4": "Google", "2001:4860:4860::8888": "Google", "2001:4860:4860::8844": "Google",
        "9.9.9.9": "Quad9", "149.112.112.112": "Quad9", "2620:fe::fe": "Quad9",
        "208.67.222.222": "OpenDNS", "208.67.220.220": "OpenDNS",
        "94.140.14.14": "AdGuard", "94.140.15.15": "AdGuard",
        "76.76.2.0": "Control D", "45.90.28.0": "NextDNS",
        "100.100.100.100": "Tailscale MagicDNS",
        "103.86.96.100": "NordVPN DNS", "103.86.99.100": "NordVPN DNS",
    ]

    static func resolverName(_ ip: String, gateway: String?) -> String? {
        if let n = resolvers[ip] { return n }
        if ip == gateway { return "Your router" }
        if ip.hasPrefix("fd7a:115c:a1e0") { return "Tailscale" }
        switch IP.scope(ip) {
        case .privateNet, .linkLocal, .uniqueLocal: return "Local network"
        case .cgnat: return "Carrier / VPN"
        default: return nil
        }
    }
}
