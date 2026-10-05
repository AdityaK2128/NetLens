import Foundation

enum Fmt {
    /// 1536 → "1.5 KB" (binary units, the way network tools report byte counts).
    static func bytes(_ v: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = v
        var i = 0
        while value >= 1024, i < units.count - 1 { value /= 1024; i += 1 }
        if i == 0 { return "\(Int(value)) B" }
        return String(format: value >= 100 ? "%.0f %@" : value >= 10 ? "%.1f %@" : "%.2f %@", value, units[i])
    }

    static func bytes<T: BinaryInteger>(_ v: T) -> String { bytes(Double(v)) }

    /// Byte rate → bits per second, decimal units (how links are advertised).
    static func bitrate(bytesPerSecond v: Double) -> String {
        bitrate(bitsPerSecond: v * 8)
    }

    static func bitrate(bitsPerSecond bits: Double) -> String {
        let units = ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]
        var value = bits
        var i = 0
        while value >= 1000, i < units.count - 1 { value /= 1000; i += 1 }
        if i == 0 { return String(format: "%.0f bps", value) }
        return String(format: value >= 100 ? "%.0f %@" : value >= 10 ? "%.1f %@" : "%.2f %@", value, units[i])
    }

    /// Splits a rate into (number, unit) for readouts that style the unit separately.
    static func bitrateParts(bytesPerSecond v: Double) -> (String, String) {
        let s = bitrate(bytesPerSecond: v)
        let parts = s.split(separator: " ")
        return (String(parts.first ?? ""), String(parts.last ?? ""))
    }

    static func bytesParts(_ v: Double) -> (String, String) {
        let s = bytes(v)
        let parts = s.split(separator: " ")
        return (String(parts.first ?? ""), String(parts.last ?? ""))
    }

    static func ms(_ v: Double?, digits: Int? = nil) -> String {
        guard let v else { return "—" }
        if let digits { return String(format: "%.\(digits)f ms", v) }
        if v < 1 { return String(format: "%.2f ms", v) }
        if v < 10 { return String(format: "%.1f ms", v) }
        return String(format: "%.0f ms", v)
    }

    static func msValue(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v < 1 { return String(format: "%.2f", v) }
        if v < 10 { return String(format: "%.1f", v) }
        return String(format: "%.0f", v)
    }

    static func percent(_ v: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f%%", v)
    }

    static func km(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.1fk km", v / 1000) : String(format: "%.0f km", v)
    }

    static func count(_ v: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static let clockMillis: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func hex(_ v: UInt64, width: Int = 4) -> String {
        "0x" + String(v, radix: 16, uppercase: false).leftPad(width, "0")
    }

    static func flag(_ countryCode: String?) -> String {
        guard let cc = countryCode?.uppercased(), cc.count == 2 else { return "" }
        var s = ""
        for scalar in cc.unicodeScalars {
            guard let u = UnicodeScalar(127397 + scalar.value) else { return "" }
            s.unicodeScalars.append(u)
        }
        return s
    }
}

extension String {
    func leftPad(_ width: Int, _ ch: Character = " ") -> String {
        count >= width ? self : String(repeating: ch, count: width - count) + self
    }
    func rightPad(_ width: Int, _ ch: Character = " ") -> String {
        count >= width ? self : self + String(repeating: ch, count: width - count)
    }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
