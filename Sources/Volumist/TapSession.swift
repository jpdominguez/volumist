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

    init(processes: [AudioObjectID], gain: Float) throws {
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
    }

    deinit {
        stop()
        AudioHardwareDestroyProcessTap(tapID)
        vm_destroy(mixer)
    }

    func setGain(_ gain: Float) { vm_set_gain(mixer, gain) }

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
