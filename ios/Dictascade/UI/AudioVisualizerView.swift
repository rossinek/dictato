import SwiftUI

private struct AudioBar: Identifiable {
    let id = UUID()
    let level: Float
    let birthTime: Date
}

struct AudioVisualizerView: View {
    let levels: [Float]
    private let barWidth: CGFloat = 2.5
    private let minBarHeight: CGFloat = 2.5
    private let travelDuration: TimeInterval = 3.0

    @State private var bars: [AudioBar] = []

    var body: some View {
        GeometryReader { geo in
            let maxHeight = geo.size.height
            let width = geo.size.width

            TimelineView(.animation) { context in
                let now = context.date

                Canvas { ctx, size in
                    let fadeZone: CGFloat = 0.15

                    for bar in bars {
                        let age = now.timeIntervalSince(bar.birthTime)
                        let progress = age / travelDuration
                        guard progress >= 0 && progress <= 1 else { continue }

                        let eased = easeInOut(Float(progress))
                        let x = width * (1 - CGFloat(eased)) - barWidth / 2
                        let barHeight = max(minBarHeight, CGFloat(bar.level) * maxHeight)

                        // Edge proximity (0 at edge, 1 in center)
                        let posNorm = x / width
                        let edgeProximity: CGFloat
                        if posNorm < fadeZone {
                            edgeProximity = posNorm / fadeZone
                        } else if posNorm > 1 - fadeZone {
                            edgeProximity = (1 - posNorm) / fadeZone
                        } else {
                            edgeProximity = 1
                        }

                        // Vertical scale: 2x at edge, 1x in center
                        let maxScale: CGFloat = 2.0
                        let vScale = 1 + (maxScale - 1) * (1 - edgeProximity)
                        let scaledHeight = barHeight * vScale
                        let scaledY = (maxHeight - scaledHeight) / 2

                        let baseOpacity = 0.3 + Double(bar.level) * 0.7
                        let rect = CGRect(x: x, y: scaledY, width: barWidth, height: scaledHeight)
                        let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                        ctx.fill(path, with: .color(.primary.opacity(baseOpacity * Double(edgeProximity))))
                    }
                }
                .frame(width: width, height: maxHeight)
            }
        }
        .onChange(of: levels) {
            let now = Date.now

            if let last = levels.last {
                bars.append(AudioBar(level: normalizeLevel(last), birthTime: now))
            }

            bars.removeAll { now.timeIntervalSince($0.birthTime) > travelDuration }
        }
    }

    /// Fast at edges, slow (but never zero) in middle
    private func easeInOut(_ t: Float) -> Float {
        if t < 0.5 {
            return 0.5 * pow(2 * t, 0.6)
        } else {
            return 1 - 0.5 * pow(2 * (1 - t), 0.6)
        }
    }

    private func normalizeLevel(_ level: Float) -> Float {
        guard level > 0 else { return 0 }
        let dbFloor: Float = -70
        let dbCeil: Float = -10
        let db = 20 * log10(level)
        let normalized = (db - dbFloor) / (dbCeil - dbFloor)
        return max(0, min(1, normalized))
    }
}
