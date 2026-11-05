import CMixer
import CoreAudio
import Foundation
import AppKit
import SwiftUI

/// Diagnostics: `Volumist --selftest <pid> <log-file>`. Uses independent taps to measure the audio
/// emitted by process `pid` and the audio leaving Volumist, verifying the gain end to end.
enum SelfTest {
    final class Meter {
        let tap: AudioObjectID
        var aggregate = AudioObjectID(0)
        var proc: AudioDeviceIOProcID?
        let meter = vm_meter_create()

        init(process: AudioObjectID, output: AudioObjectID) throws {
            let desc = CATapDescription(stereoMixdownOfProcesses: [process])
            desc.uuid = UUID(); desc.isPrivate = true; desc.muteBehavior = .unmuted
            var id = AudioObjectID(0)
            var status = AudioHardwareCreateProcessTap(desc, &id)
            guard status == noErr else { throw AudioError("tap", status) }
            tap = id
            let uid = readString(output, kAudioDevicePropertyDeviceUID)!
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Volumist Meter",
                kAudioAggregateDeviceUIDKey: "volumist-meter.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: uid,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                                   kAudioSubTapDriftCompensationKey: true]],
            ]
            status = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate)
            guard status == noErr else { throw AudioError("aggregate", status) }
            status = AudioDeviceCreateIOProcID(aggregate, vm_meter_ioproc, UnsafeMutableRawPointer(meter), &proc)
            guard status == noErr else { throw AudioError("ioproc", status) }
            status = AudioDeviceStart(aggregate, proc)
            guard status == noErr else { throw AudioError("start", status) }
        }

        func rms() -> Float { vm_meter_take_rms(meter) }
    }

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
            try session.start(outputUID: readString(output, kAudioDevicePropertyDeviceUID)!)
            let mine = processObject(ProcessInfo.processInfo.processIdentifier)
            guard mine != 0 else { throw AudioError("Volumist is not listed as an audio process", -1) }
            let sourceMeter = try Meter(process: source, output: output)
            let mineMeter = try Meter(process: mine, output: output)

            for gain: Float in [1, 0.25, 0.5, 0, 1] {
                session.setGain(gain)
                Thread.sleep(forTimeInterval: 1)
                _ = sourceMeter.rms(); _ = mineMeter.rms()
                Thread.sleep(forTimeInterval: 1.5)
                let a = sourceMeter.rms(), b = mineMeter.rms()
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
        guard mine != 0, let meter = try? Meter(process: mine, output: output) else {
            fail("no meter, engine error: \(engine.lastError ?? "-")")
        }
        func measure(_ label: String) {
            wait(1); _ = meter.rms(); wait(1.5)
            log(String(format: "%@: output %.5f  error: %@  apps: %@", label, meter.rms(), engine.lastError ?? "-", state()))
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
                 lowered: Bool = false, neverLower: Bool = false) -> AudioApp {
            // The bundle's own icon: NSWorkspace would return it tinted if the system icon style is.
            let file = Bundle(path: path)?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
            let icon = file.flatMap { NSImage(contentsOfFile: "\(path)/Contents/Resources/\(($0 as NSString).deletingPathExtension).icns") }
            return AudioApp(id: name, name: name, icon: icon ?? NSWorkspace.shared.icon(forFile: path), isPlaying: true,
                     volume: volume, isMuted: muted, outputUID: output, outputName: output, outputMissing: false,
                            neverLower: neverLower, isLowered: lowered)
        }
        let engine = AudioEngine(preview: [
            row("Spotify", "/Applications/Spotify.app", 0.8, output: "External Speakers", lowered: true),
            row("VLC", "/Applications/VLC.app", 1),
            row("Zoom", "/Applications/zoom.us.app", 1.25, neverLower: true),
            row("Discord", "/Applications/Discord.app", 0.8, muted: true),
        ], output: "Headphones", call: "Zoom")

        let view = NSHostingView(rootView: MixerView(engine: engine).background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: .aqua)
        view.frame.size = view.fittingSize
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.backgroundColor = .windowBackgroundColor
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
}
