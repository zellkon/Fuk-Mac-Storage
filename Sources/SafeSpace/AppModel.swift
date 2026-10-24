import SwiftUI
import AppKit
#if canImport(SafeSpaceCore)
import SafeSpaceCore
#endif

@MainActor
final class AppModel: ObservableObject {
    @Published var results: [String: GroupResult] = [:]
    @Published var openedFolder: URL?
    @Published var openedResult: GroupResult?
    @Published var selected = Set<String>()
    @Published var busy = false
    @Published var isScanning = false
    /// Folder currently being measured after the user opened it from the list.
    @Published var openingFolder: URL?
    @Published var status = "Ready • Scan storage to begin"
    @Published var lastScan: Date?
    @Published var freeBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var docker: DockerSnapshot?
    @Published var dockerError: String?
    @Published var activity = "No cleanup activity yet."
    @Published var activityTitle = "Activity"
    @Published var activityDate = Date()
    @Published var showActivity = false
    private var worker: Task<Void, Never>?
    /// The user's real home folder. Inside the App Sandbox, FileManager's home is the app container.
    let home: URL = {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true).standardizedFileURL
    }()
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    /// Sandboxed builds can only read folders the user picked in an open panel. Outside the sandbox
    /// both are always true.
    @Published var homeAccess = !AppModel.isSandboxed
    @Published var diskAccess = !AppModel.isSandboxed
    private var scopedURLs: [URL] = []
    private static let homeBookmarkKey = "homeBookmark"
    private static let diskBookmarkKey = "diskBookmark"
    static let diskRoot = URL(fileURLWithPath: "/", isDirectory: true)

    init() { restoreAccess() }

    private func restoreAccess() {
        guard Self.isSandboxed else { return }
        homeAccess = resolveBookmark(Self.homeBookmarkKey, expecting: home)
        diskAccess = resolveBookmark(Self.diskBookmarkKey, expecting: Self.diskRoot)
    }
    private func resolveBookmark(_ key: String, expecting expected: URL) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: key) else { return false }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              url.standardizedFileURL.path == expected.path, url.startAccessingSecurityScopedResource() else {
            UserDefaults.standard.removeObject(forKey: key)
            return false
        }
        scopedURLs.append(url)
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: key)
        }
        return true
    }
    /// Asks the user to pick their home folder (or the startup disk) so the sandboxed app may read it.
    /// Returns true when access is available afterwards.
    @discardableResult
    func requestAccess(disk: Bool = false) -> Bool {
        if disk ? diskAccess : homeAccess { return true }
        let expected = disk ? Self.diskRoot : home
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = expected
        panel.prompt = "Allow Access"
        panel.message = disk
            ? "Select your startup disk (\(FileManager.default.displayName(atPath: "/"))) so Fuk Mac Storage can measure everything on it. Nothing is changed without your confirmation."
            : "Select your home folder “\(home.lastPathComponent)” so Fuk Mac Storage can measure caches, logs and developer data. Nothing is changed without your confirmation."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard url.standardizedFileURL.path == expected.path else {
            status = disk ? "Please select the startup disk itself to scan the whole disk." : "Please select your home folder “\(home.lastPathComponent)” itself."
            return false
        }
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            status = "Could not save folder access. Try again."
            return false
        }
        UserDefaults.standard.set(data, forKey: disk ? Self.diskBookmarkKey : Self.homeBookmarkKey)
        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        if disk { diskAccess = true } else { homeAccess = true }
        return true
    }
    var chosen: [DiskEntry] { (results.values.flatMap(\.entries) + (openedResult?.entries ?? [])).filter { selected.contains($0.id) && $0.eligible } }
    /// Off by default: Desktop, Documents and Downloads are skipped so macOS does not prompt.
    /// On: they are scanned too, plus a read-only overview of the whole disk.
    var deepScan: Bool { UserDefaults.standard.bool(forKey: "deepScan") }
    var usedFraction: Double { totalBytes > 0 ? Double(totalBytes - freeBytes) / Double(totalBytes) : 0 }
    var selectedBytes: Int64 { chosen.reduce(0) { $0 + $1.bytes } }
    var cacheBytes: Int64 { results.values.filter { $0.group.canClean }.reduce(0) { $0 + $1.bytes } }
    func refreshCapacity() {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/")
        freeBytes = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        totalBytes = (attrs?[.systemSize] as? NSNumber)?.int64Value ?? 0
    }
    func scan() {
        guard !busy, requestAccess() else { return }
        busy = true
        isScanning = true
        selected.removeAll()
        results.removeAll()
        openedFolder = nil
        openedResult = nil
        lastScan = nil
        status = "Scanning storage…"
        let root = home
        let deep = deepScan
        let groups = DiskGroup.all + (deep && diskAccess ? [DiskGroup.wholeDisk] : [])
        let skipping = deep ? [] : DiskGroup.privacyProtectedFolders
        // Docker's CLI and socket are out of reach inside the App Sandbox.
        let checkDocker = !Self.isSandboxed
        worker = Task.detached(priority: .utility) { [weak self] in
            guard let model = self else { return }
            do {
                for group in groups {
                    try Task.checkCancellation()
                    await MainActor.run { model.status = "Scanning \(group.title)…" }
                    let result = try DiskScanner.scan(group: group, home: root, skipping: group.id == "home" ? skipping : [])
                    await MainActor.run { model.results[group.id] = result }
                }
                try Task.checkCancellation()
                if checkDocker {
                    await MainActor.run { model.status = "Checking Docker…"; model.docker = nil }
                    do {
                        let docker = try DockerService.scan()
                        await MainActor.run { model.docker = docker; model.dockerError = nil }
                    } catch is CancellationError { throw CancellationError() }
                    catch { await MainActor.run { model.dockerError = error.localizedDescription } }
                }
                await MainActor.run { model.status = "Scan complete • Review selected items before cleaning"; model.lastScan = Date() }
            } catch {
                await MainActor.run { model.status = "Scan stopped • Current results are partial" }
            }
            await MainActor.run { model.busy = false; model.isScanning = false; model.refreshCapacity() }
        }
    }
    func cancel() { worker?.cancel(); status = "Stopping…" }
    func openFolder(_ entry: DiskEntry, group: DiskGroup) {
        guard !busy, entry.isDirectory else { return }
        busy = true
        openingFolder = entry.url
        status = "Opening \(entry.url.lastPathComponent)…"
        let folder = entry.url
        worker = Task.detached(priority: .utility) { [weak self] in
            guard let model = self else { return }
            do {
                let result = try DiskScanner.scanDirectory(folder, group: group)
                await MainActor.run { model.openedFolder = folder; model.openedResult = result; model.status = "Showing \(folder.lastPathComponent)" }
            } catch is CancellationError { await MainActor.run { model.status = "Stopped opening \(folder.lastPathComponent)" } }
            catch { await MainActor.run { model.status = "Could not open folder: \(error.localizedDescription)" } }
            await MainActor.run { model.busy = false; model.openingFolder = nil }
        }
    }
    func closeFolder() { openedFolder = nil; openedResult = nil }
    func refreshDocker() {
        guard !busy else { return }
        busy = true
        docker = nil
        dockerError = nil
        status = "Checking Docker…"
        worker = Task.detached(priority: .utility) { [weak self] in
            guard let model = self else { return }
            do {
                let report = try DockerService.scan()
                await MainActor.run { model.docker = report; model.status = "Docker updated" }
            } catch {
                await MainActor.run { model.dockerError = error.localizedDescription; model.status = "Docker unavailable" }
            }
            await MainActor.run { model.busy = false }
        }
    }
    func clean(_ entries: [DiskEntry]) {
        guard !busy, !entries.isEmpty else { return }
        busy = true
        status = "Moving selected items to Trash…"
        selected.removeAll()
        let root = home
        worker = Task.detached(priority: .utility) { [weak self] in
            guard let model = self else { return }
            var messages: [String] = []
            var removed = Set<String>()
            let policy = CleanupPolicy(home: root)
            for entry in entries {
                do {
                    try policy.moveToTrash(entry)
                    messages.append("Moved to Trash: \(entry.url.path)")
                    removed.insert(entry.url.path)
                } catch { messages.append("Could not clean \(entry.url.path): \(error.localizedDescription)") }
            }
            let report = messages.joined(separator: "\n") + "\n\nStorage is only released after you empty Trash. Items can be restored until then."
            await MainActor.run {
                model.activity = report
                model.activityTitle = "Cleanup complete"
                model.activityDate = Date()
                model.showActivity = true
                model.busy = false
                model.results = model.results.mapValues { result in
                    GroupResult(group: result.group, entries: result.entries.filter { !removed.contains($0.url.path) }, issues: result.issues)
                }
                if let result = model.openedResult {
                    model.openedResult = GroupResult(group: result.group, entries: result.entries.filter { !removed.contains($0.url.path) }, issues: result.issues)
                }
                model.status = "Cleanup complete • Refresh whenever you want a new scan"
                model.refreshCapacity()
            }
        }
    }
    func prune(_ action: DockerAction, report: DockerSnapshot) {
        guard !busy else { return }
        busy = true
        status = "Running Docker cleanup…"
        worker = Task.detached(priority: .utility) { [weak self] in
            guard let model = self else { return }
            let message: String
            do { message = try DockerService.prune(action, snapshot: report) }
            catch { message = error.localizedDescription }
            await MainActor.run {
                model.activity = "docker \(action.arguments.joined(separator: " "))\nEndpoint: \(report.endpoint)\n\n\(message)\n\nmacOS free storage may not increase immediately because Docker Desktop uses a disk image."
                model.activityTitle = "Docker cleanup complete"
                model.activityDate = Date()
                model.showActivity = true
                model.busy = false
                model.refreshCapacity()
                model.refreshDocker()
            }
        }
    }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
