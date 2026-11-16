import AppCore
import SwiftUI

/// AR view with the ROS status strip, the live joints panel, and the connection sheet.
struct ContentView: View {
    @State private var session = ROSSession()
    @State private var showConnection = false

    var body: some View {
        ZStack {
            ARContainerView()
                .ignoresSafeArea()
            VStack {
                StatusStrip(session: session) { showConnection = true }
                    .padding(.top, 8)
                Spacer()
                if let js = session.jointState {
                    JointsPanel(jointState: js, rateHz: session.jointRateHz, robotName: session.robotName)
                        .padding(.horizontal)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.default, value: session.jointState == nil)
        }
        .sheet(isPresented: $showConnection) {
            ConnectionSheet(session: session)
        }
    }
}

#Preview {
    ContentView()
}
