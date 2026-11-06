import AppKit
import SwiftUI

/// One version's entry in the CHANGELOG.md bundled with the app, so the two can't drift apart.
struct ReleaseNotes: Identifiable, Equatable {
    let version: String
    var changes: [String] = []
    var id: String { version }

    static func parse(_ text: String) -> [ReleaseNotes] {
        var notes: [ReleaseNotes] = []
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("## ") {
                notes.append(ReleaseNotes(version: String(line.dropFirst(3))))
            } else if line.hasPrefix("- "), !notes.isEmpty {
                notes[notes.count - 1].changes.append(String(line.dropFirst(2)))
            }
        }
        return notes.filter { !$0.changes.isEmpty }
    }

    static var bundled: [ReleaseNotes] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }
}

/// What opens by itself when Volumist starts. A menu bar app has no window of its own, so without
/// this a new user sees nothing happen, and an update goes unnoticed.
enum LaunchScreen: Equatable {
    case welcome
    case whatsNew([ReleaseNotes])
    case none

    private static let lastSeenKey = "lastSeenVersion"
    private static let settingKeys = ["volumes", "ducking", "checksForUpdates"]

    /// Versions before 1.3 saved no version, so settings are what tell an update from a new user.
    static func decide(lastSeen: String?, current: String, hasSettings: Bool, notes: [ReleaseNotes]) -> LaunchScreen {
        if lastSeen == nil, !hasSettings { return .welcome }
        let unseen = notes.filter { note in
            guard !UpdateChecker.isNewer(note.version, than: current) else { return false }
            return lastSeen.map { UpdateChecker.isNewer(note.version, than: $0) } ?? (note.version == current)
        }
        return unseen.isEmpty ? .none : .whatsNew(unseen)
    }

    /// Each screen opens only once, so the version counts as seen from here on.
    static func forThisLaunch() -> LaunchScreen {
        let defaults = UserDefaults.standard
        let current = UpdateChecker.currentVersion
        let screen = decide(lastSeen: defaults.string(forKey: lastSeenKey), current: current,
                            hasSettings: settingKeys.contains { defaults.object(forKey: $0) != nil },
                            notes: ReleaseNotes.bundled)
        defaults.set(current, forKey: lastSeenKey)
        return screen
    }
}

private struct ScreenHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var engine: AudioEngine
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader(title: "Welcome to Volumist", subtitle: "A volume mixer for every app on your Mac.")

            step(symbol: "slider.vertical.3", title: "Find it in the menu bar",
                 detail: "Volumist has no Dock icon. Click this icon at the top of your screen to open it.")

            permissionStep

            Divider()

            Text("Optional. You can change these at any time.").font(.callout).foregroundStyle(.secondary)
            option("Lower other apps during calls", isOn: $engine.ducking.isEnabled,
                   detail: "Music and videos get quieter while an app is using your microphone.")
            option("Open at login", isOn: $engine.launchAtLogin, detail: nil)
            option("Check for updates", isOn: $engine.checksForUpdates,
                   detail: "Asks GitHub for the latest version once a day. Nothing else is sent.")

            HStack {
                Spacer()
                Button("Get Started", action: finish).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var permissionStep: some View {
        HStack(alignment: .top, spacing: 12) {
            icon(engine.permission == .granted ? "checkmark.circle.fill" : "waveform",
                 color: engine.permission == .granted ? .green : .accentColor)
            VStack(alignment: .leading, spacing: 6) {
                Text(engine.permission == .granted ? "Audio permission granted" : "Allow audio capture").font(.headline)
                Text("macOS calls it audio capture because Volumist has to read an app's audio to change its volume. Nothing is recorded or sent.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if engine.permission != .granted {
                    Button(engine.permission == .denied ? "Open Privacy Settings" : "Grant Permission") {
                        if engine.permission == .denied { engine.openPrivacySettings() } else { engine.requestPermission() }
                    }
                }
            }
        }
    }

    private func step(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon(symbol, color: .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func icon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol).font(.title3).foregroundStyle(color).frame(width: 26)
    }

    private func option(_ title: String, isOn: Binding<Bool>, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn).toggleStyle(.checkbox)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 20)
            }
        }
    }
}

struct WhatsNewView: View {
    private static let changelog = URL(string: "https://github.com/jpdominguez/volumist/blob/main/CHANGELOG.md")!
    private static let maxUnscrolledLines = 8

    let notes: [ReleaseNotes]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreenHeader(title: "What's New", subtitle: "You're using Volumist \(UpdateChecker.currentVersion).")

            if notes.reduce(0, { $0 + $1.changes.count + 1 }) > Self.maxUnscrolledLines {
                ScrollView { list.frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 340)
            } else {
                list
            }

            HStack {
                Link("Full changelog", destination: Self.changelog)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Version \(note.version)").font(.headline)
                    ForEach(note.changes, id: \.self) { change in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(change).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
