import SwiftUI

struct HTTPInspectorView: View {
    @Environment(AppModel.self) private var model
    @State private var urlText = "https://www.cloudflare.com"
    @State private var method = "GET"
    @State private var http3 = false
    @State private var running = false
    @State private var result: HTTPProbeResult?

    private let phaseColors: [String: Color] = [
        "DNS": .teal, "TCP": .orange, "TLS": .purple, "QUIC + TLS": .purple,
        "Request": .gray, "Wait (TTFB)": .green, "Download": .blue,
    ]

    var body: some View {
        Page(spacing: 18) {
            PageHeader(eyebrow: "Diagnose · curl -w", title: "HTTP & TLS inspector",
                       subtitle: "A cold request on a fresh connection, timed phase by phase — DNS, TCP handshake, TLS, server think-time, transfer — plus the certificate chain and what the headers give away.")

            HStack(spacing: 10) {
                Picker("", selection: $method) { Text("GET").tag("GET"); Text("HEAD").tag("HEAD") }
                    .labelsHidden().frame(width: 80)
                InstrumentField(placeholder: "https://example.com", text: $urlText, icon: "link") { run() }
                Toggle("Try HTTP/3", isOn: $http3).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                InfoButton(term: .http3)
                    .help("Lets URLSession use QUIC immediately instead of discovering it via Alt-Svc")
                Button(running ? "Requesting…" : "Send") { run() }.buttonStyle(.borderedProminent).disabled(running)
            }

            if let r = result {
                if let e = r.error, r.status == nil {
                    Callout(kind: .warning, title: "Request failed", message: e)
                }
                if let last = r.transactions.last {
                    summary(r, last)
                    waterfall(r)
                    HStack(alignment: .top, spacing: 18) {
                        connectionPanel(last, r)
                        securityPanel(r)
                    }
                }
                if !r.certificates.isEmpty { certificatePanel(r) }
                if !r.headers.isEmpty { headersPanel(r) }
            } else {
                EmptyState(icon: "lock.shield", title: "Inspect any URL",
                           message: "Compare a CDN-fronted site with a far-away origin and watch where the time goes. TLS 1.3 saves a whole round trip; HTTP/3 folds TCP and TLS into one QUIC handshake.")
            }
        }
        .onAppear { if let t = model.takeTarget(.http) { urlText = t; run() } }
    }

    private func run() {
        var s = urlText.trimmed
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else { return }
        urlText = s
        running = true
        Task {
            result = await HTTPProbe.run(url: url, method: method, http3: http3)
            running = false
        }
    }

    // MARK: summary

    private func summary(_ r: HTTPProbeResult, _ t: HTTPTransaction) -> some View {
        let ttfb = t.phases.first { $0.name == "Wait (TTFB)" }
        let totalAll = r.transactions.reduce(0) { $0 + $1.total }
        return HStack(spacing: 12) {
            Readout(label: "Status", value: r.status.map(String.init) ?? "—", accent: (r.status ?? 0) < 400 ? Theme.teal : Theme.coral,
                    caption: r.status.map { HTTPURLResponse.localizedString(forStatusCode: $0) })
            Readout(label: "Protocol", value: protoName(t.proto), accent: Theme.ink,
                    caption: t.reused ? "reused connection" : "new connection", size: 22)
            Readout(label: "Total", value: String(format: "%.0f", totalAll), unit: "ms", accent: Theme.ink,
                    caption: r.transactions.count > 1 ? "\(r.transactions.count - 1) redirect(s)" : nil)
            Readout(label: "Time to first byte", value: ttfb.map { String(format: "%.0f", $0.duration) } ?? "—", unit: "ms", accent: Theme.amber,
                    caption: "server think-time + 1 RTT", info: .ttfb)
            Readout(label: "Body", value: Fmt.bytesParts(Double(r.bodyBytes)).0, unit: Fmt.bytesParts(Double(r.bodyBytes)).1, accent: Theme.ink,
                    caption: r.header("content-encoding").map { "encoded: \($0)" })
        }
    }

    private func protoName(_ p: String) -> String {
        switch p {
        case "h3": "HTTP/3"
        case "h2": "HTTP/2"
        case "http/1.1": "HTTP/1.1"
        default: p
        }
    }

    // MARK: waterfall

    private func waterfall(_ r: HTTPProbeResult) -> some View {
        let span = max(r.transactions.map(\.total).max() ?? 1, 1)
        return Panel("Timing waterfall", icon: "chart.bar.xaxis") {
            HStack(spacing: 10) {
                ForEach(["DNS", "TCP", "TLS", "Wait (TTFB)", "Download"], id: \.self) { n in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(phaseColors[n] ?? Theme.ink).frame(width: 10, height: 6)
                        Text(n).font(.mono(9.5)).foregroundStyle(Theme.muted)
                    }
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(r.transactions) { t in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(t.url).font(.mono(11)).foregroundStyle(Theme.ink2).lineLimit(1)
                            Spacer()
                            if let s = t.status { Chip(text: "\(s)", color: s < 300 ? Theme.teal : s < 400 ? Theme.amber : Theme.coral) }
                            Chip(text: protoName(t.proto))
                        }
                        ForEach(t.phases) { p in
                            HStack(spacing: 10) {
                                Text(p.name).font(.mono(10.5)).foregroundStyle(Theme.muted).frame(width: 90, alignment: .leading)
                                GeometryReader { g in
                                    let c = phaseColors[p.name] ?? Theme.ink
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(c)
                                        .frame(width: max(2, g.size.width * p.duration / span), height: 12)
                                        .offset(x: g.size.width * p.start / span)
                                        .frame(maxHeight: .infinity)
                                }
                                .frame(height: 16)
                                Text(String(format: "%.1f ms", p.duration)).font(.mono(10.5, .medium)).foregroundStyle(Theme.ink)
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }
                    }
                }
                if let t = r.transactions.last, let tcp = t.phases.first(where: { $0.name == "TCP" })?.duration, tcp > 0 {
                    Text("TCP handshake ≈ 1 RTT ≈ \(Fmt.ms(tcp)) to this server. TLS 1.3 adds one more; HTTP/3 merges both into a single QUIC round trip.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    // MARK: details

    private func connectionPanel(_ t: HTTPTransaction, _ r: HTTPProbeResult) -> some View {
        Panel("Connection", icon: "cable.connector") {
            VStack(spacing: 0) {
                KV(key: "Remote", value: t.remote ?? "—")
                KV(key: "Local", value: t.local ?? "—")
                KV(key: "TLS", value: t.tlsVersion ?? "—", info: .tlsHandshake)
                KV(key: "Cipher", value: t.cipher ?? "—")
                KV(key: "Served by (CDN)", value: r.edge ?? "—", color: r.edge == nil ? Theme.muted : Theme.ink, info: .cdnEdge)
                KV(key: "Server", value: r.header("server") ?? "—")
                KV(key: "Alt-Svc", value: r.header("alt-svc").map { $0.contains("h3") ? "advertises HTTP/3" : $0 } ?? "—", info: .http3)
                KV(key: "Proxy", value: t.proxied ? "yes" : "no")
                KV(key: "Path", value: [t.expensive ? "expensive" : nil, t.constrained ? "low data mode" : nil].compactMap { $0 }.joined(separator: ", ").nilIfEmpty ?? "normal")
            }
        }
    }

    private func securityPanel(_ r: HTTPProbeResult) -> some View {
        let checks: [(String, String, String)] = [
            ("Strict-Transport-Security", "HSTS", "Forces HTTPS for future visits"),
            ("Content-Security-Policy", "CSP", "Limits where scripts may load from"),
            ("X-Content-Type-Options", "nosniff", "Stops MIME-type guessing"),
            ("X-Frame-Options", "Frame options", "Clickjacking protection (or CSP frame-ancestors)"),
            ("Referrer-Policy", "Referrer policy", "Controls what leaks in the Referer header"),
            ("Permissions-Policy", "Permissions", "Restricts camera, mic, geolocation APIs"),
        ]
        return Panel("Security posture", icon: "checkmark.shield", info: .hsts) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    StatusDot(color: r.trustOK == true ? Theme.good : Theme.coral)
                    Text(r.trustOK == true ? "Certificate chain trusted by macOS" : (r.trustError ?? "Not trusted"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                }
                Hairline()
                ForEach(checks, id: \.0) { header, label, why in
                    let present = r.header(header) != nil || (header == "X-Frame-Options" && (r.header("Content-Security-Policy")?.contains("frame-ancestors") ?? false))
                    HStack(spacing: 8) {
                        Image(systemName: present ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(present ? Theme.teal : Theme.faint)
                        Text(label).font(.system(size: 12)).foregroundStyle(present ? Theme.ink : Theme.muted)
                        Spacer()
                        Text(why).font(.system(size: 10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                    .help(r.header(header) ?? "Not set")
                }
            }
        }
    }

    private func certificatePanel(_ r: HTTPProbeResult) -> some View {
        Panel("Certificate chain", icon: "seal") {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(r.certificates.enumerated()), id: \.element.id) { i, c in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: i == 0 ? "doc.text" : i == r.certificates.count - 1 ? "building.columns" : "arrow.down.doc")
                                .foregroundStyle(i == 0 ? Theme.amber : Theme.teal)
                            Text(i == 0 ? "Leaf" : i == r.certificates.count - 1 ? "Root" : "Intermediate")
                                .font(.mono(9.5, .semibold)).foregroundStyle(Theme.muted)
                        }
                        Text(c.subject).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                        Text("issued by \(c.issuer)").font(.system(size: 11)).foregroundStyle(Theme.ink2).lineLimit(2)
                        if let d = c.daysLeft {
                            HStack(spacing: 6) {
                                Meter(value: Double(max(d, 0)) / 398, color: d < 14 ? Theme.coral : d < 45 ? Theme.amber : Theme.teal, height: 4)
                                Text("\(d)d left").font(.mono(10.5)).foregroundStyle(d < 14 ? Theme.coral : Theme.ink2)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            if let nb = c.notBefore, let na = c.notAfter {
                                Text("\(Fmt.dateTime.string(from: nb)) → \(Fmt.dateTime.string(from: na))").font(.mono(9.5)).foregroundStyle(Theme.muted)
                            }
                            Text(c.keyDescription).font(.mono(10)).foregroundStyle(Theme.muted)
                            Text("SHA-256 \(c.sha256.prefix(23))…").font(.mono(9.5)).foregroundStyle(Theme.faint).help(c.sha256).textSelection(.enabled)
                        }
                        if !c.sans.isEmpty {
                            Text("\(c.sans.count) name\(c.sans.count == 1 ? "" : "s"): " + c.sans.prefix(6).joined(separator: ", ") + (c.sans.count > 6 ? "…" : ""))
                                .font(.mono(9.5)).foregroundStyle(Theme.ink2).lineLimit(3)
                                .help(c.sans.joined(separator: "\n"))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.trough).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.lineSoft)))
                }
            }
        }
    }

    private func headersPanel(_ r: HTTPProbeResult) -> some View {
        Panel("Response headers · \(r.headers.count)", icon: "list.bullet.rectangle") {
            VStack(spacing: 0) {
                ForEach(r.headers, id: \.0) { k, v in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(k.lowercased()).font(.mono(11, .medium)).foregroundStyle(Theme.amber).frame(width: 240, alignment: .leading)
                        Text(v).font(.mono(11)).foregroundStyle(Theme.ink2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
