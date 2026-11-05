import CMixer
import CoreAudio
import Foundation

/// A tap on the processes of one app. While it exists the app is muted at system level;
/// while its I/O is also running, the app's audio plays again through Volumist with the chosen gain.
final class TapSession {
    private let description: CATapDescription
    private let tapID: AudioObjectID
    private let tapUID: String
    private let mixer: OpaquePointer
    private var aggregateID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?
    private(set) var processes: [AudioObjectID]

    /// The device it is playing through right now, or nil while the I/O is stopped.
    private(set) var outputUID: String?
    private(set) var hasStarted = false

    private var equalizer = [Float](repeating: 0, count: Int(VM_EQ_BANDS))
    private var sampleRate = 48_000.0
    private var levels = false

    init(processes: [AudioObjectID], gain: Float, balance: Float = 0, equalizer: [Float]? = nil,
         leveler: Bool = false) throws {
        self.processes = processes
        description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "Volumist"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .muted

        var id = AudioObjectID(0)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr else { throw AudioError("Could not create the tap", status) }
        tapID = id
        tapUID = description.uuid.uuidString
        mixer = vm_create(gain)
        setBalance(balance)
        if let equalizer { setEqualizer(equalizer) }
        setLeveler(leveler)
    }

    deinit {
        stop()
        AudioHardwareDestroyProcessTap(tapID)
        vm_destroy(mixer)
    }

    /// `fade` takes about a second, for automatic changes. Otherwise it takes ~10 ms at 48 kHz,
    /// fast enough to follow a slider without clicks.
    func setGain(_ gain: Float, fade: Bool = false) { vm_set_gain(mixer, gain, fade ? 0.00005 : 0.002) }

    func setBalance(_ balance: Float) { vm_set_balance(mixer, balance) }

    func setEqualizer(_ gains: [Float]) {
        equalizer = gains
        vm_set_eq(mixer, gains, sampleRate)
    }

    func setLeveler(_ enabled: Bool) {
        levels = enabled
        vm_set_leveler(mixer, enabled ? 1 : 0, sampleRate)
    }

    /// The peak level since the last call, as heard: after gain and limiting.
    func takePeak() -> Float { vm_take_peak(mixer) }

    /// Adds or removes processes without interrupting the audio (e.g. a new browser helper).
    func update(processes new: [AudioObjectID]) throws {
        guard new != processes else { return }
        description.processes = new
        var addr = address(kAudioTapPropertyDescription)
        var ref = Unmanaged.passUnretained(description).toOpaque()
        let status = AudioObjectSetPropertyData(tapID, &addr, 0, nil,
                                                UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &ref)
        guard status == noErr else { throw AudioError("Could not update the tap", status) }
        processes = new
    }

    func start(outputUID: String) throws {
        if self.outputUID == outputUID { return }
        stop()
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Volumist",
            kAudioAggregateDeviceUIDKey: "volumist.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var status = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID)
        guard status == noErr else { throw AudioError("Could not create the aggregate device", status) }

        // The filters are designed for one sample rate, and each output can have its own.
        sampleRate = readValue(aggregateID, kAudioDevicePropertyNominalSampleRate, as: Float64(0)) ?? sampleRate
        setEqualizer(equalizer)
        setLeveler(levels)

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcID(aggregateID, vm_ioproc, UnsafeMutableRawPointer(mixer), &proc)
        guard status == noErr, let proc else {
            stop()
            throw AudioError("Could not create the IOProc", status)
        }
        procID = proc
        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else {
            stop()
            throw AudioError("Could not start audio", status)
        }
        self.outputUID = outputUID
        hasStarted = true
    }

    func stop() {
        outputUID = nil
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
    }
}
