import Foundation
import Security
import CryptoKit

struct HTTPPhase: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let start: Double     // ms from fetch start
    let duration: Double
}

struct HTTPTransaction: Identifiable {
    let id = UUID()
    let url: String
    let status: Int?
    let proto: String
    let reused: Bool
    let proxied: Bool
    let remote: String?
    let local: String?
    let tlsVersion: String?
    let cipher: String?
    let phases: [HTTPPhase]
    let total: Double
    let fetchType: String
    let requestHeaderBytes: Int64
    let responseBodyBytes: Int64
    let expensive: Bool
    let constrained: Bool
}

struct CertInfo: Identifiable {
    let id = UUID()
    let subject: String
    let issuer: String
    let notBefore: Date?
    let notAfter: Date?
    let serial: String
    let keyDescription: String
    let sans: [String]
    let sha256: String
    let isSelfIssued: Bool

    var daysLeft: Int? { notAfter.map { Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0 } }
}

struct HTTPProbeResult {
    var transactions: [HTTPTransaction] = []
    var status: Int?
    var headers: [(String, String)] = []
    var certificates: [CertInfo] = []
    var trustOK: Bool?
    var trustError: String?
    var error: String?
    var bodyBytes = 0
    var finalURL: String?

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    /// Who's actually serving this — inferred from tell-tale response headers.
    var edge: String? {
        if header("cf-ray") != nil { return "Cloudflare" }
        if header("x-amz-cf-id") != nil { return "Amazon CloudFront" }
        if header("x-vercel-id") != nil { return "Vercel" }
        if header("x-nf-request-id") != nil { return "Netlify" }
        if let v = header("x-served-by"), v.contains("cache-") { return "Fastly" }
        if header("x-fastly-request-id") != nil { return "Fastly" }
        if header("x-akamai-transformed") != nil || (header("server")?.lowercased().contains("akamai") ?? false) { return "Akamai" }
        if header("x-azure-ref") != nil { return "Azure Front Door" }
        if let s = header("server")?.lowercased() {
            if s.contains("gws") || s.contains("google") { return "Google" }
            if s.contains("cloudfront") { return "Amazon CloudFront" }
        }
        if header("x-goog-generation") != nil || header("x-guploader-uploadid") != nil { return "Google Cloud" }
        return nil
    }
}

/// One-shot HTTP request on a fresh ephemeral session so every phase (DNS, TCP,
/// TLS, TTFB) is measured from cold.
final class HTTPProbe: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    private var result = HTTPProbeResult()
    private var cont: CheckedContinuation<HTTPProbeResult, Never>?
    private var body = Data()

    static func run(url: URL, method: String = "GET", http3: Bool = false) async -> HTTPProbeResult {
        let probe = HTTPProbe()
        return await probe.start(url: url, method: method, http3: http3)
    }

    private func start(url: URL, method: String, http3: Bool) async -> HTTPProbeResult {
        await withCheckedContinuation { c in
            cont = c
            let cfg = URLSessionConfiguration.ephemeral
            cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            cfg.urlCache = nil
            cfg.httpCookieStorage = nil
            cfg.timeoutIntervalForRequest = 20
            let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.assumesHTTP3Capable = http3
            req.setValue("NetLens/0.1 (network inspector)", forHTTPHeaderField: "User-Agent")
            let task = session.dataTask(with: req)
            task.resume()
        }
    }

    // MARK: delegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if body.count < 5_000_000 { body.append(data) }
        result.bodyBytes += data.count
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            var err: CFError?
            result.trustOK = SecTrustEvaluateWithError(trust, &err)
            result.trustError = err.map { CFErrorCopyDescription($0) as String }
            if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] {
                result.certificates = chain.map(Self.describe)
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        result.transactions = metrics.transactionMetrics.map(Self.transaction)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let http = task.response as? HTTPURLResponse {
            result.status = http.statusCode
            result.headers = http.allHeaderFields.compactMap { k, v in
                guard let k = k as? String else { return nil }
                return (k, "\(v)")
            }
            .sorted { $0.0.lowercased() < $1.0.lowercased() }
            result.finalURL = http.url?.absoluteString
        }
        if let error { result.error = error.localizedDescription }
        session.finishTasksAndInvalidate()
        // Metrics are delivered before completion; hop to finish on next tick to be safe.
        DispatchQueue.main.async { [self] in
            cont?.resume(returning: result)
            cont = nil
        }
    }

    // MARK: decoding

    private static func transaction(_ t: URLSessionTaskTransactionMetrics) -> HTTPTransaction {
        let origin = t.fetchStartDate ?? t.domainLookupStartDate ?? t.connectStartDate ?? Date()
        func ms(_ d: Date?) -> Double? { d.map { $0.timeIntervalSince(origin) * 1000 } }
        var phases: [HTTPPhase] = []
        func add(_ name: String, _ a: Date?, _ b: Date?) {
            guard let s = ms(a), let e = ms(b), e >= s else { return }
            phases.append(HTTPPhase(name: name, start: s, duration: e - s))
        }
        let isQUIC = t.networkProtocolName == "h3"
        add("DNS", t.domainLookupStartDate, t.domainLookupEndDate)
        if isQUIC {
            add("QUIC + TLS", t.connectStartDate, t.connectEndDate)
        } else {
            add("TCP", t.connectStartDate, t.secureConnectionStartDate ?? t.connectEndDate)
            add("TLS", t.secureConnectionStartDate, t.secureConnectionEndDate)
        }
        add("Request", t.requestStartDate, t.requestEndDate)
        add("Wait (TTFB)", t.requestEndDate, t.responseStartDate)
        add("Download", t.responseStartDate, t.responseEndDate)
        let total = ms(t.responseEndDate) ?? phases.map { $0.start + $0.duration }.max() ?? 0

        var remote: String?
        if let a = t.remoteAddress { remote = t.remotePort.map { a.contains(":") ? "[\(a)]:\($0)" : "\(a):\($0)" } ?? a }
        var local: String?
        if let a = t.localAddress { local = t.localPort.map { a.contains(":") ? "[\(a)]:\($0)" : "\(a):\($0)" } ?? a }

        let fetch: String
        switch t.resourceFetchType {
        case .networkLoad: fetch = "network"
        case .localCache: fetch = "cache"
        case .serverPush: fetch = "server push"
        default: fetch = "unknown"
        }
        return HTTPTransaction(
            url: t.request.url?.absoluteString ?? "", status: (t.response as? HTTPURLResponse)?.statusCode,
            proto: t.networkProtocolName ?? "?", reused: t.isReusedConnection, proxied: t.isProxyConnection,
            remote: remote, local: local, tlsVersion: tlsName(t.negotiatedTLSProtocolVersion), cipher: cipherName(t.negotiatedTLSCipherSuite),
            phases: phases, total: total, fetchType: fetch,
            requestHeaderBytes: t.countOfRequestHeaderBytesSent, responseBodyBytes: t.countOfResponseBodyBytesReceived,
            expensive: t.isExpensive, constrained: t.isConstrained)
    }

    private static func tlsName(_ v: tls_protocol_version_t?) -> String? {
        guard let v else { return nil }
        switch v {
        case .TLSv13: return "TLS 1.3"
        case .TLSv12: return "TLS 1.2"
        case .TLSv11: return "TLS 1.1"
        case .TLSv10: return "TLS 1.0"
        case .DTLSv12: return "DTLS 1.2"
        default: return String(format: "0x%04X", v.rawValue)
        }
    }

    private static func cipherName(_ c: tls_ciphersuite_t?) -> String? {
        guard let c else { return nil }
        let names: [UInt16: String] = [
            0x1301: "TLS_AES_128_GCM_SHA256", 0x1302: "TLS_AES_256_GCM_SHA384", 0x1303: "TLS_CHACHA20_POLY1305_SHA256",
            0xC02B: "ECDHE-ECDSA-AES128-GCM-SHA256", 0xC02C: "ECDHE-ECDSA-AES256-GCM-SHA384",
            0xC02F: "ECDHE-RSA-AES128-GCM-SHA256", 0xC030: "ECDHE-RSA-AES256-GCM-SHA384",
            0xCCA9: "ECDHE-ECDSA-CHACHA20-POLY1305", 0xCCA8: "ECDHE-RSA-CHACHA20-POLY1305",
            0x009C: "RSA-AES128-GCM-SHA256", 0x009D: "RSA-AES256-GCM-SHA384",
        ]
        return names[c.rawValue] ?? String(format: "0x%04X", c.rawValue)
    }

    static func describe(_ cert: SecCertificate) -> CertInfo {
        let subject = (SecCertificateCopySubjectSummary(cert) as String?) ?? "?"
        var issuer = "?"
        var sans: [String] = []
        let keys = [kSecOIDX509V1IssuerName, kSecOIDSubjectAltName, kSecOIDX509V1SubjectName] as CFArray
        if let values = SecCertificateCopyValues(cert, keys, nil) as? [String: [String: Any]] {
            if let iss = values[kSecOIDX509V1IssuerName as String]?[kSecPropertyKeyValue as String] as? [[String: Any]] {
                issuer = distinguished(iss)
            }
            if let san = values[kSecOIDSubjectAltName as String]?[kSecPropertyKeyValue as String] as? [[String: Any]] {
                sans = san.compactMap { $0[kSecPropertyKeyValue as String] as? String }
            }
        }
        let der = SecCertificateCopyData(cert) as Data
        let fp = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        var serial = ""
        if let s = SecCertificateCopySerialNumberData(cert, nil) as Data? {
            serial = s.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
        var keyDesc = "?"
        if let key = SecCertificateCopyKey(cert), let attrs = SecKeyCopyAttributes(key) as? [String: Any] {
            let type = attrs[kSecAttrKeyType as String] as? String
            let bits = attrs[kSecAttrKeySizeInBits as String] as? Int ?? 0
            let name = type == (kSecAttrKeyTypeRSA as String) ? "RSA" : type == (kSecAttrKeyTypeECSECPrimeRandom as String) ? "ECDSA P-\(bits)" : "Key"
            keyDesc = name == "RSA" ? "RSA \(bits)-bit" : name
        }
        let notBefore = SecCertificateCopyNotValidBeforeDate(cert) as Date?
        let notAfter = SecCertificateCopyNotValidAfterDate(cert) as Date?
        return CertInfo(subject: subject, issuer: issuer, notBefore: notBefore, notAfter: notAfter, serial: serial,
                        keyDescription: keyDesc, sans: sans, sha256: fp, isSelfIssued: issuer.contains(subject))
    }

    private static func distinguished(_ parts: [[String: Any]]) -> String {
        // Prefer CN, then O.
        var cn: String?, o: String?
        for p in parts {
            let label = p[kSecPropertyKeyLabel as String] as? String ?? ""
            let value = p[kSecPropertyKeyValue as String] as? String
            if label == "2.5.4.3" { cn = value }
            if label == "2.5.4.10" { o = value }
        }
        return [cn, o].compactMap { $0 }.joined(separator: " · ")
    }
}
