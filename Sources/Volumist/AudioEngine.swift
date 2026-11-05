import AppKit
import Combine
import CoreAudio
import ServiceManagement

struct AudioApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    var isPlaying: Bool
    var volume: Double
    var isMuted: Bool
    var outputUID: String?   // nil: follows the system output
    var outputName: String?
    var outputMissing: Bool  // the chosen output is disconnected, so it plays through the system one
    var neverLower = false   // excluded from lowering during calls
    var isLowered = false    // being lowered right now because of a call
}

/// Lowers other apps while a call is in progress.
struct DuckingOptions: Codable, Equatable {
    enum Trigger: String, Codable, CaseIterable, Identifiable {
        case anyMicrophone, callApps
        var id: Self { self }
        var title: String { self == .anyMicrophone ? "Any app using the microphone" : "Known call apps only" }
    }
    var isEnabled = false
    var level = 0.5 // slider position: same perceptual curve as the app volumes, relative to them
    var trigger = Trigger.anyMicrophone

    /// Apps counted by `.callApps`. Browsers are not here: they use the microphone for many other things.
    static let callApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram", "com.skype.skype", "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp",
    ]
}

/// Watches which apps use audio and keeps one `TapSession` per adjusted app.
/// Apps left at their defaults never go through Volumist: their audio takes the normal system path.
@MainActor
final class AudioEngine: ObservableObject {
    static let maxVolume = 1.5
    private static let ioGrace: TimeInterval = 20   // keep I/O running after playback stops
    private static let tapHold: TimeInterval = 3    // avoids rebuilding the tap when passing through 100 %
    private static let listGrace: TimeInterval = 60 // keep the row visible after playback stops
    private static let callGrace: TimeInterval = 2  // ignore brief microphone gaps within a call

    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var permission = AudioPermission.state
    @Published private(set) var outputName = ""
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var lastError: String?
    @Published private(set) var callAppName: String?
    @Published var ducking = DuckingOptions() {
        didSet {
            guard ducking != oldValue else { return }
            if let data = try? JSONEncoder().encode(ducking) {
                UserDefaults.standard.set(data, forKey: duckingKey)
            }
            reconcile()
        }
    }
    // Lives here rather than in @State: the Command Line Tools ship without the SwiftUI macro plugin.
    @Published var launchAtLogin = LaunchAtLogin.isEnabled {
        didSet { LaunchAtLogin.set(launchAtLogin) }
    }

    private struct Group {
        var identity: AppIdentity
        var processes: [AudioObjectID] = []
        var isPlaying = false
        var usesMicrophone = false
    }
    private struct Setting: Codable {
        var volume = 1.0
        var isMuted = false
        var outputUID: String?
        var outputName: String? // so it can be shown while disconnected
        var neverLower: Bool? // optional so that settings saved by version 1.0 still decode
        var usesDefaultAudio: Bool { volume == 1 && !isMuted && outputUID == nil }
        var isEmpty: Bool { usesDefaultAudio && neverLower != true }
        var gain: Float { isMuted ? 0 : Float(volume * volume) } // perceptual curve
    }

    private var settings: [String: Setting] = [:]
    private var groups: [String: Group] = [:]
    private var sessions: [String: TapSession] = [:]
    private var lastPlayed: [String: Date] = [:]
    private var lastChange: [String: Date] = [:]
    private var lowered = Set<String>()
    private var lastCall = Date.distantPast
    private var lastCallName: String?
    /// Diagnostics only: behaves as if this app had the microphone open.
    var simulatedCallApp: String? { didSet { reconcile() } }
    private var identities: [pid_t: AppIdentity] = [:]
    private var defaultOutputUID: String?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var deviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var timer: Timer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let settingsKey = "volumes"
    private let duckingKey = "ducking"

    /// Sample state for rendering the UI, with no audio side effects.
    init(preview apps: [AudioApp], output: String, call: String) {
        self.apps = apps
        outputName = output
        callAppName = call
        // Through the wrapper: assigning `ducking` would save it and reconcile against real audio.
        _ducking = Published(initialValue: DuckingOptions(isEnabled: true))
        _launchAtLogin = Published(initialValue: false)
        permission = .granted
    }

    /// Diagnostics: the apps holding the microphone right now, whether or not they would trigger lowering.
    var liveMicrophoneApps: [String] {
        groups.values.filter(\.usesMicrophone).map { "\($0.identity.name) (user app: \($0.identity.isUserApp))" }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let saved = try? JSONDecoder().decode([String: Setting].self, from: data) {
            settings = saved
        }
        if let data = UserDefaults.standard.data(forKey: duckingKey),
           let saved = try? JSONDecoder().decode(DuckingOptions.self, from: data) {
            _ducking = Published(initialValue: saved)
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDevices] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        if permission != .granted { requestPermission() }
        reconcile()
    }

    func requestPermission() {
        AudioPermission.request { [weak self] _ in
            MainActor.assumeIsolated {
                self?.permission = AudioPermission.state
                self?.reconcile()
            }
        }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }

    func setVolume(_ volume: Double, for id: String) {
        change(id) { $0.volume = min(max(volume, 0), Self.maxVolume); $0.isMuted = false }
    }

    func toggleMute(for id: String) {
        change(id) { $0.isMuted.toggle() }
    }

    /// A nil `uid` returns the app to the system output.
    func setOutput(_ uid: String?, name: String? = nil, for id: String) {
        change(id) { $0.outputUID = uid; $0.outputName = name }
    }

    func setNeverLower(_ value: Bool, for id: String) {
        change(id) { $0.neverLower = value ? true : nil }
    }

    func resetAll() {
        for id in settings.keys { lastChange[id] = .distantPast }
        settings.removeAll()
        save()
        reconcile()
    }

    private func change(_ id: String, _ edit: (inout Setting) -> Void) {
        var setting = settings[id] ?? Setting()
        edit(&setting)
        settings[id] = setting.isEmpty ? nil : setting
        lastChange[id] = Date()
        save()
        sessions[id]?.setGain(gain(for: setting, lowered: lowered.contains(id)))
        reconcile()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    /// The single place where actual state is compared with desired state. Idempotent.
    private func reconcile() {
        permission = AudioPermission.state
        refreshDevices()
        refreshGroups()

        let now = Date()
        for (id, group) in groups where group.isPlaying { lastPlayed[id] = now }
        refreshCall(now: now)

        var failure: String?
        for id in Set(groups.keys).union(sessions.keys) {
            do { try reconcileSession(id, now: now) } catch {
                sessions[id] = nil // never leave an app muted because of a failure
                failure = "\(groups[id]?.identity.name ?? id): \(error)"
            }
        }
        lastError = failure
        publish(now: now)
    }

    private func reconcileSession(_ id: String, now: Date) throws {
        let setting = settings[id] ?? Setting()
        guard let group = groups[id], permission == .granted else {
            sessions[id] = nil
            lowered.remove(id)
            return
        }
        let lower = shouldLower(id, setting: setting, group: group)
        if !lower, lowered.contains(id) { lastChange[id] = now } // holds the tap while it fades back up
        let held = now.timeIntervalSince(lastChange[id] ?? .distantPast) < Self.tapHold
        guard !setting.usesDefaultAudio || lower || (held && sessions[id] != nil) else {
            sessions[id] = nil
            lowered.remove(id)
            return
        }

        let session: TapSession
        if let existing = sessions[id] {
            session = existing
            try session.update(processes: group.processes)
        } else {
            session = try TapSession(processes: group.processes, gain: setting.gain)
            sessions[id] = session
        }

        let gain = gain(for: setting, lowered: lower)
        if lower != lowered.contains(id) {
            session.setGain(gain, fade: true)
            if lower { lowered.insert(id) } else { lowered.remove(id) }
        }

        // A tap mutes on its own; I/O is only needed when there is something to hear.
        let recentlyPlaying = now.timeIntervalSince(lastPlayed[id] ?? .distantPast) < Self.ioGrace
        if gain > 0, recentlyPlaying, let target = targetOutput(for: setting) {
            try session.start(outputUID: target)
        } else {
            session.stop()
        }
    }

    private func gain(for setting: Setting, lowered: Bool) -> Float {
        setting.gain * (lowered ? Float(ducking.level * ducking.level) : 1)
    }

    /// The apps in the call are never lowered. Idle apps are skipped so a call doesn't tap everything.
    private func shouldLower(_ id: String, setting: Setting, group: Group) -> Bool {
        callAppName != nil && setting.neverLower != true && !isCallApp(id, group)
            && (group.isPlaying || sessions[id] != nil)
    }

    private func isCallApp(_ id: String, _ group: Group) -> Bool {
        guard id != simulatedCallApp else { return true }
        guard group.usesMicrophone, group.identity.isUserApp else { return false }
        return ducking.trigger == .anyMicrophone || DuckingOptions.callApps.contains(id)
    }

    private func refreshCall(now: Date) {
        var name: String?
        if ducking.isEnabled {
            name = simulatedCallApp ?? groups.filter { isCallApp($0.key, $0.value) }.map(\.value.identity.name).sorted().first
        }
        if let name {
            lastCall = now
            lastCallName = name
        } else if ducking.isEnabled, now.timeIntervalSince(lastCall) < Self.callGrace {
            name = lastCallName // the periodic timer ends the grace period
        }
        if name != callAppName { callAppName = name }
    }

    /// If the chosen output is disconnected the system one is used, and the choice is kept:
    /// the app returns to it by itself on reconnection.
    private func targetOutput(for setting: Setting) -> String? {
        if let uid = setting.outputUID, devices.contains(where: { $0.id == uid }) { return uid }
        return defaultOutputUID
    }

    private func refreshDevices() {
        let fresh = outputDevices()
        if fresh != devices { devices = fresh }
        let system = defaultOutputDevice()
        defaultOutputUID = system.flatMap { readString($0, kAudioDevicePropertyDeviceUID) }
        let name = system.flatMap { readString($0, kAudioObjectPropertyName) } ?? ""
        if name != outputName { outputName = name }

        // The aggregate is tied to the device's sample rate: rebuild it when that changes.
        let selector = kAudioDevicePropertyNominalSampleRate
        for object in Set(deviceListeners.keys).subtracting(fresh.map(\.object)) {
            var addr = address(selector)
            if let listener = deviceListeners.removeValue(forKey: object) {
                AudioObjectRemovePropertyListenerBlock(object, &addr, .main, listener)
            }
        }
        for device in fresh where deviceListeners[device.object] == nil {
            let uid = device.id
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.sessions.values.filter { $0.outputUID == uid }.forEach { $0.stop() }
                    self?.reconcile()
                }
            }
            var addr = address(selector)
            if AudioObjectAddPropertyListenerBlock(device.object, &addr, .main, listener) == noErr {
                deviceListeners[device.object] = listener
            }
        }
    }

    private func refreshGroups() {
        let objects = readObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        var fresh: [String: Group] = [:]
        var livePIDs = Set<pid_t>()
        for object in objects {
            guard let pid = readValue(object, kAudioProcessPropertyPID, as: pid_t(0)), pid != ownPID else { continue }
            livePIDs.insert(pid)
            watchProcess(object)
            let identity = identities[pid] ?? AppIdentity.resolve(pid: pid, object: object)
            identities[pid] = identity
            fresh[identity.key, default: Group(identity: identity)].processes.append(object)
            if readValue(object, kAudioProcessPropertyIsRunningOutput, as: UInt32(0)) == 1 {
                fresh[identity.key]?.isPlaying = true
            }
            if readValue(object, kAudioProcessPropertyIsRunningInput, as: UInt32(0)) == 1 {
                fresh[identity.key]?.usesMicrophone = true
            }
        }
        identities = identities.filter { livePIDs.contains($0.key) }
        for object in Set(processListeners.keys).subtracting(objects) { unwatchProcess(object) }
        for key in fresh.keys { fresh[key]?.processes.sort() }
        groups = fresh
    }

    private func watchProcess(_ object: AudioObjectID) {
        guard processListeners[object] == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        var output = address(kAudioProcessPropertyIsRunningOutput)
        var input = address(kAudioProcessPropertyIsRunningInput)
        if AudioObjectAddPropertyListenerBlock(object, &output, .main, listener) == noErr {
            AudioObjectAddPropertyListenerBlock(object, &input, .main, listener)
            processListeners[object] = listener
        }
    }

    private func unwatchProcess(_ object: AudioObjectID) {
        guard let listener = processListeners.removeValue(forKey: object) else { return }
        var output = address(kAudioProcessPropertyIsRunningOutput)
        var input = address(kAudioProcessPropertyIsRunningInput)
        AudioObjectRemovePropertyListenerBlock(object, &output, .main, listener)
        AudioObjectRemovePropertyListenerBlock(object, &input, .main, listener)
    }

    private func publish(now: Date) {
        let visible = groups.compactMap { id, group -> AudioApp? in
            let setting = settings[id] ?? Setting()
            let recent = now.timeIntervalSince(lastPlayed[id] ?? .distantPast) < Self.listGrace
            guard group.isPlaying || recent || !setting.usesDefaultAudio else { return nil }
            return AudioApp(id: id, name: group.identity.name, icon: group.identity.icon,
                            isPlaying: group.isPlaying, volume: setting.volume, isMuted: setting.isMuted,
                            outputUID: setting.outputUID, outputName: setting.outputName,
                            outputMissing: setting.outputUID.map { uid in !devices.contains { $0.id == uid } } ?? false,
                            neverLower: setting.neverLower == true, isLowered: lowered.contains(id))
        }
        let sorted = visible.sorted {
            $0.isPlaying != $1.isPlaying ? $0.isPlaying
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if !sorted.elementsEqual(apps, by: { $0.id == $1.id && $0.isPlaying == $1.isPlaying
            && $0.volume == $1.volume && $0.isMuted == $1.isMuted
            && $0.outputUID == $1.outputUID && $0.outputMissing == $1.outputMissing
            && $0.neverLower == $1.neverLower && $0.isLowered == $1.isLowered }) {
            apps = sorted
        }
    }
}

private extension AppIdentity {
    static func resolve(pid: pid_t, object: AudioObjectID) -> AppIdentity {
        AppResolver.identity(pid: pid, bundleID: readString(object, kAudioProcessPropertyBundleID))
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ enabled: Bool) {
        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    }
}
