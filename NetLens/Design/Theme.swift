import SwiftUI
import AppKit

/// NetLens visual language: native macOS. Semantic system colors (light & dark),
/// one restrained accent, SF Pro with monospaced digits where numbers change, hairline
/// separators, no glows or gradients. Color is used only to carry meaning.
enum Theme {
    // MARK: Surfaces
    static let bg        = Color(nsColor: .windowBackgroundColor)
    static let bg1       = Color(nsColor: .windowBackgroundColor)
    static let card      = Color(nsColor: .controlBackgroundColor)
    static let fill      = Color.primary.opacity(0.045)       // subtle inset / track
    static let separator = Color(nsColor: .separatorColor)

    // MARK: Text
    static let text      = Color.primary
    static let secondary = Color.secondary
    static let tertiary  = Color(nsColor: .tertiaryLabelColor)

    // MARK: Meaning
    static let accent    = Color.accentColor
    static let good      = Color(nsColor: .systemGreen)
    static let warn      = Color(nsColor: .systemOrange)
    static let bad       = Color(nsColor: .systemRed)
    static let down      = Color(nsColor: .systemBlue)        // received
    static let up        = Color(nsColor: .systemPurple)      // sent
    static let special   = Color(nsColor: .systemIndigo)      // tunnels, relays, anycast

    // MARK: Legacy aliases (pre-redesign names, remapped to the native palette)
    static let panel     = card
    static let panel2    = card
    static let raised    = card
    static let trough    = fill
    static let line      = separator
    static let lineSoft  = separator.opacity(0.6)
    static let amber     = text
    static let amberSoft = Color(nsColor: .systemOrange)
    static let teal      = text
    static let tealSoft  = Color(nsColor: .systemTeal)
    static let coral     = bad
    static let violet    = special
    static let lime      = text
    static let ink       = text
    static let ink2      = secondary
    static let muted     = secondary
    static let faint     = tertiary

    static let radius: CGFloat = 10
    static let radiusSmall: CGFloat = 7
    static let radiusLarge: CGFloat = 14

    /// Latency → text colour. Neutral in the normal range; colour only when it matters.
    static func latency(_ ms: Double?) -> Color {
        guard let ms else { return tertiary }
        switch ms {
        case ..<150: return text
        case ..<300: return warn
        default: return bad
        }
    }

    /// Latency → trace colour for graphics (globe arcs, markers) where neutral must still be a colour.
    static func latencyTrace(_ ms: Double?) -> Color {
        guard let ms else { return Color(nsColor: .systemGray) }
        switch ms {
        case ..<50: return good
        case ..<150: return accent
        case ..<300: return warn
        default: return bad
        }
    }

    /// Wi-Fi RSSI (dBm) → colour.
    static func signal(_ rssi: Int?) -> Color {
        guard let rssi else { return tertiary }
        switch rssi {
        case (-72)...: return text
        case (-80)...: return warn
        default: return bad
        }
    }

    static func loss(_ pct: Double) -> Color {
        switch pct {
        case ..<0.5: return text
        case ..<3: return warn
        default: return bad
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension Font {
    /// SF Pro with tabular digits — for values that change (rates, latencies, counts, addresses).
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: max(size, 10.5), weight: weight).monospacedDigit()
    }
    /// True monospace — only for byte dumps and tool output.
    static func code(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Headings.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }
}

extension View {
    /// Small secondary caption above a title (sentence case, no decoration).
    func eyebrowStyle(_ color: Color = Theme.secondary) -> some View {
        self.font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.secondary)
    }

    /// Kept for source compatibility — the native design has no glows.
    func glow(_ color: Color, radius: CGFloat = 8, opacity: Double = 0.55) -> some View { self }
}
