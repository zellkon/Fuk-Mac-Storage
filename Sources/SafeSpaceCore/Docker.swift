import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
}
public enum CommandRunner {
    public static func run(executable: URL, arguments: [String], timeout: TimeInterval = 60) throws -> CommandResult {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("safespace-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw SafetyError.rejected("Could not create a temporary Docker log.")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Ignore DOCKER_HOST / DOCKER_CONTEXT / DOCKER_API_VERSION from the launch environment.
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
                               "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try Task.checkCancellation()
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Task.isCancelled || Date() > deadline {
                process.terminate()
                for _ in 0..<20 {
                    if !process.isRunning { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                if Task.isCancelled { throw CancellationError() }
                throw SafetyError.rejected("Docker timed out. A running prune may continue in the daemon; refresh before trying again.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        try handle.synchronize()
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 2_000_000) ?? Data()
        return .init(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
public enum DockerAction: String, CaseIterable, Identifiable, Sendable {
    case build, dangling, stopped, standard, allImages, volumes
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .build: return "Unused build cache"
        case .dangling: return "Dangling images"
        case .stopped: return "Stopped containers"
        case .standard: return "Standard system prune"
        case .allImages: return "System prune + all unused images"
        case .volumes: return "Unused volumes • data-loss risk"
        }
    }
    public var arguments: [String] {
        switch self {
        case .build: return ["builder", "prune", "--all", "--force"]
        case .dangling: return ["image", "prune", "--force"]
        case .stopped: return ["container", "prune", "--force"]
        case .standard: return ["system", "prune", "--force"]
        case .allImages: return ["system", "prune", "--all", "--force"]
        case .volumes: return ["volume", "prune", "--force"]
        }
    }
    public var warning: String {
        switch self {
        case .build: return "Deletes unused build cache. The next build can be slower and may download data again."
        case .dangling: return "Deletes dangling images. You may need to build or pull again."
        case .stopped: return "Deletes ALL stopped containers, including any unsaved data in their writable layers."
        case .standard: return "Deletes stopped containers, unused networks, dangling images and build cache. Does not prune volumes."
        case .allImages: return "Also deletes all images unused by a container. You may lose locally built images that were not pushed. Does not prune volumes."
        case .volumes: return "May delete databases and the only copy of data in a volume that is no longer referenced. Review and back up first. This cannot be restored from Trash."
        }
    }
    public var reclaimTypes: [String] {
        switch self {
        case .build: return ["Build Cache"]
        case .dangling: return ["Images"]
        case .stopped: return ["Containers"]
        case .standard, .allImages: return ["Images", "Containers", "Build Cache"]
        case .volumes: return ["Local Volumes"]
        }
    }
}
public struct DockerUsage: Identifiable, Sendable {
    public var id: String { type }
    public let type: String
    public let size: String
    public let reclaimable: String
}
public struct DockerSnapshot: Sendable {
    public let executable: URL
    public let context: String
    public let endpoint: String
    public let usage: [DockerUsage]
    public let date: Date
    public func estimate(for action: DockerAction) -> String {
        let values = usage.filter { action.reclaimTypes.contains($0.type) }
        return values.map { "\($0.type): \($0.reclaimable)" }.joined(separator: " • ")
    }
}
public enum DockerService {
    public static func findExecutable() -> URL? {
        ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker/bin/docker").path]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    public static func validateEndpoint(_ endpoint: String) throws {
        guard endpoint.hasPrefix("unix:///"), !endpoint.contains("\n") else {
            throw SafetyError.rejected("This Docker context is not a local Unix socket. Remote Docker cleanup is blocked.")
        }
    }
    static func checked(_ exe: URL, _ args: [String], timeout: TimeInterval = 60) throws -> String {
        let result = try CommandRunner.run(executable: exe, arguments: args, timeout: timeout)
        guard result.status == 0 else { throw SafetyError.rejected(result.output.isEmpty ? "Docker failed with status \(result.status)." : result.output) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func scan() throws -> DockerSnapshot {
        guard let exe = findExecutable() else { throw SafetyError.rejected("Docker CLI was not found. Install and open Docker Desktop, then refresh Docker.") }
        let context = try checked(exe, ["context", "show"])
        let endpoint = try checked(exe, ["context", "inspect", context, "--format", "{{.Endpoints.docker.Host}}"])
        try validateEndpoint(endpoint)
        let output = try checked(exe, ["--host", endpoint, "system", "df", "--format", "{{json .}}"])
        let usage = output.split(separator: "\n").compactMap { line -> DockerUsage? in
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = json["Type"] as? String, let size = json["Size"] as? String,
                  let reclaimable = json["Reclaimable"] as? String else { return nil }
            return DockerUsage(type: type, size: size, reclaimable: reclaimable)
        }
        guard !usage.isEmpty else { throw SafetyError.rejected("Could not read docker system df:\n\(output)") }
        return .init(executable: exe, context: context, endpoint: endpoint, usage: usage, date: Date())
    }
    public static func prune(_ action: DockerAction, snapshot: DockerSnapshot) throws -> String {
        try validateEndpoint(snapshot.endpoint)
        guard Date().timeIntervalSince(snapshot.date) < 300 else { throw SafetyError.rejected("The Docker report is older than 5 minutes. Refresh Docker before cleaning.") }
        // Explicitly pin the reviewed endpoint, even if the active context changes.
        return try checked(snapshot.executable, ["--host", snapshot.endpoint] + action.arguments, timeout: 600)
    }
}
