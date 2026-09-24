import Foundation

enum HandoffPrompt {
    static let limit = 6_000

    static func make(job: ClipJob, captures: [ClipCapture], changedPaths: [String], deletedCount: Int, completedAt: Date,
                     lint: MemoryLintReport = MemoryLintReport(), rolledBack: [String] = []) -> String {
        var lines = ["上一批已成功保存", "jobID=\(job.id.uuidString) · agent=\(job.agent.rawValue)",
            "完成时间：\(completedAt.ISO8601Format())"]
        if let start = captures.map(\.date).min(), let end = captures.map(\.date).max() {
            lines.append("资料时间：\(start.ISO8601Format()) 至 \(end.ISO8601Format())")
        }
        lines.append("sourceIDs：" + job.sourceIDs.map(\.uuidString).joined(separator: ", "))
        lines.append("结果：更新 \(changedPaths.count) 个文件，删除 \(deletedCount) 个文件。以磁盘现状为准。")
        var result = lines.joined(separator: "\n")
        for path in changedPaths.sorted() {
            let line = "\n更新：\(path)"
            guard result.utf8.count + line.utf8.count <= 4_000 else {
                result += "\n其余文件路径已省略。"
                break
            }
            result += line
        }
        // Cap problems are the agent's to fix, never the user's: the instruction travels with the handoff until the page is split.
        let mandatory = rolledBack.map { "上一批写入 \($0) 超过上限，已恢复上一版；先整理该页（对话经过移入 Daily，只留结论），仍然过长再按主题拆分，然后根据上面的 sourceIDs 补写相关内容" } + lint.mandatoryLines
        if !mandatory.isEmpty {
            result += "\n必须先处理（否则写入会被回退）："
            for line in mandatory {
                let text = "\n- " + line
                guard result.utf8.count + text.utf8.count <= limit else { break }
                result += text
            }
        }
        // Vault checks ride along so the next run can repair structure while it has the files open.
        if !lint.isEmpty {
            result += "\n整理提示（软性检查，按需处理，不要为此改写无关内容）："
            for line in lint.lines {
                let text = "\n- " + line
                guard result.utf8.count + text.utf8.count <= limit else {
                    result += "\n- 其余提示已省略。"
                    break
                }
                result += text
            }
        }
        return result
    }
}

// Diagnostic data stays in MemoryLintReport; wording for the next Agent run lives with the prompts.
extension MemoryLintReport {
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
