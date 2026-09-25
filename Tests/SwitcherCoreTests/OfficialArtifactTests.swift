import XCTest
@testable import SwitcherCore

final class OfficialArtifactTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PairbarArtifact-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func fixture(_ name: String) throws -> URL {
        let app = root.appendingPathComponent(name + ".app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("program".utf8).write(to: app.appendingPathComponent("Contents/MacOS"))
        try Data("archive".utf8).write(to: resources.appendingPathComponent("app.asar"))
        try FileManager.default.createSymbolicLink(atPath: resources.appendingPathComponent("link").path,
                                                    withDestinationPath: "app.asar")
        return app
    }

    private func pin(_ app: URL) throws -> Compatibility.ArtifactPin {
        let result = try CanonicalBundleDigest.calculate(app)
        return .init(version: "1", build: "2", sha256: result.sha256, entries: result.entries)
    }

    private func decide(_ app: URL, _ pin: Compatibility.ArtifactPin, signatureValid: Bool = false,
                        version: String = "1", build: String = "2", team: String = Compatibility.expectedTeamIdentifier,
                        identifier: String = Compatibility.bundleIdentifier, arm64: Bool = true) throws -> OfficialVerification {
        try Compatibility.decideOfficialVerification(signatureValid: signatureValid, version: version, build: build,
            team: team, identifier: identifier, arm64: arm64, pin: pin) {
            try CanonicalBundleDigest.calculate(app)
        }
    }

    func testValidSignatureDoesNotConsultFallback() throws {
        let pin = Compatibility.ArtifactPin(version: "1", build: "2", sha256: "no", entries: 0)
        XCTAssertEqual(try Compatibility.decideOfficialVerification(signatureValid: true, version: nil, build: nil,
            team: nil, identifier: nil, arm64: false, pin: pin, digest: { XCTFail("fallback consulted"); throw CanonicalBundleDigest.Failure.unsafeTree }), .codeSigning)
    }

    func testExactPinAndByteMutation() throws {
        let app = try fixture("Original"), expected = try pin(app)
        XCTAssertEqual(try decide(app, expected), .reviewedArtifact)
        try Data("progrAm".utf8).write(to: app.appendingPathComponent("Contents/MacOS"))
        XCTAssertThrowsError(try decide(app, expected))
    }

    func testExtraAndDeletedFiles() throws {
        let app = try fixture("Original"), expected = try pin(app)
        let extra = app.appendingPathComponent("Contents/Resources/extra")
        try Data([1]).write(to: extra)
        XCTAssertThrowsError(try decide(app, expected))
        try FileManager.default.removeItem(at: extra)
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Resources/app.asar"))
        XCTAssertThrowsError(try decide(app, expected))
    }

    func testChangedSymlink() throws {
        let app = try fixture("Original"), expected = try pin(app)
        let link = app.appendingPathComponent("Contents/Resources/link")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../MacOS")
        XCTAssertThrowsError(try decide(app, expected))
    }

    func testMetadataAndUnknownBuildFailClosed() throws {
        let app = try fixture("Original"), expected = try pin(app)
        XCTAssertThrowsError(try decide(app, expected, version: "9")) {
            XCTAssertEqual($0.localizedDescription, "Esta versión de ChatGPT necesita una actualización/revisión de Pairbar antes de usar perfiles adicionales.")
        }
        XCTAssertThrowsError(try decide(app, expected, build: "9"))
        XCTAssertThrowsError(try decide(app, expected, team: "WRONG")) {
            XCTAssertEqual($0.localizedDescription, "Pairbar no puede verificar esta app.")
        }
        XCTAssertThrowsError(try decide(app, expected, identifier: "wrong"))
        XCTAssertThrowsError(try decide(app, expected, arm64: false))
        let unknown = Compatibility.ArtifactPin(version: "9", build: "9", sha256: expected.sha256, entries: expected.entries)
        XCTAssertThrowsError(try decide(app, unknown))
    }

    func testCopiesIgnoreTimesAndXattrs() throws {
        let first = try fixture("First")
        let second = root.appendingPathComponent("Second.app")
        try FileManager.default.copyItem(at: first, to: second)
        let changed = second.appendingPathComponent("Contents/MacOS")
        let old = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: changed.path)
        let value = Data("quarantine-like metadata".utf8)
        let xattrResult = value.withUnsafeBytes { setxattr(changed.path, "com.pairbar.test", $0.baseAddress, value.count, 0, 0) }
        XCTAssertEqual(xattrResult, 0)
        XCTAssertEqual(try CanonicalBundleDigest.calculate(first), try CanonicalBundleDigest.calculate(second))
    }

    func testUnsafeLinksFailClosed() throws {
        let app = try fixture("Original")
        let link = app.appendingPathComponent("Contents/Resources/link")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/passwd")
        XCTAssertThrowsError(try CanonicalBundleDigest.calculate(app))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../../../etc/passwd")
        XCTAssertThrowsError(try CanonicalBundleDigest.calculate(app))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "link")
        XCTAssertThrowsError(try CanonicalBundleDigest.calculate(app))
    }

    func testUnexpectedFilesystemTypeFailsClosed() throws {
        let app = try fixture("Original")
        let pipe = app.appendingPathComponent("Contents/Resources/pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertThrowsError(try CanonicalBundleDigest.calculate(app))
    }
}
