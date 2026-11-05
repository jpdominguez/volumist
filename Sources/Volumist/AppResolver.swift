import AppKit
import Darwin

struct AppIdentity {
    let key: String
    let name: String
    let icon: NSImage?
    /// True for apps the user launched, and their helpers. False for system services such as Siri's
    /// listener, which hold the microphone without being in a call.
    var isUserApp = false
}

/// Groups helper processes (Chrome tabs, Safari's WebKit…) under the app that created them.
enum AppResolver {
    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    private static let responsible: Responsible? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: Responsible.self) }

    static func identity(pid: pid_t, bundleID: String?) -> AppIdentity {
        for candidate in [responsible?(pid), pid].compactMap({ $0 }) where candidate > 0 {
            if let app = NSRunningApplication(processIdentifier: candidate),
               app.activationPolicy == .regular, let id = app.bundleIdentifier {
                return AppIdentity(key: id, name: app.localizedName ?? id, icon: app.icon, isUserApp: true)
            }
        }
        if let path = executablePath(pid), let range = path.range(of: ".app/") {
            let bundlePath = String(path[..<range.lowerBound]) + ".app"
            let bundle = Bundle(path: bundlePath)
            let name = (bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            return AppIdentity(key: bundle?.bundleIdentifier ?? bundlePath, name: name,
                               icon: NSWorkspace.shared.icon(forFile: bundlePath))
        }
        var name = executablePath(pid).map { ($0 as NSString).lastPathComponent } ?? bundleID ?? "Process \(pid)"
        if name == "systemsoundserverd" { name = "System Sounds" }
        return AppIdentity(key: bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? name, name: name, icon: nil)
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }
}
