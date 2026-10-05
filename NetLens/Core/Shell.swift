import Foundation

/// Runs the system's own networking tools (nettop, netstat, arp, route, networkQuality…).
/// They ship with every Mac, need no privileges, and are the ground truth.
enum Shell {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(path, args, timeout: timeout))
            }
        }
    }

    static func runSync(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return Result(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        killer.cancel()
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Runs an AppleScript `do shell script … with administrator privileges` — the
    /// standard macOS password prompt. Only ever triggered by an explicit user action.
    static func runAsAdmin(_ command: String) async -> Result {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return await run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: 120)
    }
}

/// Long-running process with line-by-line output (used for tools that stream).
final class StreamingProcess {
    private let process = Process()
    private var buffer = Data()
    private let lock = NSLock()
    var onLine: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    init(_ path: String, _ args: [String]) {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
    }

    func start() throws {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.consume(d)
        }
        process.terminationHandler = { [weak self] p in self?.onExit?(p.terminationStatus) }
        try process.run()
    }

    private func consume(_ d: Data) {
        lock.lock()
        buffer.append(d)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    var isRunning: Bool { process.isRunning }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}
