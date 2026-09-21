import Foundation

enum OrganizationHandoff {
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

extension LibraryStore {
    public func organizationHandoff() throws -> String? {
        try database.run("SELECT value FROM vault_meta WHERE key='organization_handoff'").first?["value"]
    }
}
