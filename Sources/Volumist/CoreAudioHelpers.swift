import AudioToolbox
import CoreAudio
import Foundation

struct AudioError: Error, CustomStringConvertible {
    let description: String
    init(_ what: String, _ status: OSStatus) { description = "\(what) (OSStatus \(status))" }
}

func address(_ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func readValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as initial: T) -> T? {
    var addr = address(selector)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
    }
    return status == noErr ? value : nil
}

func readObjectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var addr = address(selector, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list) == noErr else { return [] }
    return list
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>?
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
    }
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func defaultOutputDevice() -> AudioObjectID? {
    let id = readValue(AudioObjectID(kAudioObjectSystemObject),
                       kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID(0))
    return id == 0 ? nil : id
}

/// The same volume as the Mac's keyboard keys. Nil for outputs without one, such as many HDMI monitors.
func readSystemVolume(_ device: AudioObjectID) -> Double? {
    var addr = systemVolumeAddress
    guard AudioObjectHasProperty(device, &addr) else { return nil }
    var settable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return nil }
    var volume = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &volume) == noErr else { return nil }
    return Double(volume)
}

func writeSystemVolume(_ volume: Double, device: AudioObjectID) {
    var addr = systemVolumeAddress
    var value = Float32(volume)
    AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
}

func readSystemMute(_ device: AudioObjectID) -> Bool {
    var addr = systemMuteAddress
    guard AudioObjectHasProperty(device, &addr) else { return false }
    var muted = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted) == noErr && muted != 0
}

var systemMuteAddress: AudioObjectPropertyAddress {
    address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
}

var systemVolumeAddress: AudioObjectPropertyAddress {
    address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
}

struct OutputDevice: Identifiable, Equatable {
    let id: String // Unlike the AudioObjectID, the UID survives reconnections and restarts
    let object: AudioObjectID
    let name: String
    var channels = 2
    var isBluetooth = false
}

func outputChannelCount(_ device: AudioObjectID) -> Int {
    readObjectList(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).reduce(0) { total, stream in
        let format = readValue(stream, kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription())
        return total + Int(format?.mChannelsPerFrame ?? 0)
    }
}

func outputDevices() -> [OutputDevice] {
    readObjectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { object in
        guard !readObjectList(object, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).isEmpty,
              let uid = readString(object, kAudioDevicePropertyDeviceUID),
              let name = readString(object, kAudioObjectPropertyName) else { return nil }
        // Hardware only: virtual devices and aggregates (including Volumist's private ones)
        // are not outputs you can hear by themselves.
        let transport = readValue(object, kAudioDevicePropertyTransportType, as: UInt32(0))
        guard transport != kAudioDeviceTransportTypeVirtual,
              transport != kAudioDeviceTransportTypeAggregate else { return nil }
        return OutputDevice(id: uid, object: object, name: name, channels: outputChannelCount(object),
                            isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                                || transport == kAudioDeviceTransportTypeBluetoothLE)
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}
