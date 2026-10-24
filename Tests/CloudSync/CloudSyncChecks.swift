import Foundation
@testable import MyClipCore

actor CloudTestCredentials: CloudCredentialStorage {
    var values: [CloudSyncProvider: CloudCredential] = [:]
    func read(_ provider: CloudSyncProvider) -> CloudCredential? { values[provider] }
    func save(_ credential: CloudCredential, for provider: CloudSyncProvider) { values[provider] = credential }
    func remove(_ provider: CloudSyncProvider) { values.removeValue(forKey: provider) }
}

/// Stateful contract fixture: exercises real request construction, reconciliation and SQLite checkpoints.
actor CloudTestTransport: CloudHTTPTransport {
    struct File: Sendable {
        var id: String
        var name: String
        var parent: String
        var key: String
        var library: String
        var folder: Bool
        var markdown = ""
        var trashed = false
    }
    var files: [String: File] = [:]
    var requests: [URLRequest] = []
    var failUpdateAt: Int?
    var updates = 0
    var uncertainNextDocument = false
    var reject = false
    var warnings = false
    var delay: Duration = .zero
    func failUpdate(_ index: Int?) { failUpdateAt = index }
    func uncertainCreate() { uncertainNextDocument = true }
    func rejectRequests(_ value: Bool) { reject = value }
    func emitWarnings(_ value: Bool) { warnings = value }
    func setDelay(_ value: Duration) { delay = value }
    func allFiles() -> [File] { Array(files.values) }
    func allRequests() -> [URLRequest] { requests }
    func deleteRemote(_ id: String) { files.removeValue(forKey: id) }
    func addUnmanaged(parent: String) { files["unmanaged"] = File(id: "unmanaged", name: "My own page", parent: parent, key: "", library: "", folder: false) }
    func addUnmanagedCopy(_ name: String, parent: String) { files["unmanaged"] = File(id: "unmanaged", name: name, parent: parent, key: "", library: "", folder: false) }

    func send(_ request: URLRequest) async throws -> CloudHTTPResponse {
        requests.append(request)
        if delay != .zero { try await Task.sleep(for: delay) }
        if reject { return response(.null, 403) }
        let url = try cloudUnwrap(request.url)
        let path = url.path
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody.flatMap { try? JSONDecoder().decode(CloudJSON.self, from: $0) } ?? .null
        if url.host == "oauth2.googleapis.com" {
            return response(.object(["access_token": .string("refreshed-test-token"), "expires_in": .number(3600)]))
        }
        if path.hasSuffix("/about") {
            return response(.object(["user": .object(["emailAddress": .string("fixture@example.invalid"), "permissionId": .string("google-user")]),
                                      "importFormats": .object(["text/markdown": .array([.string("application/vnd.google-apps.document")])])]))
        }
        if path == "/v1/users/me" { return response(.object(["id": .string("notion-user"), "bot": .object(["workspace_name": .string("Fixture workspace")])])) }
        let notion = url.host == "api.notion.com"
        if method == "GET", notion, path.contains("/blocks/") {
            let parent = url.pathComponents[3]
            let children = files.values.filter { $0.parent == parent && !$0.trashed }.sorted { $0.id < $1.id }.map { file in
                CloudJSON.object(["id": .string(file.id), "type": .string("child_page"), "child_page": .object(["title": .string(file.name)])])
            }
            return response(.object(["results": .array(children), "has_more": .bool(false)]))
        }
        if method == "GET", !notion, path.hasSuffix("/files") {
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            let parent = String(q.split(separator: "'").dropFirst().first ?? "")
            let result = files.values.filter { $0.parent == parent && !$0.trashed }.map(googleFile)
            return response(.object(["files": .array(result)]))
        }
        if method == "POST", path.hasSuffix(notion ? "/pages" : "/files") {
            let name = notion ? body["properties"]["title"]["title"].array.first?["text"]["content"].string ?? "" : body["name"].string ?? ""
            let parent = notion ? body["parent"]["page_id"].string ?? "" : body["parents"].array.first?.string ?? ""
            let folder = notion ? name.hasPrefix("MyClip Memory · ") : body["mimeType"].string == "application/vnd.google-apps.folder"
            let id = UUID().uuidString.lowercased()
            var file = File(id: id, name: name, parent: parent, key: body["appProperties"]["myclip_id"].string ?? "",
                            library: body["appProperties"]["myclip_library"].string ?? "", folder: folder)
            file.markdown = body["markdown"].string ?? ""
            files[id] = file
            if !folder && uncertainNextDocument { uncertainNextDocument = false; throw URLError(.networkConnectionLost) }
            return response(.object(["id": .string(id), "name": .string(name)]))
        }
        let id = path.hasSuffix("/markdown") ? url.pathComponents.dropLast().last ?? "" : url.lastPathComponent
        if method == "GET" {
            if notion, path.hasSuffix("/markdown"), let file = files[id] { return response(.object(["markdown": .string(file.markdown)])) }
            if let file = files[id] { return response(notion ? .object(["id": .string(id), "in_trash": .bool(file.trashed)]) : googleFile(file)) }
            if notion, id == "12345678-1234-1234-1234-123456789012" { return response(.object(["id": .string(id), "in_trash": .bool(false)])) }
            return response(.null, 404)
        }
        if method == "PATCH", var file = files[id] {
            if path.contains("/upload/") || path.hasSuffix("/markdown") {
                updates += 1
                if updates == failUpdateAt { return response(.null, 400) }
                if notion {
                    file.markdown = body["replace_content"]["new_str"].string ?? ""
                } else {
                    let raw = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                    file.markdown = raw.components(separatedBy: "Content-Type: text/markdown; charset=UTF-8\r\n\r\n").last?.components(separatedBy: "\r\n--myclip-").first ?? ""
                }
                files[id] = file
                return response(.object(["id": .string(id), "warnings": warnings ? .array([.string("fixture warning")]) : .array([])]))
            }
            if body["trashed"].bool || body["in_trash"].bool { file.trashed = true }
            if let name = body["properties"]["title"]["title"].array.first?["text"]["content"].string { file.name = name }
            files[id] = file
            return response(.object(["id": .string(id)]))
        }
        return response(.null, 404)
    }
    private func googleFile(_ file: File) -> CloudJSON {
        .object(["id": .string(file.id), "name": .string(file.name), "trashed": .bool(file.trashed),
                 "mimeType": .string(file.folder ? "application/vnd.google-apps.folder" : "application/vnd.google-apps.document"),
                 "appProperties": .object(["myclip_id": .string(file.key), "myclip_library": .string(file.library)])])
    }
    private func response(_ value: CloudJSON, _ status: Int = 200) -> CloudHTTPResponse {
        CloudHTTPResponse(data: (try? JSONEncoder().encode(value)) ?? Data(), status: status)
    }
}

@MainActor
final class CloudSyncChecks {
    var temporaryRoots: [URL] = []
    func cleanup() { for root in temporaryRoots { try? FileManager.default.removeItem(at: root) } }
    private func fixture() async throws -> (LibraryStore, CloudTestTransport, CloudTestCredentials, CloudSyncEngine) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-CloudTests-" + UUID().uuidString)
        temporaryRoots.append(root)
        let store = try LibraryStore(root: root)
        _ = try await store.snapshot()
        let profile = try await store.readMemory(path: "Profile.md")
        try await store.updateEntry(id: profile.id, title: profile.title, body: "# Profile\n\nI prefer concise replies. See [[Wiki/Topic|the topic]].", expectedRevision: profile.revision)
        try "# Topic\n\nA durable topic. [[Profile|About me]]\n\n`[[Profile]]`".write(to: root.appendingPathComponent("Memory/Wiki/Topic.md"), atomically: true, encoding: .utf8)
        try "# Daily\n\nDaily fixture".write(to: root.appendingPathComponent("Memory/Daily/Day.md"), atomically: true, encoding: .utf8)
        try "# Inbox\n\nUnconfirmed fixture".write(to: root.appendingPathComponent("Memory/Inbox/Pending.md"), atomically: true, encoding: .utf8)
        let transport = CloudTestTransport(), credentials = CloudTestCredentials()
        return (store, transport, credentials, CloudSyncEngine(store: store, credentials: credentials, transport: transport, notionDelay: .zero))
    }
    private func connect(_ provider: CloudSyncProvider, engine: CloudSyncEngine, expires: Date? = nil) async throws {
        if provider == .notion { _ = try await engine.connectNotion(token: "fixture-token", page: "12345678-1234-1234-1234-123456789012") }
        else {
            _ = try await engine.connectGoogle(CloudCredential(accessToken: "fixture-token", refreshToken: "fixture-refresh",
                expiresAt: expires ?? Date().addingTimeInterval(3600), googleClient: GoogleDesktopClient(clientID: "fixture.apps.googleusercontent.com", clientSecret: "fixture-secret")))
        }
    }

    func testExportIsDeterministicScopedAndLinksPointToCloud() async throws {
        let (store, _, _, _) = try await fixture()
        let entries = try await store.cloudMemoryEntries()
        let snapshot = CloudMemorySnapshot(entries: entries, options: CloudSyncOptions())
        try cloudEqual(snapshot.documents.count, 3, "Overview, confirmed profile and topic; seeded roots, Daily and Inbox excluded")
        let items = Dictionary(uniqueKeysWithValues: snapshot.documents.map { ($0.id, CloudSyncItem(remoteID: $0.id, url: "https://example.invalid/" + $0.id, path: $0.path)) })
        let topic = try cloudUnwrap(snapshot.documents.first { $0.path == "Wiki/Topic.md" })
        let rendered = snapshot.rendered(topic, items: items)
        try cloudCheck(rendered.contains("[About me](https://example.invalid/"))
        try cloudCheck(rendered.contains("`[[Profile]]`"), "Code examples must not be rewritten")
        try cloudFalse(rendered.contains(store.root.path))
        try cloudEqual(snapshot.documents.map(\.sourceHash), CloudMemorySnapshot(entries: entries.reversed(), options: CloudSyncOptions()).documents.map(\.sourceHash))
        var options = CloudSyncOptions(); options.includeDaily = true; options.includeInbox = true
        try cloudEqual(CloudMemorySnapshot(entries: entries, options: options).documents.count, 5)
    }

    func testBothDestinationsAreIncrementalAndKeepRemoteIDsAcrossRestart() async throws {
        for provider in CloudSyncProvider.allCases {
            let (store, transport, credentials, engine) = try await fixture()
            try await connect(provider, engine: engine)
            let first = try await engine.sync(provider)
            try cloudEqual(first.items.count, 3)
            let before = await transport.allRequests()
            let reopened = try LibraryStore(root: store.root)
            let next = CloudSyncEngine(store: reopened, credentials: credentials, transport: transport, notionDelay: .zero)
            let second = try await next.sync(provider)
            try cloudEqual(first.items, second.items)
            let after = await transport.allRequests()
            try cloudEqual(after.filter { $0.httpMethod == "POST" }.count, before.filter { $0.httpMethod == "POST" }.count)
            try cloudEqual(after.filter { $0.httpMethod == "PATCH" }.count, before.filter { $0.httpMethod == "PATCH" }.count)
            let snapshot = CloudMemorySnapshot(entries: try await reopened.cloudMemoryEntries(), options: second.options)
            try cloudEqual(snapshot.pendingCount(for: second), 0)
            let rows = try await reopened.cloudSyncTargets()
            let stored = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
            try cloudFalse(stored.contains("fixture-token")); try cloudFalse(stored.contains("fixture-secret"))
        }
    }

    func testEditRenameDeleteAndScopeChangesUpdateOnlyManagedCopies() async throws {
        for provider in CloudSyncProvider.allCases {
            let (store, transport, _, engine) = try await fixture()
            try await connect(provider, engine: engine)
            let first = try await engine.sync(provider)
            await transport.addUnmanaged(parent: try cloudUnwrap(first.rootID))
            let topic = try await store.readMemory(path: "Wiki/Topic.md")
            let originalID = first.items[topic.id.uuidString]?.remoteID
            try await store.moveMemory(topic.id, to: "Wiki/Renamed.md", expectedRevision: topic.revision)
            let renamed = try await engine.sync(provider)
            try cloudEqual(renamed.items[topic.id.uuidString]?.remoteID, originalID)
            try cloudEqual(renamed.items[topic.id.uuidString]?.path, "Wiki/Renamed.md")
            var options = renamed.options; options.includeDaily = true
            _ = try await engine.setOptions(options, for: provider)
            let expanded = try await engine.sync(provider)
            try cloudEqual(expanded.items.count, 4)
            options.includeDaily = false
            _ = try await engine.setOptions(options, for: provider)
            try await store.deleteEntry(id: topic.id)
            let final = try await engine.sync(provider)
            try cloudEqual(final.items.count, 2)
            let files = await transport.allFiles()
            try cloudCheck(files.first { $0.id == originalID }?.trashed == true)
            try cloudFalse(try cloudUnwrap(files.first { $0.id == "unmanaged" }).trashed)
        }
    }

    func testInterruptedWritesResumeWithoutRepeatingCompletedUpdates() async throws {
        let (_, transport, _, engine) = try await fixture()
        try await connect(.notion, engine: engine)
        await transport.failUpdate(2)
        _ = try await expectCloudError { _ = try await engine.sync(.notion) }
        let checkpoint = try await engine.targets()[0]
        try cloudNil(checkpoint.lastSyncedAt)
        try cloudEqual(checkpoint.items.count, 3)
        try cloudEqual(checkpoint.items.values.filter { !$0.sourceHash.isEmpty }.count, 1)
        let createdBefore = await transport.allRequests().filter { $0.httpMethod == "POST" }.count
        let resumed = try await engine.sync(.notion)
        try cloudNotNil(resumed.lastSyncedAt)
        let createdAfter = await transport.allRequests().filter { $0.httpMethod == "POST" }.count
        try cloudEqual(createdBefore, createdAfter)
    }

    func testUncertainCreateIsReconciledBeforeRetryForBothProviders() async throws {
        for provider in CloudSyncProvider.allCases {
            let (_, transport, _, engine) = try await fixture()
            try await connect(provider, engine: engine)
            await transport.uncertainCreate()
            _ = try await expectCloudError { _ = try await engine.sync(provider) }
            let result = try await engine.sync(provider)
            let files = await transport.allFiles().filter { !$0.folder && !$0.trashed }
            try cloudEqual(files.count, result.items.count)
            try cloudEqual(files.count, 3)
        }
    }

    func testRefreshTokenIsRotatedSecurelyAndPreservedWhenNotReturned() async throws {
        let (_, transport, credentials, engine) = try await fixture()
        try await connect(.googleDrive, engine: engine, expires: .distantPast)
        _ = try await engine.sync(.googleDrive)
        let credential = await credentials.read(.googleDrive)
        try cloudEqual(credential?.accessToken, "refreshed-test-token")
        try cloudEqual(credential?.refreshToken, "fixture-refresh")
        let requests = await transport.allRequests()
        let refresh = try cloudUnwrap(requests.first { $0.url?.host == "oauth2.googleapis.com" })
        try cloudCheck(String(decoding: refresh.httpBody ?? Data(), as: UTF8.self).contains("grant_type=refresh_token"))
        try cloudCheck(requests.filter { $0.url?.path.contains("/files") == true }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-test-token" })
    }

    func testDisconnectStopsAccessAndReconnectRetainsIDs() async throws {
        let (_, transport, credentials, engine) = try await fixture()
        try await connect(.notion, engine: engine)
        let first = try await engine.sync(.notion)
        let disconnected = try await engine.disconnect(.notion)
        try cloudFalse(disconnected.connected)
        let removed = await credentials.read(.notion)
        try cloudNil(removed)
        let before = await transport.allRequests().count
        _ = try await expectCloudError { _ = try await engine.sync(.notion) }
        let after = await transport.allRequests().count
        try cloudEqual(before, after)
        try await connect(.notion, engine: engine)
        try cloudEqual(try await engine.sync(.notion).items, first.items)
    }

    func testNotionWarningsAndPermissionFailuresNeverReportSuccess() async throws {
        let (_, transport, _, engine) = try await fixture()
        try await connect(.notion, engine: engine)
        await transport.emitWarnings(true)
        _ = try await expectCloudError { _ = try await engine.sync(.notion) }
        try cloudNil(try await engine.targets()[0].lastSyncedAt)
        await transport.emitWarnings(false)
        await transport.rejectRequests(true)
        let error = try await expectCloudError { _ = try await engine.sync(.notion) }
        try cloudCheck(error.localizedDescription.contains("权限"))
        try cloudNil(try await engine.targets()[0].lastSyncedAt)
    }

    func testOAuthPKCEAndDestinationValidation() throws {
        try cloudEqual(GoogleCloudAuthorization.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let url = GoogleCloudAuthorization.url(client: GoogleDesktopClient(clientID: "fixture.apps.googleusercontent.com"), redirect: URL(string: "http://127.0.0.1:1234/oauth/callback")!, state: "state", verifier: "verifier")
        let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        try cloudEqual(fields.first { $0.name == "scope" }?.value, GoogleCloudAuthorization.scope)
        try cloudEqual(fields.first { $0.name == "code_challenge_method" }?.value, "S256")
        try cloudEqual(try GoogleDriveMemoryStore.folderID("https://drive.google.com/drive/folders/a_b-123"), "a_b-123")
        try cloudThrows(try GoogleDriveMemoryStore.folderID("https://evil.invalid/folders/test"))
        try cloudThrows(try GoogleDriveMemoryStore.folderID("bad' or true"))
        try cloudEqual(try NotionMemoryStore.pageID("https://www.notion.so/Title-12345678123412341234123456789012?x=1"), "12345678-1234-1234-1234-123456789012")
        try cloudThrows(try NotionMemoryStore.pageID("https://evil.invalid/12345678123412341234123456789012"))
        try cloudThrows(try GoogleDesktopClient.decode(Data("{\"web\":{\"client_id\":\"fixture\"}}".utf8)))
    }

    func testMissingRemoteDocumentRepairsLinksWithoutDeletingUnmanagedPages() async throws {
        for provider in CloudSyncProvider.allCases {
            let (store, transport, _, engine) = try await fixture()
            try await connect(provider, engine: engine)
            let first = try await engine.sync(provider)
            let profile = try await store.readMemory(path: "Profile.md")
            let oldID = try cloudUnwrap(first.items[profile.id.uuidString]?.remoteID)
            await transport.deleteRemote(oldID)
            let repaired = try await engine.sync(provider)
            let newID = try cloudUnwrap(repaired.items[profile.id.uuidString]?.remoteID)
            try cloudCheck(newID != oldID)
            let topic = try await store.readMemory(path: "Wiki/Topic.md")
            let topicID = try cloudUnwrap(repaired.items[topic.id.uuidString]?.remoteID)
            let files = await transport.allFiles()
            let content = try cloudUnwrap(files.first { $0.id == topicID }?.markdown)
            try cloudCheck(content.contains(newID.replacingOccurrences(of: provider == .notion ? "-" : "", with: "")))
            try cloudFalse(content.contains(oldID))
        }
    }

    func testUnmanagedSameNameIsNotAdoptedAfterMissingCheckpoint() async throws {
        let (_, transport, _, engine) = try await fixture()
        try await connect(.notion, engine: engine)
        await transport.uncertainCreate()
        _ = try await expectCloudError { _ = try await engine.sync(.notion) }
        let checkpoint = try await engine.targets()[0]
        let files = await transport.allFiles()
        let orphan = try cloudUnwrap(files.first { !$0.folder })
        await transport.deleteRemote(orphan.id)
        await transport.addUnmanagedCopy(orphan.name, parent: try cloudUnwrap(checkpoint.rootID))
        _ = try await expectCloudError { _ = try await engine.sync(.notion) }
        let after = await transport.allFiles()
        try cloudEqual(after.first { $0.id == "unmanaged" }?.markdown, "")
    }

    func testInvalidLocalFileDoesNotUploadAndClearingLibraryRemovesManagedCopies() async throws {
        let (store, transport, _, engine) = try await fixture()
        try await connect(.notion, engine: engine)
        let first = try await engine.sync(.notion)
        let topic = store.root.appendingPathComponent("Memory/Wiki/Topic.md")
        let original = try String(contentsOf: topic, encoding: .utf8)
        try "---\nid: invalid\n---\nBad data".write(to: topic, atomically: true, encoding: .utf8)
        let before = await transport.allRequests().count
        _ = try await expectCloudError { _ = try await engine.sync(.notion) }
        let after = await transport.allRequests().count
        try cloudEqual(before, after)
        try original.write(to: topic, atomically: true, encoding: .utf8)
        let entries = try await store.cloudMemoryEntries()
        for entry in entries {
            if let initial = MemoryLayout.initialBody(for: entry.relativePath) {
                try await store.updateEntry(id: entry.id, title: entry.title, body: initial, expectedRevision: entry.revision)
            } else { try await store.deleteEntry(id: entry.id) }
        }
        let cleared = try await engine.sync(.notion)
        try cloudEqual(cleared.items.count, 0)
        let remote = await transport.allFiles()
        try cloudCheck(remote.filter { first.items.values.map(\.remoteID).contains($0.id) }.allSatisfy(\.trashed))
        try cloudFalse(try cloudUnwrap(remote.first { $0.id == first.rootID }).trashed)
    }
}

struct CloudCheckFailure: Error, CustomStringConvertible {
    let description: String
}
func cloudCheck(_ condition: Bool, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) throws {
    if !condition { throw CloudCheckFailure(description: "\(file):\(line) \(message.isEmpty ? "Check failed" : message)") }
}
func cloudFalse(_ condition: Bool, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) throws { try cloudCheck(!condition, message, file: file, line: line) }
func cloudEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #fileID, line: UInt = #line) throws { try cloudCheck(actual == expected, message.isEmpty ? "Values differ" : message, file: file, line: line) }
func cloudNil<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws { try cloudCheck(value == nil, "Expected nil", file: file, line: line) }
func cloudNotNil<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws { try cloudCheck(value != nil, "Expected a value", file: file, line: line) }
func cloudUnwrap<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else { throw CloudCheckFailure(description: "\(file):\(line) Missing fixture value") }
    return value
}
func cloudThrows<T>(_ value: @autoclosure () throws -> T, file: StaticString = #fileID, line: UInt = #line) throws {
    do { _ = try value() } catch { return }
    throw CloudCheckFailure(description: "\(file):\(line) Expected an error")
}
@MainActor func expectCloudError(_ operation: () async throws -> Void) async throws -> Error {
    do { try await operation() } catch { return error }
    throw CloudCheckFailure(description: "Expected operation to fail")
}

@main struct CloudSyncCheckRunner {
    @MainActor static func main() async throws {
        let checks = CloudSyncChecks()
        defer { checks.cleanup() }
        try await checks.testExportIsDeterministicScopedAndLinksPointToCloud()
        print("PASS testExportIsDeterministicScopedAndLinksPointToCloud")
        try await checks.testBothDestinationsAreIncrementalAndKeepRemoteIDsAcrossRestart()
        print("PASS testBothDestinationsAreIncrementalAndKeepRemoteIDsAcrossRestart")
        try await checks.testEditRenameDeleteAndScopeChangesUpdateOnlyManagedCopies()
        print("PASS testEditRenameDeleteAndScopeChangesUpdateOnlyManagedCopies")
        try await checks.testInterruptedWritesResumeWithoutRepeatingCompletedUpdates()
        print("PASS testInterruptedWritesResumeWithoutRepeatingCompletedUpdates")
        try await checks.testUncertainCreateIsReconciledBeforeRetryForBothProviders()
        print("PASS testUncertainCreateIsReconciledBeforeRetryForBothProviders")
        try await checks.testRefreshTokenIsRotatedSecurelyAndPreservedWhenNotReturned()
        print("PASS testRefreshTokenIsRotatedSecurelyAndPreservedWhenNotReturned")
        try await checks.testDisconnectStopsAccessAndReconnectRetainsIDs()
        print("PASS testDisconnectStopsAccessAndReconnectRetainsIDs")
        try await checks.testNotionWarningsAndPermissionFailuresNeverReportSuccess()
        print("PASS testNotionWarningsAndPermissionFailuresNeverReportSuccess")
        try checks.testOAuthPKCEAndDestinationValidation()
        print("PASS testOAuthPKCEAndDestinationValidation")
        try await checks.testMissingRemoteDocumentRepairsLinksWithoutDeletingUnmanagedPages()
        print("PASS missing remote documents repair incoming links")
        try await checks.testUnmanagedSameNameIsNotAdoptedAfterMissingCheckpoint()
        print("PASS unmanaged same-name pages are never adopted")
        try await checks.testInvalidLocalFileDoesNotUploadAndClearingLibraryRemovesManagedCopies()
        print("PASS invalid files block uploads and empty libraries remove managed copies")
        try await runCloudSyncAppChecks()
        print("Cloud sync checks passed")
    }
}
