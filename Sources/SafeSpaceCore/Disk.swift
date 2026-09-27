import Foundation
import Darwin

public struct DiskGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let relativePath: String
    public let icon: String
    public let canClean: Bool
    public let needsExtraConfirmation: Bool
    public let note: String
    public static let all: [DiskGroup] = [
        .init(id: "cache", title: "App caches", relativePath: "Library/Caches", icon: "externaldrive", canClean: true, needsExtraConfirmation: false, note: "Temporary app data. Close related apps first."),
        .init(id: "gradle", title: "Build caches", relativePath: ".gradle/caches", icon: "hammer", canClean: true, needsExtraConfirmation: false, note: "Dependencies may download again on the next build."),
        .init(id: "logs", title: "Log files", relativePath: "Library/Logs", icon: "doc.text", canClean: true, needsExtraConfirmation: false, note: "Keep logs you may need for troubleshooting."),
        .init(id: "developer", title: "Developer tools & simulators", relativePath: "Library/Developer", icon: "chevron.left.forwardslash.chevron.right", canClean: true, needsExtraConfirmation: true, note: "Xcode and simulator data. Review each item carefully."),
        .init(id: "android", title: "Android tools & emulators", relativePath: "Library/Android", icon: "iphone", canClean: true, needsExtraConfirmation: true, note: "SDK and emulator data. Review each item carefully."),
        .init(id: "arduino", title: "Arduino tools", relativePath: "Library/Arduino15", icon: "cpu", canClean: true, needsExtraConfirmation: true, note: "Board packages and tools. Review each item carefully."),
        .init(id: "support", title: "Apps & data", relativePath: "Library/Application Support", icon: "square.stack.3d.up", canClean: true, needsExtraConfirmation: true, note: "App data can include databases, downloads and account content."),
        .init(id: "home", title: "Large personal folders", relativePath: "", icon: "house", canClean: true, needsExtraConfirmation: true, note: "Large folders in your home folder, excluding hidden system folders.")
    ]
}
public struct FileIdentity: Hashable, Sendable {
    public let device: Int32
    public let inode: UInt64
}
public struct DiskEntry: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let bytes: Int64
    public let identity: FileIdentity
    public let eligible: Bool
    public let needsExtraConfirmation: Bool
    public let issueCount: Int
    public let isLink: Bool
    public let isDirectory: Bool
}
public struct GroupResult: Sendable {
    public let group: DiskGroup
    public let entries: [DiskEntry]
    public let issues: [String]
    public init(group: DiskGroup, entries: [DiskEntry], issues: [String]) {
        self.group = group
        self.entries = entries
        self.issues = issues
    }
    public var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
}
public enum SafetyError: LocalizedError {
    case rejected(String)
    public var errorDescription: String? {
        switch self { case .rejected(let reason): return reason }
    }
}
public enum DiskScanner {
    static func metadata(_ url: URL) throws -> stat {
        var result = stat()
        guard lstat(url.path, &result) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        return result
    }
    static func identity(_ s: stat) -> FileIdentity { .init(device: s.st_dev, inode: s.st_ino) }
    static func isLink(_ s: stat) -> Bool { s.st_mode & S_IFMT == S_IFLNK }
    static func isDirectory(_ s: stat) -> Bool { s.st_mode & S_IFMT == S_IFDIR }

    // Only reads metadata. Never follows symlinks or crosses mount points.
    static func measure(_ url: URL, device: Int32, seen: inout Set<FileIdentity>, errors: inout Int) throws -> Int64 {
        try Task.checkCancellation()
        let s: stat
        do { s = try metadata(url) } catch { errors += 1; return 0 }
        guard s.st_dev == device else { errors += 1; return 0 }
        guard seen.insert(identity(s)).inserted else { return 0 }
        var bytes = Int64(s.st_blocks) * 512
        if isDirectory(s) && !isLink(s) {
            let children: [URL]
            do { children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
            catch { errors += 1; return bytes }
            for child in children { bytes += try measure(child, device: device, seen: &seen, errors: &errors) }
        }
        return bytes
    }
    public static func scan(group: DiskGroup, home: URL) throws -> GroupResult {
        let root = home.appendingPathComponent(group.relativePath).standardizedFileURL
        return try scanDirectory(root, group: group, isHomeRoot: group.id == "home")
    }
    public static func scanDirectory(_ root: URL, group: DiskGroup, isHomeRoot: Bool = false) throws -> GroupResult {
        try Task.checkCancellation()
        let root = root.standardizedFileURL
        guard root.resolvingSymlinksInPath().path == root.path else {
            return .init(group: group, entries: [], issues: ["Skipped symbolic-link path: \(root.path)"])
        }
        do {
            let rootStat = try metadata(root)
            guard isDirectory(rootStat) else { throw SafetyError.rejected("The path is not a folder.") }
            let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            var entries: [DiskEntry] = []
            var issues: [String] = []
            for child in children {
                try Task.checkCancellation()
                do {
                    let s = try metadata(child)
                    var seen = Set<FileIdentity>()
                    var errors = 0
                    let bytes = try measure(child, device: rootStat.st_dev, seen: &seen, errors: &errors)
                    let link = isLink(s)
                    let hiddenHomeItem = isHomeRoot && child.lastPathComponent.hasPrefix(".")
                    let libraryHomeItem = isHomeRoot && child.lastPathComponent == "Library"
                    // A protected file inside an otherwise valid folder must not make every
                    // Library item impossible to remove. The UI labels the size as partial and
                    // requires the stronger confirmation for these entries.
                    let allowed = group.canClean && !hiddenHomeItem && !libraryHomeItem && !link && s.st_dev == rootStat.st_dev && (isDirectory(s) || s.st_mode & S_IFMT == S_IFREG)
                    entries.append(.init(url: child, bytes: bytes, identity: identity(s), eligible: allowed, needsExtraConfirmation: group.needsExtraConfirmation || errors > 0, issueCount: errors, isLink: link, isDirectory: isDirectory(s)))
                } catch is CancellationError { throw CancellationError() }
                catch { if issues.count < 20 { issues.append("\(child.lastPathComponent): \(error.localizedDescription)") } }
            }
            return .init(group: group, entries: entries.sorted { $0.bytes > $1.bytes }, issues: issues)
        } catch is CancellationError { throw CancellationError() }
        catch { return .init(group: group, entries: [], issues: [error.localizedDescription]) }
    }
}

public struct CleanupPolicy {
    public let home: URL
    public init(home: URL) { self.home = home.standardizedFileURL }
    public func validate(_ entry: DiskEntry) throws {
        guard entry.eligible else { throw SafetyError.rejected("This item is not eligible for cleanup.") }
        let path = entry.url.standardizedFileURL
        let roots = DiskGroup.all.filter(\.canClean).map { home.appendingPathComponent($0.relativePath).standardizedFileURL }
        guard !roots.contains(path),
              let root = roots.first(where: { path.path.hasPrefix($0.path + "/") }),
              path != home.appendingPathComponent("Library"),
              path.resolvingSymlinksInPath().path == path.path else {
            throw SafetyError.rejected("This item is outside the reviewed cleanup list or is a symbolic link.")
        }
        let s = try DiskScanner.metadata(path)
        guard !DiskScanner.isLink(s), DiskScanner.identity(s) == entry.identity else {
            throw SafetyError.rejected("The item changed after scanning. Refresh before cleaning.")
        }
        var ancestor = path.deletingLastPathComponent()
        while ancestor.path != root.path {
            let ancestorStat = try DiskScanner.metadata(ancestor)
            guard !DiskScanner.isLink(ancestorStat), ancestorStat.st_dev == s.st_dev else {
                throw SafetyError.rejected("A parent folder changed or crosses a filesystem. Refresh before cleaning.")
            }
            ancestor = ancestor.deletingLastPathComponent()
        }
    }
    public func moveToTrash(_ entry: DiskEntry) throws {
        try validate(entry)
        // No permanent delete, no shell, no recursive rm. macOS moves the entry itself.
        try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
    }
}

public func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
