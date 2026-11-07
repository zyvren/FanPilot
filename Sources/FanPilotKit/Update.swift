import Foundation

/// The latest GitHub release, as far as the in-app updater cares (pure parsing, no network).
public struct ReleaseInfo: Equatable, Sendable {
    public var version: String
    public var notes: String
    public var pageURL: URL?
    public var dmgURL: URL
    public var checksumURL: URL

    /// Downloads are only accepted from this repository's release files.
    public static let downloadPrefix = "https://github.com/zyvren/FanPilot/releases/download/"
    public static let latestAPI = URL(string: "https://api.github.com/repos/zyvren/FanPilot/releases/latest")!

    public enum ParseError: Error, Equatable {
        case malformed
        case missingAsset(String)
    }

    public init(version: String, notes: String, pageURL: URL?, dmgURL: URL, checksumURL: URL) {
        self.version = version
        self.notes = notes
        self.pageURL = pageURL
        self.dmgURL = dmgURL
        self.checksumURL = checksumURL
    }

    /// Parses the body of `GET /repos/{owner}/{repo}/releases/latest`. The release must carry
    /// `FanPilot-<tag>.dmg` and `FanPilot-<tag>.dmg.sha256`, both served from `downloadPrefix`.
    public static func parse(_ data: Data) throws -> ReleaseInfo {
        struct Asset: Decodable { var name: String; var browser_download_url: String }
        struct Release: Decodable { var tag_name: String; var body: String?; var html_url: String?; var assets: [Asset] }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else { throw ParseError.malformed }

        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard AppVersion.components(version) != nil else { throw ParseError.malformed }

        func asset(_ name: String) throws -> URL {
            guard let found = release.assets.first(where: { $0.name == name }),
                  found.browser_download_url.hasPrefix(downloadPrefix),
                  let url = URL(string: found.browser_download_url) else { throw ParseError.missingAsset(name) }
            return url
        }
        let dmg = "FanPilot-\(version).dmg"
        return ReleaseInfo(version: version, notes: release.body ?? "",
                           pageURL: release.html_url.flatMap(URL.init(string:)),
                           dmgURL: try asset(dmg), checksumURL: try asset(dmg + ".sha256"))
    }

    /// The hex digest from a `shasum -a 256` line ("<64 hex>  <file>"), lowercased; nil if absent.
    public static func checksum(fromShasumOutput text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first else { return nil }
        let hex = first.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }
}

/// Dotted numeric versions ("1.0", "1.1", "1.10.2").
public enum AppVersion {
    public static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.map { $0! }
    }

    /// True when `candidate` is strictly newer than `current` ("1.10" > "1.9", "1.1" == "1.1.0").
    /// An unparsable version is never newer.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard var a = components(candidate), var b = components(current) else { return false }
        let count = max(a.count, b.count)
        a += Array(repeating: 0, count: count - a.count)
        b += Array(repeating: 0, count: count - b.count)
        return a.lexicographicallyPrecedes(b) == false && a != b
    }
}
