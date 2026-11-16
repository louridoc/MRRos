import AppCore
import SwiftUI

struct ConnectionSheet: View {
    @Bindable var session: ROSSession
    @Environment(\.dismiss) private var dismiss
    @State private var portText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("rosbridge") {
                    TextField("Host or IP", text: $session.settings.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .disabled(session.isConnected)
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                        .disabled(session.isConnected)
                        .onChange(of: portText) { _, new in
                            if let p = Int(new) {
                                session.settings.port = p
                            }
                        }
                    LabeledContent("State", value: stateText)
                    if let err = session.lastError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                    Button(session.isConnected ? "Disconnect" : "Connect") {
                        Task {
                            if session.isConnected {
                                await session.disconnect()
                            } else {
                                await session.connect()
                            }
                        }
                    }
                    .disabled(session.state == .connecting)
                }

                if session.isConnected {
                    Section {
                        LabeledContent("Robot", value: session.robotName ?? "—")
                        LabeledContent("URDF", value: session.urdf.map { "\($0.count) chars" } ?? "—")
                        LabeledContent("/joint_states", value: String(format: "%.0f Hz", session.jointRateHz))
                    } header: {
                        Text("Robot")
                    }
                    Section {
                        ForEach(session.topics) { t in
                            VStack(alignment: .leading) {
                                Text(t.name).font(.body.monospaced())
                                Text(t.type).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        HStack {
                            Text("Topics (\(session.topics.count))")
                            Spacer()
                            Button("Refresh") { Task { await session.refreshTopics() } }
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("ROS 2 connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { portText = String(session.settings.port) }
        }
    }

    private var stateText: String {
        switch session.state {
        case .disconnected: "disconnected"
        case .connecting: "connecting…"
        case .connected: "connected"
        case let .reconnecting(n): "reconnecting (\(n))"
        case let .failed(r): "failed — \(r)"
        }
    }
}
