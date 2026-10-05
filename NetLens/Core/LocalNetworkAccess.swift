import Foundation
import Network
import AppKit

/// macOS (15+) hides other devices on the LAN — Bonjour, the ARP cache, unicast to
/// local addresses — until the user allows "Local Network" for the app. There's no API
/// to read that setting, but a Bonjour browse reports `PolicyDenied` when it's off.
/// Running the check also triggers the system prompt the first time.
enum LocalNetworkAccess {
    enum Status: Equatable { case unknown, allowed, denied }

    static func check(timeout: TimeInterval = 3) async -> Status {
        await withCheckedContinuation { cont in
            let browser = NWBrowser(for: .bonjour(type: "_companion-link._tcp", domain: "local."), using: NWParameters())
            let lock = NSLock()
            var finished = false
            func finish(_ s: Status) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                browser.cancel()
                cont.resume(returning: s)
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .waiting(let e), .failed(let e):
                    if case .dns(let code) = e, code == -65570 { finish(.denied) }   // kDNSServiceErr_PolicyDenied
                default: break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                if !results.isEmpty { finish(.allowed) }
            }
            browser.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.unknown) }
        }
    }

    static func openSettings() {
        let urls = ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"]
        for s in urls {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }
}
