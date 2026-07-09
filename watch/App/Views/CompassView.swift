import SwiftUI
import StallAlertKit

struct CompassView: View {
    let reading: StationReading
    let stale: Bool
    var size: CGFloat = 30

    var body: some View {
        let render = CompassModel.render(reading: reading, now: Date())
        ZStack {
            Circle().stroke(.secondary.opacity(0.3), lineWidth: 1)
            ForEach(Array(render.ticks.enumerated()), id: \.offset) { _, tick in
                Capsule()
                    .fill(.primary.opacity(tick.opacity))
                    .frame(width: 1.5, height: size * 0.18)
                    .offset(y: -size * 0.41)
                    .rotationEffect(.degrees(tick.angleDeg))
            }
            Image(systemName: "location.north.fill")
                .font(.system(size: size * 0.45))
                .rotationEffect(.degrees(render.arrowAngleDeg))
        }
        .frame(width: size, height: size)
        .foregroundStyle(stale ? .secondary : .primary)
        .grayscale(stale ? 1 : 0)
    }
}
