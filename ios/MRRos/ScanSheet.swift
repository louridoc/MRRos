import SwiftUI

struct ScanSheet: View {
    @Bindable var scanScene: ScanScene
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Points", value: "\(scanScene.pointCount)")
                    Text(scanScene.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let summary = scanScene.lastUploadSummary {
                        LabeledContent("Last upload", value: summary)
                    }
                    Button {
                        scanScene.request = .capture
                    } label: {
                        Label("Capture", systemImage: "camera.metering.matrix")
                    }
                    Button(role: .destructive) {
                        scanScene.request = .clear
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .disabled(scanScene.pointCount == 0)
                    Button {
                        scanScene.request = .upload
                    } label: {
                        if scanScene.isUploading {
                            ProgressView()
                        } else {
                            Label("Upload to ar_bridge", systemImage: "arrow.up.circle")
                        }
                    }
                    .disabled(scanScene.pointCount == 0 || scanScene.isUploading)
                } header: {
                    Text("Environment scan")
                } footer: {
                    Text(
                        "Capture adds what the LiDAR has fused so far to the running scan; tap it "
                            + "as you move around the space. Upload publishes the latched "
                            + "/mrros/static_cloud topic and writes a .pcd file on the ROS side."
                    )
                }
            }
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
