import SwiftUI

/// Spectrum display: pre-EQ and post-EQ traces over the log-frequency display
/// bins, drawn behind the EQ response curve and its draggable band handles.
struct SpectrumView: View {
    let preLevels: [Float]
    let postLevels: [Float]
    let showPre: Bool
    let showPost: Bool

    private static let floorDB: Float = -100
    private static let ceilingDB: Float = 0

    var body: some View {
        Canvas { context, size in
            // Faint dB gridlines every 20 dB.
            var grid = Path()
            for db in stride(from: -80, through: -20, by: 20) {
                let y = y(forDB: Float(db), height: size.height)
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 1)

            if showPre, preLevels.count > 1 {
                context.stroke(path(for: preLevels, in: size),
                               with: .color(.secondary.opacity(0.6)), lineWidth: 1)
            }
            if showPost, postLevels.count > 1 {
                let path = path(for: postLevels, in: size)
                context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
            }
        }
        .accessibilityLabel("Spectrum analyzer")
        .accessibilityHidden(false)
    }

    private func y(forDB db: Float, height: CGFloat) -> CGFloat {
        let clamped = min(max(db, Self.floorDB), Self.ceilingDB)
        let normalized = (clamped - Self.floorDB) / (Self.ceilingDB - Self.floorDB)
        return height * CGFloat(1 - normalized)
    }

    private func path(for levels: [Float], in size: CGSize) -> Path {
        var path = Path()
        let stepX = size.width / CGFloat(levels.count - 1)
        for (i, level) in levels.enumerated() {
            let point = CGPoint(x: CGFloat(i) * stepX, y: y(forDB: level, height: size.height))
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

/// Compact overlay legend for the stacked spectrum + EQ editor view.
struct SpectrumLegend: View {
    let showPre: Bool
    let showPost: Bool
    let hasEQCurve: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showPre {
                legendRow(
                    swatch: .line(color: .secondary.opacity(0.6), width: 1),
                    title: "Pre",
                    detail: "system input (dBFS)"
                )
            }
            if showPost {
                legendRow(
                    swatch: .line(color: .accentColor, width: 1.5),
                    title: "Post",
                    detail: "after EQ + preamp + output (dBFS)"
                )
            }
            if hasEQCurve {
                legendRow(
                    swatch: .curve,
                    title: "EQ curve",
                    detail: "filter gain only (excludes preamp)"
                )
            }
        }
        .font(.caption2)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(legendAccessibilityLabel)
    }

    private var legendAccessibilityLabel: String {
        var parts = ["Spectrum legend"]
        if showPre { parts.append("pre trace shows unprocessed input in dBFS") }
        if showPost { parts.append("post trace shows output after EQ preamp and master gain in dBFS") }
        if hasEQCurve { parts.append("EQ curve shows filter gain only not including preamp") }
        return parts.joined(separator: ". ")
    }

    private enum Swatch {
        case line(color: Color, width: CGFloat)
        case curve
    }

    @ViewBuilder
    private func legendRow(swatch: Swatch, title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Group {
                switch swatch {
                case .line(let color, let width):
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color)
                        .frame(width: 18, height: width)
                case .curve:
                    ZStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 18, height: 8)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accentColor)
                            .frame(width: 18, height: 2)
                            .offset(y: -1)
                    }
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
