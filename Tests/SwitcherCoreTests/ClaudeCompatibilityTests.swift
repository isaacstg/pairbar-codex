import XCTest
import Foundation
@testable import SwitcherCore

final class ClaudeCompatibilityTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("ClaudeCompatibilityTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // The suite creates only synthetic packaged-code fixtures below the ignored work directory.
        if let scratch { try FileManager.default.removeItem(at: scratch) }
    }

    func testValidArchiveReadsEntrypointAndFindsOnlyPresentMarkers() throws {
        let source = """
        const user = 'CLAUDE_USER_DATA_DIR';
        const secure = 'CLAUDE_SECURESTORAGE_CONFIG_DIR';
        """
        let fixture = try makeArchive(main: "main.js", entrypoint: Data(source.utf8),
                                      additionalPayload: Data("irrelevant CLAUDE_CONFIG_DIR marker".utf8))
        let reader = try ClaudeASARReader(url: fixture, containing: scratch)

        XCTAssertEqual(try reader.entrypoint(), source)
        XCTAssertEqual(try reader.markersPresent(ClaudePackagedCodeReview.requiredMarkers),
                       ClaudePackagedCodeReview.requiredMarkers)
        XCTAssertNoThrow(try reader.verifyUnchanged())
    }

    func testMarkerSearchPreservesMatchesAcrossChunkBoundary() throws {
        let marker = "CLAUDE_SECURESTORAGE_CONFIG_DIR"
        // Build once to learn the small header size, then place the marker across a 1 MiB read boundary.
        var prefixCount = 1_048_000
        var fixture = try makeArchive(main: "main.js", entrypoint: Data((String(repeating: "x", count: prefixCount) + marker).utf8))
        for _ in 0..<3 {
            let bytes = try Data(contentsOf: fixture)
            let markerOffset = try XCTUnwrap(bytes.range(of: Data(marker.utf8))?.lowerBound)
            let desired = 1_048_576 - marker.utf8.count / 2
            prefixCount += desired - markerOffset
            fixture = try makeArchive(main: "main.js", entrypoint: Data((String(repeating: "x", count: prefixCount) + marker).utf8))
        }
        let bytes = try Data(contentsOf: fixture)
        let markerOffset = try XCTUnwrap(bytes.range(of: Data(marker.utf8))?.lowerBound)
        XCTAssertLessThan(markerOffset, 1_048_576)
        XCTAssertGreaterThan(markerOffset + marker.utf8.count, 1_048_576)

        let reader = try ClaudeASARReader(url: fixture, containing: scratch)
        XCTAssertEqual(try reader.markersPresent([marker]), [marker])
    }

    func testPackagedCodeReviewAlwaysReportsUnprovenIsolationAndMissingMarkers() {
        let findings = ClaudePackagedCodeReview.findings(entrypoint: "", archiveMarkers: [])

        XCTAssertTrue(findings.contains(.runtimeSeparationUnproven))
        XCTAssertTrue(findings.contains(.configurationAndAuthenticationMayBeShared))
        XCTAssertTrue(findings.contains(.oauthRoutingUnproven))
        XCTAssertTrue(findings.contains(.coworkIsolationUnproven))
        XCTAssertTrue(findings.contains(.userDataOverrideMarkerMissing))
        XCTAssertTrue(findings.contains(.configOverrideMarkerMissing))
        XCTAssertTrue(findings.contains(.secureStorageOverrideMarkerMissing))
    }

    func testPackagedCodeReviewDetectsEnvironmentDeletionAndPairingImpact() {
        let dot = ClaudePackagedCodeReview.findings(
            entrypoint: "delete process.env.CLAUDE_USER_DATA_DIR; localPairingDisabledReason",
            archiveMarkers: ClaudePackagedCodeReview.requiredMarkers
        )
        let bracket = ClaudePackagedCodeReview.findings(
            entrypoint: #"delete renamed.env["CLAUDE_USER_DATA_DIR"]"#,
            archiveMarkers: ClaudePackagedCodeReview.requiredMarkers
        )

        XCTAssertTrue(dot.contains(.userDataOverrideDeletedByEntrypoint))
        XCTAssertTrue(dot.contains(.localPairingAffectedByRelocation))
        XCTAssertTrue(bracket.contains(.userDataOverrideDeletedByEntrypoint))
        XCTAssertFalse(dot.contains(.userDataOverrideMarkerMissing))
        XCTAssertFalse(dot.contains(.configOverrideMarkerMissing))
        XCTAssertFalse(dot.contains(.secureStorageOverrideMarkerMissing))
    }

    func testIsolationPreflightCannotEnableManagedLaunches() {
        XCTAssertFalse(ClaudeIsolationPreflight.managedLaunchAllowed)
        XCTAssertEqual(ClaudeCompatibility.capabilities.map(\.status), ["unvalidated", "unvalidated", "unvalidated"])

        let reviewedKeys = ClaudeIsolationPreflight.findings(
            proposedArguments: [],
            proposedEnvironmentKeys: ClaudePackagedCodeReview.requiredMarkers.union(["CODEX_HOME"])
        )
        XCTAssertEqual(reviewedKeys, [.runtimeSeparationUnproven])

        let unsafeRecipe = ClaudeIsolationPreflight.findings(
            proposedArguments: ["--user-data-dir=/tmp/claude"],
            proposedEnvironmentKeys: ["CLAUDE_USER_DATA_DIR", "HOME"]
        )
        XCTAssertTrue(unsafeRecipe.contains(.runtimeSeparationUnproven))
        XCTAssertTrue(unsafeRecipe.contains(.prohibitedLaunchArguments))
        XCTAssertTrue(unsafeRecipe.contains(.unreviewedEnvironmentKeys))
    }

    func testEntrypointRejectsTraversalAbsolutePathsLinksAndUnpackedFiles() throws {
        for main in ["../escape.js", "/absolute.js", "dir//main.js", "dir\\main.js"] {
            let package = try JSONSerialization.data(withJSONObject: ["main": main], options: [.sortedKeys])
            let fixture = try makeArchive(package: ["main": main], files: [:], payload: package + Data("x".utf8))
            assertError(.entrypointUnavailable) {
                _ = try ClaudeASARReader(url: fixture, containing: self.scratch).entrypoint()
            }
        }

        for unsafeEntry in [
            ["offset": "0", "size": 1, "link": "elsewhere.js"] as [String: Any],
            ["offset": "0", "size": 1, "unpacked": true] as [String: Any]
        ] {
            let package = Data(#"{"main":"main.js"}"#.utf8)
            let fixture = try makeArchive(
                package: ["main": "main.js"],
                files: ["main.js": unsafeEntry],
                payload: package + Data("x".utf8)
            )
            assertError(.entrypointUnavailable) {
                _ = try ClaudeASARReader(url: fixture, containing: self.scratch).entrypoint()
            }
        }
    }

    func testEntrypointRejectsInvalidMetadataAndInvalidUTF8() throws {
        let package = Data(#"{"main":"main.js"}"#.utf8)
        let cases: [[String: Any]] = [
            ["offset": "-1", "size": 1],
            ["offset": "999999", "size": 1],
            ["offset": "0", "size": true],
            ["offset": "0", "size": 8_388_609],
            ["offset": "0", "size": 0],
            ["offset": "0", "size": 1, "files": [:]]
        ]
        for entry in cases {
            let fixture = try makeArchive(package: ["main": "main.js"], files: ["main.js": entry], payload: package + Data("x".utf8))
            assertError(.entrypointUnavailable) {
                _ = try ClaudeASARReader(url: fixture, containing: self.scratch).entrypoint()
            }
        }

        let invalidUTF8 = try makeArchive(main: "main.js", entrypoint: Data([0xff, 0xfe, 0xfd]))
        assertError(.entrypointUnavailable) {
            _ = try ClaudeASARReader(url: invalidUTF8, containing: self.scratch).entrypoint()
        }
    }

    func testMalformedArchiveHeadersAndJSONAreRejectedWithinBounds() throws {
        let empty = try write(Data(), named: "empty")
        assertError(.unsafeCodeAsset) {
            _ = try ClaudeASARReader(url: empty, containing: self.scratch)
        }
        for bytes in [Data(repeating: 0, count: 15), Data(repeating: 0, count: 16)] {
            let fixture = try write(bytes, named: "malformed")
            assertError(.malformedArchive) {
                _ = try ClaudeASARReader(url: fixture, containing: self.scratch)
            }
        }

        var invalidJSON = Data()
        invalidJSON.append(littleEndian(4))
        invalidJSON.append(littleEndian(12))
        invalidJSON.append(littleEndian(8))
        invalidJSON.append(littleEndian(4))
        invalidJSON.append(Data("nope".utf8))
        let invalidFixture = try write(invalidJSON, named: "invalid-json")
        assertError(.malformedArchive) {
            _ = try ClaudeASARReader(url: invalidFixture, containing: self.scratch)
        }
    }

    func testMarkerQueryBoundsAreEnforced() throws {
        let fixture = try makeArchive(main: "main.js", entrypoint: Data("safe".utf8))
        let reader = try ClaudeASARReader(url: fixture, containing: scratch)

        assertError(.malformedArchive) { _ = try reader.markersPresent([""]) }
        assertError(.malformedArchive) { _ = try reader.markersPresent(Set((0..<17).map(String.init))) }
        assertError(.malformedArchive) { _ = try reader.markersPresent([String(repeating: "x", count: 129)]) }
    }

    func testCodeAssetRejectsSymlinkAndHardlink() throws {
        let original = try makeArchive(main: "main.js", entrypoint: Data("safe".utf8))
        let symlink = scratch.appendingPathComponent("linked.asar")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        assertError(.unsafeCodeAsset) {
            _ = try ClaudeASARReader(url: symlink, containing: self.scratch)
        }

        let hardlink = scratch.appendingPathComponent("hardlinked.asar")
        try FileManager.default.linkItem(at: original, to: hardlink)
        assertError(.unsafeCodeAsset) {
            _ = try ClaudeASARReader(url: original, containing: self.scratch)
        }
    }

    func testVerifyUnchangedRejectsReplacementAfterInspection() throws {
        let fixture = try makeArchive(main: "main.js", entrypoint: Data("safe".utf8))
        let reader = try ClaudeASARReader(url: fixture, containing: scratch)
        try Data("replacement".utf8).write(to: fixture, options: .atomic)

        assertError(.applicationChanged) { try reader.verifyUnchanged() }
    }

    private func makeArchive(main: String, entrypoint: Data, additionalPayload: Data = Data()) throws -> URL {
        let package = try JSONSerialization.data(withJSONObject: ["main": main], options: [.sortedKeys])
        let files: [String: Any] = [
            "package.json": ["offset": "0", "size": package.count],
            main: ["offset": String(package.count), "size": entrypoint.count],
            "markers.bin": ["offset": String(package.count + entrypoint.count), "size": additionalPayload.count]
        ]
        return try makeArchive(package: ["main": main], files: files, payload: package + entrypoint + additionalPayload)
    }

    private func makeArchive(package: [String: Any], files: [String: Any], payload: Data) throws -> URL {
        var entries = files
        if entries["package.json"] == nil {
            let packageData = try JSONSerialization.data(withJSONObject: package, options: [.sortedKeys])
            entries["package.json"] = ["offset": "0", "size": packageData.count]
        }
        let header = try JSONSerialization.data(withJSONObject: ["files": entries], options: [.sortedKeys])
        let paddingCount = (4 - (header.count % 4)) % 4
        let headerPayloadSize = header.count + 4 + paddingCount
        let headerPickleSize = headerPayloadSize + 4

        var archive = Data()
        archive.append(littleEndian(4))
        archive.append(littleEndian(UInt32(headerPickleSize)))
        archive.append(littleEndian(UInt32(headerPayloadSize)))
        archive.append(littleEndian(UInt32(header.count)))
        archive.append(header)
        archive.append(Data(repeating: 0, count: paddingCount))
        archive.append(payload)
        return try write(archive, named: "fixture")
    }

    private func write(_ data: Data, named stem: String) throws -> URL {
        let url = scratch.appendingPathComponent(stem + "-" + UUID().uuidString + ".asar")
        try data.write(to: url)
        return url
    }

    private func littleEndian(_ value: UInt32) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private func assertError(_ expected: ClaudeInspectionError, file: StaticString = #filePath, line: UInt = #line,
                             _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? ClaudeInspectionError)?.rawValue, expected.rawValue, file: file, line: line)
        }
    }
}
