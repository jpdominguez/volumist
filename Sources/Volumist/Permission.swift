import Foundation

/// macOS has no public API to query the audio capture permission, so TCC is loaded dynamically.
/// Without the permission taps deliver silence, and since they also mute the original app it would
/// go silent: that is why the engine creates no tap until the permission is granted.
enum AudioPermission {
    enum State { case granted, denied, unknown }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var state: State {
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ done: @escaping (Bool) -> Void) {
        guard let symbol = dlsym(tcc, "TCCAccessRequest") else { return done(false) }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }
}
