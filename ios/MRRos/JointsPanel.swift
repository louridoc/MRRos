import ROSMessages
import SwiftUI

/// Live joint positions as bars in [-π, π] with the value in degrees.
struct JointsPanel: View {
    let jointState: SensorMsgs.JointState
    let rateHz: Double
    let robotName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(robotName ?? "joints").font(.caption.bold())
                Spacer()
                Text(String(format: "%.0f Hz", rateHz)).font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(jointState.name.enumerated()), id: \.offset) { i, name in
                let value = i < jointState.position.count ? jointState.position[i] : 0
                HStack(spacing: 8) {
                    Text(name)
                        .font(.caption2.monospaced())
                        .frame(width: 110, alignment: .leading)
                        .lineLimit(1)
                    JointBar(value: value)
                    Text(String(format: "%6.1f°", value * 180 / .pi))
                        .font(.caption2.monospacedDigit())
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct JointBar: View {
    let value: Double // radians

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let mid = w / 2
            let x = mid + CGFloat(max(-1, min(1, value / .pi))) * mid
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Rectangle().fill(.secondary).frame(width: 1).offset(x: mid)
                Capsule().fill(.tint)
                    .frame(width: abs(x - mid))
                    .offset(x: min(x, mid))
            }
        }
        .frame(height: 8)
    }
}
