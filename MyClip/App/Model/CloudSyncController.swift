import Foundation
import Combine
import MyClipCore

@MainActor
final class CloudSyncController: ObservableObject {
    @Published private(set) var targets: [CloudSyncTarget] = []
    @Published private(set) var operations: [CloudSyncProvider: String] = [:]
    @Published private(set) var errors: [CloudSyncProvider: String] = [:]
    @Published private(set) var loaded = false
    @Published private(set) var loadError: String?
    @Published private(set) var entries: [KnowledgeEntry] = []
    @Published private(set) var syncing: Set<CloudSyncProvider> = []
    let preview: Bool
    private let engine: CloudSyncEngine
    private let oauth = GoogleCloudOAuth()
    private var starting = false
    private var stopped = false
    private var debounce: Task<Void, Never>?
    private var tasks: [CloudSyncProvider: Task<Void, Never>] = [:]
    private var retryAt: [CloudSyncProvider: Date] = [:]
    private var failures: [CloudSyncProvider: Int] = [:]
    private var entrySignature = ""
    private var snapshots: [CloudSyncProvider: CloudMemorySnapshot] = [:]

    init(store: LibraryStore, preview: Bool, engine: CloudSyncEngine? = nil) {
        self.preview = preview
        self.engine = engine ?? CloudSyncEngine(store: store)
    }
    func start() {
        stopped = false
        if loaded { scheduleAutomatic(); return }
        guard !starting else { return }
        starting = true
        Task {
            defer { starting = false }
            do { try await reload(); loaded = true; loadError = nil; scheduleAutomatic() }
            catch { loadError = error.localizedDescription }
        }
    }
    func stop() {
        stopped = true
        debounce?.cancel(); debounce = nil
        for task in tasks.values { task.cancel() }
        oauth.cancel()
    }
    func observe(_ entries: [KnowledgeEntry]) {
        let signature = entries.map { "\($0.id):\($0.revision):\($0.relativePath)" }.sorted().joined(separator: "\n")
        if signature != entrySignature {
            self.entries = entries; entrySignature = signature; snapshots.removeAll()
        }
        scheduleAutomatic()
    }
    func target(_ provider: CloudSyncProvider) -> CloudSyncTarget? { targets.first { $0.provider == provider } }
    func pending(_ provider: CloudSyncProvider) -> Int {
        guard let target = target(provider) else { return 0 }
        return snapshot(provider).pendingCount(for: target)
    }
    func canSync(_ provider: CloudSyncProvider) -> Bool {
        guard loaded, !preview, operations[provider] == nil, let target = target(provider), target.connected else { return false }
        return !target.items.isEmpty || !snapshot(provider).documents.isEmpty
    }
    func connectGoogle(_ client: GoogleDesktopClient, folder: String) async -> Bool {
        guard !preview, operations[.googleDrive] == nil else { return false }
        operations[.googleDrive] = String(localized: "等待浏览器授权…"); errors[.googleDrive] = nil
        defer { operations[.googleDrive] = nil; scheduleAutomatic() }
        do {
            let credential = try await oauth.authorize(client)
            try Task.checkCancellation()
            operations[.googleDrive] = String(localized: "正在验证 Google Drive…")
            _ = try await engine.connectGoogle(credential, folder: folder)
            try await reload()
            retryAt[.googleDrive] = nil; failures[.googleDrive] = nil
            return true
        } catch is CancellationError { return false }
        catch { errors[.googleDrive] = error.localizedDescription; return false }
    }
    func connectNotion(token: String, page: String) async -> Bool {
        guard !preview, operations[.notion] == nil else { return false }
        operations[.notion] = String(localized: "正在验证 Notion…"); errors[.notion] = nil
        defer { operations[.notion] = nil; scheduleAutomatic() }
        do {
            _ = try await engine.connectNotion(token: token, page: page)
            try await reload()
            retryAt[.notion] = nil; failures[.notion] = nil
            return true
        } catch is CancellationError { return false }
        catch { errors[.notion] = error.localizedDescription; return false }
    }
    func sync(_ provider: CloudSyncProvider) {
        guard canSync(provider) else { return }
        operations[provider] = String(localized: "正在准备同步…"); errors[provider] = nil
        syncing.insert(provider)
        tasks[provider] = Task { [weak self] in
            guard let self else { return }
            defer { operations[provider] = nil; tasks[provider] = nil; syncing.remove(provider); scheduleAutomatic() }
            do {
                _ = try await engine.sync(provider) { [weak self] message in
                    await MainActor.run { self?.operations[provider] = message }
                }
                retryAt[provider] = nil; failures[provider] = nil
            } catch is CancellationError {
                errors[provider] = String(localized: "同步已停止，已完成的进度会保留。")
                retryAt[provider] = Date.distantFuture
            } catch {
                errors[provider] = error.localizedDescription
                let count = min((failures[provider] ?? 0) + 1, 5)
                failures[provider] = count
                retryAt[provider] = Date().addingTimeInterval(min(30 * pow(2, Double(count - 1)), 300))
            }
            do { try await reload() } catch { errors[provider] = error.localizedDescription }
        }
    }
    func syncAll() { for provider in CloudSyncProvider.allCases { sync(provider) } }
    func cancelSync(_ provider: CloudSyncProvider) { tasks[provider]?.cancel() }
    func setOptions(_ options: CloudSyncOptions, for provider: CloudSyncProvider) {
        guard !preview, operations[provider] == nil else { return }
        operations[provider] = String(localized: "正在保存同步设置…")
        tasks[provider] = Task {
            defer { operations[provider] = nil; tasks[provider] = nil; scheduleAutomatic() }
            do {
                _ = try await engine.setOptions(options, for: provider)
                try await reload()
                errors[provider] = nil; retryAt[provider] = nil
            } catch { errors[provider] = error.localizedDescription }
        }
    }
    func disconnect(_ provider: CloudSyncProvider) {
        guard !preview, operations[provider] == nil else { return }
        operations[provider] = String(localized: "正在断开连接…")
        tasks[provider] = Task {
            defer { operations[provider] = nil; tasks[provider] = nil }
            do { _ = try await engine.disconnect(provider); try await reload(); errors[provider] = nil }
            catch { errors[provider] = error.localizedDescription; try? await reload() }
        }
    }
    private func reload() async throws { targets = try await engine.targets(); snapshots.removeAll() }
    private func snapshot(_ provider: CloudSyncProvider) -> CloudMemorySnapshot {
        if let snapshot = snapshots[provider] { return snapshot }
        let snapshot = CloudMemorySnapshot(entries: entries, options: target(provider)?.options ?? CloudSyncOptions())
        snapshots[provider] = snapshot
        return snapshot
    }
    private func scheduleAutomatic() {
        guard loaded, !preview, !stopped, debounce == nil, targets.contains(where: automaticDue) else { return }
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self else { return }
            debounce = nil
            for target in targets where automaticDue(target) { sync(target.provider) }
        }
    }
    private func automaticDue(_ target: CloudSyncTarget) -> Bool {
        target.connected && target.options.automatic && operations[target.provider] == nil
            && (retryAt[target.provider] ?? .distantPast) <= Date() && pending(target.provider) > 0
    }
}
