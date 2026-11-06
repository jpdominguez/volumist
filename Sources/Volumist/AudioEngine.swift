import AppKit
import Combine
import CoreAudio
import CMixer
import OSLog
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
    var secondOutputUID: String? // also plays here
    var secondOutputName: String?
    var secondOutputMissing = false
    var secondOutputFailed = false // macOS couldn't combine the two, so only the first one plays
    var isMono = false       // every output in use is mono, so balance can't do anything
    var mayEcho = false      // two outputs with very different delays
    var neverLower = false   // excluded from lowering during calls
    var isLowered = false    // being lowered right now because of a call
    var balance = 0.0        // -1 left, 1 right
    var equalizer = Equalizer.flat
    var levelsVolume = false // automatic leveling of loud and quiet passages
}

/// Levels change many times per second, so they live apart to redraw only the meters.
final class LevelStore: ObservableObject {
    @Published var levels: [String: Float] = [:]
}

enum Equalizer {
    static let bandCount = Int(VM_EQ_BANDS)
    static let range = -12.0...12.0
    static let flat = [Double](repeating: 0, count: bandCount)
    static let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    static let presets: [(name: String, gains: [Double])] = [
        ("Flat", flat),
        ("Bass Boost", [7, 6, 5, 3, 1, 0, 0, 0, 0, 0]),
        ("Bass Cut", [-7, -6, -5, -3, -1, 0, 0, 0, 0, 0]),
        ("Voice", [-6, -5, -3, -1, 1, 3, 4, 3, 1, 0]),
        ("Treble Boost", [0, 0, 0, 0, 0, 1, 3, 4, 6, 7]),
        ("Loudness", [6, 5, 2, 0, -1, 0, 0, 1, 4, 5]),
    ]
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
    var extraCallApps: [String: String]? // bundle ID to name. Optional so earlier settings still decode.

    func countsAsCallApp(_ id: String) -> Bool {
        trigger == .anyMicrophone || Self.callApps.contains(id) || extraCallApps?[id] != nil
    }

    /// Apps counted by `.callApps`. Browsers are not here: they use the microphone for many other things,
    /// so they only count if the user adds them.
    static let callApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram", "com.skype.skype", "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp",
        "org.whispersystems.signal-desktop",
    ]
}

/// Decides whether a call is still going on. Some apps release the microphone when you mute yourself,
/// so a known call app that is still playing stays in its call for a while.
struct CallTracker {
    static let grace: TimeInterval = 2     // ignore brief microphone gaps within a call
    static let sustain: TimeInterval = 180 // limit, for apps that keep their output open after a call

    /// The app kept in its call without using the microphone. It must not be lowered either.
    private(set) var sustained: String?
    private var last: (id: String, name: String, date: Date)?

    /// Returns the name of the app in the call, if there is one.
    mutating func update(active: (id: String, name: String)?, isPlaying: (String) -> Bool, now: Date) -> String? {
        sustained = nil
        if let active {
            last = (active.id, active.name, now)
            return active.name
        }
        guard let last else { return nil }
        let silence = now.timeIntervalSince(last.date)
        if DuckingOptions.callApps.contains(last.id), isPlaying(last.id), silence < Self.sustain {
            sustained = last.id
            return last.name
        }
        return silence < Self.grace ? last.name : nil // the periodic timer ends the grace period
    }
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
    @Published private(set) var callAppName: String?
    @Published private(set) var availableUpdate: UpdateChecker.Release?
    @Published var expandedApp: String?
    @Published private(set) var systemVolume: Double?
    @Published var listHeight: CGFloat = 0
    @Published var checksForUpdates = false {
        didSet {
            UserDefaults.standard.set(checksForUpdates, forKey: updatesKey)
            if checksForUpdates { checkForUpdates() } else { availableUpdate = nil }
        }
    }
    let levels = LevelStore()
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
        var secondOutputUID: String?
        var secondOutputName: String?
        // Optional so that settings saved by earlier versions still decode.
        var neverLower: Bool?
        var balance: Double?
        var equalizer: [Double]?
        var levelsVolume: Bool?
        var usesDefaultAudio: Bool {
            volume == 1 && !isMuted && outputUID == nil && secondOutputUID == nil && balance == nil
                && equalizer == nil && levelsVolume == nil
        }
        var eqGains: [Float] { (equalizer ?? Equalizer.flat).map(Float.init) }
        var isEmpty: Bool { usesDefaultAudio && neverLower != true }
        var gain: Float { isMuted ? 0 : Float(volume * volume) } // perceptual curve
    }

    private var settings: [String: Setting] = [:]
    private var groups: [String: Group] = [:]
    private var sessions: [String: TapSession] = [:]
    private var lastPlayed: [String: Date] = [:]
    private var lastChange: [String: Date] = [:]
    private var lowered = Set<String>()
    private var meters: [String: MeterTap] = [:]
    private var levelTimer: Timer?
    private var updateTimer: Timer?
    private var isWindowOpen = false
    private var isPreview = false
    private var volumeDevice: AudioObjectID?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var callTracker = CallTracker()
    private var failedOutputs: [String: [String]] = [:] // tried and refused: not retried until they change
    /// Diagnostics only: behaves as if this app had the microphone open.
    var simulatedCallApp: String? { didSet { reconcile() } }
    private var identities: [pid_t: AppIdentity] = [:]
    private(set) var defaultOutputUID: String?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var deviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var timer: Timer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let logger = Logger(subsystem: "io.github.jpdominguez.volumist", category: "engine")
    private let settingsKey = "volumes"
    private let duckingKey = "ducking"
    private let updatesKey = "checksForUpdates"

    /// Sample state for rendering the UI, with no audio side effects.
    init(preview apps: [AudioApp], output: String, call: String?, expanded: String?, previewLevels: [String: Float],
         lowersInCalls: Bool = true) {
        self.apps = apps
        outputName = output
        callAppName = call
        isPreview = true
        // Through the wrapper: assigning `ducking` would save it and reconcile against real audio.
        _ducking = Published(initialValue: DuckingOptions(isEnabled: lowersInCalls))
        _launchAtLogin = Published(initialValue: false)
        _expandedApp = Published(initialValue: expanded)
        _systemVolume = Published(initialValue: 0.6)
        _devices = Published(initialValue: ["Headphones", "External Speakers", "Display Audio"].map {
            OutputDevice(id: $0, object: 0, name: $0)
        })
        levels.levels = previewLevels
        permission = .granted
    }

    func setPreview(permission: AudioPermission.State) {
        guard isPreview else { return }
        self.permission = permission
    }

    func setPreview(apps: [AudioApp], call: String?, expanded: String?) {
        guard isPreview else { return }
        self.apps = apps
        callAppName = call
        expandedApp = expanded
    }

    /// Diagnostics: the apps holding the microphone right now, whether or not they would trigger lowering.
    var liveMicrophoneApps: [String] {
        groups.values.filter(\.usesMicrophone).map { "\($0.identity.name) (user app: \($0.identity.isUserApp))" }
    }

    init(requestsPermission: Bool = true) {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let saved = try? JSONDecoder().decode([String: Setting].self, from: data) {
            settings = saved
        }
        if let data = UserDefaults.standard.data(forKey: duckingKey),
           let saved = try? JSONDecoder().decode(DuckingOptions.self, from: data) {
            _ducking = Published(initialValue: saved)
        }
        _checksForUpdates = Published(initialValue: UserDefaults.standard.bool(forKey: updatesKey))
        if checksForUpdates { checkForUpdates() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.checksForUpdates == true { self?.checkForUpdates() } }
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
        if requestsPermission, permission != .granted { requestPermission() }
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
        let processes = sessions[id]?.processes.count ?? 0
        logger.notice("""
            \(id, privacy: .public) muted=\(self.settings[id]?.isMuted == true) tap=\(self.sessions[id] != nil) \
            processes=\(processes) permission=\(String(describing: self.permission), privacy: .public)
            """)
    }

    /// A nil `uid` returns the app to the system output.
    func setOutput(_ uid: String?, name: String? = nil, for id: String) {
        change(id) { $0.outputUID = uid; $0.outputName = name }
    }

    /// A nil `uid` plays on a single output again.
    func setSecondOutput(_ uid: String?, name: String? = nil, for id: String) {
        change(id) { $0.secondOutputUID = uid; $0.secondOutputName = name }
    }

    /// What can be added as a call app: open apps, plus those already added.
    func callAppCandidates() -> [(id: String, name: String)] {
        var found = ducking.extraCallApps ?? [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  !DuckingOptions.callApps.contains(id) else { continue }
            found[id] = app.localizedName ?? id
        }
        return found.map { (id: $0.key, name: $0.value) }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func toggleCallApp(_ id: String, name: String) {
        var apps = ducking.extraCallApps ?? [:]
        apps[id] = apps[id] == nil ? name : nil
        ducking.extraCallApps = apps.isEmpty ? nil : apps
    }

    func setBalance(_ balance: Double, for id: String) {
        change(id) { $0.balance = balance == 0 ? nil : balance }
    }

    func setEqualizer(_ gains: [Double], for id: String) {
        change(id) { $0.equalizer = gains == Equalizer.flat ? nil : gains }
    }

    func reset(_ id: String) {
        change(id) { $0 = Setting() }
    }

    func setLevelsVolume(_ enabled: Bool, for id: String) {
        change(id) { $0.levelsVolume = enabled ? true : nil }
    }

    func setSystemVolume(_ volume: Double) {
        guard let volumeDevice else { return }
        writeSystemVolume(volume, device: volumeDevice)
        systemVolume = volume
    }

    func setBand(_ band: Int, gain: Double, for id: String) {
        var gains = settings[id]?.equalizer ?? Equalizer.flat
        gains[band] = gain
        setEqualizer(gains, for: id)
    }

    /// Meters only run while someone can see them.
    func setWindowOpen(_ open: Bool) {
        guard open != isWindowOpen else { return }
        isWindowOpen = open
        levelTimer?.invalidate()
        levelTimer = nil
        if open {
            levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLevels() }
            }
        } else {
            levels.levels = [:]
        }
        reconcile()
    }

    func checkForUpdates() {
        Task { [weak self] in
            guard let release = try? await UpdateChecker.latestRelease() else { return }
            let isNewer = UpdateChecker.isNewer(release.version, than: UpdateChecker.currentVersion)
            self?.availableUpdate = isNewer ? release : nil
        }
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
        failedOutputs[id] = nil
        lastChange[id] = Date()
        save()
        sessions[id]?.setGain(gain(for: setting, lowered: lowered.contains(id)))
        sessions[id]?.setBalance(Float(setting.balance ?? 0))
        sessions[id]?.setEqualizer(setting.eqGains)
        sessions[id]?.setLeveler(setting.levelsVolume == true)
        reconcile()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    /// The single place where actual state is compared with desired state. Idempotent.
    private func reconcile() {
        guard !isPreview else { return }
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
                logger.error("\(failure ?? "", privacy: .public)")
            }
        }
        lastError = failure
        reconcileMeters()
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
            meters[id] = nil // an app shouldn't have an unmuted tap alongside its muted one
            session = try TapSession(processes: group.processes, gain: setting.gain,
                                     balance: Float(setting.balance ?? 0), equalizer: setting.eqGains,
                                     leveler: setting.levelsVolume == true)
            sessions[id] = session
        }

        let gain = gain(for: setting, lowered: lower)
        if lower != lowered.contains(id) {
            session.setGain(gain, fade: true)
            if lower { lowered.insert(id) } else { lowered.remove(id) }
        }

        // A tap only mutes once it has run, so I/O also runs for muted apps and at least once for
        // idle ones. A tap that was created but never read lets the app's audio through.
        let recentlyPlaying = now.timeIntervalSince(lastPlayed[id] ?? .distantPast) < Self.ioGrace
        let outputs = targetOutputs(for: setting)
        if recentlyPlaying || !session.hasStarted, !outputs.isEmpty {
            try start(session, on: outputs, for: id)
        } else {
            session.stop()
        }
    }

    /// A pair macOS can't combine must not leave the app silent, or be retried on every pass.
    private func start(_ session: TapSession, on outputs: [String], for id: String) throws {
        guard outputs.count > 1, failedOutputs[id] != outputs else { return try session.start(outputs: Array(outputs.prefix(1))) }
        do {
            try session.start(outputs: outputs)
        } catch {
            logger.error("\(id, privacy: .public): two outputs failed: \(String(describing: error), privacy: .public)")
            failedOutputs[id] = outputs
            try session.start(outputs: Array(outputs.prefix(1)))
        }
    }

    /// Apps with a session report their level through it, so only the others need a meter.
    private func reconcileMeters() {
        var wanted = [String: [AudioObjectID]]()
        if isWindowOpen, permission == .granted {
            for (id, group) in groups where group.isPlaying && sessions[id] == nil { wanted[id] = group.processes }
        }
        for (id, meter) in meters where wanted[id] != meter.processes || meter.outputUID != defaultOutputUID {
            meters[id] = nil
        }
        guard let defaultOutputUID else { return }
        for (id, processes) in wanted where meters[id] == nil {
            meters[id] = try? MeterTap(processes: processes, outputUID: defaultOutputUID)
        }
    }

    private func refreshLevels() {
        guard !isPreview else { return }
        var fresh = [String: Float]()
        for app in apps {
            let peak = sessions[app.id]?.takePeak() ?? meters[app.id]?.take().peak ?? 0
            fresh[app.id] = max(peak, (levels.levels[app.id] ?? 0) * 0.8) // falls smoothly
        }
        levels.levels = fresh
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
        id == simulatedCallApp || id == callTracker.sustained || isUsingMicrophoneForCall(id, group)
    }

    private func isUsingMicrophoneForCall(_ id: String, _ group: Group) -> Bool {
        group.usesMicrophone && group.identity.isUserApp && ducking.countsAsCallApp(id)
    }

    private func refreshCall(now: Date) {
        guard ducking.isEnabled else {
            callTracker = CallTracker()
            if callAppName != nil { callAppName = nil }
            return
        }
        var active = simulatedCallApp.map { (id: $0, name: $0) }
        if active == nil {
            active = groups.filter { isUsingMicrophoneForCall($0.key, $0.value) }
                .map { (id: $0.key, name: $0.value.identity.name) }
                .min { $0.name < $1.name }
        }
        let name = callTracker.update(active: active, isPlaying: { groups[$0]?.isPlaying == true }, now: now)
        if name != callAppName { callAppName = name }
    }

    /// If the chosen output is disconnected the system one is used, and the choice is kept:
    /// the app returns to it by itself on reconnection.
    private func targetOutput(for setting: Setting) -> String? {
        if let uid = setting.outputUID, devices.contains(where: { $0.id == uid }) { return uid }
        return defaultOutputUID
    }

    /// The second output is skipped while it is disconnected, or if it is also the first.
    private func targetOutputs(for setting: Setting) -> [String] {
        guard let first = targetOutput(for: setting) else { return [] }
        guard let second = setting.secondOutputUID, second != first,
              devices.contains(where: { $0.id == second }) else { return [first] }
        return [first, second]
    }

    private func refreshDevices() {
        let fresh = outputDevices()
        if fresh != devices { devices = fresh }
        let system = defaultOutputDevice()
        defaultOutputUID = system.flatMap { readString($0, kAudioDevicePropertyDeviceUID) }
        let name = system.flatMap { readString($0, kAudioObjectPropertyName) } ?? ""
        if name != outputName { outputName = name }
        watchSystemVolume(on: system)

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
                    self?.sessions.values.filter { $0.outputs.contains(uid) }.forEach { $0.stop() }
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

    /// The volume also changes from the keyboard, so the slider has to follow the device.
    private func watchSystemVolume(on device: AudioObjectID?) {
        if device != volumeDevice {
            if let old = volumeDevice, let listener = volumeListener {
                var addr = systemVolumeAddress
                AudioObjectRemovePropertyListenerBlock(old, &addr, .main, listener)
            }
            volumeDevice = device
            volumeListener = nil
            if let device {
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        guard let self, let device = self.volumeDevice else { return }
                        self.systemVolume = readSystemVolume(device)
                    }
                }
                var addr = systemVolumeAddress
                if AudioObjectAddPropertyListenerBlock(device, &addr, .main, listener) == noErr {
                    volumeListener = listener
                }
            }
        }
        let volume = device.flatMap(readSystemVolume)
        if volume != systemVolume { systemVolume = volume }
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
            let outputs = targetOutputs(for: setting)
            let targets = devices.filter { outputs.contains($0.id) }
            return AudioApp(id: id, name: group.identity.name, icon: group.identity.icon,
                            isPlaying: group.isPlaying, volume: setting.volume, isMuted: setting.isMuted,
                            outputUID: setting.outputUID, outputName: setting.outputName,
                            outputMissing: setting.outputUID.map { uid in !devices.contains { $0.id == uid } } ?? false,
                            secondOutputUID: setting.secondOutputUID, secondOutputName: setting.secondOutputName,
                            secondOutputMissing: setting.secondOutputUID.map { uid in !devices.contains { $0.id == uid } } ?? false,
                            secondOutputFailed: failedOutputs[id] == outputs && outputs.count > 1,
                            isMono: !targets.isEmpty && targets.allSatisfy { $0.channels == 1 },
                            mayEcho: targets.count > 1 && targets.contains(where: \.isBluetooth),
                            neverLower: setting.neverLower == true, isLowered: lowered.contains(id),
                            balance: setting.balance ?? 0, equalizer: setting.equalizer ?? Equalizer.flat,
                            levelsVolume: setting.levelsVolume == true)
        }
        // Alphabetical only: if rows moved when an app started or stopped playing, they could
        // slip out from under the pointer in the middle of a click.
        let sorted = visible.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        if !sorted.elementsEqual(apps, by: { $0.id == $1.id && $0.isPlaying == $1.isPlaying
            && $0.volume == $1.volume && $0.isMuted == $1.isMuted
            && $0.outputUID == $1.outputUID && $0.outputMissing == $1.outputMissing
            && $0.secondOutputUID == $1.secondOutputUID && $0.secondOutputMissing == $1.secondOutputMissing
            && $0.secondOutputFailed == $1.secondOutputFailed && $0.isMono == $1.isMono && $0.mayEcho == $1.mayEcho
            && $0.neverLower == $1.neverLower && $0.isLowered == $1.isLowered
            && $0.balance == $1.balance && $0.equalizer == $1.equalizer
            && $0.levelsVolume == $1.levelsVolume }) {
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
