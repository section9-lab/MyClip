import Foundation

enum OrganizationHandoff {
    static func make(job: ClipJob, captures: [ClipCapture], changedPaths: [String], deletedCount: Int, completedAt: Date) -> String {
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
        return result
    }
}

extension LibraryStore {
    public func organizationHandoff() throws -> String? {
        try database.run("SELECT value FROM vault_meta WHERE key='organization_handoff'").first?["value"]
    }
}
