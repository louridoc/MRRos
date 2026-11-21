import SceneLibrary
import SwiftUI
import UIKit

/// Saved scenes (M5c): save the current scan, and per scene Load (replaces the current scan;
/// needs a placed robot), Upload (straight to ROS, no AR needed), Rename, Share (AirDrop/Files),
/// Delete. Scenes live in Documents/Scenes, so the Files app sees them too.
struct ScenesSheet: View {
    @Bindable var scanScene: ScanScene
    let robotScene: RobotScene
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var renaming: SceneSummary?
    @State private var renameText = ""
    @State private var shareItem: ShareItem?

    private let store = try? SceneStore.standard()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Scene name", text: $newName)
                        .textInputAutocapitalization(.sentences)
                    Button {
                        scanScene.request = .saveScene(name: trimmedName)
                    } label: {
                        Label("Save current scan", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!canSave)
                } header: {
                    Text("Current scan")
                } footer: {
                    Text(saveHint)
                }

                Section {
                    if scanScene.scenes.isEmpty {
                        Text("No saved scenes yet.").foregroundStyle(.secondary)
                    }
                    ForEach(scanScene.scenes) { scene in
                        row(scene)
                    }
                } header: {
                    Text("Saved scenes")
                } footer: {
                    Text(scanScene.status).lineLimit(3)
                }
            }
            .navigationTitle("Scenes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                refresh()
                if newName.isEmpty {
                    newName = scanScene.currentSceneName
                        ?? "Scene \(Date().formatted(date: .abbreviated, time: .shortened))"
                }
            }
            .alert("Rename scene", isPresented: renameBinding, presenting: renaming) { scene in
                TextField("Name", text: $renameText)
                Button("Rename") {
                    try? store?.rename(scene.id, to: renameText.trimmingCharacters(in: .whitespaces))
                    refresh()
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $shareItem) { item in
                ActivityView(url: item.url)
            }
        }
    }

    private func row(_ scene: SceneSummary) -> some View {
        let m = scene.manifest
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).font(.body)
                Text(
                    "\(m.createdAt.formatted(date: .abbreviated, time: .shortened)) · "
                        + "\(m.pointCount) pts · \(m.robotName ?? "robot?")"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                scanScene.request = .loadScene(id: scene.id)
                dismiss() // back to AR to see it
            } label: {
                Image(systemName: "arrow.down.to.line")
            }
            .buttonStyle(.bordered)
            .disabled(!robotScene.isPlaced || scanScene.isWorkingOnScene)
            .accessibilityLabel("Load \(m.name)")

            Button {
                scanScene.request = .uploadScene(id: scene.id)
            } label: {
                Image(systemName: "arrow.up.circle")
            }
            .buttonStyle(.bordered)
            .disabled(scanScene.isWorkingOnScene)
            .accessibilityLabel("Upload \(m.name) to ROS")
        }
        .swipeActions {
            Button(role: .destructive) {
                try? store?.delete(scene.id)
                refresh()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                renameText = m.name
                renaming = scene
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                if let folder = store?.folder(scene.id), let zip = SceneZip.make(folder: folder) {
                    shareItem = ShareItem(url: zip)
                }
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                try? store?.delete(scene.id)
                refresh()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespaces)
    }

    private var canSave: Bool {
        robotScene.isPlaced && scanScene.pointCount > 0 && !trimmedName.isEmpty && !scanScene.isWorkingOnScene
    }

    private var saveHint: String {
        if !robotScene.isPlaced {
            return "Place the robot first: scenes are saved relative to it."
        }
        if scanScene.pointCount == 0 {
            return "Capture a scan first."
        }
        return "\(scanScene.pointCount) points, the crop and exclusion boxes, and the robot's current pose."
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: {
            if !$0 {
                renaming = nil
            }
        })
    }

    private func refresh() {
        scanScene.scenes = store?.list() ?? []
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: URL {
        url
    }
}

/// A scene folder as one .zip for AirDrop/Mail (a folder can't be shared directly). Uses the file
/// coordinator's "for uploading" read, which zips a directory; copied out because that temporary
/// file is deleted when the block returns.
enum SceneZip {
    static func make(folder: URL) -> URL? {
        var result: URL?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: folder,
            options: .forUploading,
            error: &coordinationError
        ) { zip in
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent(folder.lastPathComponent)
                .appendingPathExtension("zip")
            try? FileManager.default.removeItem(at: out)
            if (try? FileManager.default.copyItem(at: zip, to: out)) != nil {
                result = out
            }
        }
        return result
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
