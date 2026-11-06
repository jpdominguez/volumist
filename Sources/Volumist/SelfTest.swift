import CMixer
import CoreAudio
import Foundation
import AppKit
import SwiftUI

/// Diagnostics: `Volumist --selftest <pid> <log-file>`. Uses independent taps to measure the audio
/// emitted by process `pid` and the audio leaving Volumist, verifying the gain end to end.
enum SelfTest {
    static func run(arguments: [String]) {
        guard arguments.count == 2, let target = pid_t(arguments[0]) else { exit(2) }
        let logURL = URL(fileURLWithPath: arguments[1])
        var text = ""
        func log(_ line: String) {
            text += line + "\n"
            try? text.write(to: logURL, atomically: true, encoding: .utf8)
        }

        log("initial permission: \(AudioPermission.state)")
        if AudioPermission.state != .granted {
            let done = DispatchSemaphore(value: 0)
            AudioPermission.request { _ in done.signal() }
            while done.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            log("permission after request: \(AudioPermission.state)")
        }

        func processObject(_ pid: pid_t) -> AudioObjectID {
            var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var pid = pid
            var object = AudioObjectID(0)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
            return object
        }

        do {
            guard let output = defaultOutputDevice() else { throw AudioError("no output device", -1) }
            log("output: \(readString(output, kAudioObjectPropertyName) ?? "?")")
            let source = processObject(target)
            guard source != 0 else { throw AudioError("the process has no audio", -1) }

            let session = try TapSession(processes: [source], gain: 1)
            try session.start(outputs: [readString(output, kAudioDevicePropertyDeviceUID)!])
            let mine = processObject(ProcessInfo.processInfo.processIdentifier)
            guard mine != 0 else { throw AudioError("Volumist is not listed as an audio process", -1) }
            let uid = readString(output, kAudioDevicePropertyDeviceUID)!
            let sourceMeter = try MeterTap(processes: [source], outputUID: uid)
            let mineMeter = try MeterTap(processes: [mine], outputUID: uid)

            for gain: Float in [1, 0.25, 0.5, 0, 1] {
                session.setGain(gain)
                Thread.sleep(forTimeInterval: 1)
                _ = sourceMeter.take(); _ = mineMeter.take()
                Thread.sleep(forTimeInterval: 1.5)
                let a = sourceMeter.take().rms, b = mineMeter.take().rms
                log(String(format: "gain %.2f  source %.5f  output %.5f  ratio %.3f", gain, a, b, a > 0 ? b / a : -1))
            }
            log("done")
        } catch {
            log("ERROR: \(error)")
        }
        exit(0)
    }

    /// `Volumist --check <folder>`: exercises the real engine with whichever app is playing and logs
    /// Volumist's output level in each state. Saved volumes are restored at the end.
    @MainActor
    static func check(directory: String) {
        var text = ""
        func log(_ line: String) {
            text += line + "\n"
            try? text.write(toFile: directory + "/check.log", atomically: true, encoding: .utf8)
        }
        func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        let savedVolumes = UserDefaults.standard.data(forKey: "volumes")
        let engine = AudioEngine()
        func state() -> String {
            engine.apps.map { "\($0.name)[\($0.id)] playing=\($0.isPlaying) vol=\($0.volume) mute=\($0.isMuted)" }
                .joined(separator: " | ")
        }

        wait(3)
        for _ in 0..<120 where engine.permission != .granted { wait(1) } // time to answer the system prompt
        log("permission: \(engine.permission)  output: \(engine.outputName)")
        log("apps: \(state())")
        func fail(_ message: String) -> Never {
            engine.resetAll()
            UserDefaults.standard.set(savedVolumes, forKey: "volumes")
            log("ERROR: \(message)")
            exit(1)
        }
        guard engine.permission == .granted else { fail("audio capture permission not granted") }
        guard let app = engine.apps.first(where: { $0.isPlaying }), let output = defaultOutputDevice() else {
            fail("no app is playing")
        }

        engine.setVolume(0.5, for: app.id)
        wait(1)
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = ProcessInfo.processInfo.processIdentifier
        var mine = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                   UInt32(MemoryLayout<pid_t>.size), &pid, &size, &mine)
        guard mine != 0, let outputUID = readString(output, kAudioDevicePropertyDeviceUID),
              let meter = try? MeterTap(processes: [mine], outputUID: outputUID) else {
            fail("no meter, engine error: \(engine.lastError ?? "-")")
        }
        func measure(_ label: String) {
            wait(1); _ = meter.take(); wait(1.5)
            let reading = meter.take()
            log(String(format: "%@: output %.5f  left %.5f  right %.5f  error: %@  apps: %@", label, reading.rms,
                       reading.left, reading.right, engine.lastError ?? "-", state()))
        }
        measure("volume 50% (gain 0.25)")
        engine.setVolume(1.2, for: app.id)
        measure("volume 120% (gain 1.44)")
        engine.toggleMute(for: app.id)
        measure("muted")
        engine.toggleMute(for: app.id)
        measure("unmuted (120%)")
        engine.setVolume(1, for: app.id)
        wait(6)
        measure("100%: must leave Volumist")
        engine.setVolume(0.5, for: app.id)
        measure("50% again")
        engine.setVolume(1, for: app.id)
        wait(6)

        // Ducking: lowered while a call is active, with the app's own volume as the base.
        log("microphone in use by: \(engine.liveMicrophoneApps.joined(separator: ", "))")
        let savedDucking = engine.ducking
        engine.ducking = DuckingOptions(isEnabled: true, level: 0.5, trigger: .callApps)
        engine.simulatedCallApp = "simulated.call.app"
        log("call simulated: \(engine.callAppName ?? "none")")
        wait(5)
        measure("in call, lower to 50% (gain 0.25)")
        engine.setVolume(0.5, for: app.id)
        wait(5)
        measure("in call, volume 50% (gain 0.0625)")
        engine.setVolume(1, for: app.id)
        engine.setNeverLower(true, for: app.id)
        wait(6)
        measure("in call, excluded app: must leave Volumist")
        engine.setNeverLower(false, for: app.id)
        wait(5)
        measure("in call, included again (gain 0.25)")
        engine.simulatedCallApp = app.id
        wait(8)
        measure("the app itself is in the call: must leave Volumist")
        engine.simulatedCallApp = "simulated.call.app"
        wait(5)
        measure("lowered again (gain 0.25)")
        engine.simulatedCallApp = nil
        wait(10)
        measure("call ended: must leave Volumist")
        engine.ducking = savedDucking

        // Balance and equalizer, which also make an app at 100% go through Volumist.
        engine.setBalance(1, for: app.id)
        wait(2)
        measure("balance fully right")
        engine.setBalance(-0.5, for: app.id)
        measure("balance half left")
        engine.setBalance(0, for: app.id)
        var gains = Equalizer.flat
        gains[4] = 12 // 500 Hz, next to the 440 Hz tone
        engine.setEqualizer(gains, for: app.id)
        measure("EQ +12 dB at 500 Hz")
        gains = Equalizer.flat
        gains[9] = 12 // 16 kHz, far from the tone
        engine.setEqualizer(gains, for: app.id)
        measure("EQ +12 dB at 16 kHz")
        gains = Equalizer.flat
        gains[4] = -12
        engine.setEqualizer(gains, for: app.id)
        measure("EQ -12 dB at 500 Hz")
        engine.setEqualizer(Equalizer.flat, for: app.id)
        wait(6)
        measure("EQ flat: must leave Volumist")

        // Leveler: this quiet tone (-29 dBFS) should rise by its maximum of 9 dB.
        engine.setLevelsVolume(true, for: app.id)
        wait(15)
        measure("leveler on a quiet tone (+9 dB)")
        engine.setLevelsVolume(false, for: app.id)
        wait(6)
        measure("leveler off: must leave Volumist")

        // Resetting one app clears everything at once.
        engine.setVolume(0.5, for: app.id)
        engine.setBalance(0.5, for: app.id)
        engine.setLevelsVolume(true, for: app.id)
        wait(2)
        engine.reset(app.id)
        wait(6)
        measure("reset app: must leave Volumist")

        // Meters: they only run with the window open, and must not touch the audio path.
        engine.setWindowOpen(true)
        wait(2)
        log(String(format: "meter at 100%%: %.4f", engine.levels.levels[app.id] ?? -1))
        measure("meter open: must not go through Volumist")
        engine.setVolume(0.5, for: app.id)
        wait(2)
        log(String(format: "meter at 50%% (gain 0.25): %.4f", engine.levels.levels[app.id] ?? -1))
        engine.setVolume(1, for: app.id)
        engine.setWindowOpen(false)
        wait(5)

        // Update check.
        log("update comparison: \(UpdateChecker.isNewer("1.10.0", than: "1.9.0")) \(UpdateChecker.isNewer("1.1.0", than: "1.2.0")) \(UpdateChecker.isNewer("1.2.0", than: "1.2.0"))")
        var latest: UpdateChecker.Release?
        Task { latest = try? await UpdateChecker.latestRelease() }
        for _ in 0..<50 where latest == nil { wait(0.2) }
        log("latest release: \(latest?.version ?? "unavailable") at \(latest?.htmlUrl.absoluteString ?? "-")  running: \(UpdateChecker.currentVersion)")

        // Routing: an idle output must become busy, and go idle again afterwards.
        func running(_ device: OutputDevice) -> Bool {
            readValue(device.object, kAudioDevicePropertyDeviceIsRunningSomewhere, as: UInt32(0)) == 1
        }
        log("outputs: \(engine.devices.map { "\($0.name)=\(running($0) ? "busy" : "idle")" }.joined(separator: ", "))")
        if let other = engine.devices.first(where: { !running($0) && $0.name != engine.outputName }) {
            engine.setOutput(other.id, name: other.name, for: app.id)
            measure("output \(other.name)")
            log("\(other.name) busy: \(running(other))")
            engine.setOutput("missing-device", name: "Missing", for: app.id)
            measure("disconnected output (must use the system one)")
            log("\(other.name) busy: \(running(other))  warning shown: \(engine.apps.first { $0.id == app.id }?.outputMissing ?? false)")
            engine.setOutput(other.id, name: other.name, for: app.id)
            measure("output reconnected")
            log("\(other.name) busy: \(running(other))")
            engine.setOutput(nil, for: app.id)
            wait(6)
            log("back to the system output, \(other.name) busy: \(running(other))")
        } else {
            log("ERROR: no other idle output")
        }
        engine.resetAll()
        UserDefaults.standard.set(savedVolumes, forKey: "volumes")
        log("done")
        exit(0)
    }

    /// `Volumist --render-preview <png>`: draws the real interface with sample state, for the docs.
    @MainActor
    static func renderPreview(to path: String) {
        _ = NSApplication.shared
        func row(_ name: String, _ path: String, _ volume: Double, muted: Bool = false, output: String? = nil,
                 lowered: Bool = false, neverLower: Bool = false, equalizer: [Double] = Equalizer.flat,
                 balance: Double = 0, secondOutput: String? = nil) -> AudioApp {
            // The bundle's own icon: NSWorkspace would return it tinted if the system icon style is.
            let file = Bundle(path: path)?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
            let icon = file.flatMap { NSImage(contentsOfFile: "\(path)/Contents/Resources/\(($0 as NSString).deletingPathExtension).icns") }
            return AudioApp(id: name, name: name, icon: icon ?? NSWorkspace.shared.icon(forFile: path), isPlaying: true,
                     volume: volume, isMuted: muted, outputUID: output, outputName: output, outputMissing: false,
                            secondOutputUID: secondOutput, secondOutputName: secondOutput,
                            neverLower: neverLower, isLowered: lowered, balance: balance, equalizer: equalizer)
        }
        let engine = AudioEngine(preview: [
            row("Spotify", "/Applications/Spotify.app", 0.8, output: "External Speakers", lowered: true,
                equalizer: Equalizer.presets[1].gains, balance: -0.2, secondOutput: "Display Audio"),
            row("VLC", "/Applications/VLC.app", 1),
            row("Zoom", "/Applications/zoom.us.app", 1.25, neverLower: true),
            row("Discord", "/Applications/Discord.app", 0.8, muted: true),
        ], output: "Headphones", call: "Zoom", expanded: "Spotify",
           previewLevels: ["Spotify": 0.12, "VLC": 0.4, "Zoom": 0.6])
        engine.showsWholeList = true

        snapshot(MixerView(engine: engine), to: path)
        exit(0)
    }

    /// `Volumist --render-screens <folder>`: the welcome and What's New screens, for checking them by eye.
    @MainActor
    static func renderScreens(to folder: String) {
        _ = NSApplication.shared
        let engine = AudioEngine(preview: [], output: "Output", call: nil, expanded: nil, previewLevels: [:],
                                 lowersInCalls: false) // as a new user sees it
        let notes = ReleaseNotes.bundled
        engine.setPreview(permission: .unknown)
        snapshot(WelcomeView(engine: engine) {}, to: "\(folder)/welcome.png")
        snapshot(WelcomeView(engine: engine) {}, to: "\(folder)/welcome-dark.png", appearance: .darkAqua)
        engine.setPreview(permission: .denied)
        snapshot(WelcomeView(engine: engine) {}, to: "\(folder)/welcome-denied.png")
        engine.setPreview(permission: .granted)
        snapshot(WelcomeView(engine: engine) {}, to: "\(folder)/welcome-granted.png")
        snapshot(WhatsNewView(notes: Array(notes.prefix(1))) {}, to: "\(folder)/whats-new.png")
        snapshot(WhatsNewView(notes: notes) {}, to: "\(folder)/whats-new-all.png")
        engine.setPreview(updateCheckMessage: "Volumist \(UpdateChecker.currentVersion) is the latest version.")
        snapshot(MixerView(engine: engine), to: "\(folder)/mixer.png")

        var app = AudioApp(id: "app", name: "Music", icon: nil, isPlaying: true, volume: 1, isMuted: false,
                           outputUID: nil, outputName: nil, outputMissing: false)
        let details = AudioEngine(preview: [app], output: "Headphones", call: nil, expanded: "app", previewLevels: [:])
        app.secondOutputUID = "External Speakers"
        app.secondOutputName = "External Speakers"
        app.mayEcho = true
        details.setPreview(apps: [app], call: nil, expanded: "app")
        snapshot(MixerView(engine: details), to: "\(folder)/two-outputs.png")
        app.secondOutputUID = nil
        app.mayEcho = false
        app.isMono = true
        details.setPreview(apps: [app], call: nil, expanded: "app")
        details.ducking.trigger = .callApps
        snapshot(MixerView(engine: details), to: "\(folder)/mono.png")
        exit(0)
    }

    @MainActor
    private static func snapshot(_ content: some View, to path: String, appearance: NSAppearance.Name = .aqua) {
        let view = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: appearance)
        view.frame.size = view.fittingSize
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.backgroundColor = .windowBackgroundColor
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Which screen opens at launch, and that both open, fit and close in real windows.
    @MainActor
    private static func checkScreens() -> (report: String, passed: Bool) {
        let notes = ReleaseNotes.parse("""
            # Changelog

            ## 1.3.0

            - New thing.
            - Other thing.

            ## 1.2.1

            - Fix.

            ## 1.0.0

            First public release.

            - Volume.
            """)
        let second = Array(notes[1...1]), first = Array(notes[0...0])
        func decide(_ lastSeen: String?, _ current: String, settings: Bool) -> LaunchScreen {
            LaunchScreen.decide(lastSeen: lastSeen, current: current, hasSettings: settings, notes: notes)
        }
        let cases: [(String, LaunchScreen, LaunchScreen)] = [
            ("new user", decide(nil, "1.3.0", settings: false), .welcome),
            ("update from before 1.3", decide(nil, "1.3.0", settings: true), .whatsNew(first)),
            ("same version", decide("1.3.0", "1.3.0", settings: true), .none),
            ("update", decide("1.2.1", "1.3.0", settings: true), .whatsNew(first)),
            ("skipped versions", decide("1.0.0", "1.3.0", settings: true), .whatsNew(Array(notes[0...1]))),
            ("newer notes than the app", decide("1.0.0", "1.2.1", settings: true), .whatsNew(second)),
            ("version without notes", decide("1.3.0", "1.3.1", settings: true), .none),
            ("downgrade", decide("1.3.0", "1.2.1", settings: true), .none),
        ]
        var report = "parsed: \(notes.map { "\($0.version):\($0.changes.count)" })\n"
        var passed = notes.map(\.changes.count) == [2, 1, 1]
        for (name, got, expected) in cases where got != expected {
            report += "launch screen, \(name): got \(got)\n"
            passed = false
        }

        // Calls: a muted user can release the microphone, and apps can keep playing after a call.
        var tracker = CallTracker()
        let start = Date()
        func call(_ active: (id: String, name: String)?, playing: Bool, at seconds: TimeInterval) -> String? {
            tracker.update(active: active, isPlaying: { _ in playing }, now: start.addingTimeInterval(seconds))
        }
        let teams = (id: "com.microsoft.teams2", name: "Teams"), browser = (id: "com.google.Chrome", name: "Chrome")
        var callResults: [(String, Bool)] = [
            ("in a call", call(teams, playing: true, at: 0) == "Teams"),
            ("muted, still playing", call(nil, playing: true, at: 60) == "Teams" && tracker.sustained == teams.id),
            ("back on the microphone", call(teams, playing: true, at: 170) == "Teams" && tracker.sustained == nil),
            ("muted again, the limit restarts", call(nil, playing: true, at: 340) == "Teams"),
            ("output left open after the limit", call(nil, playing: true, at: 360) == nil),
        ]
        tracker = CallTracker()
        _ = call(teams, playing: true, at: 0)
        callResults.append(("playback stopped: within grace", call(nil, playing: false, at: 1) == "Teams"))
        callResults.append(("playback stopped: ended", call(nil, playing: false, at: 3) == nil))
        tracker = CallTracker()
        _ = call(browser, playing: true, at: 0)
        callResults.append(("a browser isn't kept in a call", call(nil, playing: true, at: 3) == nil))
        var options = DuckingOptions(trigger: .callApps)
        callResults.append(("known app counts", options.countsAsCallApp(teams.id)))
        callResults.append(("browser doesn't count", !options.countsAsCallApp(browser.id)))
        options.extraCallApps = [browser.id: browser.name]
        callResults.append(("added browser counts", options.countsAsCallApp(browser.id)))
        let old = #"{"level":0.5,"isEnabled":true,"trigger":"callApps"}"#.data(using: .utf8)!
        callResults.append(("earlier settings decode", (try? JSONDecoder().decode(DuckingOptions.self, from: old))?.isEnabled == true))
        for (name, ok) in callResults where !ok {
            report += "calls, \(name): failed\n"
            passed = false
        }
        report += "calls: \(callResults.filter(\.1).count) of \(callResults.count) passed\n"

        let engine = AudioEngine(preview: [], output: "Output", call: nil, expanded: nil, previewLevels: [:])
        let controller = AppController(engine: engine)
        controller.install()
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
        settle()
        func press(_ title: String, in view: NSView?) { // SwiftUI's default button answers to Return
            guard let window = view?.window else { return }
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: "\r",
                                       charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            if let key { NSApp.sendEvent(key) }
        }

        controller.showWelcome()
        settle()
        let welcome = controller.screenWindow
        let welcomeFits = welcome.map { ($0.screen?.visibleFrame ?? .zero).contains($0.frame) } ?? false
        report += "welcome: visible \(welcome?.isVisible == true), key \(welcome?.isKeyWindow == true), fits \(welcomeFits), size \(welcome?.frame.size ?? .zero)\n"
        passed = passed && welcome?.isVisible == true && welcomeFits
        press("Get Started", in: welcome?.contentView)
        settle()
        report += "Get Started: closed \(welcome?.isVisible == false), mixer open \(controller.popover.isShown)\n"
        passed = passed && welcome?.isVisible == false && controller.popover.isShown

        // From the mixer: the popover gives way to the window.
        controller.showWhatsNew(notes)
        settle()
        let whatsNew = controller.screenWindow
        report += "What's New: visible \(whatsNew?.isVisible == true), mixer closed \(!controller.popover.isShown), size \(whatsNew?.frame.size ?? .zero)\n"
        passed = passed && whatsNew?.isVisible == true && !controller.popover.isShown
        press("Done", in: whatsNew?.contentView)
        settle()
        report += "Done: closed \(whatsNew?.isVisible == false)\n"
        passed = passed && whatsNew?.isVisible == false
        return (report, passed)
    }

    /// `Volumist --ui-check <log-file>`: opens and closes an app's details repeatedly in the real
    /// popover, with few and with many apps. It must resize, stay anchored and fit on the screen.
    @MainActor
    static func checkExpansion(log path: String) {
        NSApplication.shared.finishLaunching()
        var report = ""
        var passed = true
        for count in [1, 30] {
            let apps = (0..<count).map {
                AudioApp(id: "app\($0)", name: "App \($0)", icon: nil, isPlaying: true, volume: 1, isMuted: false,
                         outputUID: nil, outputName: nil, outputMissing: false)
            }
            let engine = AudioEngine(preview: apps, output: "Output", call: "Call", expanded: nil, previewLevels: [:])
            let controller = AppController(engine: engine)
            controller.install()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            // On a machine with no real menu bar this can take a while, and the window would open
            // in the corner of the screen and jump to its place, which no user sees.
            let placementLimit = Date().addingTimeInterval(10)
            while !controller.isMenuBarItemPlaced, Date() < placementLimit {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            report += "menu bar item placed: \(controller.isMenuBarItemPlaced)\n"
            controller.toggle()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            guard let window = controller.popover.contentViewController?.view.window else { exit(2) }
            let closed = window.frame
            let screen = window.screen?.visibleFrame.height ?? 0

            var failures = 0
            var drift: CGFloat = 0
            var tallest = closed.height
            var firstMove: String?
            // Up to a second: a slow machine can take longer than usual to resize, which isn't a failure.
            func wait(until done: () -> Bool) {
                let limit = Date().addingTimeInterval(1)
                repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) } while !done() && Date() < limit
            }
            for _ in 0..<10 {
                engine.expandedApp = "app0"
                wait { count != 1 || window.frame.height > closed.height }
                let open = window.frame
                tallest = max(tallest, open.height)
                if count == 1, open.height <= closed.height {
                    failures += 1
                    report += "did not grow: \(closed.height) to \(open.height)\n"
                }
                drift = max(drift, abs(open.maxY - closed.maxY), abs(open.midX - closed.midX))
                if abs(open.maxY - closed.maxY) > 1, firstMove == nil {
                    firstMove = "moved when opening: \(closed) to \(open), screen \(window.screen?.frame ?? .zero)\n"
                }
                engine.expandedApp = nil
                wait { window.frame.height == closed.height }
                let shut = window.frame
                if shut.height != closed.height {
                    failures += 1
                    report += "did not return: \(closed.height) to \(shut.height)\n"
                }
                drift = max(drift, abs(shut.maxY - closed.maxY), abs(shut.midX - closed.midX))
                if abs(shut.maxY - closed.maxY) > 1, firstMove == nil {
                    firstMove = "moved when closing: \(closed) to \(shut), screen \(window.screen?.frame ?? .zero)\n"
                }
            }
            report += firstMove ?? ""
            report += "\(count) apps: closed height \(closed.height), tallest \(tallest), screen \(screen), failed \(failures) of 20, top edge moved \(drift)\n"
            // Some runners never get a menu bar, so the window has nothing to stay anchored to there.
            if controller.isMenuBarItemPlaced {
                passed = passed && failures == 0 && drift < 1 && tallest <= screen
            } else {
                report += "no menu bar: window size and position not judged\n"
            }

            // A dropdown must stay open, even if Volumist isn't the active app.
            if count == 1 {
                let control = Dropdown.Control()
                control.frame = NSRect(x: 20, y: 20, width: 100, height: 20)
                control.items = [DropdownItem(title: "One") {}, DropdownItem(title: "Two") {}]
                window.contentView?.addSubview(control)
                var stayedOpen = false
                let timer = Timer(timeInterval: 1.2, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        stayedOpen = control.activeMenu != nil
                        control.activeMenu?.cancelTracking()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                control.openMenu()
                RunLoop.main.run(until: Date().addingTimeInterval(1.6))
                control.removeFromSuperview()
                report += "app active: \(NSApp.isActive), dropdown open after 1.2 s: \(stayedOpen), window open: \(controller.popover.isShown)\n"
                passed = passed && stayedOpen && controller.popover.isShown
            }

            // The Escape key closes the window.
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                       charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
            if let key { NSApp.sendEvent(key) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            report += "closed by Escape: \(!controller.popover.isShown)\n"
            passed = passed && !controller.popover.isShown

            // The menu bar item alternates between opening and closing.
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            var toggles = [Bool]()
            for _ in 0..<6 {
                controller.toggle()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                toggles.append(controller.popover.isShown)
            }
            report += "menu bar item: \(toggles)\n"
            passed = passed && toggles == [true, false, true, false, true, false]

            // A press that closes the window from outside, then its release on the item.
            controller.toggle()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            controller.popover.performClose(nil)
            // At once, as a real click does: a slow machine could outlast the guard if this waited.
            while controller.popover.isShown { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            controller.toggle()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            report += "press and release: stays closed: \(!controller.popover.isShown)\n"
            passed = passed && !controller.popover.isShown
        }
        let screens = checkScreens()
        report += screens.report
        passed = passed && screens.passed
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
        exit(passed ? 0 : 1)
    }
}
