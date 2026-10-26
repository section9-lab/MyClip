import Foundation
import CryptoKit
import MyClipCore

private actor CleanProfileCredentials: AgentAccountStorage {
    private var data = Data(#"{"type":"oauth","uid":"fixture","access":"fixture-access","refresh":"fixture-refresh","expires":9999999999999,"deviceChat":true,"deviceToken":"fixture-access","machineId":"fixture-machine"}"#.utf8)
    func read() -> Data? { data }
    func save(_ value: Data) { data = value }
}

private actor FixtureRuntimeFetcher: ManagedRuntimeFetching {
    let node: URL
    let executor: URL
    var calls = 0
    var failExecutor = false
    init(node: URL, executor: URL) { self.node = node; self.executor = executor }
    func fetch(_ url: URL, to destination: URL) throws {
        calls += 1
        if failExecutor && url.host == "registry.npmjs.org" { throw URLError(.notConnectedToInternet) }
        try FileManager.default.copyItem(at: url.host == "nodejs.org" ? node : executor, to: destination)
    }
    func count() -> Int { calls }
    func setFailure(_ value: Bool) { failExecutor = value }
}

@main struct ManagedRuntimeChecks {
    static func main() async throws {
        let fm = FileManager.default
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--live" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            let runtime = AgentRuntime(root: root, searchPaths: [], desktopApplications: [:],
                homeDirectory: root.appendingPathComponent("Fresh User"), inheritedEnvironment: ["PATH": "/usr/bin:/bin"])
            print("Preparing real managed runtime with no desktop apps or user executables in discovery.")
            try await runtime.install(.workbuddy)
            for agent in [ClipAgent.workbuddy, .qwenwork] {
                guard let preparedCommand = runtime.command(for: agent, customPath: ""), preparedCommand.accountContext?.provider == agent,
                      preparedCommand.executable.path.hasPrefix(root.path + "/") else { throw URLError(.cannotCreateFile) }
                let client = ACPClient(accountStorage: CleanProfileCredentials())
                var command = preparedCommand
                let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/SubscriptionAgent/clean-user-upstream.mjs")
                command.arguments = ["--import", fixture.path] + command.arguments
                let handshake = try await client.connect(command: command)
                guard handshake.supportsImages, !handshake.authMethods.isEmpty else { throw URLError(.badServerResponse) }
                let memory = root.deletingLastPathComponent().appendingPathComponent("Memory")
                try fm.createDirectory(at: memory, withIntermediateDirectories: true)
                let output = memory.appendingPathComponent("clean-profile.md")
                try? fm.removeItem(at: output)
                let session = try await client.newSession(directory: memory, ephemeralFor: agent)
                try await client.setMode(sessionID: session, modeID: agent.fullAccessModeID)
                let result = try await client.prompt(sessionID: session, text: "Create clean-profile.md using the available write tool.", images: [], maximumDuration: .seconds(60))
                guard result.stopReason == "end_turn", (try String(contentsOf: output, encoding: .utf8)).contains("Managed runtime completed the ACP tool loop.") else {
                    throw URLError(.cannotWriteToFile)
                }
                await client.close()
                print("PASS \(agent.rawValue) downloaded Node/executor, dynamic model catalog, ACP tool loop and Markdown write in a clean profile (mock account/upstream)")
            }
            return
        }
        let root = fm.temporaryDirectory.appendingPathComponent("MyClip Fresh 用户 \(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        func archive(_ name: String, version: String) throws -> URL {
            let package = root.appendingPathComponent("source-" + name).appendingPathComponent("package")
            try fm.createDirectory(at: package.appendingPathComponent("bin"), withIntermediateDirectories: true)
            let executable = package.appendingPathComponent("bin/" + name)
            try Data(("#!/bin/sh\nprintf '%s\\n' '" + version + "'\n").utf8).write(to: executable)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            try Data("Fixture MIT license".utf8).write(to: package.appendingPathComponent("LICENSE"))
            let file = root.appendingPathComponent(name + ".tgz"), process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-czf", file.path, "-C", package.deletingLastPathComponent().path, "package"]
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw URLError(.cannotCreateFile) }
            return file
        }
        let node = try archive("node", version: "v22.0.0-fixture")
        let executor = try archive("opencode", version: "fixture-executor")
        let nodeHash = SHA256.hash(data: try Data(contentsOf: node)).map { String(format: "%02x", $0) }.joined()
        let executorHash = SHA512.hash(data: try Data(contentsOf: executor)).map { String(format: "%02x", $0) }.joined()
        let manifestData = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "nodeVersion": "22.0.0-fixture", "executorVersion": "fixture-executor", "platforms": [
            ["architecture": ManagedRuntimeManifest.currentArchitecture,
             "node": ["url": "https://nodejs.org/fixture.tgz", "algorithm": "sha256", "digest": nodeHash, "member": "package/bin/node", "licenseMember": "package/LICENSE"],
             "executor": ["url": "https://registry.npmjs.org/fixture.tgz", "algorithm": "sha512", "digest": executorHash, "member": "package/bin/opencode"]]
        ]])
        let manifest = try JSONDecoder().decode(ManagedRuntimeManifest.self, from: manifestData)
        let userA = root.appendingPathComponent("User A/Runtime"), userB = root.appendingPathComponent("用户 B/Runtime")
        let fetcher = FixtureRuntimeFetcher(node: node, executor: executor)
        let installer = ManagedAgentRuntime(root: userA, manifest: manifest, fetcher: fetcher)
        let clean = AgentRuntime(root: userA, searchPaths: [], desktopApplications: [:], homeDirectory: root.appendingPathComponent("Fresh Home"),
                                 inheritedEnvironment: ["PATH": "/usr/bin:/bin"], componentManifest: manifest)
        check(clean.availability(of: .workbuddy, customPath: "") == .accountSetup && clean.availability(of: .qwenwork, customPath: "") == .accountSetup,
              "Fresh users can connect both account providers without any installed desktop app or CLI")
        check(clean.command(for: .workbuddy, customPath: "") == nil, "Unprepared components are never advertised as ready")
        async let first = installer.prepare()
        async let second = installer.prepare()
        let (a, b) = try await (first, second)
        let initialFetches = await fetcher.count()
        check(a == b && initialFetches == 2, "Concurrent setup downloads one copy of each verified component")
        check(fm.fileExists(atPath: a.appendingPathComponent("LICENSE.node").path), "Downloaded runtime retains its license")
        for agent in [ClipAgent.workbuddy, .qwenwork] {
            let command = clean.command(for: agent, customPath: "")
            check(command?.executable == a.appendingPathComponent("node") && command?.arguments.contains(a.appendingPathComponent("opencode").path) == true,
                  "\(agent.rawValue) uses the managed runtime in paths containing Unicode and spaces")
            check(command?.accountContext?.scope == userA.deletingLastPathComponent(), "\(agent.rawValue) credentials remain scoped to this user's library")
        }
        _ = try await installer.prepare()
        check(await fetcher.count() == 2, "Reconnect reuses prepared components without another download")
        check(ManagedAgentRuntime.readyDirectory(root: userB, manifest: manifest) == nil, "Another user's library does not inherit readiness or account state")
        try Data("corrupted".utf8).write(to: a.appendingPathComponent("node"))
        check(ManagedAgentRuntime.readyDirectory(root: userA, manifest: manifest) == nil, "A damaged executable invalidates readiness")
        _ = try await installer.prepare()
        check(ManagedAgentRuntime.readyDirectory(root: userA, manifest: manifest) != nil, "Retry repairs only the managed component directory")
        let broken = root.appendingPathComponent("broken.tgz")
        try Data("corrupted download".utf8).write(to: broken)
        do { try ManagedAgentRuntime.verify(broken, asset: manifest.platforms[0].node); check(false, "Corrupt archive must fail") }
        catch { check(true, "Checksum failure stops installation before extraction or execution") }
        let failing = FixtureRuntimeFetcher(node: node, executor: executor)
        await failing.setFailure(true)
        let retry = ManagedAgentRuntime(root: userB, manifest: manifest, fetcher: failing)
        do { _ = try await retry.prepare(); check(false, "Interrupted setup must fail") }
        catch { check(ManagedAgentRuntime.readyDirectory(root: userB, manifest: manifest) == nil, "Interrupted setup never produces a ready receipt") }
        await failing.setFailure(false)
        _ = try await retry.prepare()
        check(ManagedAgentRuntime.readyDirectory(root: userB, manifest: manifest) != nil, "Offline failure can be retried successfully")
        let env = ACPCommand.accountEnvironment(inheriting: ["NODE_OPTIONS": "untrusted module", "OPENCODE_CONFIG": "/someone/config",
            "OPENAI_API_KEY": "someone-else", "HTTPS_PROXY": "https://proxy.example", "HOME": "/different/user"])
        check(env["NODE_OPTIONS"] == nil && env["OPENCODE_CONFIG"] == nil && env["OPENAI_API_KEY"] == nil && env["HTTPS_PROXY"] != nil,
              "Account connections discard unrelated provider credentials and injected runtime options")
        let bundled = try ManagedRuntimeManifest.load()
        check(Set(bundled.platforms.map(\.architecture)) == ["arm64", "x86_64"], "The release manifest supports Apple Silicon and Intel")
        print("Managed runtime checks: \(failures) failure(s)")
        if failures > 0 { exit(1) }
    }
}
