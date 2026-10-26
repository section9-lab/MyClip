import Foundation
import CryptoKit

/// Release-controlled compatibility and integrity data, never user accounts or model IDs.
public struct ManagedRuntimeManifest: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let url: URL
        public let algorithm: String
        public let digest: String
        public let member: String
        public let licenseMember: String?
    }
    public struct Platform: Decodable, Sendable {
        public let architecture: String
        public let node: Asset
        public let executor: Asset
    }
    public let schemaVersion: Int
    public let nodeVersion: String
    public let executorVersion: String
    public let platforms: [Platform]

    public static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
    public static func load() throws -> Self {
        guard let url = Bundle.module.url(forResource: "runtime-distribution", withExtension: "json", subdirectory: "Resources/SubscriptionAgent") else {
            throw LibraryError.invalidResult(String(localized: "应用缺少运行组件清单，请重新下载完整版本。"))
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    public var identity: String {
        // The complete artifact identities are stable across JSON formatting changes.
        let value = ([String(schemaVersion), nodeVersion, executorVersion] + platforms.flatMap {
            [$0.architecture, $0.node.url.absoluteString, $0.node.algorithm, $0.node.digest, $0.node.member,
             $0.node.licenseMember ?? "", $0.executor.url.absoluteString, $0.executor.algorithm, $0.executor.digest, $0.executor.member]
        }).joined(separator: "\n")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func directory(in root: URL, architecture: String = currentArchitecture) -> URL {
        root.appendingPathComponent("Components").appendingPathComponent(identity).appendingPathComponent(architecture)
    }
}

public protocol ManagedRuntimeFetching: Sendable {
    func fetch(_ url: URL, to destination: URL) async throws
}

private final class RuntimeDownloadPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == task.originalRequest?.url?.host ? request : nil)
    }
}

public struct RuntimeURLSessionFetcher: ManagedRuntimeFetching {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: RuntimeDownloadPolicy(), delegateQueue: nil)
    }
    public func fetch(_ url: URL, to destination: URL) async throws {
        guard url.scheme == "https", ["nodejs.org", "registry.npmjs.org"].contains(url.host) else {
            throw LibraryError.invalidResult(String(localized: "运行组件下载地址无效。"))
        }
        let (file, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 512 * 1024 * 1024 else {
            throw LibraryError.invalidResult(String(localized: "运行组件下载失败，请检查网络后重试。"))
        }
        try FileManager.default.moveItem(at: file, to: destination)
    }
}

/// Uses native macOS APIs and tar; a fresh Mac needs no Python, npm, Node or Agent CLI.
public actor ManagedAgentRuntime {
    private struct Receipt: Codable {
        let manifest: String
        let nodeSize: Int
        let executorSize: Int
    }
    private let root: URL
    private let manifest: ManagedRuntimeManifest
    private let fetcher: any ManagedRuntimeFetching
    private var preparing: Task<URL, any Error>?

    public init(root: URL, manifest: ManagedRuntimeManifest, fetcher: any ManagedRuntimeFetching = RuntimeURLSessionFetcher()) {
        self.root = root; self.manifest = manifest; self.fetcher = fetcher
    }

    public static func readyDirectory(root: URL, manifest: ManagedRuntimeManifest, architecture: String = ManagedRuntimeManifest.currentArchitecture) -> URL? {
        let directory = manifest.directory(in: root, architecture: architecture)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("receipt.json")),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.manifest == manifest.identity,
              validExecutable(directory.appendingPathComponent("node"), size: receipt.nodeSize),
              validExecutable(directory.appendingPathComponent("opencode"), size: receipt.executorSize) else { return nil }
        return directory
    }

    public func prepare() async throws -> URL {
        if let ready = Self.readyDirectory(root: root, manifest: manifest) { return ready }
        if let preparing { return try await preparing.value }
        let root = root, manifest = manifest, fetcher = fetcher
        let task = Task { try await Self.install(root: root, manifest: manifest, fetcher: fetcher) }
        preparing = task
        defer { preparing = nil }
        return try await task.value
    }

    private static func validExecutable(_ url: URL, size: Int) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == size, size > 0 else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    public static func verify(_ file: URL, asset: ManagedRuntimeManifest.Asset) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var sha256 = SHA256(), sha512 = SHA512()
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            switch asset.algorithm {
            case "sha256": sha256.update(data: chunk)
            case "sha512": sha512.update(data: chunk)
            default: throw LibraryError.invalidResult("Unsupported component digest")
            }
        }
        let actual = asset.algorithm == "sha256" ? sha256.finalize().map { String(format: "%02x", $0) }.joined()
            : sha512.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == asset.digest else { throw LibraryError.invalidResult(String(localized: "运行组件校验失败，请重新连接以重试下载。")) }
    }

    private static func install(root: URL, manifest: ManagedRuntimeManifest, fetcher: any ManagedRuntimeFetching) async throws -> URL {
        guard manifest.schemaVersion == 1, let platform = manifest.platforms.first(where: { $0.architecture == ManagedRuntimeManifest.currentArchitecture }) else {
            throw LibraryError.invalidResult(String(localized: "当前 Mac 的处理器暂不支持此运行组件。"))
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = root.appendingPathComponent(".components-\(UUID())")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let payload = staging.appendingPathComponent("ready")
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        for (name, asset) in [("node", platform.node), ("opencode", platform.executor)] {
            try Task.checkCancellation()
            let archive = staging.appendingPathComponent(name + ".tgz")
            try await fetcher.fetch(asset.url, to: archive)
            try await Task.detached(priority: .utility) { [asset, archive, name, staging, payload] in
                let fm = FileManager.default
                try verify(archive, asset: asset)
                let extract = staging.appendingPathComponent("unpack-" + name)
                try fm.createDirectory(at: extract, withIntermediateDirectories: true)
                let members = [asset.member, asset.licenseMember].compactMap { $0 }
                guard members.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else {
                    throw LibraryError.invalidResult("Invalid archive member")
                }
                try run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", extract.path] + members)
                for member in members {
                    let source = extract.appendingPathComponent(member)
                    let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                          source.resolvingSymlinksInPath().path.hasPrefix(extract.resolvingSymlinksInPath().path + "/") else {
                        throw LibraryError.invalidResult("Invalid component file")
                    }
                    try fm.copyItem(at: source, to: payload.appendingPathComponent(member == asset.member ? name : "LICENSE." + name))
                }
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: payload.appendingPathComponent(name).path)
            }.value
        }
        // Verify the real downloaded executables, without any user shell or login config.
        try await Task.detached(priority: .utility) {
            try run(payload.appendingPathComponent("node"), ["--version"], expected: "v" + manifest.nodeVersion)
            try run(payload.appendingPathComponent("opencode"), ["--version"], expected: manifest.executorVersion)
        }.value
        if let license = Bundle.module.url(forResource: "OpenCode.LICENSE", withExtension: "txt", subdirectory: "Resources/SubscriptionAgent") {
            try fm.copyItem(at: license, to: payload.appendingPathComponent("LICENSE.opencode"))
        }
        let receipt = Receipt(manifest: manifest.identity,
            nodeSize: try payload.appendingPathComponent("node").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            executorSize: try payload.appendingPathComponent("opencode").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        try JSONEncoder().encode(receipt).write(to: payload.appendingPathComponent("receipt.json"), options: .atomic)
        try Task.checkCancellation()
        let destination = manifest.directory(in: root)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            if Self.readyDirectory(root: root, manifest: manifest) != nil { return destination }
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: payload, to: destination)
        return destination
    }

    private static func run(_ executable: URL, _ arguments: [String], expected: String? = nil) throws {
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": executable.deletingLastPathComponent().path]
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              expected == nil || String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
            throw LibraryError.invalidResult(String(localized: "运行组件无法在当前系统启动，请重新下载应用或重试。"))
        }
    }
}
