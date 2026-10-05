import Foundation
import AppKit

/// `NetLens -NLDiag /path/report.txt` writes a short report about what macOS lets this
/// app see on the local network, then quits. Used for troubleshooting permissions.
@MainActor
enum Diagnostics {
    static func runIfRequested(_ model: AppModel) {
        guard let path = UserDefaults.standard.string(forKey: "NLDiag") else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            var lines: [String] = []
            lines.append("primary \(model.net.primaryInterface ?? "-") router \(model.net.router ?? "-"); physical \(model.physicalInterface?.name ?? "-") lan router \(model.lanRouter ?? "-")")
            lines.append("local network check: \(await LocalNetworkAccess.check())")
            for host in [model.lanRouter, UserDefaults.standard.string(forKey: "NLDiagHost")].compactMap({ $0 }) {
                let p = await Pinger.shared.ping(host, timeout: 1)
                lines.append("ping \(host): \(p.rtt.map { "\($0) ms" } ?? p.error ?? "?")")
            }
            let v4 = Neighbors.linkLayerTable(family: AF_INET)
            lines.append("arp in-process: \(v4.count) rows, \(v4.filter { $0.mac != nil }.count) with MAC")
            let v6 = Neighbors.linkLayerTable(family: AF_INET6)
            lines.append("ndp in-process: \(v6.count) rows, \(v6.filter { $0.mac == "02:00:00:00:00:00" }.count) redacted")
            if let a = model.physicalInterface?.ipv4.first, let m = a.netmask {
                let r = await SubnetSweep.run(address: a.address, netmask: m) { _ in }
                lines.append("sweep \(a.address)/\(m): " + r.sorted { $0.key < $1.key }.map { "\($0.key) [\($0.value.method) \(Int($0.value.rtt)) ms]" }.joined(separator: ", "))
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
