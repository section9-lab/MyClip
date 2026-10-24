import Foundation

/// Serializes mutations per destination; checkpoints every successful remote operation for resumable syncs.
public actor CloudSyncEngine {
    private let store: LibraryStore
    private let credentials: any CloudCredentialStorage
    private let http: CloudHTTP
    private var busy: Set<CloudSyncProvider> = []

    public init(store: LibraryStore, credentials: (any CloudCredentialStorage)? = nil,
                transport: any CloudHTTPTransport = CloudURLSessionTransport(), notionDelay: Duration = .milliseconds(350)) {
        self.store = store
        self.credentials = credentials ?? CloudKeychain(libraryRoot: store.root)
        http = CloudHTTP(transport: transport, notionDelay: notionDelay)
    }

    public func targets() async throws -> [CloudSyncTarget] { try await store.cloudSyncTargets() }

    public func connectGoogle(_ credential: CloudCredential, folder: String = "") async throws -> CloudSyncTarget {
        try begin(.googleDrive); defer { busy.remove(.googleDrive) }
        guard credential.googleClient != nil, credential.refreshToken != nil else {
            throw CloudSyncError.message(String(localized: "Google 未返回离线授权，请重新连接并完成授权。"))
        }
        let parent = try GoogleDriveMemoryStore.folderID(folder)
        let account = try await GoogleDriveMemoryStore(http: http, token: credential.accessToken).account(parent: parent)
        return try await saveConnection(.googleDrive, credential: credential, parent: parent,
                                        account: (account.id + ":" + (credential.googleClient?.clientID ?? ""), account.name))
    }

    public func connectNotion(token: String, page: String) async throws -> CloudSyncTarget {
        try begin(.notion); defer { busy.remove(.notion) }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw CloudSyncError.message(String(localized: "请输入有效的 Notion 集成令牌。"))
        }
        let parent = try NotionMemoryStore.pageID(page)
        let account = try await NotionMemoryStore(http: http, token: token).account(parent: parent)
        return try await saveConnection(.notion, credential: CloudCredential(accessToken: token), parent: parent, account: account)
    }

    public func setOptions(_ options: CloudSyncOptions, for provider: CloudSyncProvider) async throws -> CloudSyncTarget {
        try begin(provider); defer { busy.remove(provider) }
        var target = try await target(provider)
        target.options = options
        try await store.saveCloudSyncTarget(target)
        return target
    }

    public func disconnect(_ provider: CloudSyncProvider) async throws -> CloudSyncTarget {
        try begin(provider); defer { busy.remove(provider) }
        var target = try await target(provider)
        // Keep non-secret remote IDs so reconnecting the same account can resume without orphaning copies.
        target.connected = false
        try await store.saveCloudSyncTarget(target)
        try await credentials.remove(provider)
        return target
    }

    public func sync(_ provider: CloudSyncProvider, progress: @Sendable (String) async -> Void = { _ in }) async throws -> CloudSyncTarget {
        try begin(provider); defer { busy.remove(provider) }
        var target = try await target(provider)
        guard target.connected else { throw CloudSyncError.message(String(localized: "请先连接云端账号。")) }
        let credential = try await activeCredential(provider)
        let remote: any CloudRemoteStore = provider == .googleDrive
            ? GoogleDriveMemoryStore(http: http, token: credential.accessToken)
            : NotionMemoryStore(http: http, token: credential.accessToken)
        let entries = try await store.cloudMemoryEntries()
        let snapshot = CloudMemorySnapshot(entries: entries, options: target.options)
        guard !snapshot.documents.isEmpty || !target.items.isEmpty else {
            throw CloudSyncError.message(String(localized: "还没有可同步的记忆。整理或编辑 Memory 后再试。"))
        }
        let libraryID = try await store.cloudSyncLibraryID()
        await progress(String(localized: "正在检查云端位置…"))
        let root = try await remote.root(parent: target.parentID, existing: target.rootID, libraryID: libraryID)
        target.rootID = root.id; target.rootURL = root.url
        try await store.saveCloudSyncTarget(target)
        let existing = try await remote.list(root: root.id, libraryID: libraryID)
        let existingIDs = Set(existing.map(\.id))
        // Listing can lag just-completed writes. Confirm missing IDs individually before recreating them.
        for (id, item) in target.items where !existingIDs.contains(item.remoteID) {
            if try await !remote.exists(item) { target.items.removeValue(forKey: id) }
        }

        // Reconcile an uncertain create before issuing another POST. Notion child-page names are unique paths
        // inside the app-owned root; Drive uses private appProperties with library and memory IDs.
        for document in snapshot.documents where target.items[document.id] == nil {
            let matches = existing.filter { provider == .googleDrive ? $0.key == document.id : $0.name == document.path }
            guard matches.count <= 1 else { throw CloudSyncError.message(String(localized: "发现重复的云端记忆，请保留一份后重试：\(document.path)")) }
            if let match = matches.first {
                try await remote.verify(match, document: document)
                target.items[document.id] = CloudSyncItem(remoteID: match.id, url: match.url, path: document.path)
            }
        }
        try await store.saveCloudSyncTarget(target)
        // Allocate links before rendering, including documents that refer to pages created later in this run.
        for document in snapshot.documents where target.items[document.id] == nil {
            try Task.checkCancellation()
            await progress(String(localized: "正在创建：\(document.path)"))
            let item = try await remote.create(document, root: root.id, libraryID: libraryID)
            target.items[document.id] = CloudSyncItem(remoteID: item.id, url: item.url, path: document.path)
            try await store.saveCloudSyncTarget(target)
        }
        for (index, document) in snapshot.documents.enumerated() {
            try Task.checkCancellation()
            guard var item = target.items[document.id] else { continue }
            let markdown = "MyClip memory ID: " + document.id + "\n\n" + snapshot.rendered(document, items: target.items)
            let renderedHash = CloudMemoryDocument.hash(markdown)
            if item.sourceHash != document.sourceHash || item.renderedHash != renderedHash {
                await progress(String(localized: "正在同步 \(index + 1)/\(snapshot.documents.count)：\(document.path)"))
                try await remote.update(document, item: item, markdown: markdown)
                item.path = document.path; item.sourceHash = document.sourceHash; item.renderedHash = renderedHash
                target.items[document.id] = item
                try await store.saveCloudSyncTarget(target)
            }
        }
        let current = Set(snapshot.documents.map(\.id))
        for (id, item) in target.items.sorted(by: { $0.key < $1.key }) where !current.contains(id) {
            try Task.checkCancellation()
            await progress(String(localized: "正在移除旧副本：\(item.path)"))
            try await remote.remove(item)
            target.items.removeValue(forKey: id)
            try await store.saveCloudSyncTarget(target)
        }
        target.lastSyncedAt = Date()
        try await store.saveCloudSyncTarget(target)
        return target
    }

    private func begin(_ provider: CloudSyncProvider) throws {
        guard busy.insert(provider).inserted else { throw CloudSyncError.message(String(localized: "此目标正在同步或连接，请稍候。")) }
    }
    private func target(_ provider: CloudSyncProvider) async throws -> CloudSyncTarget {
        guard let target = try await store.cloudSyncTargets().first(where: { $0.provider == provider }) else {
            throw CloudSyncError.message(String(localized: "请先连接云端账号。"))
        }
        return target
    }
    private func saveConnection(_ provider: CloudSyncProvider, credential: CloudCredential, parent: String,
                                account: (id: String, name: String)) async throws -> CloudSyncTarget {
        let old = try await store.cloudSyncTargets().first { $0.provider == provider }
        var target = old.flatMap { $0.accountID == account.id && $0.parentID == parent ? $0 : nil }
            ?? CloudSyncTarget(provider: provider, account: account.name, parentID: parent)
        target.connected = true; target.account = account.name; target.accountID = account.id
        let previousCredential = try await credentials.read(provider)
        try await credentials.save(credential, for: provider)
        do { try await store.saveCloudSyncTarget(target) }
        catch {
            if let previousCredential { try? await credentials.save(previousCredential, for: provider) }
            else { try? await credentials.remove(provider) }
            throw error
        }
        return target
    }
    private func activeCredential(_ provider: CloudSyncProvider) async throws -> CloudCredential {
        guard var credential = try await credentials.read(provider) else { throw CloudSyncError.http(401) }
        if provider == .googleDrive, credential.expiresAt.map({ $0.timeIntervalSinceNow < 120 }) != false {
            guard let client = credential.googleClient, let refresh = credential.refreshToken else { throw CloudSyncError.http(401) }
            var fields = ["client_id": client.clientID, "refresh_token": refresh, "grant_type": "refresh_token"]
            if let secret = client.clientSecret { fields["client_secret"] = secret }
            credential = try await GoogleCloudAuthorization.token(fields: fields, client: client, previousRefresh: refresh, transport: http.transport)
            try await credentials.save(credential, for: provider)
        }
        return credential
    }
}
