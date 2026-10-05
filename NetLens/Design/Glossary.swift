import SwiftUI

/// Plain-English explanations for the networking terms NetLens shows. Each entry
/// answers "what is it" and, where useful, "why should I care".
enum Glossary: String, CaseIterable, Identifiable {
    case rtt, jitter, packetLoss, mos, ttlProbe, replyTTL, traceroute
    case anycast, pathStretch, asn, ixp, isp, publicIP, nat, cgnat, natPMP, vpnExit
    case rssi, noise, snr, phyRate, channelWidth, band, wifiSecurity, ssidPrivacy
    case dnsResolver, dnssec, doh, dot, edns, dnsTTL, delegation
    case ttfb, tlsHandshake, http3, alpn, sni, cdnEdge, hsts
    case rpm, bufferbloat
    case retransmits, congestionControl, tcpWindow, trafficClass, transparentProxy
    case listeningExposure, ecmp, privateHop, mtu, linkLocal, privateMAC, dhcp
    case bonjour, arp, routeLookup, bandwidthCaps, bpf, captureFilter, socketStates, clientIsolation
    case portStates, nmapTiming, osDetection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rtt: "Round-trip time (RTT)"
        case .jitter: "Jitter"
        case .packetLoss: "Packet loss"
        case .mos: "MOS — call quality score"
        case .ttlProbe: "TTL probe"
        case .replyTTL: "Reply TTL"
        case .traceroute: "How traceroute works"
        case .anycast: "Anycast"
        case .pathStretch: "Path stretch"
        case .asn: "Autonomous system (ASN)"
        case .ixp: "Internet exchange (IXP)"
        case .isp: "ISP edge"
        case .publicIP: "Public IP address"
        case .nat: "NAT"
        case .cgnat: "Carrier-grade NAT (CGNAT)"
        case .natPMP: "NAT-PMP"
        case .vpnExit: "VPN exit"
        case .rssi: "Signal strength (RSSI)"
        case .noise: "Noise floor"
        case .snr: "Signal-to-noise ratio (SNR)"
        case .phyRate: "PHY rate"
        case .channelWidth: "Channel width"
        case .band: "Wi-Fi bands"
        case .wifiSecurity: "Wi-Fi security"
        case .ssidPrivacy: "Why the network name is hidden"
        case .dnsResolver: "DNS resolver"
        case .dnssec: "DNSSEC"
        case .doh: "DNS over HTTPS (DoH)"
        case .dot: "DNS over TLS (DoT)"
        case .edns: "EDNS"
        case .dnsTTL: "TTL (DNS)"
        case .delegation: "Delegation"
        case .ttfb: "Time to first byte (TTFB)"
        case .tlsHandshake: "TLS handshake"
        case .http3: "HTTP/3 and QUIC"
        case .alpn: "ALPN"
        case .sni: "SNI (server name)"
        case .cdnEdge: "CDN edge"
        case .hsts: "Security headers"
        case .rpm: "Responsiveness (RPM)"
        case .bufferbloat: "Bufferbloat"
        case .retransmits: "Retransmissions"
        case .congestionControl: "Congestion control"
        case .tcpWindow: "Receive buffer & send window"
        case .trafficClass: "Service class"
        case .transparentProxy: "Transparent proxy"
        case .listeningExposure: "Who can reach a listening port"
        case .ecmp: "ECMP (load-balanced paths)"
        case .privateHop: "Private addresses in a route"
        case .mtu: "MTU"
        case .linkLocal: "Link-local address"
        case .privateMAC: "Private (randomised) MAC"
        case .dhcp: "DHCP lease"
        case .bonjour: "Bonjour (mDNS)"
        case .arp: "ARP & neighbour cache"
        case .routeLookup: "Route lookup"
        case .bandwidthCaps: "How bandwidth caps work"
        case .bpf: "Packet capture (BPF)"
        case .captureFilter: "Filter syntax"
        case .socketStates: "Connection states"
        case .clientIsolation: "Client isolation"
        case .portStates: "Open, closed, filtered"
        case .nmapTiming: "Timing templates"
        case .osDetection: "Service & OS detection"
        }
    }

    var body: String {
        switch self {
        case .rtt:
            "How long a packet takes to reach a host and for the reply to come back, in milliseconds. Under 30 ms feels instant, 30–100 ms is normal for nearby countries, 150 ms+ is noticeable in calls and games."
        case .jitter:
            "How much latency varies from one packet to the next. A steady 60 ms is fine for a video call; 20 ms that swings to 120 ms causes choppy audio and rubber-banding in games."
        case .packetLoss:
            "Share of probes that never got a reply. Even 1–2% hurts calls and slows TCP downloads, because lost data has to be resent."
        case .mos:
            "Mean Opinion Score, estimated from latency, jitter and loss using the ITU E-model: how a voice call over this path would sound, from 1 (unusable) to 4.5 (excellent). 4.0+ is good."
        case .ttlProbe:
            "Your router ignores ordinary pings, so NetLens sends a packet towards the Internet that is allowed only one hop. The router has to answer with \"time exceeded\" — and that reply gives the same round-trip time."
        case .traceroute:
            "Every packet carries a hop limit (TTL) that each router decrements. NetLens sends probes with limits of 1, 2, 3… and the router where each one runs out replies — revealing itself and the round trip to it. Some routers never reply; that's shown as * * * and is usually harmless."
        case .replyTTL:
            "Every reply starts with a hop budget (TTL) that drops by one per router. Systems start at 64 (macOS, Linux), 128 (Windows) or 255 (network gear), so the remaining TTL hints at both the distance and the operating system."
        case .anycast:
            "One IP address announced from many data centres at once — the Internet routes you to the nearest copy. Cloudflare, Google DNS and most CDNs work this way. That's why a server \"in San Francisco\" can answer from Sydney in 5 ms: IP location databases only know one place for the address."
        case .pathStretch:
            "Light in fibre covers about 200 km per millisecond, so distance sets a hard minimum on latency. Path stretch is measured RTT divided by that minimum. Close to 1× means a direct route; 3× or more means detours, slow hops or queuing."
        case .asn:
            "The Internet is a network of about 75,000 independently run networks — ISPs, clouds, universities — each with an Autonomous System Number (like AS13335 for Cloudflare). A route is the list of networks your packets cross."
        case .ixp:
            "A building where many networks plug into a shared switch to swap traffic directly (\"peering\"). Passing through an IXP usually means a shorter, cheaper, faster path than going via a paid transit provider."
        case .isp:
            "The first router on the public Internet: where your ISP's network begins after your home router."
        case .publicIP:
            "The address the rest of the Internet sees for you. Devices in your home share it through NAT. With a VPN on, it belongs to the VPN server instead."
        case .nat:
            "Network Address Translation: your router rewrites the private addresses of all your devices into one public address on the way out, and maps replies back. It's why your Mac's address starts with 10., 172.16–31. or 192.168."
        case .cgnat:
            "When ISPs run out of IPv4 addresses they put a second NAT in their own network and share one public address among many customers. You'll see 100.64.x.x addresses. It breaks port forwarding and hosting games or servers from home."
        case .natPMP:
            "A small protocol (RFC 6886) that lets apps ask the router for its public address or a port mapping. If your router answers, NetLens learns its WAN address — the most reliable way to spot double NAT or CGNAT."
        case .vpnExit:
            "With a VPN active, traffic leaves through the VPN provider's server, so the \"ISP\" and location you see are the VPN's, not your home connection's."
        case .rssi:
            "Received signal strength from the access point, in dBm (closer to 0 is stronger). −50 is excellent, −67 is the minimum for reliable calls, below −75 is weak."
        case .noise:
            "Background radio energy on the channel, in dBm. Typically −90 to −95. Higher noise (say −80) drowns out the signal."
        case .snr:
            "Signal minus noise, in dB — the number that actually decides speed. 40+ dB is superb, 25+ is good, under 15 is unreliable."
        case .phyRate:
            "The raw link rate your Mac and the access point negotiated over the air. Real throughput is typically 50–70% of this, shared with everyone on the channel."
        case .channelWidth:
            "How much radio spectrum the link uses: 20, 40, 80 or 160 MHz. Wider is faster but more prone to overlap with neighbours."
        case .band:
            "2.4 GHz travels far but is crowded and slow; 5 GHz is faster with more channels; 6 GHz (Wi-Fi 6E/7) is fastest and least congested but has the shortest range."
        case .wifiSecurity:
            "WPA3 is current best practice; WPA2 is fine with a strong password; WEP and open networks can be read by anyone nearby."
        case .ssidPrivacy:
            "Wi-Fi network names reveal where you are, so macOS only shows them to apps with Location access. NetLens never uses or stores your location."
        case .dnsResolver:
            "The server that turns names like example.com into IP addresses for your Mac. Usually your router or ISP, or a public service such as Cloudflare (1.1.1.1). VPNs often replace it."
        case .dnssec:
            "Digital signatures on DNS records so answers can't be forged. The AD flag means the resolver checked the signatures for you."
        case .doh:
            "DNS queries sent inside ordinary HTTPS, so networks along the way can't see or tamper with the names you look up."
        case .dot:
            "DNS queries wrapped in TLS on port 853 — private like DoH, but easier for network admins to identify."
        case .edns:
            "Extensions to DNS that allow larger UDP responses and extra options such as DNSSEC, cookies and padding."
        case .dnsTTL:
            "How long resolvers may cache a record before asking again. Low TTLs (minutes) let services move traffic quickly; high TTLs (hours) mean fewer lookups."
        case .delegation:
            "No server knows every name. The root servers point to .com's servers, which point to example.com's own servers, which hold the answer. This view walks that chain."
        case .ttfb:
            "The wait between sending the request and receiving the first byte of the response: one network round trip plus the server's thinking time."
        case .tlsHandshake:
            "Before encrypted data flows, client and server agree on keys. TLS 1.3 needs one round trip; TLS 1.2 needed two."
        case .http3:
            "HTTP/3 runs over QUIC, which is built on UDP and combines the connection and encryption handshakes into a single round trip. It also copes better with packet loss and switching networks."
        case .alpn:
            "Application-Layer Protocol Negotiation: during the TLS handshake the client lists the protocols it speaks (h2, http/1.1…) and the server picks one."
        case .sni:
            "The hostname a client puts, unencrypted, in its TLS hello so a shared server knows which site's certificate to present. That's how packet capture can see which sites apps connect to even over HTTPS."
        case .cdnEdge:
            "A content delivery network serves sites from servers close to you. Response headers often reveal which CDN (Cloudflare, Fastly, CloudFront…) answered."
        case .hsts:
            "Response headers that tell the browser to tighten security: always use HTTPS (HSTS), only run approved scripts (CSP), don't allow framing, and so on."
        case .rpm:
            "Round trips Per Minute while the link is fully busy. It measures how responsive your connection stays under load. Above 1000 is high; below 300 means calls and games will suffer whenever someone downloads."
        case .bufferbloat:
            "Routers and modems with oversized buffers queue data instead of signalling congestion, so latency balloons whenever the link is busy. Smart queue management (fq_codel, CAKE) on the router fixes it."
        case .retransmits:
            "Data TCP had to send again because the original was lost or acknowledged too late. A few is normal; a high ratio points to a lossy link."
        case .congestionControl:
            "The algorithm TCP uses to decide how fast to send without overwhelming the network. macOS defaults to CUBIC."
        case .tcpWindow:
            "How much data can be in flight. The receive buffer is how much this Mac will accept unacknowledged; the send window is how much the other side currently allows."
        case .trafficClass:
            "macOS tags each socket with a service class (background, best effort, interactive video, voice…) so the system can prioritise what you're actively using."
        case .transparentProxy:
            "Some VPN \"threat protection\" features re-make every connection on an app's behalf. The app keeps a placeholder socket and the proxy owns the real one. NetLens matches them up so traffic is credited — and capped — to the right app."
        case .listeningExposure:
            "A server bound to * (0.0.0.0 or ::) accepts connections from any network the Mac is on. Bound to 127.0.0.1 or ::1, only programs on this Mac can reach it."
        case .ecmp:
            "Equal-cost multi-path: routers spread traffic across parallel links, so different probes to the same hop can be answered by different routers. Normal on big networks."
        case .privateHop:
            "Routers inside an ISP often use private or shared (100.64.x.x) addresses that don't appear on the public Internet. Harmless, but they can't be located."
        case .mtu:
            "Maximum transmission unit: the largest packet the link carries without splitting it, usually 1500 bytes on Ethernet and Wi-Fi, less inside VPN tunnels."
        case .linkLocal:
            "Addresses (169.254.x.x, fe80::) that only work on the local link. Every IPv6 interface has one; seeing only link-local IPv6 means your network has no IPv6 Internet."
        case .privateMAC:
            "Modern devices randomise their hardware address per network to avoid being tracked. Such addresses can't be traced to a manufacturer."
        case .dhcp:
            "Your router lends this Mac its IP address for a fixed period (the lease) along with the gateway and DNS servers. The Mac renews it automatically halfway through."
        case .bonjour:
            "Apple's zero-configuration networking: devices announce services (AirPlay, printers, file sharing…) on the local network with multicast DNS, no setup needed."
        case .arp:
            "The table mapping IP addresses on your local network to hardware (MAC) addresses — ARP for IPv4, Neighbor Discovery for IPv6. Every device you've recently exchanged packets with appears here. Recent macOS versions hide it from apps; NetLens reads it through its helper when installed."
        case .portStates:
            "Open: a program accepted the connection. Closed: the host answered but nothing is listening. Filtered: no answer at all — a firewall dropped the probe, so nmap can't tell what's behind it."
        case .nmapTiming:
            "How hard nmap pushes: Polite (T2) waits between probes so it won't disturb fragile devices or trip alarms, Normal (T3) is nmap's default, Aggressive (T4) assumes a fast, reliable network and is what most people use on a LAN."
        case .osDetection:
            "Version detection (-sV) talks to each open port and matches the replies against thousands of known services. OS detection (-O) sends unusual packets and compares how the TCP/IP stack reacts with a database of fingerprints; it needs administrator rights to craft those packets."
        case .clientIsolation:
            "Many campus, office, hotel and apartment Wi-Fi networks stop connected devices from talking to each other: the access point only forwards traffic between each device and the router. Everyone is online, but from your Mac the network looks almost empty — that's a security feature, not a scanning problem."
        case .routeLookup:
            "Asks the kernel which route it would actually use for a destination. The most specific match wins, which is how VPNs steer only some traffic into their tunnel."
        case .bandwidthCaps:
            "NetLens tracks which ports each app is using and passes them to its helper, which steers those packets through a kernel dummynet pipe with the speed you choose — the engine behind Apple's Network Link Conditioner. The pipe's own packet counters confirm each cap is really being applied. Limits are removed automatically if NetLens quits."
        case .bpf:
            "The Berkeley Packet Filter is the kernel tap that tcpdump and Wireshark use to copy packets off an interface. It needs administrator permission once."
        case .captureFilter:
            "Type a protocol (tcp, udp, dns, tls, quic, http, arp, icmp), host 1.2.3.4, port 443, sni contains openai, syn or rst. Combine with and, or, not. Anything else searches the packet summaries."
        case .socketStates:
            "Established: data can flow. SynSent: still connecting. CloseWait / FinWait / TimeWait: one side has finished and the connection is winding down. Listen: a server waiting for connections."
        }
    }
}

/// Small ⓘ button that explains a term in a popover.
struct InfoButton: View {
    let term: Glossary
    var size: CGFloat = 11
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: size))
                .foregroundStyle(Theme.tertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(term.title)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            GlossaryCard(term: term)
        }
    }
}

struct GlossaryCard: View {
    let term: Glossary
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(term.title).font(.system(size: 13, weight: .semibold))
            Text(term.body)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

/// A label with an optional ⓘ — used for field captions.
struct TermLabel: View {
    let text: String
    var term: Glossary?
    var font: Font = .system(size: 11.5)
    var color: Color = Theme.secondary

    var body: some View {
        HStack(spacing: 3) {
            Text(text).font(font).foregroundStyle(color).lineLimit(1)
            if let term { InfoButton(term: term, size: 10) }
        }
    }
}

/// An inline tag (e.g. "anycast") that explains itself when clicked.
struct TermTag: View {
    let text: String
    let term: Glossary
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 2) {
                Text(text)
                Image(systemName: "info.circle").font(.system(size: 8.5))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Theme.fill))
        }
        .buttonStyle(.plain)
        .help(term.title)
        .popover(isPresented: $shown, arrowEdge: .bottom) { GlossaryCard(term: term) }
    }
}
