import SwiftUI

/// Spectrum display stub (Chunk 3.1): pre-EQ and post-EQ traces over the
/// log-frequency display bins. The polished version (axis labels, response
/// curve overlay, draggable EQ handles) is Phase 5 — this proves the data path.
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
