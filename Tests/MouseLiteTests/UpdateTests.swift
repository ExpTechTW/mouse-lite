import CryptoKit
import XCTest
@testable import MouseLite

final class UpdateTests: XCTestCase {
    private func release(
        tag: String, name: String? = nil, code: Int?, prerelease: Bool, draft: Bool = false, assets: [Release.Asset]? = nil
    ) -> Release {
        let body = code.map { "Notes\n<!-- mouselite-build: \($0) -->" }
        return Release(
            tagName: tag, name: name, body: body, draft: draft, prerelease: prerelease,
            htmlURL: URL(string: "https://github.com/ExpTechTW/mouse-lite/releases/tag/\(tag)")!,
            assets: assets ?? [zip(label: name ?? tag)]
        )
    }

    private func zip(label: String) -> Release.Asset {
        Release.Asset(
            name: "MouseLite-\(label).zip", size: 1024, digest: "sha256:abc",
            downloadURL: URL(string: "https://github.com/ExpTechTW/mouse-lite/releases/download/\(label)/MouseLite-\(label).zip")!
        )
    }

    func testBuildInfoReadsTheKeysTheBuildWrites() {
        let info: [String: Any] = [
            "MouseLiteLabel": "26w43a",
            "CFBundleVersion": "126000042",
            "MouseLiteDate": "26-10-24",
            "MouseLitePrerelease": true,
            "MouseLiteRepository": "ExpTechTW/mouse-lite",
        ]
        let build = BuildInfo(info: info)
        XCTAssertEqual(build.label, "26w43a")
        XCTAssertEqual(build.code, 126_000_042)
        XCTAssertEqual(build.date, "26-10-24")
        XCTAssertTrue(build.isPrerelease)
        XCTAssertEqual(build.repository, "ExpTechTW/mouse-lite")
    }

    func testBuildInfoWithoutKeysIsADevBuild() {
        let build = BuildInfo(info: ["CFBundleVersion": "12"])
        XCTAssertEqual(build.label, "dev")
        XCTAssertEqual(build.code, 0)
        XCTAssertNil(build.repository)
        XCTAssertTrue(build.isPrerelease)
    }

    func testBuildInfoRejectsAReplacementLookingRepository() {
        let build = BuildInfo(info: [
            "MouseLiteLabel": "26w43a",
            "CFBundleVersion": "1",
            "MouseLiteRepository": "https://evil.example/mouse-lite",
        ])
        XCTAssertNil(build.repository)
    }

    func testReleaseReadsBuildCodeFromNotes() {
        XCTAssertEqual(release(tag: "v26.1", code: 126_000_042, prerelease: false).code, 126_000_042)
        XCTAssertNil(release(tag: "v26.1", code: nil, prerelease: false).code)
    }

    func testReleaseUsesTitleThenTagAsLabel() {
        XCTAssertEqual(release(tag: "26w43a", name: "26w43a", code: 1, prerelease: true).label, "26w43a")
        XCTAssertEqual(release(tag: "v26.1", code: 1, prerelease: false).label, "v26.1")
    }

    func testArchiveIsTheZippedAppNotAnyOtherAsset() {
        let release = release(
            tag: "v26.1", code: 1, prerelease: false,
            assets: [
                Release.Asset(name: "MouseLite-26.1.dmg", size: 1, digest: nil, downloadURL: URL(string: "https://example.com/a.dmg")!),
                zip(label: "26.1"),
            ]
        )
        XCTAssertEqual(release.archive?.name, "MouseLite-26.1.zip")
    }

    func testReleaseChannelIgnoresSnapshots() {
        let releases = [
            release(tag: "v26.1", code: 100, prerelease: false),
            release(tag: "26w43a", code: 120, prerelease: true),
        ]
        XCTAssertEqual(UpdateCheck.update(in: releases, channel: .release, current: 50)?.tagName, "v26.1")
    }

    func testPrereleaseChannelAlsoTakesANewerRelease() {
        let releases = [
            release(tag: "v0.1.0", code: 200, prerelease: false),
            release(tag: "26w43a", code: 120, prerelease: true),
            release(tag: "26w43b", code: 130, prerelease: true),
        ]
        // The RC/snapshot channel hears finals too, but only when their code is the newest.
        XCTAssertEqual(UpdateCheck.update(in: releases, channel: .prerelease, current: 50)?.tagName, "v0.1.0")
    }

    func testPrereleaseChannelDoesNotDowngradeToAnOlderRelease() {
        let releases = [
            release(tag: "v0.1.0", code: 100, prerelease: false),
            release(tag: "26w43a", code: 120, prerelease: true),
        ]
        XCTAssertEqual(UpdateCheck.update(in: releases, channel: .prerelease, current: 110)?.tagName, "26w43a")
    }

    func testNewestBuildWinsNotNewestRelease() {
        let releases = [
            release(tag: "26w44a", code: 110, prerelease: true),
            release(tag: "26w43a", code: 130, prerelease: true),
        ]
        XCTAssertEqual(UpdateCheck.update(in: releases, channel: .prerelease, current: 0)?.tagName, "26w43a")
    }

    func testNothingNewerMeansNoUpdate() {
        let releases = [release(tag: "v26.1", code: 100, prerelease: false)]
        XCTAssertNil(UpdateCheck.update(in: releases, channel: .release, current: 100))
        XCTAssertNil(UpdateCheck.update(in: releases, channel: .release, current: 120))
    }

    func testDraftsAndUnusableReleasesAreSkipped() {
        let releases = [
            release(tag: "v26.3", code: 300, prerelease: false, draft: true),
            release(tag: "v26.2", code: 200, prerelease: false, assets: []),
            release(tag: "v26.1", code: nil, prerelease: false),
        ]
        XCTAssertNil(UpdateCheck.update(in: releases, channel: .release, current: 0))
    }

    func testDigestMatchesAndMismatchFails() throws {
        let data = Data("MouseLite update".utf8)
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MouseLite-\(UUID().uuidString).zip")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let good = Release.Asset(name: "MouseLite-26.1.zip", size: data.count, digest: "sha256:\(hex)",
                                 downloadURL: URL(string: "https://example.com/a.zip")!)
        XCTAssertNoThrow(try UpdateInstaller.checkDigest(of: file, against: good))

        let bad = Release.Asset(name: good.name, size: data.count, digest: "sha256:deadbeef",
                                downloadURL: good.downloadURL)
        XCTAssertThrowsError(try UpdateInstaller.checkDigest(of: file, against: bad)) { error in
            XCTAssertEqual(error as? UpdateFailure, .damaged)
        }
    }
}
