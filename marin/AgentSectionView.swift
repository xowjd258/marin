import SwiftUI

struct AgentSectionView: View {
    @ObservedObject var agent: RealtimeAgentClient
    @ObservedObject var camera: CameraCaptureManager
    @ObservedObject var executive: RobotExecutive

    var body: some View {
        Section("Agent") {
            Text("Status: \(agent.state.rawValue)")
                .font(.subheadline)

            Text(agent.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Last Event: \(agent.lastEventType)")
                .font(.caption)

            if !agent.lastErrorDetail.isEmpty {
                Text("Error: \(agent.lastErrorDetail)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
            }

            if !agent.outputText.isEmpty {
                Text(agent.outputText)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            }

            HStack(spacing: 12) {
                if agent.state == .idle || agent.state == .failed {
                    Button("Connect") {
                        agent.connect()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Disconnect") {
                        agent.disconnect()
                    }
                    .buttonStyle(.bordered)

                    if agent.isVoiceStreaming {
                        Button("Interrupt") {
                            agent.interruptCurrentResponse()
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }
                }
            }

            HStack(spacing: 16) {
                Label(
                    agent.isVoiceStreaming ? "Mic On" : "Mic Off",
                    systemImage: agent.isVoiceStreaming ? "mic.fill" : "mic.slash"
                )
                .font(.caption)
                .foregroundStyle(agent.isVoiceStreaming ? .green : .secondary)

                Label(
                    camera.isRunning ? "Cam On" : "Cam Off",
                    systemImage: camera.isRunning ? "eye.fill" : "eye.slash"
                )
                .font(.caption)
                .foregroundStyle(camera.isRunning ? .green : .secondary)
            }
        }

        Section("Executive") {
            Text(executive.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
