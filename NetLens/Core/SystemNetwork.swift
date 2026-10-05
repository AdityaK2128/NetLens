import Foundation
import SystemConfiguration

/// Snapshot of the global network configuration from configd's dynamic store —
/// the same source `scutil` reads.
struct GlobalNetState: Equatable {
    var primaryInterface: String?
    var primaryService: String?
    var router: String?
    var routerV6: String?
    var primaryInterfaceV6: String?
    var dnsServers: [String] = []
    var searchDomains: [String] = []
    var computerName: String = Host.current().localizedName ?? "This Mac"
    var localHostName: String?
    var proxies: [String] = []
    var hardwareModel: String = ""
}

enum SystemNetwork {
    static func read() -> GlobalNetState {
        var st = GlobalNetState()
        guard let store = SCDynamicStoreCreate(nil, "NetLens.read" as CFString, nil, nil) else { return st }
        if let v4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            st.primaryInterface = v4["PrimaryInterface"] as? String
            st.primaryService = v4["PrimaryService"] as? String
            st.router = v4["Router"] as? String
        }
        if let v6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any] {
            st.routerV6 = v6["Router"] as? String
            st.primaryInterfaceV6 = v6["PrimaryInterface"] as? String
        }
        if let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] {
            st.dnsServers = dns["ServerAddresses"] as? [String] ?? []
            st.searchDomains = dns["SearchDomains"] as? [String] ?? []
        }
        if let name = SCDynamicStoreCopyComputerName(store, nil) as String? { st.computerName = name }
        st.localHostName = SCDynamicStoreCopyLocalHostName(store) as String?
        if let p = SCDynamicStoreCopyProxies(store) as? [String: Any] {
            st.proxies = describeProxies(p)
        }
        st.hardwareModel = sysctlString("hw.model") ?? ""
        return st
    }

    /// The IPv4 router of the service bound to `interface` (e.g. the Wi-Fi's own router
    /// while a VPN tunnel is the primary interface and owns the global "Router").
    static func router(forInterface interface: String) -> String? {
        guard let store = SCDynamicStoreCreate(nil, "NetLens.router" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] else { return nil }
        for k in keys {
            guard let v = SCDynamicStoreCopyValue(store, k as CFString) as? [String: Any],
                  v["InterfaceName"] as? String == interface else { continue }
            if let r = v["Router"] as? String { return r }
        }
        return nil
    }

    private static func describeProxies(_ p: [String: Any]) -> [String] {
        var out: [String] = []
        func add(_ enableKey: String, _ hostKey: String, _ portKey: String, _ label: String) {
            if (p[enableKey] as? Int) == 1, let h = p[hostKey] as? String {
                let port = (p[portKey] as? Int).map { ":\($0)" } ?? ""
                out.append("\(label) \(h)\(port)")
            }
        }
        add("HTTPEnable", "HTTPProxy", "HTTPPort", "HTTP")
        add("HTTPSEnable", "HTTPSProxy", "HTTPSPort", "HTTPS")
        add("SOCKSEnable", "SOCKSProxy", "SOCKSPort", "SOCKS")
        if (p["ProxyAutoConfigEnable"] as? Int) == 1, let url = p["ProxyAutoConfigURLString"] as? String {
            out.append("PAC \(url)")
        }
        if (p["ProxyAutoDiscoveryEnable"] as? Int) == 1 { out.append("WPAD auto-discovery") }
        return out
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var v: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return v
    }
}

/// Fires `onChange` whenever configd publishes a network change (Wi-Fi roam, VPN up,
/// cable plugged, DHCP renew…). Coalesced so bursts of keys trigger one refresh.
final class NetworkChangeWatcher {
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        var ctx = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                        retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkChangeWatcher>.fromOpaque(info).takeUnretainedValue().fire()
        }
        guard let store = SCDynamicStoreCreate(nil, "NetLens.watch" as CFString, callback, &ctx) else { return }
        let patterns = ["State:/Network/Global/.*", "State:/Network/Interface/.*/IPv4", "State:/Network/Interface/.*/IPv6",
                        "State:/Network/Interface/.*/AirPort", "State:/Network/Interface/.*/Link"] as CFArray
        SCDynamicStoreSetNotificationKeys(store, nil, patterns)
        source = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        self.store = store
    }

    private func fire() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}
