import XCTest
@testable import FanPilotKit

final class UpdateTests: XCTestCase {
    private func json(tag: String = "1.1", assets: [(String, String)]? = nil) -> Data {
        let base = ReleaseInfo.downloadPrefix + tag + "/"
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let list = assets ?? [("FanPilot-\(v).dmg", base + "FanPilot-\(v).dmg"),
                              ("FanPilot-\(v).dmg.sha256", base + "FanPilot-\(v).dmg.sha256")]
        let items = list.map { "{\"name\":\"\($0.0)\",\"browser_download_url\":\"\($0.1)\"}" }.joined(separator: ",")
        return Data("{\"tag_name\":\"\(tag)\",\"body\":\"Notes\",\"html_url\":\"https://github.com/zyvren/FanPilot/releases/tag/\(tag)\",\"assets\":[\(items)]}".utf8)
    }

    func testParsesTheLatestRelease() throws {
        let info = try ReleaseInfo.parse(json())
        XCTAssertEqual(info.version, "1.1")
        XCTAssertEqual(info.notes, "Notes")
        XCTAssertEqual(info.dmgURL.lastPathComponent, "FanPilot-1.1.dmg")
        XCTAssertEqual(info.checksumURL.lastPathComponent, "FanPilot-1.1.dmg.sha256")
        XCTAssertEqual(try ReleaseInfo.parse(json(tag: "v1.2")).version, "1.2")
    }

    func testRejectsMissingOrForeignAssets() {
        XCTAssertThrowsError(try ReleaseInfo.parse(json(assets: [("FanPilot-1.1.dmg", ReleaseInfo.downloadPrefix + "1.1/FanPilot-1.1.dmg")])))
        let foreign = [("FanPilot-1.1.dmg", "https://evil.example/FanPilot-1.1.dmg"),
                       ("FanPilot-1.1.dmg.sha256", ReleaseInfo.downloadPrefix + "1.1/FanPilot-1.1.dmg.sha256")]
        XCTAssertThrowsError(try ReleaseInfo.parse(json(assets: foreign)))
        XCTAssertThrowsError(try ReleaseInfo.parse(json(tag: "latest")))
        XCTAssertThrowsError(try ReleaseInfo.parse(Data("not json".utf8)))
    }

    func testChecksumLine() {
        let hex = String(repeating: "aB", count: 32)
        XCTAssertEqual(ReleaseInfo.checksum(fromShasumOutput: "\(hex)  dist/FanPilot-1.1.dmg\n"), hex.lowercased())
        XCTAssertNil(ReleaseInfo.checksum(fromShasumOutput: "abc  file"))
        XCTAssertNil(ReleaseInfo.checksum(fromShasumOutput: ""))
    }

    func testVersionOrdering() {
        XCTAssertTrue(AppVersion.isNewer("1.1", than: "1.0"))
        XCTAssertTrue(AppVersion.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(AppVersion.isNewer("2.0", than: "1.99.9"))
        XCTAssertFalse(AppVersion.isNewer("1.1", than: "1.1.0"))
        XCTAssertFalse(AppVersion.isNewer("1.0", than: "1.1"))
        XCTAssertFalse(AppVersion.isNewer("1.2", than: "dev"))
        XCTAssertFalse(AppVersion.isNewer("1.x", than: "1.0"))
    }
}
