import AppCore
import SwiftUI

/// AR view with the ROS status strip, robot placement controls, the live joints panel, and
/// the connection sheet.
struct ContentView: View {
    @State private var session = ROSSession()
    @State private var scene = RobotScene()
    @State private var scanScene = ScanScene()
    @State private var showConnection = false
    @State private var showScan = false

    var body: some View {
        ZStack {
            ARContainerView(session: session, scene: scene, scanScene: scanScene)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                HStack {
                    StatusStrip(session: session) { showConnection = true }
                    Spacer()
                    Button { showScan = true } label: {
                        Image(systemName: "camera.metering.matrix")
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Environment scan")
                }
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
                PlacementBar(session: session, scene: scene)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            }
            .animation(.default, value: session.jointState == nil)
        }
        .sheet(isPresented: $showConnection) {
            ConnectionSheet(session: session)
        }
        .sheet(isPresented: $showScan) {
            ScanSheet(scanScene: scanScene)
        }
    }
}

/// Place / remove the robot and show what the AR coordinator reports.
struct PlacementBar: View {
    let session: ROSSession
    @Bindable var scene: RobotScene

    var body: some View {
        VStack(spacing: 8) {
            Text(scene.status)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    scene.request = .place
                } label: {
                    Label(scene.isPlaced ? "Re-place" : "Place robot", systemImage: "figure.stand")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.urdfRobot == nil || scene.isBuilding)

                Button(role: .destructive) {
                    scene.request = .remove
                } label: {
                    Label("Remove", systemImage: "trash")
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
