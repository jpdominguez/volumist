import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--selftest") {
            SelfTest.run(arguments: Array(CommandLine.arguments[(index + 1)...]))
        } else if let index = CommandLine.arguments.firstIndex(of: "--render-preview") {
            MainActor.assumeIsolated { SelfTest.renderPreview(to: CommandLine.arguments[index + 1]) }
        } else if let index = CommandLine.arguments.firstIndex(of: "--check") {
            MainActor.assumeIsolated { SelfTest.check(directory: CommandLine.arguments[index + 1]) }
        } else {
            VolumistApp.main()
        }
    }
}

struct VolumistApp: App {
    @StateObject private var engine = AudioEngine()

    var body: some Scene {
        MenuBarExtra("Volumist", systemImage: "slider.vertical.3") {
            MixerView(engine: engine)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MixerView: View {
    @ObservedObject var engine: AudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "hifispeaker").foregroundStyle(.secondary)
                Text(engine.outputName.isEmpty ? "No audio output" : engine.outputName)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }

            if engine.permission != .granted { permissionNotice }

            if engine.apps.isEmpty {
                Text("No app is playing audio.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                ForEach(engine.apps) { app in
                    AppRow(app: app, engine: engine, enabled: engine.permission == .granted)
                }
            }

            if let error = engine.lastError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Toggle("Open at login", isOn: $engine.launchAtLogin)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Reset") { engine.resetAll() }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 340)
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Volumist needs the system audio capture permission to change the volume of each app.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Button(engine.permission == .denied ? "Open Privacy Settings" : "Grant Permission") {
                if engine.permission == .denied { engine.openPrivacySettings() } else { engine.requestPermission() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AppRow: View {
    let app: AudioApp
    let engine: AudioEngine
    let enabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .opacity(app.isPlaying ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Text(app.isMuted ? "Muted" : "\(Int((app.volume * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { app.isMuted ? 0 : app.volume },
                                      set: { engine.setVolume(snap($0), for: app.id) }),
                       in: 0...AudioEngine.maxVolume)
                    .controlSize(.small)
                    .accessibilityLabel("Volume of \(app.name)")
                outputMenu
            }

            Button { engine.toggleMute(for: app.id) } label: {
                Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 20)
                    .foregroundStyle(app.isMuted ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(app.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")
        }
        .disabled(!enabled)
    }

    private var outputMenu: some View {
        Menu {
            Button("System Output (\(engine.outputName))") { engine.setOutput(nil, for: app.id) }
            Divider()
            ForEach(engine.devices) { device in
                Button(device.name) { engine.setOutput(device.id, name: device.name, for: app.id) }
            }
        } label: {
            Text(outputLabel).font(.caption).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(app.outputMissing ? Color.orange : Color.secondary)
        .accessibilityLabel("Output of \(app.name)")
    }

    private var outputLabel: String {
        guard app.outputUID != nil else { return "System Output" }
        let name = app.outputName ?? "Output"
        return app.outputMissing ? "\(name) (disconnected)" : name
    }

    /// Makes it easy to land exactly on 100 %, the value at which an app leaves Volumist.
    private func snap(_ value: Double) -> Double { abs(value - 1) < 0.03 ? 1 : value }
}
