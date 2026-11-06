import Foundation

/// The optional update check. It asks GitHub for the latest release and sends nothing else.
/// It reads where the public page redirects to, because the API allows only 60 requests an hour
/// for each IP address, which a university or office network can use up by itself.
enum UpdateChecker {
    struct Release: Equatable {
        let tagName: String
        let htmlUrl: URL
        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    }

    enum Outcome: Equatable {
        case upToDate, available(Release), failed
    }

    private static let latestPage = URL(string: "https://github.com/jpdominguez/volumist/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func latestRelease() async throws -> Release {
        var request = URLRequest(url: latestPage)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, let url = response.url,
              let release = release(from: url) else { throw URLError(.badServerResponse) }
        return release
    }

    /// `.../releases/tag/v1.3.1` gives that version. With no releases, GitHub stays on `.../releases`.
    static func release(from url: URL) -> Release? {
        let path = url.pathComponents
        guard path.count >= 2, path[path.count - 2] == "tag" else { return nil }
        return Release(tagName: url.lastPathComponent, htmlUrl: url)
    }

    static func check() async -> Outcome {
        guard let release = try? await latestRelease() else { return .failed }
        return isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
    }

    static func isNewer(_ version: String, than current: String) -> Bool {
        version.compare(current, options: .numeric) == .orderedDescending
    }
}
