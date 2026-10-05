import SwiftUI

/// Thin line chart for live series. `nil` samples are gaps (and, with `markGaps`,
/// small red ticks — e.g. lost pings).
struct Sparkline: View {
    var values: [Double?]
    var color: Color = Theme.accent
    var lineWidth: CGFloat = 1.25
    var fill: Bool = true
    var markGaps: Bool = false
    var minY: Double? = 0
    var maxY: Double? = nil
    var capacity: Int? = nil

    var body: some View {
        Canvas { ctx, size in
            let n = max(capacity ?? values.count, 2)
            let present = values.compactMap { $0 }
            guard !values.isEmpty else { return }
            let lo = minY ?? (present.min() ?? 0)
            var hi = maxY ?? (present.max() ?? 1)
            if hi - lo < 0.0001 { hi = lo + 1 }
            let offset = n - values.count
            func pt(_ i: Int, _ v: Double) -> CGPoint {
                CGPoint(x: size.width * CGFloat(i + offset) / CGFloat(n - 1),
                        y: size.height - size.height * CGFloat((v - lo) / (hi - lo)) * 0.92 - 1)
            }

            var segments: [[CGPoint]] = []
            var current: [CGPoint] = []
            for (i, v) in values.enumerated() {
                if let v {
                    current.append(pt(i, v))
                } else {
                    if !current.isEmpty { segments.append(current); current = [] }
                    if markGaps {
                        let x = size.width * CGFloat(i + offset) / CGFloat(n - 1)
                        var tick = Path()
                        tick.move(to: CGPoint(x: x, y: size.height))
                        tick.addLine(to: CGPoint(x: x, y: size.height * 0.7))
                        ctx.stroke(tick, with: .color(Theme.bad.opacity(0.7)), lineWidth: 1)
                    }
                }
            }
            if !current.isEmpty { segments.append(current) }

            for seg in segments {
                var line = Path()
                line.addLines(seg)
                if fill, seg.count > 1, let first = seg.first, let last = seg.last {
                    var area = line
                    area.addLine(to: CGPoint(x: last.x, y: size.height))
                    area.addLine(to: CGPoint(x: first.x, y: size.height))
                    area.closeSubpath()
                    ctx.fill(area, with: .color(color.opacity(0.10)))
                }
                ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// Faint reference grid.
struct Graticule: View {
    var columns: Int = 10
    var rows: Int = 4
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            for j in 1..<rows {
                let y = size.height * CGFloat(j) / CGFloat(rows)
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(p, with: .color(Theme.separator.opacity(0.5)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// Throughput: received above the baseline, sent mirrored below.
struct DualTrace: View {
    var down: [Double]
    var up: [Double]
    var capacity: Int

    var body: some View {
        GeometryReader { geo in
            let peak = max(down.max() ?? 0, up.max() ?? 0, 1)
            VStack(spacing: 0) {
                Sparkline(values: down.map { Optional($0) }, color: Theme.down, minY: 0, maxY: peak, capacity: capacity)
                    .frame(height: geo.size.height / 2)
                Sparkline(values: up.map { Optional($0) }, color: Theme.up, minY: 0, maxY: peak, capacity: capacity)
                    .frame(height: geo.size.height / 2)
                    .scaleEffect(x: 1, y: -1)
            }
        }
    }
}
