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
    /// Browsing records and external posts filed as entities or as items for the user.
    public var misfiled: [String] = []
    /// Current-state passages whose annotated event time has passed.
    public var expired: [String] = []
    /// Files holding what looks like a one-time code or credential; only the kind is named, never the value.
    public var sensitive: [String] = []
    /// Cited screenshot IDs with no capture record, mostly mistyped; they never reach sourceIDs.
    public var unknownCitations: [String] = []
    /// Pages linked from so many others that following their links reaches most of the vault.
    public var hubs: [String] = []
    /// Pages with lines longer than a search snippet shows.
    public var longLines: [String] = []

    public var isEmpty: Bool {
        brokenLinks.isEmpty && unlinkedMentions.isEmpty && candidateEntities.isEmpty && oversized.isEmpty && invalidFiles.isEmpty && mustSplit.isEmpty
            && misfiled.isEmpty && expired.isEmpty && sensitive.isEmpty && unknownCitations.isEmpty && hubs.isEmpty && longLines.isEmpty
    }

    /// Instructions the next run has to follow before writing, unlike the soft `lines`.
    public var mandatoryLines: [String] {
        invalidFiles.map { "\($0) 无效，未被索引：修到 \(MemoryDocument.maxBodyBytes / 1000) KB 以内且正文非空。过长的先整理，把对话经过移入对应日期的 Daily 并互链，页面只留当前状态、已确认决定、关键背景；仍超过再按主题拆分，新页面写入 Wiki 对应目录并从原页链接" }
            + mustSplit.map { "\($0) 接近 \(MemoryDocument.maxBodyBytes / 1000) KB 上限：先整理，把对话经过移入对应日期的 Daily 并互链，页面按固定结构只留当前状态、已确认决定、关键背景；整理后仍超过 \(MemoryDocument.maxBodyBytes * 3 / 4 / 1000) KB 再按主题拆分" }

    }

    /// Lines for the organizing prompt's handoff record.
    public var lines: [String] {
        var result: [String] = []
        // Stale state and secrets lead: they are wrong now, the rest is structure.
        if !sensitive.isEmpty { result.append("疑似保存了验证码或密钥，改成不含具体值的描述（例如“收到登录验证码”）：" + sensitive.joined(separator: "；")) }
        if !expired.isEmpty { result.append("当前状态里的事件时间已过，按后续证据更新结果，没有证据时移出当前状态，历史保留在对应 Daily 或项目页：" + expired.joined(separator: "；")) }
        if !unknownCitations.isEmpty { result.append("引用了没有记录的截图 ID（多为抄错），核对后改成本批或已有记忆里真实的 ID，找不到依据就删掉该引用：" + unknownCitations.joined(separator: "；")) }
        if !brokenLinks.isEmpty { result.append("断链（目标不存在，需修正或建页）：" + brokenLinks.joined(separator: "；")) }
        if !unlinkedMentions.isEmpty { result.append("提到已有页面但未加链接：" + unlinkedMentions.joined(separator: "；")) }
        if !candidateEntities.isEmpty { result.append("多处提到但没有页面的名词，考虑建 Wiki 页或 Inbox 条目：" + candidateEntities.joined(separator: "、")) }
        if !oversized.isEmpty { result.append("过长文件（先整理再追加：把对话经过移入对应 Daily 并互链，页面按固定结构只留当前结论）：" + oversized.joined(separator: "；")) }
        if !hubs.isEmpty { result.append("被大量页面链接的枢纽页：按工作线拆成子页 Wiki/Projects/名称/主题.md，原页只留概览、当前状态和子页导航，再把各处链接改到最具体的子页或 #小节：" + hubs.joined(separator: "；")) }
        if !longLines.isEmpty { result.append("超过 \(GraphConstants.excerptLimit) 字的行会在检索片段里被截断，拆成每行一件事（不含链接和来源约 120 字以内），链接与来源跟着各自的事实：" + longLines.joined(separator: "；")) }
        if !misfiled.isEmpty { result.append("外部内容或浏览记录放在了实体或待确认目录，移到 Wiki/Reading 并链接其中提到的实体页：" + misfiled.joined(separator: "；")) }
        return result
    }
}

public enum MemoryLint {
    static let nowLimit = 6_000
    static let reportLimit = 10
    /// Title endings that name a reading or browsing event rather than the thing itself.
    static let readingSuffixes = ["浏览", "帖文", "帖子", "报道", "视频", "视频片段", "说法", "文章", "访谈", "照片", "截图", "推文",
                                  " post", " article", " video", " thread", " tweet"]
    static let sensitivePatterns: [(kind: String, pattern: String)] = [
        ("验证码", #"(?i)(?:验证码|校验码|动态码|verification code|one-time code|\botp\b|passcode)[^\n\d`]{0,12}(?<![0-9A-Za-z-])\d{4,8}(?![0-9A-Za-z-])"#),
        ("密钥", #"(?<![A-Za-z0-9])(?:sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35})"#)
    ]

    static func isReadingTitle(_ title: String) -> Bool {
        // A trailing part number such as “（四）” does not change what the page is about.
        let stem = title.replacingOccurrences(of: #"\s*(?:（[^）]*）|\([^)]*\))\s*$"#, with: "", options: .regularExpression).lowercased()
        return readingSuffixes.contains { stem.hasSuffix($0) }
    }

    static func sensitiveKinds(in body: String) -> [String] {
        sensitivePatterns.filter { body.range(of: $0.pattern, options: .regularExpression) != nil }.map(\.kind)
    }

    /// Passages with a past event inside a page's current state: all of Now.md, and the “当前状态” section of project pages.
    /// Only cited event annotations count, the same ones event-time search indexes.
    static func expiredPassages(_ body: String, path: String, sourceIDs: [UUID], now: Date) -> [String] {
        guard path == "Now.md" || path.hasPrefix("Wiki/Projects/") else { return [] }
        var headings: [(offset: Int, title: String)] = [], offset = 0
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") { headings.append((offset, line.dropFirst(3).trimmingCharacters(in: .whitespaces))) }
            offset += line.count + 1
        }
        return MemoryPassage.parse(body, sourceIDs: sourceIDs).compactMap { passage in
            guard let event = passage.eventTime, event.end < now else { return nil }
            let section = headings.last { $0.offset <= passage.startOffset }?.title ?? ""
            guard path == "Now.md" || section.hasPrefix("当前状态") else { return nil }
            return String(passage.text.split(separator: "\n").first { !$0.hasPrefix("<!--") }?.prefix(40) ?? "")
        }
    }
    static let projectLimit = 12_000
    /// Distinct linking pages that make a page a hub. In the vault this was written against, two project pages were linked
    /// from 29 and 22 pages (archives and root files not counted) and no other page from more than 14.
    static let hubPages = 20

    /// Lines a snippet would cut, counted as shown: without citations and with links as their labels. Code blocks are skipped.
    static func longLineCount(_ body: String) -> Int {
        var fenced = false, count = 0
        for line in body.split(separator: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle(); continue }
            if !fenced && KnowledgeEntry.displayed(line).count > GraphConstants.excerptLimit { count += 1 }
        }
        return count
    }
    static let minimumEntityFiles = 3
    static let stopWords: Set<String> = ["github", "readme", "api", "mcp", "json", "macos", "ios", "codex", "chatgpt", "claude", "ocr", "uuid", "url", "http", "https", "png", "markdown", "wiki", "daily", "inbox", "memory", "profile", "now", "projects", "topics", "workflows", "archives", "imessage", "wechat", "utc", "iso", "cli", "sdk", "gif", "pdf", "html", "css", "swift", "python", "bash", "true", "false", "null", "todo", "doing", "done", "agent", "agents", "id", "ids", "md", "arm", "intel", "action", "actions", "key", "keys", "openrouter",
                                                  // Halves of product names (“Claude Code”, “Chat Bridge”) and generic interface words.
                                                  "code", "app", "apple", "chat", "bridge", "logo", "mac", "demo", "ui"]

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
    public func memoryLint(now: Date = Date()) throws -> MemoryLintReport {
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
        for item in entries { item.aliases.forEach { known.insert($0.lowercased()) } }

        var unlinked: [(name: String, paths: [String])] = []
        for page in entries where !page.isRootDocument && page.relativePath.hasPrefix("Wiki/") {
            // Declared aliases are names too: a page mentioning "代理客户端协议" without linking the ACP page is reported.
            let names = ([page.title] + page.aliases).filter(MemoryLint.isNameLike)
            guard !names.isEmpty else { continue }
            let paths = entries.filter { other in
                other.id != page.id && !other.isRootDocument && !(linked[other.id]?.contains(page.id) ?? false)
                    && names.contains { MemoryLint.mentions(other.body, name: $0) }
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
        report.misfiled = entries.filter { ($0.relativePath.hasPrefix("Wiki/Topics/") || $0.relativePath.hasPrefix("Inbox/")) && MemoryLint.isReadingTitle($0.title) }
            .map(\.relativePath).sorted().prefix(MemoryLint.reportLimit).map { $0 }
        report.expired = entries.flatMap { item in MemoryLint.expiredPassages(item.body, path: item.relativePath, sourceIDs: item.sourceIDs, now: now).map { "\(item.relativePath)「\($0)」" } }
            .prefix(MemoryLint.reportLimit).map { $0 }
        report.sensitive = entries.compactMap { item in
            let kinds = MemoryLint.sensitiveKinds(in: item.body)
            return kinds.isEmpty ? nil : "\(item.relativePath)（\(kinds.joined(separator: "、"))）"
        }.sorted().prefix(MemoryLint.reportLimit).map { $0 }
        // A library without capture records (imported or test vaults) has nothing to check citations against.
        if try !database.run("SELECT 1 FROM captures LIMIT 1").isEmpty {
            let recorded = Set(try database.run("SELECT id FROM captures").compactMap { $0["id"].flatMap(UUID.init(uuidString:)) })
            report.unknownCitations = entries.compactMap { item in
                let unknown = MemoryPassage.explicitSources(in: item.body).filter { !recorded.contains($0) }
                return unknown.isEmpty ? nil : "\(item.relativePath)（" + unknown.map { "`\($0.uuidString)`" }.joined(separator: "、") + "）"
            }.sorted().prefix(MemoryLint.reportLimit).map { $0 }
        }
        var linking: [UUID: Set<UUID>] = [:]
        for (source, targets) in linked where byID[source].map({ !$0.isRootDocument }) ?? false {
            targets.filter { $0 != source }.forEach { linking[$0, default: []].insert(source) }
        }
        report.hubs = entries.compactMap { item -> (String, Int)? in
            guard !item.isRootDocument else { return nil }
            // Its own sub-pages link back for navigation; that is the structure a split is meant to produce.
            let children = String(item.relativePath.dropLast(3)) + "/"
            let count = (linking[item.id] ?? []).filter { !(byID[$0]?.relativePath.hasPrefix(children) ?? true) }.count
            return count >= MemoryLint.hubPages ? (item.relativePath, count) : nil
        }.sorted { $0.1 > $1.1 }.prefix(MemoryLint.reportLimit).map { "\($0.0)（\($0.1) 个页面链接）" }
        report.longLines = entries.filter { !$0.isRootDocument }.compactMap { item -> (String, Int)? in
            let count = MemoryLint.longLineCount(item.body)
            return count > 0 ? (item.relativePath, count) : nil
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(MemoryLint.reportLimit).map { "\($0.0)（\($0.1) 行）" }
        report.invalidFiles = try MemoryLayout.scan(in: root.appendingPathComponent("Memory")).invalid.map(\.description)
        return report
    }
}
