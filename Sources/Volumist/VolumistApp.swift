import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--selftest") {
            SelfTest.run(arguments: Array(CommandLine.arguments[(index + 1)...]))
        } else if let index = CommandLine.arguments.firstIndex(of: "--render-preview") {
            MainActor.assumeIsolated { SelfTest.renderPreview(to: CommandLine.arguments[index + 1]) }
        } else if let index = CommandLine.arguments.firstIndex(of: "--render-screens") {
            MainActor.assumeIsolated { SelfTest.renderScreens(to: CommandLine.arguments[index + 1]) }
        } else if let index = CommandLine.arguments.firstIndex(of: "--render-demo") {
            let arguments = CommandLine.arguments
            MainActor.assumeIsolated {
                DemoRenderer.render(to: arguments[index + 1],
                                    keyFrames: arguments.count > index + 2 ? arguments[index + 2] : nil)
            }
        } else if let index = CommandLine.arguments.firstIndex(of: "--ui-check") {
            MainActor.assumeIsolated { SelfTest.checkExpansion(log: CommandLine.arguments[index + 1]) }
        } else if let index = CommandLine.arguments.firstIndex(of: "--check") {
            MainActor.assumeIsolated { SelfTest.check(directory: CommandLine.arguments[index + 1]) }
        } else {
            MainActor.assumeIsolated {
                let application = NSApplication.shared
                let screen = LaunchScreen.forThisLaunch()
                // The welcome screen explains the permission before macOS asks for it.
                let engine = AudioEngine(requestsPermission: screen != .welcome)
                let controller = AppController(engine: engine, launchScreen: screen)
                application.delegate = controller
                application.run()
            }
        }
    }
}

/// Owns the menu bar item. A popover stays anchored to it while its content changes size,
/// which a SwiftUI MenuBarExtra window doesn't do.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let engine: AudioEngine
    let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var lastClose = Date.distantPast
    private let launchScreen: LaunchScreen
    private(set) var screenWindow: NSWindow?

    init(engine: AudioEngine, launchScreen: LaunchScreen = .none) {
        self.engine = engine
        self.launchScreen = launchScreen
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        install()
        switch launchScreen {
        case .welcome: showWelcome()
        case .whatsNew(let notes): showWhatsNew(notes)
        case .none: break
        }
    }

    func showWelcome() {
        showScreen(title: "Welcome to Volumist", WelcomeView(engine: engine) { [weak self] in
            self?.screenWindow?.close()
            // Opening the mixer shows where it lives in the menu bar.
            if self?.popover.isShown == false { self?.toggle() }
        })
    }

    func showWhatsNew(_ notes: [ReleaseNotes]) {
        showScreen(title: "What's New", WhatsNewView(notes: notes) { [weak self] in self?.screenWindow?.close() })
    }

    /// A window and not the popover, which closes as soon as the permission dialog takes the focus.
    private func showScreen(title: String, _ content: some View) {
        screenWindow?.close()
        popover.performClose(nil)
        let host = NSHostingController(rootView: content)
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.center()
        screenWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func install() {
        let host = NSHostingController(rootView: MixerView(engine: engine) { [weak self] in
            self?.showWhatsNew(ReleaseNotes.bundled)
        })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        // Not .transient: it closes on mouse down, so the status item's click, which arrives on
        // mouse up, would find it closed and reopen it. Volumist decides when it closes instead.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "Volumist")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        statusItem = item
    }

    /// A new status item takes a moment to reach the menu bar. Until then it sits at the screen's origin.
    var isMenuBarItemPlaced: Bool { (statusItem?.button?.window?.frame.minY ?? 0) > 0 }

    @objc func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else if Date().timeIntervalSince(lastClose) < 0.3 {
            // The press on this same click already closed the window, as a click outside it or by
            // deactivating the app, and this is its release. It must not open it again.
        } else if let button = statusItem?.button {
            // Active from the start, so that the first click inside doesn't have to activate it.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        engine.setWindowOpen(true)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
        // This monitor sees clicks in other apps, and never clicks in Volumist.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
            return nil
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        lastClose = Date()
        engine.setWindowOpen(false)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }
}

struct MixerView: View {
    @ObservedObject var engine: AudioEngine
    var showWhatsNew: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "hifispeaker").foregroundStyle(.secondary)
                Text(engine.outputName.isEmpty ? "No audio output" : engine.outputName)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }

            if engine.outputLevels.count > 1 {
                VStack(spacing: 6) {
                    ForEach(engine.outputLevels) { output in
                        HStack(spacing: 8) {
                            Text(output.name).font(.caption)
                                .fontWeight(output.isCurrent ? .semibold : .regular)
                                .foregroundStyle(output.isCurrent ? .primary : .secondary)
                                .lineLimit(1).truncationMode(.tail)
                                .frame(width: 120, alignment: .leading)
                            Slider(value: Binding(get: { output.volume },
                                                  set: { engine.setOutputVolume($0, for: output.id) }), in: 0...1)
                                .controlSize(.small)
                                .accessibilityLabel("Volume of \(output.name)")
                            Text("\(Int((output.volume * 100).rounded()))%")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
                Divider()
            } else if let volume = engine.systemVolume {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { volume }, set: { engine.setSystemVolume($0) }), in: 0...1)
                        .controlSize(.small)
                        .accessibilityLabel("System volume")
                    Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
            }

            if engine.permission != .granted { permissionNotice }

            if engine.apps.isEmpty {
                Text("No app is playing audio.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                appList
            }

            if let update = engine.availableUpdate {
                HStack {
                    Label("Volumist \(update.version) is available", systemImage: "arrow.down.circle")
                        .font(.caption)
                    Spacer()
                    Link("Download", destination: update.htmlUrl).font(.caption)
                }
            }

            if let error = engine.lastError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            callSection

            Divider()

            Toggle("Check for updates", isOn: $engine.checksForUpdates)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            HStack {
                Toggle("Open at login", isOn: $engine.launchAtLogin)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("What's New", action: showWhatsNew)
                Button("Reset") { engine.resetAll() }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 360)
    }

    /// Scrolls when the apps don't fit. A ScrollView has no size of its own, so it takes the
    /// height of its content, up to what the screen leaves free.
    private var appList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(engine.apps) { app in
                    AppRow(app: app, engine: engine, enabled: engine.permission == .granted)
                }
            }
            .background(GeometryReader { Color.clear.preference(key: ListHeight.self, value: $0.size.height) })
        }
        .frame(height: min(engine.listHeight, maxListHeight))
        .onPreferenceChange(ListHeight.self) { height in
            MainActor.assumeIsolated { engine.listHeight = height }
        }
    }

    /// The screen minus everything else in the window, which grows with what is showing, and a margin.
    private var maxListHeight: CGFloat {
        if engine.showsWholeList { return .infinity }
        var reserved: CGFloat = 290
        reserved += engine.outputLevels.count > 1 ? CGFloat(engine.outputLevels.count) * 22 : 30
        if engine.ducking.isEnabled { reserved += 55 }
        if engine.ducking.isEnabled, engine.ducking.trigger == .callApps { reserved += 65 }
        if engine.permission != .granted { reserved += 80 }
        if engine.availableUpdate != nil { reserved += 22 }
        if engine.lastError != nil { reserved += 30 }
        return max((NSScreen.main?.visibleFrame.height ?? 800) - reserved, 200)
    }

    private var callSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Lower other apps during calls", isOn: $engine.ducking.isEnabled)
                .toggleStyle(.checkbox)
            if engine.ducking.isEnabled {
                HStack {
                    Text("Lower to").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $engine.ducking.level, in: 0...1)
                        .controlSize(.small)
                        .accessibilityLabel("Volume during calls")
                    Text("\(Int((engine.ducking.level * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                HStack {
                    Text("Detect calls from").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Dropdown(title: engine.ducking.trigger.title, items: DuckingOptions.Trigger.allCases.map { trigger in
                        DropdownItem(title: trigger.title, isSelected: trigger == engine.ducking.trigger) {
                            engine.ducking.trigger = trigger
                        }
                    }, accessibilityLabel: "Detect calls from")
                    .fixedSize()
                }
                if engine.ducking.trigger == .callApps {
                    HStack {
                        Text("Also count").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Dropdown(title: extraCallAppsTitle, makeItems: {
                            engine.callAppCandidates().map { app in
                                DropdownItem(title: app.name, isSelected: engine.ducking.extraCallApps?[app.id] != nil) {
                                    engine.toggleCallApp(app.id, name: app.name)
                                }
                            }
                        }, accessibilityLabel: "Other apps that count as calls")
                        .fixedSize()
                    }
                    Text("For calls in a browser, such as Google Meet, add your browser.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let name = engine.callAppName {
                    Label("Call detected in \(name)", systemImage: "phone.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
        }
    }

    private var extraCallAppsTitle: String {
        let names = (engine.ducking.extraCallApps ?? [:]).values.sorted()
        switch names.count {
        case 0: return "Choose apps"
        case 1: return names[0]
        default: return "\(names.count) apps"
        }
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
    // Must be observed: the row reads engine state that isn't in `app`, and SwiftUI skips redrawing
    // a child whose stored properties look unchanged.
    @ObservedObject var engine: AudioEngine
    let enabled: Bool

    private var isExpanded: Bool { engine.expandedApp == app.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row
            if isExpanded { AppDetails(app: app, engine: engine).disabled(!enabled) }
        }
    }

    private var row: some View {
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
                    Text(statusText)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { app.isMuted ? 0 : app.volume },
                                      set: { engine.setVolume(snap($0), for: app.id) }),
                       in: 0...AudioEngine.maxVolume)
                    .controlSize(.small)
                    .accessibilityLabel("Volume of \(app.name)")
                LevelMeter(store: engine.levels, id: app.id)
                HStack {
                    outputDropdown
                    Spacer()
                    if engine.ducking.isEnabled {
                        Toggle("Lower in calls", isOn: Binding(get: { !app.neverLower },
                                                               set: { engine.setNeverLower(!$0, for: app.id) }))
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .font(.caption)
                            .accessibilityLabel("Lower \(app.name) during calls")
                    }
                }
            }

            VStack(spacing: 4) {
                Button { engine.toggleMute(for: app.id) } label: {
                    Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 24, height: 22)
                        .foregroundStyle(app.isMuted ? Color.red : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(app.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")

                Button { engine.expandedApp = isExpanded ? nil : app.id } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 24, height: 22)
                        .foregroundStyle(isExpanded || isCustomized ? Color.accentColor : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Balance and equalizer of \(app.name)")
            }
        }
        .disabled(!enabled)
    }

    private var isCustomized: Bool {
        app.balance != 0 || app.equalizer != Equalizer.flat || app.levelsVolume || app.secondOutputUID != nil
    }

    private var statusText: String {
        if app.isMuted { return "Muted" }
        let volume = "\(Int((app.volume * 100).rounded()))%"
        return app.isLowered ? "\(volume) · lowered" : volume
    }

    private var outputDropdown: some View {
        var items = [DropdownItem(title: "System Output (\(engine.outputName))", isSelected: app.outputUID == nil) {
            engine.setOutput(nil, for: app.id)
        }]
        for (index, device) in engine.devices.enumerated() {
            items.append(DropdownItem(title: device.name, isSelected: app.outputUID == device.id,
                                      isSeparatorBefore: index == 0) {
                engine.setOutput(device.id, name: device.name, for: app.id)
            })
        }
        return Dropdown(title: outputLabel, items: items, color: app.outputMissing ? .systemOrange : .labelColor,
                        accessibilityLabel: "Output of \(app.name)")
            .fixedSize()
    }

    private var outputLabel: String {
        guard app.outputUID != nil else { return "System Output" }
        let name = app.outputName ?? "Output"
        return app.outputMissing ? "\(name) (disconnected)" : name
    }

    /// Makes it easy to land exactly on 100 %, the value at which an app leaves Volumist.
    private func snap(_ value: Double) -> Double { abs(value - 1) < 0.03 ? 1 : value }
}

struct ListHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct LevelMeter: View {
    @ObservedObject var store: LevelStore
    let id: String

    /// The last 60 dB, so that quiet audio still moves the bar.
    private var fraction: CGFloat {
        let level = store.levels[id] ?? 0
        guard level > 0 else { return 0 }
        return CGFloat(min(max(1 + 20 * log10(level) / 60, 0), 1))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.green.opacity(0.8)).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

struct AppDetails: View {
    let app: AudioApp
    @ObservedObject var engine: AudioEngine

    private var presetName: String {
        Equalizer.presets.first { $0.gains == app.equalizer }?.name ?? "Custom"
    }

    private var secondOutputLabel: String {
        guard let name = app.secondOutputName, app.secondOutputUID != nil else { return "No other output" }
        return app.secondOutputMissing ? "\(name) (disconnected)" : name
    }

    /// The other outputs, as the first one can't also be the second.
    private var secondOutputItems: [DropdownItem] {
        let first = app.outputMissing ? engine.defaultOutputUID : app.outputUID ?? engine.defaultOutputUID
        var items = [DropdownItem(title: "No other output", isSelected: app.secondOutputUID == nil) {
            engine.setSecondOutput(nil, for: app.id)
        }]
        for (index, device) in engine.devices.filter({ $0.id != first }).enumerated() {
            items.append(DropdownItem(title: device.name, isSelected: app.secondOutputUID == device.id,
                                      isSeparatorBefore: index == 0) {
                engine.setSecondOutput(device.id, name: device.name, for: app.id)
            })
        }
        return items
    }

    private func note(_ text: String, color: Color = .secondary) -> some View {
        Text(text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if engine.devices.count > 1 || app.secondOutputUID != nil {
                HStack {
                    Text("Also play on").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Dropdown(title: secondOutputLabel, items: secondOutputItems,
                             color: app.secondOutputMissing ? .systemOrange : .labelColor,
                             accessibilityLabel: "Second output of \(app.name)")
                    .fixedSize()
                }
                if app.secondOutputFailed {
                    note("macOS couldn't use these two outputs together, so only the first one is playing.", color: .orange)
                } else if app.mayEcho {
                    note("Bluetooth plays later than other outputs, so you may hear an echo in the same room.")
                }
            }

            HStack(spacing: 6) {
                Text("Balance").font(.caption).foregroundStyle(.secondary)
                Text("L").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(get: { app.balance },
                                      set: { engine.setBalance(abs($0) < 0.05 ? 0 : $0, for: app.id) }),
                       in: -1...1)
                    .controlSize(.small)
                    .accessibilityLabel("Balance of \(app.name)")
                    .disabled(app.isMono)
                Text("R").font(.caption2).foregroundStyle(.secondary)
            }
            if app.isMono {
                note("This output is mono right now, so balance has no effect. Bluetooth headphones switch to mono while their microphone is in use.")
            }

            Toggle("Level loud and quiet parts", isOn: Binding(get: { app.levelsVolume },
                                                               set: { engine.setLevelsVolume($0, for: app.id) }))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.caption)
                .accessibilityLabel("Level loud and quiet parts of \(app.name)")

            HStack {
                Text("Equalizer").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Dropdown(title: presetName, items: Equalizer.presets.map { preset in
                    DropdownItem(title: preset.name, isSelected: preset.gains == app.equalizer) {
                        engine.setEqualizer(preset.gains, for: app.id)
                    }
                }, accessibilityLabel: "Equalizer preset of \(app.name)")
                .fixedSize()
            }

            HStack(alignment: .top, spacing: 2) {
                ForEach(0..<Equalizer.bandCount, id: \.self) { band in
                    EQBand(gain: app.equalizer[band], label: Equalizer.labels[band]) {
                        engine.setBand(band, gain: $0, for: app.id)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Reset \(app.name)") { engine.reset(app.id) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct EQBand: View {
    let gain: Double
    let label: String
    let changed: (Double) -> Void

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                let height = geometry.size.height
                let range = Equalizer.range
                let knob = height * (range.upperBound - gain) / (range.upperBound - range.lowerBound)
                ZStack {
                    Capsule().fill(.quaternary).frame(width: 3)
                    Rectangle().fill(.tertiary).frame(height: 1).position(x: geometry.size.width / 2, y: height / 2)
                    Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                        .position(x: geometry.size.width / 2, y: knob)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let position = min(max(value.location.y / height, 0), 1)
                    let raw = range.upperBound - position * (range.upperBound - range.lowerBound)
                    let rounded = (raw * 2).rounded() / 2
                    changed(abs(rounded) < 1 ? 0 : rounded) // snaps to flat
                })
            }
            .frame(height: 70)
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel("\(label) hertz")
        .accessibilityValue("\(gain, specifier: "%.1f") decibels")
        .accessibilityAdjustableAction { direction in
            changed(min(max(gain + (direction == .increment ? 1 : -1), Equalizer.range.lowerBound), Equalizer.range.upperBound))
        }
    }
}
