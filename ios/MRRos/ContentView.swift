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
                ScanBar(scanScene: scanScene, robotScene: scene)
                    .padding(.horizontal)
                PlacementBar(session: session, scene: scene, scanScene: scanScene)
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
    @Bindable var robotScene: RobotScene

    var body: some View {
        VStack(spacing: 8) {
            Text(
                scanScene.isEditingBoxes
                    ? "Pick a box, Move/Size/Rotate and X (red), Y (green) or Z (blue), then drag along that arrow."
                    : scanScene.status
            )
            .font(.caption)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)

            if scanScene.isEditingBoxes {
                BoxEditControls(scanScene: scanScene)
            }

            HStack(spacing: 12) {
                // Boxes live in base_link, so they need a placed robot. Editing them and aligning
                // the robot both use the drag gesture, so turning one on turns the other off.
                Toggle(isOn: $scanScene.cropEnabled) {
                    Label(scanScene.cropSummary ?? "Crop", systemImage: "crop")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .disabled(!robotScene.isPlaced)
                .onChange(of: scanScene.cropEnabled) { _, on in
                    if on {
                        scanScene.editTarget = .crop
                    } else if scanScene.editTarget == .crop {
                        if let last = scanScene.exclusionIDs.last {
                            scanScene.editTarget = .exclusion(last)
                        } else {
                            scanScene.isEditingBoxes = false
                        }
                    }
                }

                Button {
                    scanScene.request = .addExclusion
                } label: {
                    Label("Exclude", systemImage: "plus.square.dashed")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(!robotScene.isPlaced)

                if scanScene.cropEnabled || !scanScene.exclusionIDs.isEmpty {
                    Button(scanScene.isEditingBoxes ? "Done" : "Edit") {
                        scanScene.isEditingBoxes.toggle()
                        if scanScene.isEditingBoxes { robotScene.isAligning = false }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
                Spacer(minLength: 0)
            }

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

/// Which box a drag edits (chips: Crop · Box 1 · …), what it does (Move/Size/Rotate) and along
/// which axis. Rotate is exclusion boxes only and needs no axis (it's about the box's vertical).
struct BoxEditControls: View {
    @Bindable var scanScene: ScanScene

    private var editingExclusion: Bool {
        if case .exclusion = scanScene.editTarget { true } else { false }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if scanScene.cropEnabled {
                            chip("Crop", target: .crop, color: .yellow)
                        }
                        ForEach(Array(scanScene.exclusionIDs.enumerated()), id: \.element) { index, id in
                            chip("Box \(index + 1)", target: .exclusion(id), color: .orange)
                        }
                    }
                }
                if editingExclusion {
                    Button(role: .destructive) {
                        scanScene.request = .deleteSelected
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Delete selected exclusion box")
                }
            }

            Picker("Edit", selection: $scanScene.editMode) {
                ForEach(ScanScene.BoxEditMode.allCases.filter { $0 != .rotate || editingExclusion }) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)

            if scanScene.editMode != .rotate {
                Picker("Axis", selection: $scanScene.editAxis) {
                    ForEach(ScanScene.EditAxis.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .onChange(of: scanScene.editTarget) { _, target in
            if target == .crop, scanScene.editMode == .rotate { scanScene.editMode = .move }
        }
    }

    private func chip(_ title: String, target: ScanScene.EditTarget, color: Color) -> some View {
        let selected = scanScene.editTarget == target
        return Button(title) { scanScene.editTarget = target }
            .font(.caption.weight(selected ? .bold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(selected ? 0.45 : 0.15), in: Capsule())
            .buttonStyle(.plain)
    }
}

/// Place / remove the robot and show what the AR coordinator reports.
struct PlacementBar: View {
    let session: ROSSession
    @Bindable var scene: RobotScene
    let scanScene: ScanScene

    var body: some View {
        VStack(spacing: 8) {
            Text(
                scene.isAligning
                    ? "Pick X (red), Y (green) or Z (blue) and drag along that arrow, or Rotate Z and drag sideways. Done when it overlays the real robot."
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

            if let saved = scene.savedAlignment, !scene.isPlaced {
                HStack(spacing: 12) {
                    Button {
                        scene.request = .restoreSaved
                    } label: {
                        if scene.isRestoring {
                            Label("Relocalizing…", systemImage: "location.viewfinder")
                                .frame(maxWidth: .infinity)
                        } else {
                            Label(
                                "Restore saved · \(saved.robotName ?? "robot") · "
                                    + saved.savedAt.formatted(date: .abbreviated, time: .shortened),
                                systemImage: "clock.arrow.circlepath"
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(session.urdfRobot == nil || scene.isRestoring || scene.isBuilding)

                    Button(role: .destructive) {
                        scene.request = .forgetSaved
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(scene.isRestoring)
                    .accessibilityLabel("Forget saved alignment")
                }
                .font(.caption)
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
                    if scene.isAligning { scanScene.isEditingBoxes = false }
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
