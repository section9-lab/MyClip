import Foundation

public enum TaskPrompt {
    /// The task-discovery response contract, quoted into the legacy prompt's own turn
    /// so the organizing agent returns task leads in the same response it edits Memory files in.
    public static var responseContract: String { PromptLibrary.text("shared/task-response-contract") }

    public static func context(tasks: [WorkTask]) -> String {
        let rows = tasks.prefix(200).map { ["taskID": $0.id.uuidString, "title": $0.title, "project": $0.project, "status": $0.status.rawValue, "statusAsOf": ($0.statusObservedAt ?? $0.updatedAt).ISO8601Format()] }
        let json = String(decoding: (try? JSONEncoder().encode(rows)) ?? Data("[]".utf8), as: UTF8.self)
        return PromptLibrary.render("shared/task-context", ["json": json])
    }

    public static func discoveryPrompt(memories: [KnowledgeEntry], tasks: [WorkTask]) -> String {
        let rows = memories.map { ["memoryID": $0.id.uuidString, "path": $0.relativePath, "title": $0.title] }
        let json = String(decoding: (try? JSONEncoder().encode(rows)) ?? Data("[]".utf8), as: UTF8.self)
        return PromptLibrary.render("generation/task-discovery", [
            "context": context(tasks: tasks),
            "memories": json
        ])
    }

    public static func memoryCatalog(_ memories: [KnowledgeEntry]) -> String {
        let rows = memories.map { ["memoryID": $0.id.uuidString, "path": $0.relativePath, "title": $0.title] }
        return PromptLibrary.render("shared/memory-catalog", [
            "json": String(decoding: (try? JSONEncoder().encode(rows)) ?? Data("[]".utf8), as: UTF8.self)
        ])
    }

    public static func repairPrompt(stage: TaskIngestion, captures: [ClipCapture], memories: [KnowledgeEntry], tasks: [WorkTask]) -> String {
        let sources = captures.map {
            PromptLibrary.render("generation/repair-source", [
                "sourceID": $0.id.uuidString,
                "app": $0.appName,
                "date": $0.date.ISO8601Format()
            ])
        }.joined(separator: "\n")
        return PromptLibrary.render("generation/task-repair", [
            "responseContract": responseContract,
            "context": context(tasks: tasks),
            "memoryCatalog": memoryCatalog(memories),
            "sources": sources,
            "error": stage.error ?? PromptLibrary.text("generation/task-repair-default-error"),
            "response": String(stage.response.prefix(64_000))
        ])
    }
}
