import Foundation
import AppKit
import Darwin

struct ProcessIdentity {
    let pid: Int32
    let name: String          // best human name ("Google Chrome")
    let executable: String    // raw process name ("Google Chrome Helper")
    let path: String?
    let bundlePath: String?
    let icon: NSImage?
    var isApp: Bool { bundlePath != nil }
}

/// pid → friendly name + icon. Helper processes (e.g. "Google Chrome Helper") are
/// attributed to the outermost .app bundle in their path so traffic lands on the app
/// a human recognises.
final class ProcessCatalog: @unchecked Sendable {
    static let shared = ProcessCatalog()
    private var cache: [Int32: ProcessIdentity] = [:]
    private var iconCache: [String: NSImage] = [:]
    private let lock = NSLock()

    func identity(pid: Int32, fallbackName: String) -> ProcessIdentity {
        lock.lock()
        if let c = cache[pid], c.executable.hasPrefix(String(fallbackName.prefix(10))) || fallbackName.isEmpty {
            lock.unlock()
            return c
        }
        lock.unlock()

        let path = Self.path(of: pid)
        var name = fallbackName
        var exe = fallbackName
        var bundlePath: String?
        var icon: NSImage?

        if let path {
            exe = (path as NSString).lastPathComponent
            if let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app") : nil) {
                let bp = String(path[..<range.upperBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let full = bp.hasPrefix("/") ? bp : "/" + bp
                bundlePath = full
                let bundle = Bundle(path: full)
                name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? ((full as NSString).lastPathComponent as NSString).deletingPathExtension
                lock.lock()
                if let cached = iconCache[full] { icon = cached }
                lock.unlock()
                if icon == nil {
                    let img = NSWorkspace.shared.icon(forFile: full)
                    img.size = NSSize(width: 32, height: 32)
                    icon = img
                    lock.lock(); iconCache[full] = img; lock.unlock()
                }
            } else {
                name = exe
            }
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            if let n = app.localizedName { name = n }
            if let i = app.icon { icon = i }
        }
        let ident = ProcessIdentity(pid: pid, name: name, executable: exe, path: path, bundlePath: bundlePath, icon: icon)
        lock.lock(); cache[pid] = ident; lock.unlock()
        return ident
    }

    static func path(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }
}
