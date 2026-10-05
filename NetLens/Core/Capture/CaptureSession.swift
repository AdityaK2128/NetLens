import Foundation
import Observation

@MainActor
@Observable
final class CaptureSession {
    enum State: Equatable { case idle, capturing, stopped, failed(String) }
    enum Access: Equatable { case unknown, direct, helper, none(inAccessGroup: Bool) }

    var state: State = .idle
    var access: Access = .unknown
    var interface = "en0"
    var filterText = "" { didSet { refilter() } }
    var selection: PacketRow.ID?
    private(set) var rows: [PacketRow] = []
    private(set) var filtered: [PacketRow] = []
    private(set) var protocolCounts: [String: Int] = [:]
    private(set) var totalBytes = 0
    private(set) var rate: Double = 0
    private(set) var startedAt: Date?
    private(set) var dlt: UInt32 = 1

    let maxPackets = 60_000

    @ObservationIgnored private var raw: [RawPacket] = []
    @ObservationIgnored private var firstID = 1
    @ObservationIgnored private var capture: BPFCapture?
    @ObservationIgnored private var pendingRows: [PacketRow] = []
    @ObservationIgnored private var pendingRaw: [RawPacket] = []
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var lastRateCheck = (Date(), 0)

    var filterIsValid: Bool { true }

    func checkAccess() async {
        if BPFCapture.canOpenDirectly { access = .direct; return }
        if let r = await BandwidthShaper.send(["cmd": "status"]), r["ok"] as? Bool == true { access = .helper; return }
        let groups = await Shell.run("/usr/bin/id", ["-Gn"], timeout: 3).stdout
        access = .none(inAccessGroup: groups.split(separator: " ").contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "access_bpf" })
    }

    /// One-off: let the access_bpf group read BPF devices until the next reboot
    /// (what Wireshark's ChmodBPF does at boot).
    func grantGroupAccess() async {
        let r = await Shell.runAsAdmin("chgrp access_bpf /dev/bpf* && chmod g+rw /dev/bpf*")
        if !r.ok { state = .failed(r.stderr.contains("canceled") ? "Cancelled" : r.stderr.trimmed) }
        await checkAccess()
    }

    func start() {
        stop()
        var fd: Int32? = nil
        if access == .helper {
            switch HelperBPF.requestFD() {
            case .success(let f): fd = f
            case .failure(let e): state = .failed(e.description); return
            }
        }
        let cap = BPFCapture(interface: interface)
        let t0 = Date().timeIntervalSince1970
        var decoder: PacketDecoder?
        var counter = (rows.last?.id ?? 0)
        cap.onPackets = { [weak self] packets in
            guard let self else { return }
            if decoder == nil { decoder = PacketDecoder(dlt: cap.dlt) }
            var batch: [PacketRow] = []
            batch.reserveCapacity(packets.count)
            for p in packets {
                counter += 1
                batch.append(decoder!.summarize(p, number: counter, t0: t0))
            }
            self.lock.lock()
            self.pendingRows += batch
            self.pendingRaw += packets
            self.lock.unlock()
        }
        cap.onStop = { [weak self] err in
            Task { @MainActor in
                guard let self else { return }
                if let err { self.state = .failed(err) } else if self.state == .capturing { self.state = .stopped }
            }
        }
        do {
            try cap.start(fd: fd)
            capture = cap
            dlt = cap.dlt
            state = .capturing
            startedAt = Date()
            flushTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.flush()
                }
            }
        } catch {
            state = .failed((error as? BPFCapture.CaptureError)?.description ?? error.localizedDescription)
            if case BPFCapture.CaptureError.permission = error { Task { await checkAccess() } }
        }
    }

    func stop() {
        capture?.stop()
        capture = nil
        flushTask?.cancel()
        flushTask = nil
        flush()
        if state == .capturing { state = .stopped }
    }

    func clear() {
        lock.lock(); pendingRows = []; pendingRaw = []; lock.unlock()
        rows = []; filtered = []; raw = []; firstID = 1
        protocolCounts = [:]; totalBytes = 0; selection = nil
    }

    private func flush() {
        lock.lock()
        let newRows = pendingRows, newRaw = pendingRaw
        pendingRows = []; pendingRaw = []
        lock.unlock()
        guard !newRows.isEmpty else { updateRate(0); return }
        if rows.isEmpty { firstID = newRows[0].id }
        rows += newRows
        raw += newRaw
        for r in newRows {
            protocolCounts[r.proto, default: 0] += 1
            totalBytes += r.length
        }
        if rows.count > maxPackets {
            let drop = rows.count - maxPackets
            rows.removeFirst(drop)
            raw.removeFirst(drop)
            firstID = rows.first?.id ?? firstID
            if filtered.count > maxPackets { filtered.removeFirst(filtered.count - maxPackets) }
        }
        let f = PacketFilter(expression: filterText)
        filtered += newRows.filter(f.matches)
        updateRate(newRows.count)
    }

    private func updateRate(_ n: Int) {
        let (t, count) = lastRateCheck
        let total = count + n
        let dt = Date().timeIntervalSince(t)
        if dt >= 1 {
            rate = Double(total) / dt
            lastRateCheck = (Date(), 0)
        } else {
            lastRateCheck = (t, total)
        }
    }

    private func refilter() {
        let f = PacketFilter(expression: filterText)
        filtered = rows.filter(f.matches)
    }

    func rawPacket(_ id: PacketRow.ID) -> RawPacket? {
        let i = id - firstID
        guard i >= 0, i < raw.count else { return nil }
        return raw[i]
    }

    func row(_ id: PacketRow.ID) -> PacketRow? {
        let i = id - firstID
        guard i >= 0, i < rows.count, rows[i].id == id else { return rows.first { $0.id == id } }
        return rows[i]
    }

    func detail(_ id: PacketRow.ID) -> [PField] {
        guard let p = rawPacket(id), let r = row(id) else { return [] }
        return PacketDecoder.dissect(p, row: r, dlt: dlt, interface: interface)
    }

    func pcapData(filteredOnly: Bool) -> Data {
        let packets: [RawPacket]
        if filteredOnly {
            packets = filtered.compactMap { rawPacket($0.id) }
        } else {
            packets = raw
        }
        return PcapWriter.data(packets: packets, dlt: dlt)
    }
}
