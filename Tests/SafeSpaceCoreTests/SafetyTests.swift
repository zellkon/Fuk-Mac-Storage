import XCTest
@testable import SafeSpaceCore

final class SafetyTests: XCTestCase {
    var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("SafeSpaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    @discardableResult
    func write(_ path: String, bytes: Int = 8192) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: bytes).write(to: url)
        return url
    }
    func group(_ id: String) -> DiskGroup { DiskGroup.all.first { $0.id == id }! }
    func scan(_ id: String) throws -> GroupResult { try DiskScanner.scan(group: group(id), home: home) }
    func forged(_ url: URL) throws -> DiskEntry {
        .init(url: url, bytes: 0, identity: DiskScanner.identity(try DiskScanner.metadata(url)), eligible: true, needsExtraConfirmation: false, issueCount: 0, isLink: false, isDirectory: true)
    }
    func testAllowedCacheLogAndGradleChildren() throws {
        for (id, path) in [("cache", "Library/Caches/example/file"), ("logs", "Library/Logs/example.log"), ("gradle", ".gradle/caches/8.0/file")] {
            try write(path)
            let result = try scan(id)
            XCTAssertEqual(result.entries.count, 1)
            XCTAssertTrue(result.entries[0].eligible)
            XCTAssertGreaterThan(result.bytes, 0)
            XCTAssertNoThrow(try CleanupPolicy(home: home).validate(result.entries[0]))
        }
    }
    func testDeveloperAndAppDataGroupsRequireExtraConfirmationButRemainEligible() throws {
        for id in ["developer", "android", "arduino", "support"] {
            let path = group(id).relativePath + "/critical.db"
            let url = try write(path)
            let entry = try scan(id).entries[0]
            XCTAssertTrue(entry.eligible)
            XCTAssertTrue(entry.needsExtraConfirmation)
            XCTAssertNoThrow(try CleanupPolicy(home: home).validate(forged(url)))
        }
    }
    func testRootAndNestedPathsRejected() throws {
        let nested = try write("Library/Caches/app/child")
        XCTAssertThrowsError(try CleanupPolicy(home: home).validate(forged(home.appendingPathComponent("Library/Caches"))))
        XCTAssertNoThrow(try CleanupPolicy(home: home).validate(forged(nested)))
    }
    func testScanDirectoryShowsNestedChildren() throws {
        try write("Library/Caches/app/first", bytes: 10_000)
        try write("Library/Caches/app/second", bytes: 20_000)
        let app = home.appendingPathComponent("Library/Caches/app")
        let result = try DiskScanner.scanDirectory(app, group: group("cache"))
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertTrue(result.entries.allSatisfy(\.eligible))
        XCTAssertTrue(result.entries.allSatisfy { !$0.isDirectory })
    }
    func testSymbolicLinkToDeveloperNotFollowedOrCleanable() throws {
        let target = try write("Library/Developer/important", bytes: 1_000_000).deletingLastPathComponent()
        let cache = home.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let link = cache.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let result = try scan("cache")
        XCTAssertTrue(result.entries[0].isLink)
        XCTAssertFalse(result.entries[0].eligible)
        XCTAssertLessThan(result.bytes, 1_000_000)
        XCTAssertThrowsError(try CleanupPolicy(home: home).validate(forged(link)))
    }
    func testSymlinkedRootRejected() throws {
        let target = try write("Library/Developer/file").deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Library/Caches"), withDestinationURL: target)
        let result = try scan("cache")
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertFalse(result.issues.isEmpty)
    }
    func testEntryReplacedAfterScanRejected() throws {
        let original = try write("Library/Caches/app/file").deletingLastPathComponent()
        let entry = try scan("cache").entries[0]
        try FileManager.default.moveItem(at: original, to: original.appendingPathExtension("old"))
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        XCTAssertThrowsError(try CleanupPolicy(home: home).validate(entry))
    }
    func testIncompleteButReviewedEntryCanStillBeValidated() throws {
        let url = try write("Library/Application Support/example/data").deletingLastPathComponent()
        let identity = DiskScanner.identity(try DiskScanner.metadata(url))
        let entry = DiskEntry(url: url, bytes: 0, identity: identity, eligible: true, needsExtraConfirmation: true, issueCount: 2, isLink: false, isDirectory: true)
        XCTAssertNoThrow(try CleanupPolicy(home: home).validate(entry))
    }
    func testAncestorReplacedWithSymlinkRejected() throws {
        try write("Library/Caches/app/file")
        let entry = try scan("cache").entries[0]
        let root = home.appendingPathComponent("Library/Caches")
        let moved = home.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: moved)
        XCTAssertThrowsError(try CleanupPolicy(home: home).validate(entry))
    }
    func testMissingDirectoryReported() throws {
        let result = try scan("android")
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertFalse(result.issues.isEmpty)
    }
    func testHardLinksWithinEntryNotCountedTwice() throws {
        let file = try write("Library/Caches/app/one")
        let before = try scan("cache").bytes
        try FileManager.default.linkItem(at: file, to: file.deletingLastPathComponent().appendingPathComponent("two"))
        XCTAssertEqual(try scan("cache").bytes, before)
    }
    func testNestedSymlinkDoesNotCountTarget() throws {
        try write("Library/Caches/app/small")
        let huge = try write("Library/Developer/huge", bytes: 1_000_000)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Library/Caches/app/link"), withDestinationURL: huge)
        XCTAssertLessThan(try scan("cache").bytes, 1_000_000)
    }
    func testRemoteDockerBlocked() {
        for endpoint in ["ssh://server", "tcp://127.0.0.1:2375", "unix://relative", ""] {
            XCTAssertThrowsError(try DockerService.validateEndpoint(endpoint))
        }
        XCTAssertNoThrow(try DockerService.validateEndpoint("unix:///var/run/docker.sock"))
    }
    func testOnlyExplicitVolumeActionPrunesVolumes() {
        for action in DockerAction.allCases where action != .volumes {
            XCTAssertFalse(action.arguments.contains("--volumes"))
            XCTAssertFalse(action.arguments.contains("volume"))
        }
        XCTAssertEqual(DockerAction.volumes.arguments, ["volume", "prune", "--force"])
    }
    func testProcessOutputAndExitCode() throws {
        let result = try CommandRunner.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["sample"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "sample")
    }
    func testProcessTimeout() {
        XCTAssertThrowsError(try CommandRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.1))
    }
    func testCancellation() async throws {
        let root = home!
        let task = Task.detached { () throws -> GroupResult in
            while !Task.isCancelled { await Task.yield() }
            return try DiskScanner.scan(group: DiskGroup.all[0], home: root)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
