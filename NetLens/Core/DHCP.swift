import Foundation

struct DHCPLease {
    var server: String?
    var router: String?
    var subnetMask: String?
    var dns: [String] = []
    var domain: String?
    var leaseSeconds: Int?
    var leaseStart: Date?
    var leaseExpires: Date?
    var state: String?
    var messageType: String?
    var options: [(String, String)] = []

    /// `ipconfig getpacket` + `getsummary` (no root needed).
    static func read(interface: String) async -> DHCPLease? {
        let packet = await Shell.run("/usr/sbin/ipconfig", ["getpacket", interface], timeout: 4)
        guard packet.ok, !packet.stdout.isEmpty else { return nil }
        var lease = DHCPLease()
        var inOptions = false
        for raw in packet.stdout.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("options:") { inOptions = true; continue }
            guard inOptions, let colon = line.range(of: "): ") ?? line.range(of: "):") else { continue }
            let keyPart = line[..<colon.lowerBound]
            let key = keyPart.split(separator: " ").first.map(String.init) ?? ""
            let value = line[colon.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " {}"))
            guard !key.isEmpty, key != "end" else { continue }
            lease.options.append((key, value))
            switch key {
            case "server_identifier": lease.server = value
            case "router": lease.router = value.components(separatedBy: ", ").first
            case "subnet_mask": lease.subnetMask = value
            case "domain_name_server": lease.dns = value.components(separatedBy: ", ")
            case "domain_name": lease.domain = value
            case "lease_time":
                lease.leaseSeconds = value.hasPrefix("0x") ? Int(value.dropFirst(2), radix: 16) : Int(value)
            case "dhcp_message_type": lease.messageType = value.components(separatedBy: " ").first
            default: break
            }
        }
        let summary = await Shell.run("/usr/sbin/ipconfig", ["getsummary", interface], timeout: 4)
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yyyy HH:mm:ss"
        for raw in summary.stdout.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("LeaseStartTime : ") { lease.leaseStart = f.date(from: String(line.dropFirst(17))) }
            if line.hasPrefix("LeaseExpirationTime : ") { lease.leaseExpires = f.date(from: String(line.dropFirst(22))) }
            if line.hasPrefix("State : "), lease.state == nil { lease.state = String(line.dropFirst(8)) }
        }
        return lease
    }

    static func optionName(_ k: String) -> String {
        k.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
