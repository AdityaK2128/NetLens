import Foundation
import Darwin

struct GeoInfo: Codable, Hashable {
    var ip: String
    var country: String?
    var countryCode: String?
    var region: String?
    var city: String?
    var lat: Double
    var lon: Double
    var timezone: String?
    var isp: String?
    var org: String?
    var asn: String?          // "AS13335 Cloudflare, Inc."
    var asName: String?       // "CLOUDFLARENET"
    var hosting: Bool?
    var mobile: Bool?
    var proxy: Bool?
    var fetched: Date = Date()

    var asNumber: String? {
        guard let asn, asn.hasPrefix("AS") else { return nil }
        return asn.split(separator: " ").first.map(String.init)
    }
    var place: String {
        [city, region == city ? nil : region, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    var shortPlace: String {
        [city, countryCode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    var operatorName: String { org?.isEmpty == false ? org! : (isp ?? asName ?? "Unknown network") }
}

/// IP → location/ASN via ip-api.com's batch endpoint (free tier: 15 batch requests/min,
/// 100 IPs each). Results are cached on disk for a week. Private and reserved addresses
/// never leave the machine, and the whole feature can be switched off in Settings.
actor GeoIPService {
    static let shared = GeoIPService()

    static let enabledKey = "geoip.enabled"
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private var cache: [String: GeoInfo] = [:]
    private var negative: [String: Date] = [:]
    private var waiters: [String: [CheckedContinuation<GeoInfo?, Never>]] = [:]
    private var queue: [String] = []
    private var flushScheduled = false
    private var rateRemaining = 15
    private var rateResetAt = Date.distantPast
    private var dirty = false
    private var selfInfo: (GeoInfo, Date)?

    private let fields = "status,message,query,country,countryCode,regionName,city,lat,lon,timezone,isp,org,as,asname,mobile,proxy,hosting"

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetLens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("geoip-cache.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let decoded = try? JSONDecoder().decode([String: GeoInfo].self, from: data) {
            let cutoff = Date().addingTimeInterval(-7 * 86400)
            cache = decoded.filter { $0.value.fetched > cutoff }
        }
    }

    func cached(_ ip: String) -> GeoInfo? { cache[ip] }

    func info(for ip: String) async -> GeoInfo? {
        let key = IP.stripScope(ip)
        if let c = cache[key] { return c }
        guard IP.isGlobal(key), Self.isEnabled else { return nil }
        if let n = negative[key], Date().timeIntervalSince(n) < 600 { return nil }
        return await withCheckedContinuation { cont in
            if waiters[key] == nil {
                waiters[key] = []
                queue.append(key)
            }
            waiters[key]!.append(cont)
            scheduleFlush()
        }
    }

    func infos(for ips: [String]) async -> [String: GeoInfo] {
        await withTaskGroup(of: (String, GeoInfo?).self) { group in
            for ip in Set(ips) { group.addTask { (ip, await self.info(for: ip)) } }
            var out: [String: GeoInfo] = [:]
            for await (ip, g) in group { if let g { out[ip] = g } }
            return out
        }
    }

    /// Location of this machine's public egress address (VPN exit if one is active).
    func selfLocation(force: Bool = false) async -> GeoInfo? {
        if !force, let (g, at) = selfInfo, Date().timeIntervalSince(at) < 300 { return g }
        guard Self.isEnabled else { return nil }
        guard let url = URL(string: "http://ip-api.com/json/?fields=\(fields)") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let g = Self.decode(data) {
                selfInfo = (g, Date())
                cache[g.ip] = g
                return g
            }
        } catch {}
        return selfInfo?.0
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await self.flush()
        }
    }

    private func flush() async {
        flushScheduled = false
        guard !queue.isEmpty else { return }
        if rateRemaining <= 0, Date() < rateResetAt {
            let wait = rateResetAt.timeIntervalSinceNow + 0.5
            try? await Task.sleep(for: .seconds(wait))
        }
        let batch = Array(queue.prefix(100))
        queue.removeFirst(batch.count)
        let results = await fetch(batch)
        for ip in batch {
            let g = results[ip]
            if let g { cache[ip] = g; dirty = true } else { negative[ip] = Date() }
            for w in waiters.removeValue(forKey: ip) ?? [] { w.resume(returning: g) }
        }
        if !queue.isEmpty { scheduleFlush() }
        if dirty { persist() }
    }

    private func fetch(_ ips: [String]) async -> [String: GeoInfo] {
        guard let url = URL(string: "http://ip-api.com/batch?fields=\(fields)") else { return [:] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ips)
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse {
                if let rl = http.value(forHTTPHeaderField: "X-Rl").flatMap(Int.init) { rateRemaining = rl }
                if let ttl = http.value(forHTTPHeaderField: "X-Ttl").flatMap(Double.init) {
                    rateResetAt = Date().addingTimeInterval(ttl)
                }
                if http.statusCode == 429 { rateRemaining = 0; return [:] }
            }
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
            var out: [String: GeoInfo] = [:]
            for obj in arr {
                if let d = try? JSONSerialization.data(withJSONObject: obj), let g = Self.decode(d) {
                    out[g.ip] = g
                }
            }
            return out
        } catch {
            return [:]
        }
    }

    private static func decode(_ data: Data) -> GeoInfo? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["status"] as? String) == "success",
              let ip = o["query"] as? String,
              let lat = o["lat"] as? Double, let lon = o["lon"] as? Double else { return nil }
        func s(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return GeoInfo(ip: ip, country: s("country"), countryCode: s("countryCode"), region: s("regionName"),
                       city: s("city"), lat: lat, lon: lon, timezone: s("timezone"), isp: s("isp"), org: s("org"),
                       asn: s("as"), asName: s("asname"), hosting: o["hosting"] as? Bool, mobile: o["mobile"] as? Bool,
                       proxy: o["proxy"] as? Bool)
    }

    private func persist() {
        dirty = false
        let snapshot = cache
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: GeoIPService.cacheURL, options: .atomic)
            }
        }
    }

    func clearCache() {
        cache = [:]
        negative = [:]
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }
}

/// PTR lookups through the system resolver, cached, with bounded concurrency.
actor ReverseDNS {
    static let shared = ReverseDNS()
    private var cache: [String: String?] = [:]
    private var inflight: [String: Task<String?, Never>] = [:]

    func cached(_ ip: String) -> String?? { cache[ip] }

    func lookup(_ ip: String) async -> String? {
        if let c = cache[ip] { return c }
        if let t = inflight[ip] { return await t.value }
        let t = Task.detached(priority: .utility) { () -> String? in
            guard let (storage, len) = SockAddr.make(ip) else { return nil }
            var st = storage
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = withUnsafePointer(to: &st) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, len, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
            guard rc == 0 else { return nil }
            let name = String(cString: host)
            return name == ip ? nil : name
        }
        inflight[ip] = t
        let v = await t.value
        inflight[ip] = nil
        cache[ip] = v
        return v
    }
}
