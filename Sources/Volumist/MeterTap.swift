import CMixer
import CoreAudio
import Foundation

/// Reads the level of some processes without changing their audio: the tap is unmuted, nothing is
/// routed anywhere and the aggregate outputs silence.
final class MeterTap {
    let processes: [AudioObjectID]
    let outputUID: String
    private let tap: AudioObjectID
    private var aggregate = AudioObjectID(0)
    private var proc: AudioDeviceIOProcID?
    private let meter = vm_meter_create()

    init(processes: [AudioObjectID], outputUID: String) throws {
        self.processes = processes
        self.outputUID = outputUID
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "Volumist Meter"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var id = AudioObjectID(0)
        var status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr else {
            vm_meter_destroy(meter)
            throw AudioError("Could not create the meter tap", status)
        }
        tap = id

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Volumist Meter",
            kAudioAggregateDeviceUIDKey: "volumist-meter.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        status = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate)
        if status == noErr {
            status = AudioDeviceCreateIOProcID(aggregate, vm_meter_ioproc, UnsafeMutableRawPointer(meter), &proc)
        }
        if status == noErr { status = AudioDeviceStart(aggregate, proc) }
        guard status == noErr else {
            teardown()
            throw AudioError("Could not start the meter", status)
        }
    }

    deinit { teardown() }

    func take() -> VMMeterReading { vm_meter_take(meter) }

    private func teardown() {
        if let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
            self.proc = nil
        }
        if aggregate != 0 {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = 0
        }
        AudioHardwareDestroyProcessTap(tap)
        vm_meter_destroy(meter)
    }
}
