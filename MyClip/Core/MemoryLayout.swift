import Foundation

public enum MemoryLayout {
    public static let rootFiles = ["Memory.md", "Profile.md", "Now.md"]
    public static let folders = ["Wiki", "Wiki/Projects", "Wiki/Topics", "Wiki/Workflows", "Daily", "Inbox"]

    public static func initialBody(for path: String) -> String? {
        let templates: [String: String] = [
            "Memory.md": "# Memory\n\n## 关于我\n- [[Profile|个人信息与偏好]]\n- [[Now|当前关注事项]]\n\n## 重要记忆\n主题积累在 Wiki/，每日记录保存在 Daily/。\n\n## 待确认\n待确认内容保存在 Inbox/。\n",
            "Profile.md": "# Profile\n\n## 已确认的信息\n尚未填写。只保存你明确表达或确认的信息。\n\n## 沟通偏好\n\n## 工作方式\n\n## 长期目标\n\n## 最近确认\n",
            "Now.md": "# Now\n\n## 当前项目\n尚未整理。\n\n## 当前问题\n\n## 下一步\n"
        ]
        return templates[path]
    }

    static func defaultPath(id: UUID, title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|[]#%").union(.controlCharacters)
        let name = title.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return "Wiki/\(String(name.isEmpty ? "Memory" : String(name.prefix(60))))--\(id.uuidString.prefix(8)).md"
    }

    static func url(_ path: String, in directory: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.utf8.count <= 768, parts.count <= 12, path.lowercased().hasSuffix(".md"),
              !path.contains("\\"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else {
            throw LibraryError.invalidResult("Memory 路径必须是资料库内的相对 Markdown 路径：\(path)")
        }
        var cursor = directory
        for part in [String?](arrayLiteral: nil) + parts.map({ Optional(String($0)) }) {
            if let part { cursor.appendPathComponent(part) }
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw LibraryError.invalidResult("Memory 路径不能经过符号链接。")
            }
        }
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard cursor.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base) else { throw LibraryError.invalidResult("Memory 路径越界。") }
        return cursor
    }

    static func folderPaths(in directory: URL) throws -> [String] {
        _ = try Self.url("Memory.md", in: directory)
        let base = directory.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { enumerator.skipDescendants(); continue }
            if values.isDirectory == true { paths.append(String(url.standardizedFileURL.path.dropFirst(base.path.count + 1))) }
        }
        return paths.sorted()
    }

    static func markdownFiles(in directory: URL) throws -> [(String, URL)] {
        _ = try Self.url("Memory.md", in: directory)
        let base = directory.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [(String, URL)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw LibraryError.invalidResult("Memory 中不能索引符号链接：\(url.lastPathComponent)") }
            guard values.isRegularFile == true, url.pathExtension.lowercased() == "md" else { continue }
            let path = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(base.path.count + 1))
            _ = try Self.url(path, in: directory)
            result.append((path, url))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    public struct InvalidFile: Equatable, Sendable {
        public let path: String
        public let reason: String
        public var description: String { "\(path)（\(reason)）" }
    }

    /// One unreadable, empty or oversized file is reported rather than failing the whole vault.
    /// Two files claiming one ID still fail: the index could not tell which one is the memory.
    static func scan(in directory: URL) throws -> (documents: [(String, URL, String, MemoryDocument)], invalid: [InvalidFile]) {
        var result: [(String, URL, String, MemoryDocument)] = []
        var invalid: [InvalidFile] = []
        var ids: [UUID: String] = [:]
        for (path, url) in try markdownFiles(in: directory) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { invalid.append(InvalidFile(path: path, reason: "不是 UTF-8 文本。")); continue }
            let document: MemoryDocument
            do { document = try MemoryDocument(text) } catch LibraryError.invalidResult(let reason) {
                // A plain note without MyClip metadata is described by its body problem, not by the missing header.
                var explanation = reason
                if !text.hasPrefix("---\n") {
                    do { try MemoryDocument.validate(title: "", body: text) } catch LibraryError.invalidResult(let bodyReason) { explanation = bodyReason } catch {}
                }
                invalid.append(InvalidFile(path: path, reason: explanation))
                continue
            }
            guard ids.updateValue(path, forKey: document.id) == nil else { throw LibraryError.invalidResult("多个文件使用同一 Memory ID：\(path)") }
            result.append((path, url, text, document))
        }
        return (result.sorted { $0.0 < $1.0 }, invalid.sorted { $0.path < $1.path })
    }
}

extension LibraryStore {
    func draftPath(_ draft: KnowledgeDraft, current: KnowledgeEntry?) throws -> String? {
        guard let path = draft.path else { return current?.relativePath }
        _ = try MemoryLayout.url(path, in: root.appendingPathComponent("Memory"))
        if let current {
            guard path == current.relativePath else { throw LibraryError.invalidResult("更新已有记忆时不能改变文件路径。") }
        } else {
            guard ["Wiki/", "Daily/", "Inbox/"].contains(where: path.hasPrefix) else {
                throw LibraryError.invalidResult("新记忆应放在 Wiki、Daily 或 Inbox 中。")
            }
        }
        return path
    }

    func prepareMemoryLayout() throws {
        guard try database.run("SELECT value FROM vault_meta WHERE key='layout'").isEmpty else { return }
        let directory = root.appendingPathComponent("Memory")
        for folder in MemoryLayout.folders {
            _ = try MemoryLayout.url(folder + "/Memory.md", in: directory)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try database.transaction {
            guard try database.run("SELECT value FROM vault_meta WHERE key='layout'").isEmpty else { return }
            for name in MemoryLayout.rootFiles where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
                let id = UUID()
                _ = try saveEntry(id: id, kind: .memory, title: String(name.dropLast(3)), body: MemoryLayout.initialBody(for: name)!, revision: 1, agent: .codex, sourceIDs: [], relativePath: name)
                if name == "Profile.md" { try database.run("INSERT INTO protected_entries VALUES(?)", [id.uuidString]) }
            }
            try database.run("INSERT INTO vault_meta VALUES('layout','1')")
            // Never move the schema version backwards; a fresh library is already current.
            if (Int(try database.run("PRAGMA user_version").first?["user_version"] ?? "0") ?? 0) < 5 { try database.script("PRAGMA user_version=5") }
        }
    }
}
