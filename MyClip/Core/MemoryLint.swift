import Foundation

/// Soft checks over the Memory vault. Findings are handed to the next organizing run rather than blocking a write,
/// because the agent edits files directly and the rules need judgement to apply.
public struct MemoryLintReport: Sendable, Equatable {
    public var brokenLinks: [String] = []
    public var unlinkedMentions: [String] = []
    public var candidateEntities: [String] = []
    public var oversized: [String] = []
    public var invalidFiles: [String] = []
    /// Pages close to the hard body cap. Writes past the cap are rolled back, so these must be split before anything is appended.
    public var mustSplit: [String] = []

    public var isEmpty: Bool { brokenLinks.isEmpty && unlinkedMentions.isEmpty && candidateEntities.isEmpty && oversized.isEmpty && invalidFiles.isEmpty && mustSplit.isEmpty }

    /// Instructions the next run has to follow before writing, unlike the soft `lines`.
    public var mandatoryLines: [String] {
        mustSplit.map { "\($0) 接近 \(MemoryDocument.maxBodyBytes / 1000) KB 上限：先整理，把对话经过移入对应日期的 Daily 并互链，页面按固定结构只留当前状态、已确认决定、关键背景；整理后仍超过 \(MemoryDocument.maxBodyBytes * 3 / 4 / 1000) KB 再按主题拆分" }
    }

    /// Lines for the organizing prompt's handoff record.
    public var lines: [String] {
        var result: [String] = []
        if !brokenLinks.isEmpty { result.append("断链（目标不存在，需修正或建页）：" + brokenLinks.joined(separator: "；")) }
        if !unlinkedMentions.isEmpty { result.append("提到已有页面但未加链接：" + unlinkedMentions.joined(separator: "；")) }
        if !candidateEntities.isEmpty { result.append("多处提到但没有页面的名词，考虑建 Wiki 页或 Inbox 条目：" + candidateEntities.joined(separator: "、")) }
        if !oversized.isEmpty { result.append("过长文件（先整理再追加：把对话经过移入对应 Daily 并互链，页面按固定结构只留当前结论）：" + oversized.joined(separator: "；")) }
        if !invalidFiles.isEmpty { result.append("无效文件（未被索引，需修复到 \(MemoryDocument.maxBodyBytes / 1000) KB 以内且正文非空）：" + invalidFiles.joined(separator: "；")) }
        return result
    }
}

public enum MemoryLint {
    static let nowLimit = 6_000
    static let projectLimit = 12_000
    static let minimumEntityFiles = 3
    static let stopWords: Set<String> = ["github", "readme", "api", "mcp", "json", "macos", "ios", "codex", "chatgpt", "claude", "ocr", "uuid", "url", "http", "https", "png", "markdown", "wiki", "daily", "inbox", "memory", "profile", "now", "projects", "topics", "workflows", "archives", "imessage", "wechat", "utc", "iso", "cli", "sdk", "gif", "pdf", "html", "css", "swift", "python", "bash", "true", "false", "null", "todo", "doing", "done", "agent", "agents", "id", "ids", "md", "arm", "intel", "action", "actions", "key", "keys", "openrouter"]

    static func isNameLike(_ title: String) -> Bool {
        let latin = title.range(of: #"^[A-Za-z][A-Za-z0-9_.-]{2,}$"#, options: .regularExpression) != nil
        let cjk = title.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } && (2...12).contains(title.count) && !title.contains(" ")
        return latin || cjk
    }

    static func mentions(_ body: String, name: String) -> Bool {
        if name.unicodeScalars.allSatisfy({ $0.isASCII }) {
            let pattern = "(?i)(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9_])"
            return body.range(of: pattern, options: .regularExpression) != nil
        }
        return body.range(of: name, options: .caseInsensitive) != nil
    }

    static func identifiers(in body: String) -> Set<String> {
        var text = body
        for pattern in ["(?ms)^ {0,3}(`{3,}|~{3,})[^\\n]*\\n.*?(?:^ {0,3}\\1[ \\t]*(?:\\n|$)|\\z)", "`+[^`\\n]*`+", #"\[\[[^\]\n]+\]\]"#, #"https?://\S+"#] {
            text = (try? NSRegularExpression(pattern: pattern))?.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ") ?? text
        }
        let expression = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_-])[A-Za-z][A-Za-z0-9_-]{2,}(?![A-Za-z0-9_-])"#)
        var result = Set<String>()
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let word = String(text[range])
            // Plain lowercase words are vocabulary; names carry capitals, digits or hyphens.
            guard word != word.lowercased() || word.contains("-") || word.rangeOfCharacter(from: .decimalDigits) != nil,
                  UUID(uuidString: word) == nil, !stopWords.contains(word.lowercased()) else { continue }
            result.insert(word)
        }
        return result
    }
}

extension LibraryStore {
    /// Runs the vault checks. Archives are ignored; root files are checked for size only.
    public func memoryLint() throws -> MemoryLintReport {
        var report = MemoryLintReport()
        let entries = try database.run("SELECT * FROM entries").map(entry).filter { !$0.relativePath.hasPrefix(Self.archivePrefix) }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

        var broken: [String: [String]] = [:]
        for row in try database.run("SELECT source,target,fragment FROM memory_links WHERE target_id IS NULL") {
            guard let source = row["source"].flatMap(UUID.init(uuidString:)), let path = byID[source]?.relativePath, let target = row["target"] else { continue }
            let written = (row["fragment"] ?? "").isEmpty ? target : target + "#" + row["fragment"]!
            if !(broken[written]?.contains(path) ?? false) { broken[written, default: []].append(path) }
        }
        report.brokenLinks = broken.sorted { $0.key < $1.key }.prefix(10).map { "\($0.key) ← \($0.value.sorted().prefix(3).joined(separator: ", "))" }

        var linked: [UUID: Set<UUID>] = [:]
        for row in try database.run("SELECT source,target_id FROM memory_links WHERE target_id IS NOT NULL") {
            if let source = row["source"].flatMap(UUID.init(uuidString:)), let target = row["target_id"].flatMap(UUID.init(uuidString:)) { linked[source, default: []].insert(target) }
        }
        var known = Set<String>()
        for item in entries {
            known.insert(item.title.lowercased())
            known.insert((item.relativePath as NSString).lastPathComponent.dropLast(3).lowercased())
        }
        for alias in try database.run("SELECT target FROM memory_aliases").compactMap({ $0["target"] }) {
            known.insert(((alias as NSString).lastPathComponent.dropLast(3)).lowercased())
        }

        var unlinked: [(name: String, paths: [String])] = []
        for page in entries where !page.isRootDocument && page.relativePath.hasPrefix("Wiki/") && MemoryLint.isNameLike(page.title) {
            let paths = entries.filter { other in
                other.id != page.id && !other.isRootDocument && !(linked[other.id]?.contains(page.id) ?? false) && MemoryLint.mentions(other.body, name: page.title)
            }.map(\.relativePath).sorted()
            if !paths.isEmpty { unlinked.append((page.title, paths)) }
        }
        report.unlinkedMentions = unlinked.sorted { $0.paths.count == $1.paths.count ? $0.name < $1.name : $0.paths.count > $1.paths.count }.prefix(10)
            .map { "\($0.name) ← \($0.paths.prefix(3).joined(separator: ", "))" + ($0.paths.count > 3 ? " 等 \($0.paths.count) 处" : "") }

        var counts: [String: Set<UUID>] = [:], spelling: [String: String] = [:]
        for item in entries where !item.isRootDocument {
            for word in MemoryLint.identifiers(in: item.body) where !known.contains(word.lowercased()) {
                counts[word.lowercased(), default: []].insert(item.id)
                spelling[word.lowercased()] = spelling[word.lowercased()] ?? word
            }
        }
        report.candidateEntities = counts.filter { $0.value.count >= MemoryLint.minimumEntityFiles }
            .sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }.prefix(10)
            .map { "\(spelling[$0.key] ?? $0.key)（\($0.value.count) 个文件）" }

        for item in entries {
            let limit = item.relativePath == "Now.md" ? MemoryLint.nowLimit : item.relativePath.hasPrefix("Wiki/Projects/") ? MemoryLint.projectLimit : Int.max
            if item.body.utf8.count > MemoryDocument.maxBodyBytes * 3 / 4 {
                report.mustSplit.append("\(item.relativePath)（\(item.body.utf8.count / 1000) KB）")
            } else if item.body.count > limit {
                report.oversized.append("\(item.relativePath)（\(item.body.count) 字）")
            }
        }
        report.oversized.sort()
        report.mustSplit.sort()
        report.invalidFiles = try MemoryLayout.scan(in: root.appendingPathComponent("Memory")).invalid.map(\.description)
        return report
    }
}
