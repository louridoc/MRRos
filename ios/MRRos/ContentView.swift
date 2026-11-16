import AppCore
import SwiftUI

/// M0 "Hello AR": an AR view with world tracking plus a status strip proving the
/// package graph links. Replaced by real screens from M1 on.
struct ContentView: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            ARContainerView()
                .ignoresSafeArea()
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text("MRRos \(AppInfo.version) · \(AppInfo.lidarSupportDescription)")
                    .font(.footnote.monospaced())
            }
            .padding(10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 24)
        }
    }
}

#Preview {
    ContentView()
}
