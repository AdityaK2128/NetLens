import Foundation

struct Neighbor: Identifiable, Hashable {
    var id: String { ip + "|" + interface }
    let ip: String
    var mac: String?
    let interface: String
    var isV6: Bool
    var permanent: Bool
    var expires: String?
    var isRouter: Bool
    var state: String?
    var hostname: String?
    var services: [String] = []

    var vendor: String? { mac.flatMap(Neighbors.vendor) }
    var isRandomizedMAC: Bool { mac.map(Neighbors.isLocallyAdministered) ?? false }
    var isMulticast: Bool { IP.scope(ip) == .multicast || ip.hasSuffix(".255") }
}

enum Neighbors {
    /// IPv4 neighbours from the ARP cache.
    static func arp() async -> [Neighbor] {
        let r = await Shell.run("/usr/sbin/arp", ["-an"], timeout: 5)
        var out: [Neighbor] = []
        for line in r.stdout.split(separator: "\n") {
            // ? (192.168.1.1) at a:b:c:d:e:f on en0 ifscope [ethernet]
            let s = String(line)
            guard let lp = s.firstIndex(of: "("), let rp = s.firstIndex(of: ")") else { continue }
            let ip = String(s[s.index(after: lp)..<rp])
            let tokens = s.split(separator: " ").map(String.init)
            var mac: String? = nil
            var iface = ""
            if let at = tokens.firstIndex(of: "at"), at + 1 < tokens.count {
                let m = tokens[at + 1]
                mac = m.contains(":") ? normaliseMAC(m) : nil
            }
            if let on = tokens.firstIndex(of: "on"), on + 1 < tokens.count { iface = tokens[on + 1] }
            let permanent = s.contains("permanent")
            var expires: String? = nil
            if let ex = tokens.firstIndex(of: "expires"), ex + 2 < tokens.count { expires = tokens[ex + 2] }
            out.append(Neighbor(ip: ip, mac: mac, interface: iface, isV6: false, permanent: permanent,
                                expires: expires, isRouter: false, state: mac == nil ? "incomplete" : nil))
        }
        return out
    }

    /// IPv6 neighbours from the NDP cache.
    static func ndp() async -> [Neighbor] {
        let r = await Shell.run("/usr/sbin/ndp", ["-an"], timeout: 5)
        var out: [Neighbor] = []
        for line in r.stdout.split(separator: "\n").dropFirst() {
            let t = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard t.count >= 4 else { continue }
            let ip = t[0]
            let mac = t[1].contains(":") && !t[1].hasPrefix("(") ? normaliseMAC(t[1]) : nil
            let iface = t[2]
            let expire = t[3]
            let state = t.count > 4 ? t[4] : nil
            let flags = t.count > 5 ? t[5] : ""
            out.append(Neighbor(ip: ip, mac: mac, interface: iface, isV6: true, permanent: expire == "permanent",
                                expires: expire == "permanent" ? nil : expire, isRouter: flags.contains("R"),
                                state: ndpState(state)))
        }
        return out
    }

    static func ndpState(_ s: String?) -> String? {
        switch s {
        case "R": "reachable"
        case "S": "stale"
        case "D": "delay"
        case "P": "probe"
        case "I": "incomplete"
        case "N": "nostate"
        case "W": "waitdelete"
        default: s
        }
    }

    /// "a:b:c:d:e:f" → "0a:0b:0c:0d:0e:0f"
    static func normaliseMAC(_ m: String) -> String {
        m.split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":").lowercased()
    }

    /// U/L bit set → locally administered, almost always a privacy-randomised address.
    static func isLocallyAdministered(_ mac: String) -> Bool {
        guard let first = mac.split(separator: ":").first, let b = UInt8(first, radix: 16) else { return false }
        return b & 0x02 != 0 && b & 0x01 == 0
    }

    static func vendor(_ mac: String) -> String? {
        let parts = mac.lowercased().split(separator: ":")
        guard parts.count >= 3 else { return nil }
        if isLocallyAdministered(mac) {
            if parts[0] == "02" && parts[1] == "42" { return "Docker (virtual)" }
            return nil
        }
        let oui = parts.prefix(3).joined(separator: ":")
        return ouiTable[oui]
    }

    /// Small, deliberately conservative OUI table — common home-lab and virtualisation
    /// vendors. Unknown is better than wrong.
    static let ouiTable: [String: String] = {
        var t: [String: String] = [:]
        func add(_ vendor: String, _ ouis: [String]) { for o in ouis { t[o] = vendor } }
        add("VMware", ["00:50:56", "00:0c:29", "00:05:69", "00:1c:14"])
        add("Parallels", ["00:1c:42"])
        add("VirtualBox", ["08:00:27", "0a:00:27"])
        add("QEMU / KVM", ["52:54:00"])
        add("Hyper-V", ["00:15:5d"])
        add("Xen", ["00:16:3e"])
        add("Raspberry Pi", ["b8:27:eb", "dc:a6:32", "e4:5f:01", "d8:3a:dd", "28:cd:c1", "2c:cf:67"])
        add("Espressif (ESP32/ESP8266)", ["24:0a:c4", "30:ae:a4", "84:f3:eb", "a4:cf:12", "24:6f:28", "ec:fa:bc",
                                          "5c:cf:7f", "18:fe:34", "60:01:94", "7c:9e:bd", "8c:aa:b5", "bc:dd:c2",
                                          "c4:4f:33", "cc:50:e3", "3c:71:bf", "98:f4:ab", "48:3f:da", "ac:67:b2"])
        add("Ubiquiti", ["00:15:6d", "00:27:22", "04:18:d6", "24:a4:3c", "44:d9:e7", "68:72:51", "78:8a:20",
                         "80:2a:a8", "b4:fb:e4", "dc:9f:db", "f0:9f:c2", "fc:ec:da", "74:83:c2", "e0:63:da"])
        add("Synology", ["00:11:32"])
        add("Philips Hue", ["00:17:88", "ec:b5:fa"])
        add("Sonos", ["00:0e:58", "5c:aa:fd", "94:9f:3e", "b8:e9:37", "48:a6:b8", "78:28:ca"])
        add("Cisco", ["00:00:0c"])
        add("Apple", ["00:03:93", "00:0a:27", "00:0a:95", "00:1e:c2", "00:25:00", "f0:18:98", "a4:5e:60",
                      "ac:bc:32", "3c:07:54", "00:1b:63", "00:23:12", "88:66:5a", "70:56:81"])
        add("Nest / Google", ["18:b4:30", "64:16:66"])
        return t
    }()
}
