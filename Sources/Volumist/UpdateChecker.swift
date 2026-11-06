import Foundation

/// The optional update check. It asks GitHub for the latest release and sends nothing else.
enum UpdateChecker {
    struct Release: Decodable, Equatable {
        let tagName: String
        let htmlUrl: URL
        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    }

    enum Outcome: Equatable {
        case upToDate, available(Release), failed
    }

    private static let endpoint = URL(string: "https://api.github.com/repos/jpdominguez/volumist/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func latestRelease() async throws -> Release {
        let (data, _) = try await URLSession.shared.data(from: endpoint)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Release.self, from: data)
    }

    static func check() async -> Outcome {
        guard let release = try? await latestRelease() else { return .failed }
        return isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
    }

    static func isNewer(_ version: String, than current: String) -> Bool {
        version.compare(current, options: .numeric) == .orderedDescending
    }
}
