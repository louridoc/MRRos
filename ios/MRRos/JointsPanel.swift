import ROSMessages
import SwiftUI

/// Live joint positions as bars in [-π, π] with the value in degrees. Greys out and says
/// "stale" when `/joint_states` stops arriving, so a frozen feed never looks healthy.
struct JointsPanel: View {
    let jointState: SensorMsgs.JointState
    let rateHz: Double
    let robotName: String?
    let lastUpdate: Date?

    private static let staleAfter: TimeInterval = 1.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let stale = isStale(at: context.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(robotName ?? "joints").font(.caption.bold())
                    Spacer()
                    if stale {
                        Label(staleText(at: context.date), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else {
                        Text(String(format: "%.0f Hz", rateHz)).font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
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
            .opacity(stale ? 0.55 : 1)
            .tint(stale ? .gray : .accentColor)
        }
    }

    private func isStale(at now: Date) -> Bool {
        guard let lastUpdate else { return true }
        return now.timeIntervalSince(lastUpdate) > Self.staleAfter
    }

    private func staleText(at now: Date) -> String {
        guard let lastUpdate else { return "stale" }
        let s = Int(now.timeIntervalSince(lastUpdate))
        return s < 60 ? "stale \(s)s" : "stale \(s / 60)m"
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
