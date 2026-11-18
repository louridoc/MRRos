import AppCore
import SwiftUI

/// AR view with the ROS status strip, robot placement controls, the live joints panel, and
/// the connection sheet.
struct ContentView: View {
    @State private var session = ROSSession()
    @State private var scene = RobotScene()
    @State private var scanScene = ScanScene()
    @State private var showConnection = false

    var body: some View {
        ZStack {
            ARContainerView(session: session, scene: scene, scanScene: scanScene)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                StatusStrip(session: session) { showConnection = true }
                    .padding(.top, 8)
                Spacer()
                if let js = session.jointState {
                    JointsPanel(
                        jointState: js, rateHz: session.jointRateHz,
                        robotName: session.robotName, lastUpdate: session.lastJointUpdate
                    )
                    .padding(.horizontal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // Both bars float directly over the live camera feed (never a sheet) — a scan
                // is only useful if you can see where you're pointing the phone while you tap.
                ScanBar(scanScene: scanScene)
                    .padding(.horizontal)
                PlacementBar(session: session, scene: scene)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            }
            .animation(.default, value: session.jointState == nil)
        }
        .sheet(isPresented: $showConnection) {
            ConnectionSheet(session: session)
        }
    }
}

/// Capture/clear/upload the environment scan — an overlay, not a sheet, so the AR camera feed
/// (what you're actually using to aim the scan) stays visible the whole time.
struct ScanBar: View {
    @Bindable var scanScene: ScanScene

    var body: some View {
        VStack(spacing: 8) {
            Text(scanScene.status)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    scanScene.request = .capture
                } label: {
                    Label("Capture", systemImage: "camera.metering.matrix")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    scanScene.request = .clear
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(scanScene.pointCount == 0)

                Button {
                    scanScene.request = .upload
                } label: {
                    if scanScene.isUploading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(scanScene.pointCount == 0 || scanScene.isUploading)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Place / remove the robot and show what the AR coordinator reports.
struct PlacementBar: View {
    let session: ROSSession
    @Bindable var scene: RobotScene

    var body: some View {
        VStack(spacing: 8) {
            Text(
                scene.isAligning
                    ? "Pick X (red) or Y (green) and drag along that arrow, or Rotate Z (blue) and drag sideways. Done when it overlays the real robot."
                    : scene.status
            )
            .font(.caption)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)

            if scene.isAligning {
                Picker("Axis", selection: $scene.alignAxis) {
                    ForEach(RobotScene.AlignAxis.allCases) { axis in
                        Text(axis.rawValue).tag(axis)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 12) {
                Button {
                    scene.request = .place
                } label: {
                    Label(scene.isPlaced ? "Re-place" : "Place robot", systemImage: "figure.stand")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.urdfRobot == nil || scene.isBuilding)

                Button {
                    scene.isAligning.toggle()
                } label: {
                    Label(scene.isAligning ? "Done" : "Align", systemImage: "move.3d")
                }
                .buttonStyle(.bordered)
                .disabled(!scene.isPlaced)

                Button(role: .destructive) {
                    scene.request = .remove
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(!scene.isPlaced)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

#Preview {
    ContentView()
}
