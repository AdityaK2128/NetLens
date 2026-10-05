import SwiftUI
import UniformTypeIdentifiers

struct CaptureView: View {
    @Environment(AppModel.self) private var model
    @State private var session = CaptureSession()
    @State private var fields: [PField] = []
    @State private var selectedField: PField.ID?
    @State private var exporting = false
    @State private var exportDoc = PcapDocument(data: Data())

    private var selectedRange: Range<Int>? {
        guard let id = selectedField else { return nil }
        func find(_ fs: [PField]) -> PField? {
            for f in fs {
                if f.id == id { return f }
                if let c = f.children, let hit = find(c) { return hit }
            }
            return nil
        }
        return find(fields)?.range
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            accessBanner
            toolbar
            VSplitView {
                packetTable
                    .frame(minHeight: 200)
                HSplitView {
                    detailTree.frame(minWidth: 320)
                    hexView.frame(minWidth: 380)
                }
                .frame(minHeight: 200)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .task {
            if let p = model.physicalInterface?.name ?? model.net.primaryInterface { session.interface = p }
            await session.checkAccess()
        }
        .onChange(of: session.selection) { _, id in
            fields = id.map { session.detail($0) } ?? []
            selectedField = nil
        }
        .onDisappear { session.stop() }
        .fileExporter(isPresented: $exporting, document: exportDoc,
                      contentType: .pcap, defaultFilename: "netlens-\(Int(Date().timeIntervalSince1970)).pcap") { _ in }
    }

    // MARK: header & controls

    private var header: some View {
        PageHeader(eyebrow: "Capture · tcpdump / Wireshark-lite", title: "Packet capture",
                   subtitle: "Raw frames off the wire via the kernel's BPF tap, decoded down to TLS server names, DNS answers and TCP flags. Save as .pcap to continue in Wireshark.") {
            HStack(spacing: 8) {
                Chip(text: "\(session.rows.count) captured", color: Theme.ink2)
                Chip(text: "\(session.filtered.count) shown")
                Chip(text: String(format: "%.0f pkt/s", session.rate), color: session.state == .capturing ? Theme.amber : Theme.muted)
                Chip(text: Fmt.bytes(session.totalBytes), color: Theme.ink2)
            }
        }
    }

    @ViewBuilder private var accessBanner: some View {
        switch session.access {
        case .none(let inGroup):
            HStack(spacing: 12) {
                Callout(kind: .tip, title: "Packet capture needs one-time permission",
                        message: inGroup
                        ? "You're in the access_bpf group (Wireshark set that up), but the BPF devices are currently root-only. Grant access until the next reboot, or install the NetLens helper for permanent access."
                        : "Install the NetLens privileged helper (from the Bandwidth tab) — it opens capture devices on NetLens's behalf, so nothing on your system needs loosened permissions.")
                if inGroup {
                    Button("Grant access…") { Task { await session.grantGroupAccess() } }.buttonStyle(.borderedProminent)
                }
                Button("Install helper") { model.open(.bandwidth) }.buttonStyle(.bordered)
            }
        case .helper:
            Text("Capturing through the NetLens helper (BPF descriptor passed over its socket).").font(.mono(10.5)).foregroundStyle(Theme.muted)
        default:
            EmptyView()
        }
        if case .failed(let msg) = session.state {
            Callout(kind: .warning, title: "Capture stopped", message: msg)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $session.interface) {
                ForEach(model.interfaces.filter { $0.isUp }) { i in
                    Text("\(i.name) · \(i.displayName)").tag(i.name)
                }
            }
            .labelsHidden()
            .frame(width: 210)
            .disabled(session.state == .capturing)

            if session.state == .capturing {
                Button { session.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(AmberButtonStyle(color: Theme.coral))
            } else {
                Button { session.start() } label: { Label("Capture", systemImage: "record.circle") }
                    .buttonStyle(.borderedProminent)
                    .disabled({ if case .none = session.access { return true }; return session.access == .unknown }())
            }
            Button { session.clear(); fields = [] } label: { Image(systemName: "trash") }.buttonStyle(.bordered).help("Clear")

            InstrumentField(placeholder: "Filter — e.g. dns, tls and sni contains openai, host 1.1.1.1, port 443, not arp", text: $session.filterText, icon: "line.3.horizontal.decrease")
            InfoButton(term: .captureFilter)
            Button {
                exportDoc = PcapDocument(data: session.pcapData(filteredOnly: !session.filterText.isEmpty))
                exporting = true
            } label: { Label(session.filterText.isEmpty ? "Save .pcap" : "Save filtered .pcap", systemImage: "square.and.arrow.down") }
                .buttonStyle(.bordered)
                .disabled(session.rows.isEmpty)
        }
    }

    // MARK: packet list

    private var packetTable: some View {
        Table(session.filtered, selection: $session.selection) {
            TableColumn("No.") { r in Text(verbatim: String(r.id)).font(.mono(11)).foregroundStyle(Theme.muted) }
                .width(min: 36, ideal: 56)
            TableColumn("Time") { r in Text(String(format: "%.6f", r.time)).font(.mono(11)).foregroundStyle(Theme.muted) }
                .width(min: 36, ideal: 84)
            TableColumn("Source") { r in Text(r.src).font(.mono(11)).foregroundStyle(Theme.ink).lineLimit(1) }
                .width(min: 110, ideal: 160)
            TableColumn("Destination") { r in Text(r.dst).font(.mono(11)).foregroundStyle(Theme.ink).lineLimit(1) }
                .width(min: 110, ideal: 160)
            TableColumn("Protocol") { r in
                Text(r.proto)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(color(r.category))
                    .padding(.horizontal, 6).padding(.vertical, 1)

            }
            .width(min: 36, ideal: 74)
            TableColumn("Length") { r in Text(verbatim: String(r.length)).font(.mono(11)).foregroundStyle(Theme.ink2) }
                .width(min: 36, ideal: 56)
            TableColumn("Info") { r in
                Text(r.info).font(.mono(11)).foregroundStyle(r.category == .tcpReset ? Theme.coral : Theme.ink2).lineLimit(1)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .overlay {
            if session.filtered.isEmpty {
                EmptyState(icon: session.state == .capturing ? "antenna.radiowaves.left.and.right" : "waveform.badge.magnifyingglass",
                           title: session.state == .capturing ? "Listening on \(session.interface)…" : "No packets yet",
                           message: session.state == .capturing ? nil : "Pick an interface and press Capture. Try the filter “tls” to see which hostnames every app connects to.")
            }
        }
    }

    private func color(_ c: PacketRow.Category) -> Color {
        switch c {
        case .tcp, .udp, .other: Theme.secondary
        case .tcpControl: Theme.tertiary
        case .tcpReset: Theme.bad
        case .dns: .blue
        case .tls: .purple
        case .quic: .indigo
        case .http: .green
        case .arp: .orange
        case .icmp: .pink
        }
    }

    // MARK: details

    private var detailTree: some View {
        List(fields, children: \.children, selection: $selectedField) { f in
            Text(f.label)
                .font(.mono(11.5))
                .foregroundStyle(f.label.hasPrefix("Frame") ? Theme.muted : Theme.ink)
                .textSelection(.enabled)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg1)
        .overlay { if fields.isEmpty { Text("Select a packet").font(.system(size: 12)).foregroundStyle(Theme.faint) } }
    }

    private var hexView: some View {
        let bytes = session.selection.flatMap { session.rawPacket($0)?.data } ?? []
        let range = selectedRange
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(0..<((bytes.count + 15) / 16), id: \.self) { line in
                    HexLine(bytes: bytes, line: line, highlight: range)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay { if bytes.isEmpty { Text("Bytes appear here").font(.system(size: 12)).foregroundStyle(Theme.faint) } }
    }
}

private struct HexLine: View {
    let bytes: [UInt8]
    let line: Int
    let highlight: Range<Int>?

    var body: some View {
        let start = line * 16
        let end = min(bytes.count, start + 16)
        var hex = AttributedString(String(format: "%04x  ", start))
        hex.foregroundColor = Theme.faint
        var ascii = AttributedString("  ")
        for i in start..<start + 16 {
            if i < end {
                var h = AttributedString(String(format: "%02x", bytes[i]) + (i == start + 7 ? "  " : " "))
                let c = bytes[i]
                var a = AttributedString(c >= 0x20 && c < 0x7F ? String(UnicodeScalar(c)) : "·")
                let hit = highlight?.contains(i) ?? false
                h.foregroundColor = hit ? .white : Theme.ink2
                a.foregroundColor = hit ? .white : Theme.muted
                if hit { h.backgroundColor = Theme.accent; a.backgroundColor = Theme.accent }
                hex += h
                ascii += a
            } else {
                hex += AttributedString("   " + (i == start + 7 ? " " : ""))
            }
        }
        return Text(hex + ascii).font(.code(11.5)).textSelection(.enabled)
    }
}

struct PcapDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pcap] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension UTType {
    static let pcap = UTType(filenameExtension: "pcap") ?? .data
}
