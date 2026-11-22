import AppCore
import SwiftUI

/// AR view with a minimal overlay: the connection pill on top (joints panel behind a toggle) and
/// ONE compact panel at the bottom — a single status line, edit pickers only while editing, and
/// the action row of the active mode, switched by a Robot | Scan tab. Everything floats over the
/// live camera (never a sheet): aligning and scanning both depend on seeing the room.
struct ContentView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case robot = "Robot", scan = "Scan"
        var id: String {
            rawValue
        }
    }

    @State private var session = ROSSession()
    @State private var scene = RobotScene()
    @State private var scanScene = ScanScene()
    @State private var showConnection = false
    @State private var showJoints = false
    @State private var mode: Mode = .robot

    var body: some View {
        ZStack {
            ARContainerView(session: session, scene: scene, scanScene: scanScene)
                .ignoresSafeArea()
            // Placing the robot and adding an exclusion box both raycast from the exact screen
            // centre; full-screen like the AR view so the two centres coincide. Hidden while a
            // drag edits something, where it means nothing.
            if !scene.isAligning, !scanScene.isEditingBoxes {
                Crosshair()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    StatusStrip(session: session) { showConnection = true }
                    if session.isReceivingJoints {
                        Button {
                            showJoints.toggle()
                        } label: {
                            Image(systemName: showJoints ? "chevron.up" : "slider.horizontal.3")
                                .padding(9)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showJoints ? "Hide joints" : "Show joints")
                    }
                }
                .padding(.top, 8)
                if showJoints, let js = session.jointState {
                    JointsPanel(
                        jointState: js, rateHz: session.jointRateHz,
                        robotName: session.robotName, lastUpdate: session.lastJointUpdate
                    )
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                ControlPanel(session: session, scene: scene, scanScene: scanScene, mode: $mode)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            .animation(.default, value: showJoints)
        }
        .sheet(isPresented: $showConnection) {
            ConnectionSheet(session: session)
        }
        .sheet(isPresented: $scanScene.showScenes) {
            ScenesSheet(scanScene: scanScene, robotScene: scene, arBridgeURL: session.settings.arBridgeURL)
        }
    }
}

/// The upload menu's entries (scan bar and saved scenes): what goes to ROS.
struct UploadChoices: View {
    let upload: (ScanScene.UploadMode) -> Void

    var body: some View {
        Button { upload(.points) } label: {
            Label("Upload points (MoveIt octomap)", systemImage: "circle.grid.3x3")
        }
        Button { upload(.mesh) } label: {
            Label("Upload mesh (collision object)", systemImage: "cube.transparent")
        }
        Button { upload(.both) } label: {
            Label("Upload both", systemImage: "square.stack.3d.up")
        }
    }
}

/// Title + icon when the row has room, icon only when it doesn't — never wrapped onto two lines.
struct FittingLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Label(title, systemImage: systemImage).lineLimit(1)
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        }
        .accessibilityLabel(title)
    }
}

/// A small "+" at the exact screen centre, outlined so it reads on any background.
struct Crosshair: View {
    var body: some View {
        ZStack {
            ForEach([0.0, 90.0], id: \.self) { angle in
                Capsule()
                    .fill(.white)
                    .frame(width: 26, height: 2.5)
                    .shadow(color: .black.opacity(0.8), radius: 1)
                    .rotationEffect(.degrees(angle))
            }
            Circle()
                .stroke(.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: 10, height: 10)
                .shadow(color: .black.opacity(0.8), radius: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The single bottom panel.
struct ControlPanel: View {
    let session: ROSSession
    @Bindable var scene: RobotScene
    @Bindable var scanScene: ScanScene
    @Binding var mode: ContentView.Mode

    private var statusLine: String {
        switch mode {
        case .robot:
            scene.isAligning ? "Pick an axis, drag along its arrow (Rotate Z: drag sideways). Done when it overlays." : scene.status
        case .scan:
            scanScene.isEditingBoxes ? "Pick a box, then Move/Size/Rotate along an arrow." : scanScene.status
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(statusLine)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)

            switch mode {
            case .robot:
                if scene.isAligning {
                    Picker("Axis", selection: $scene.alignAxis) {
                        ForEach(RobotScene.AlignAxis.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                RobotActions(session: session, scene: scene, scanScene: scanScene)
            case .scan:
                if scanScene.isEditingBoxes {
                    BoxEditControls(scanScene: scanScene)
                }
                ScanActions(scanScene: scanScene, robotScene: scene)
            }

            Picker("Mode", selection: $mode) {
                ForEach(ContentView.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        // Leaving a tab ends its drag mode, so a drag can never act on something hidden.
        .onChange(of: mode) { _, newMode in
            if newMode != .robot { scene.isAligning = false }
            if newMode != .scan { scanScene.isEditingBoxes = false }
        }
    }
}

/// Robot tab: place / align / remove, plus restore/forget when a saved alignment exists.
struct RobotActions: View {
    let session: ROSSession
    @Bindable var scene: RobotScene
    let scanScene: ScanScene

    var body: some View {
        HStack(spacing: 8) {
            Button {
                scene.request = .place
            } label: {
                FittingLabel(scene.isPlaced ? "Re-place" : "Place", systemImage: "figure.stand")
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

            if scene.savedAlignment != nil, !scene.isPlaced {
                Button {
                    scene.request = .restoreSaved
                } label: {
                    if scene.isRestoring {
                        ProgressView()
                    } else {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(session.urdfRobot == nil || scene.isRestoring || scene.isBuilding)
                .accessibilityLabel(restoreLabel)

                Button(role: .destructive) {
                    scene.request = .forgetSaved
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(scene.isRestoring)
                .accessibilityLabel("Forget saved alignment")
            }

            Button(role: .destructive) {
                scene.request = .remove
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(!scene.isPlaced)
            .accessibilityLabel("Remove robot")
        }
    }

    private var restoreLabel: String {
        guard let saved = scene.savedAlignment else { return "Restore saved alignment" }
        return "Restore saved alignment · \(saved.robotName ?? "robot") · "
            + saved.savedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Scan tab: capture / clear / upload, crop on/off, add exclusion box, edit boxes.
struct ScanActions: View {
    @Bindable var scanScene: ScanScene
    @Bindable var robotScene: RobotScene

    var body: some View {
        HStack(spacing: 8) {
            Button {
                scanScene.showScenes = true
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Saved scenes")

            Button {
                scanScene.request = .capture
            } label: {
                FittingLabel("Capture", systemImage: "camera.metering.matrix")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button(role: .destructive) {
                scanScene.request = .clear
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(scanScene.pointCount == 0 && scanScene.exclusionIDs.isEmpty)
            .accessibilityLabel("Clear scan and exclusion boxes")

            // Tap opens the choice, so it can't be missed (a long-press menu was).
            Menu {
                UploadChoices { mode in
                    scanScene.uploadMode = mode
                    scanScene.request = .upload
                }
            } label: {
                if scanScene.isUploading {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.up.circle")
                }
            }
            .buttonStyle(.bordered)
            .disabled(scanScene.pointCount == 0 || scanScene.isUploading)
            .accessibilityLabel("Upload scan")

            // Boxes live in base_link, so they need a placed robot.
            Toggle(isOn: $scanScene.cropEnabled) {
                Image(systemName: "crop")
            }
            .toggleStyle(.button)
            .disabled(!robotScene.isPlaced)
            .accessibilityLabel(scanScene.cropSummary ?? "Crop box")
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
                Image(systemName: "plus.square.dashed")
            }
            .buttonStyle(.bordered)
            .disabled(!robotScene.isPlaced)
            .accessibilityLabel("Add exclusion box")

            if scanScene.cropEnabled || !scanScene.exclusionIDs.isEmpty {
                Button {
                    scanScene.isEditingBoxes.toggle()
                    if scanScene.isEditingBoxes { robotScene.isAligning = false }
                } label: {
                    Image(systemName: scanScene.isEditingBoxes ? "checkmark" : "pencil")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(scanScene.isEditingBoxes ? "Done editing boxes" : "Edit boxes")
            }
        }
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


#Preview {
    ContentView()
}
