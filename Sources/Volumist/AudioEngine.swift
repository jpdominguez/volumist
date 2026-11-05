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
}

/// Watches which apps use audio and keeps one `TapSession` per adjusted app.
/// Apps left at their defaults never go through Volumist: their audio takes the normal system path.
@MainActor
final class AudioEngine: ObservableObject {
    static let maxVolume = 1.5
    private static let ioGrace: TimeInterval = 20   // keep I/O running after playback stops
    private static let tapHold: TimeInterval = 3    // avoids rebuilding the tap when passing through 100 %
    private static let listGrace: TimeInterval = 60 // keep the row visible after playback stops

    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var permission = AudioPermission.state
    @Published private(set) var outputName = ""
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var lastError: String?
    // Lives here rather than in @State: the Command Line Tools ship without the SwiftUI macro plugin.
    @Published var launchAtLogin = LaunchAtLogin.isEnabled {
        didSet { LaunchAtLogin.set(launchAtLogin) }
    }

    private struct Group {
        var identity: AppIdentity
        var processes: [AudioObjectID] = []
        var isPlaying = false
    }
    private struct Setting: Codable {
        var volume = 1.0
        var isMuted = false
        var outputUID: String?
        var outputName: String? // so it can be shown while disconnected
        var isDefault: Bool { volume == 1 && !isMuted && outputUID == nil }
        var gain: Float { isMuted ? 0 : Float(volume * volume) } // perceptual curve
    }

    private var settings: [String: Setting] = [:]
    private var groups: [String: Group] = [:]
    private var sessions: [String: TapSession] = [:]
    private var lastPlayed: [String: Date] = [:]
    private var lastChange: [String: Date] = [:]
    private var identities: [pid_t: AppIdentity] = [:]
    private var defaultOutputUID: String?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var deviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var timer: Timer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let settingsKey = "volumes"

    /// Sample state for rendering the UI, with no audio side effects.
    init(preview apps: [AudioApp], output: String) {
        self.apps = apps
        outputName = output
        permission = .granted
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let saved = try? JSONDecoder().decode([String: Setting].self, from: data) {
            settings = saved
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

    func resetAll() {
        for id in settings.keys { lastChange[id] = .distantPast }
        settings.removeAll()
        save()
        reconcile()
    }

    private func change(_ id: String, _ edit: (inout Setting) -> Void) {
        var setting = settings[id] ?? Setting()
        edit(&setting)
        settings[id] = setting.isDefault ? nil : setting
        lastChange[id] = Date()
        save()
        sessions[id]?.setGain(setting.gain)
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
            return
        }
        let held = now.timeIntervalSince(lastChange[id] ?? .distantPast) < Self.tapHold
        guard !setting.isDefault || (held && sessions[id] != nil) else {
            sessions[id] = nil
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

        // A tap mutes on its own; I/O is only needed when there is something to hear.
        let recentlyPlaying = now.timeIntervalSince(lastPlayed[id] ?? .distantPast) < Self.ioGrace
        if setting.gain > 0, recentlyPlaying, let target = targetOutput(for: setting) {
            try session.start(outputUID: target)
        } else {
            session.stop()
        }
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
        var addr = address(kAudioProcessPropertyIsRunningOutput)
        if AudioObjectAddPropertyListenerBlock(object, &addr, .main, listener) == noErr {
            processListeners[object] = listener
        }
    }

    private func unwatchProcess(_ object: AudioObjectID) {
        guard let listener = processListeners.removeValue(forKey: object) else { return }
        var addr = address(kAudioProcessPropertyIsRunningOutput)
        AudioObjectRemovePropertyListenerBlock(object, &addr, .main, listener)
    }

    private func publish(now: Date) {
        let visible = groups.compactMap { id, group -> AudioApp? in
            let setting = settings[id] ?? Setting()
            let recent = now.timeIntervalSince(lastPlayed[id] ?? .distantPast) < Self.listGrace
            guard group.isPlaying || recent || !setting.isDefault else { return nil }
            return AudioApp(id: id, name: group.identity.name, icon: group.identity.icon,
                            isPlaying: group.isPlaying, volume: setting.volume, isMuted: setting.isMuted,
                            outputUID: setting.outputUID, outputName: setting.outputName,
                            outputMissing: setting.outputUID.map { uid in !devices.contains { $0.id == uid } } ?? false)
        }
        let sorted = visible.sorted {
            $0.isPlaying != $1.isPlaying ? $0.isPlaying
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if !sorted.elementsEqual(apps, by: { $0.id == $1.id && $0.isPlaying == $1.isPlaying
            && $0.volume == $1.volume && $0.isMuted == $1.isMuted
            && $0.outputUID == $1.outputUID && $0.outputMissing == $1.outputMissing }) {
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
