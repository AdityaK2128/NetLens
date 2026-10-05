import SwiftUI
import AppKit

// MARK: - Page scaffolding

/// Plain window background (kept as a type so existing call sites keep working).
struct InkBackground: View {
    var body: some View { Theme.bg.ignoresSafeArea() }
}

struct PageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if let subtitle {
                    // Bounded line count (not fixedSize): an unbounded text height would
                    // inflate the window's minimum size when SwiftUI measures narrow widths.
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: 760, alignment: .leading)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct Page<Content: View>: View {
    var spacing: CGFloat = 20
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
    }
}

// MARK: - Card

struct Panel<Content: View, Accessory: View>: View {
    var title: String?
    var icon: String?
    var info: Glossary? = nil
    var padding: CGFloat = 16
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(spacing: 8) {
                    if let title {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text)
                    }
                    if let info { InfoButton(term: info) }
                    Spacer(minLength: 8)
                    accessory
                        .font(.system(size: 12))
                }
                .padding(.horizontal, padding)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(PanelBackground())
    }
}

extension Panel where Accessory == EmptyView {
    init(_ title: String? = nil, icon: String? = nil, info: Glossary? = nil, padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.info = info
        self.padding = padding
        self.accessory = EmptyView()
        self.content = content()
    }
}

extension Panel {
    init(_ title: String? = nil, icon: String? = nil, info: Glossary? = nil, padding: CGFloat = 16,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.info = info
        self.padding = padding
        self.accessory = accessory()
        self.content = content()
    }
}

struct PanelBackground: View {
    var radius: CGFloat = Theme.radius
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.card)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 0.5)
            )
    }
}

/// Inset area for charts, logs and dumps.
struct ScreenFrame<Content: View>: View {
    var label: String?
    var live: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
            if let label {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiary)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.fill))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
    }
}

// MARK: - Metrics

struct Readout: View {
    let label: String
    let value: String
    var unit: String? = nil
    var accent: Color = Theme.text
    var caption: String? = nil
    var size: CGFloat = 24
    var info: Glossary? = nil

    /// Numbers stay neutral; only warnings and failures are coloured.
    private var valueColor: Color {
        accent == Theme.bad || accent == Theme.warn ? accent : Theme.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TermLabel(text: label, term: info)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: size, weight: .medium).monospacedDigit())
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Text(caption ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelBackground())
    }
}

// MARK: - Chips, dots, rows

struct Chip: View {
    let text: String
    var color: Color = Theme.secondary
    var filled: Bool = false
    var icon: String? = nil

    /// Chips only take colour when they report a problem.
    private var flagged: Bool { color == Theme.bad || color == Theme.warn }

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .foregroundStyle(filled ? Color.white : (flagged ? color : Theme.secondary))
        .background(
            Capsule(style: .continuous)
                .fill(filled ? (flagged ? color : Theme.accent) : (flagged ? color.opacity(0.12) : Theme.fill))
        )
        .fixedSize()
    }
}

struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

struct KV: View {
    let key: String
    let value: String
    var color: Color = Theme.text
    var mono: Bool = true
    var help: String? = nil
    var info: Glossary? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TermLabel(text: key, term: info, font: .system(size: 12))
                .frame(minWidth: 110, alignment: .leading)
                .help(help ?? "")
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.separator).frame(height: 0.5) }
}

struct SignalBars: View {
    let rssi: Int?
    var height: CGFloat = 13

    private var level: Int {
        guard let rssi else { return 0 }
        switch rssi {
        case (-55)...: return 4
        case (-67)...: return 3
        case (-75)...: return 2
        case (-85)...: return 1
        default: return 0
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < level ? Theme.text : Theme.separator)
                    .frame(width: 3, height: height * CGFloat(i + 1) / 4)
            }
        }
    }
}

struct Meter: View {
    var value: Double
    var color: Color = Theme.accent
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill)
                Capsule()
                    .fill(color == Theme.text ? Theme.accent : color)
                    .frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Buttons (thin wrappers so old call sites map onto native styles)

struct AmberButtonStyle: PrimitiveButtonStyle {
    var color: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) { configuration.label }
            .buttonStyle(.borderedProminent)
            .tint(color)
    }
}

struct GhostButtonStyle: PrimitiveButtonStyle {
    var tint: Color = Theme.secondary
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) { configuration.label }
            .buttonStyle(.bordered)
    }
}

extension PrimitiveButtonStyle where Self == AmberButtonStyle {
    static var amber: AmberButtonStyle { AmberButtonStyle() }
}
extension PrimitiveButtonStyle where Self == GhostButtonStyle {
    static var ghost: GhostButtonStyle { GhostButtonStyle() }
}

// MARK: - Segmented control (native)

struct Segmented<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.self) { Text(label($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - Text field

struct InstrumentField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String = "magnifyingglass"
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.separator, lineWidth: 0.5))
        )
    }
}

// MARK: - Empty / info states

struct EmptyState: View {
    let icon: String
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
            if let message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

struct Callout: View {
    enum Kind { case info, tip, warning }
    var kind: Kind = .info
    let title: String
    var message: String? = nil

    private var color: Color {
        switch kind { case .info: Theme.accent; case .tip: Theme.accent; case .warning: Theme.warn }
    }
    private var icon: String {
        switch kind { case .info: "info.circle"; case .tip: "lightbulb"; case .warning: "exclamationmark.triangle" }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                if let message {
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .lineLimit(6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(color.opacity(0.07)))
    }
}

// MARK: - Helpers

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

extension View {
    func copyable(_ value: String) -> some View {
        contextMenu {
            Button("Copy “\(value.prefix(40))”") { copyToPasteboard(value) }
        }
    }
}

struct ProcessIcon: View {
    let image: NSImage?
    var size: CGFloat = 16
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "gearshape")
                    .resizable().scaledToFit().padding(2)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(width: size, height: size)
    }
}
