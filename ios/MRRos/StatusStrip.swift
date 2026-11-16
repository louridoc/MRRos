import AppCore
import ROSBridgeClient
import SwiftUI

struct StatusStrip: View {
    let session: ROSSession
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(label)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("ROS connection: \(label)")
    }

    private var label: String {
        switch session.state {
        case .disconnected: "Not connected · \(AppInfo.lidarSupportDescription)"
        case .connecting: "Connecting to \(session.settings.host)…"
        case .connected: "\(session.settings.host) · \(session.robotName ?? "no robot")"
        case let .reconnecting(attempt): "Reconnecting (\(attempt))…"
        case let .failed(reason): "Failed: \(reason)"
        }
    }

    private var color: Color {
        switch session.state {
        case .connected: .green
        case .connecting, .reconnecting: .yellow
        case .failed: .red
        case .disconnected: .gray
        }
    }
}
