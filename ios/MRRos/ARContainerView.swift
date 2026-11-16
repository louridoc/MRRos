import ARKit
import RealityKit
import SwiftUI

/// Minimal RealityKit AR session with scene reconstruction when the device has LiDAR.
struct ARContainerView: UIViewRepresentable {
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        view.debugOptions = [.showWorldOrigin]
        view.session.run(config)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
