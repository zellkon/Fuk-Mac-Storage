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
    @Published var status = "Ready • Scan storage to begin"
    @Published var lastScan: Date?
    @Published var freeBytes: Int64 = 0
    @Published var docker: DockerSnapshot?
    @Published var dockerError: String?
    @Published var activity = "No cleanup activity yet."
    @Published var activityTitle = "Activity"
    @Published var activityDate = Date()
    @Published var showActivity = false
    private var worker: Task<Void, Never>?
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    var chosen: [DiskEntry] { (results.values.flatMap(\.entries) + (openedResult?.entries ?? [])).filter { selected.contains($0.id) && $0.eligible } }
    var selectedBytes: Int64 { chosen.reduce(0) { $0 + $1.bytes } }
    var cacheBytes: Int64 { results.values.filter { $0.group.canClean }.reduce(0) { $0 + $1.bytes } }
    func refreshCapacity() {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: home.path)
        freeBytes = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
    func scan() {
        guard !busy else { return }
        busy = true
        isScanning = true
        selected.removeAll()
        results.removeAll()
        openedFolder = nil
        openedResult = nil
        lastScan = nil
        status = "Scanning storage…"
        let root = home
        worker = Task.detached(priority: .utility) { [weak self] in
            guard let model = self else { return }
            do {
                for group in DiskGroup.all {
                    try Task.checkCancellation()
                    await MainActor.run { model.status = "Scanning \(group.title)…" }
                    let result = try DiskScanner.scan(group: group, home: root)
                    await MainActor.run { model.results[group.id] = result }
                }
                try Task.checkCancellation()
                await MainActor.run { model.status = "Checking Docker…"; model.docker = nil }
                do {
                    let docker = try DockerService.scan()
                    await MainActor.run { model.docker = docker; model.dockerError = nil }
                } catch is CancellationError { throw CancellationError() }
                catch { await MainActor.run { model.dockerError = error.localizedDescription } }
                await MainActor.run { model.status = "Scan complete • Review selected items before cleaning"; model.lastScan = Date() }
            } catch {
                await MainActor.run { model.status = "Scan stopped • Current results are partial" }
            }
            await MainActor.run { model.busy = false; model.isScanning = false; model.refreshCapacity() }
        }
    }
    func cancel() { worker?.cancel(); status = "Stopping scan…" }
    func openFolder(_ entry: DiskEntry, group: DiskGroup) {
        guard !busy, entry.isDirectory else { return }
        busy = true
        status = "Scanning (entry.url.lastPathComponent)…"
        let folder = entry.url
        worker = Task.detached(priority: .utility) { [weak self] in
            guard let model = self else { return }
            do {
                let result = try DiskScanner.scanDirectory(folder, group: group)
                await MainActor.run { model.openedFolder = folder; model.openedResult = result; model.status = "Showing (folder.lastPathComponent)" }
            } catch { await MainActor.run { model.status = "Could not open folder: \(error.localizedDescription)" } }
            await MainActor.run { model.busy = false }
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
