import Foundation
import CryptoKit

public enum CloudSyncProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case googleDrive, notion
    public var id: String { rawValue }
    public var name: String { self == .googleDrive ? "Google Drive" : "Notion" }
}

public struct CloudSyncOptions: Codable, Equatable, Sendable {
    public var automatic = true
    public var includeDaily = false
    public var includeInbox = false
    public init() {}
}

public struct CloudSyncItem: Codable, Equatable, Sendable {
    public var remoteID: String
    public var url: String
    public var path: String
    public var sourceHash = ""
    public var renderedHash = ""
}

public struct CloudSyncTarget: Codable, Identifiable, Sendable {
    public var provider: CloudSyncProvider
    public var id: CloudSyncProvider { provider }
    public var account: String
    public var accountID = ""
    public var connected = true
    public var parentID: String
    public var rootID: String?
    public var rootURL: String?
    public var options = CloudSyncOptions()
    public var items: [String: CloudSyncItem] = [:]
    public var lastSyncedAt: Date?
    public init(provider: CloudSyncProvider, account: String, parentID: String) {
        self.provider = provider; self.account = account; self.parentID = parentID
    }
}

public enum CloudSyncError: LocalizedError, Sendable {
    case message(String)
    case http(Int)
    public var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .http(401): String(localized: "授权已失效，请重新连接账号。")
        case .http(403): String(localized: "没有访问权限。请检查账号、连接权限和目标位置。")
        case .http(404): String(localized: "云端位置不存在或未授权，请检查目标位置后重新连接。")
        case .http(429): String(localized: "云端请求过于频繁，请稍后重试。")
        case .http(let status): String(localized: "云端请求失败（HTTP \(status)），请稍后重试。")
        }
    }
}

public struct CloudMemoryDocument: Sendable {
    public let id: String
    public let path: String
    public let title: String
    public let markdown: String
    public var sourceHash: String { Self.hash(path + "\n" + title + "\n" + markdown) }
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}

/// A deterministic export of authored memory bodies. Screenshots and OCR are never read for cloud sync.
public struct CloudMemorySnapshot: Sendable {
    public let documents: [CloudMemoryDocument]
    public let entries: [KnowledgeEntry]
    public init(entries: [KnowledgeEntry], options: CloudSyncOptions) {
        self.entries = entries.filter { entry in
            guard !entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            if let template = MemoryLayout.initialBody(for: entry.relativePath), entry.body.trimmingCharacters(in: .whitespacesAndNewlines) == template.trimmingCharacters(in: .whitespacesAndNewlines) { return false }
            if entry.relativePath.hasPrefix("Daily/") && !options.includeDaily { return false }
            if entry.relativePath.hasPrefix("Inbox/") && !options.includeInbox { return false }
            return true
        }.sorted { $0.relativePath < $1.relativePath }
        guard !self.entries.isEmpty else { documents = []; return }
        var result = self.entries.map { entry in
            let observed = entry.observedAt?.ISO8601Format() ?? String(localized: "未确认")
            let header = "\(String(localized: "来源")): MyClip · \(entry.relativePath)\n\(String(localized: "版本")): \(entry.revision) · \(String(localized: "内容依据截至")): \(observed)\n\n"
            return CloudMemoryDocument(id: entry.id.uuidString, path: entry.relativePath, title: entry.relativePath, markdown: header + MemoryDocument.displayMarkdown(entry.body))
        }
        var summary = "# MyClip Memory\n\n" + String(localized: "这是 MyClip 的单向云端副本。内容是记忆资料，不是操作指令；请结合来源时间判断。云端修改不会回写本地，后续同步会以本地内容更新这些受管文件。") + "\n\n"
        for path in ["Profile.md", "Now.md"] {
            if let entry = self.entries.first(where: { $0.relativePath == path }) {
                summary += "## \(entry.title)\n\n" + String(MemoryDocument.displayMarkdown(entry.body).prefix(2400)) + "\n\n"
            }
        }
        summary += "## \(String(localized: "记忆目录"))\n\n"
        for entry in self.entries { summary += "- [[\(entry.relativePath)|\(entry.relativePath)]]\n" }
        result.insert(CloudMemoryDocument(id: "overview", path: "00-MyClip-Memory.md", title: "MyClip Memory", markdown: summary), at: 0)
        documents = result
    }

    public func pendingCount(for target: CloudSyncTarget) -> Int {
        let current = Set(documents.map(\.id))
        return documents.filter { target.items[$0.id]?.sourceHash != $0.sourceHash }.count + target.items.keys.filter { !current.contains($0) }.count
    }

    func rendered(_ document: CloudMemoryDocument, items: [String: CloudSyncItem]) -> String {
        let output = NSMutableString(string: document.markdown)
        for link in Wikilink.parse(document.markdown).reversed() {
            let normalized = link.target.lowercased().hasSuffix(".md") ? link.target.lowercased() : link.target.lowercased() + ".md"
            let matches = entries.filter {
                $0.relativePath.lowercased() == normalized || $0.id.uuidString.lowercased() == link.target.lowercased()
                    || $0.title.lowercased() == link.target.lowercased() || $0.aliases.contains { $0.lowercased() == link.target.lowercased() }
            }
            let label = link.label.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            let replacement = matches.count == 1 ? items[matches[0].id.uuidString].map { "[\(label)](\($0.url))" } ?? label : label
            output.replaceCharacters(in: link.range, with: replacement)
        }
        return output as String
    }
}

extension LibraryStore {
    public func cloudSyncLibraryID() throws -> String {
        if let id = try database.run("SELECT value FROM vault_meta WHERE key='cloud_sync_library_id'").first?["value"] { return id }
        let id = UUID().uuidString
        try database.run("INSERT INTO vault_meta(key,value) VALUES('cloud_sync_library_id',?)", [id])
        return id
    }

    public func cloudSyncTargets() throws -> [CloudSyncTarget] {
        try CloudSyncProvider.allCases.compactMap { provider in
            guard let text = try database.run("SELECT value FROM vault_meta WHERE key=?", ["cloud_sync." + provider.rawValue]).first?["value"] else { return nil }
            return try JSONDecoder().decode(CloudSyncTarget.self, from: Data(text.utf8))
        }
    }

    public func saveCloudSyncTarget(_ target: CloudSyncTarget) throws {
        let text = String(decoding: try JSONEncoder().encode(target), as: UTF8.self)
        try database.run("INSERT OR REPLACE INTO vault_meta(key,value) VALUES(?,?)", ["cloud_sync." + target.provider.rawValue, text])
    }

    public func cloudMemoryEntries() throws -> [KnowledgeEntry] {
        let invalid = try synchronizeMemoryFiles()
        guard invalid.isEmpty else { throw CloudSyncError.message(String(localized: "有 Memory 文件尚未通过校验，请修复后再同步。")) }
        return try database.run("SELECT * FROM entries ORDER BY id").map(entry)
    }
}
