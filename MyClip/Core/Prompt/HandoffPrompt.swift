import Foundation

enum HandoffPrompt {
    static let limit = 6_000

    static func make(job: ClipJob, captures: [ClipCapture], changedPaths: [String], deletedCount: Int, completedAt: Date,
                     lint: MemoryLintReport = MemoryLintReport(), rolledBack: [String] = []) -> String {
        var result = PromptLibrary.render("handoff/header", [
            "jobID": job.id.uuidString,
            "agent": job.agent.rawValue,
            "completedAt": completedAt.ISO8601Format()
        ])
        if let start = captures.map(\.date).min(), let end = captures.map(\.date).max() {
            result += "\n" + PromptLibrary.render("handoff/range", [
                "start": start.ISO8601Format(),
                "end": end.ISO8601Format()
            ])
        }
        result += "\n" + PromptLibrary.render("handoff/source-ids", [
            "sourceIDs": job.sourceIDs.map(\.uuidString).joined(separator: ", ")
        ])
        result += "\n" + PromptLibrary.render("handoff/result", [
            "changedCount": String(changedPaths.count),
            "deletedCount": String(deletedCount)
        ])
        for path in changedPaths.sorted() {
            let line = "\n" + PromptLibrary.render("handoff/updated", ["path": path])
            guard result.utf8.count + line.utf8.count <= 4_000 else {
                result += "\n" + PromptLibrary.text("handoff/omitted")
                break
            }
            result += line
        }
        // Cap problems are the agent's to fix, never the user's: the instruction travels with the handoff until the page is split.
        let mandatory = rolledBack.map { PromptLibrary.render("handoff/rolled-back", ["path": $0]) } + lint.mandatoryLines
        if !mandatory.isEmpty {
            result += "\n" + PromptLibrary.text("handoff/mandatory-header")
            for line in mandatory {
                let text = "\n" + PromptLibrary.render("handoff/row", ["text": line])
                guard result.utf8.count + text.utf8.count <= limit else { break }
                result += text
            }
        }
        // Vault checks ride along so the next run can repair structure while it has the files open.
        if !lint.isEmpty {
            result += "\n" + PromptLibrary.text("handoff/hints-header")
            for line in lint.lines {
                let text = "\n" + PromptLibrary.render("handoff/row", ["text": line])
                guard result.utf8.count + text.utf8.count <= limit else {
                    result += "\n" + PromptLibrary.text("handoff/hints-omitted")
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
        let maxBodyKB = String(MemoryDocument.maxBodyBytes / 1000)
        let threeQuartersKB = String(MemoryDocument.maxBodyBytes * 3 / 4 / 1000)
        return invalidFiles.map {
            PromptLibrary.render("handoff/invalid-file", ["path": $0, "maxBodyKB": maxBodyKB])
        } + mustSplit.map {
            PromptLibrary.render("handoff/must-split", ["path": $0, "maxBodyKB": maxBodyKB, "threeQuartersKB": threeQuartersKB])
        }
    }

    /// Lines for the organizing prompt's handoff record.
    public var lines: [String] {
        var result: [String] = []
        func add(_ name: String, _ list: [String], extra: [String: String] = [:]) {
            guard !list.isEmpty else { return }
            var values = extra
            values["list"] = list.joined(separator: "；")
            result.append(PromptLibrary.render(name, values))
        }
        // Stale state and secrets lead: they are wrong now, the rest is structure.
        add("handoff/line-sensitive", sensitive)
        add("handoff/line-expired", expired)
        add("handoff/line-unknown-citations", unknownCitations)
        add("handoff/line-broken-links", brokenLinks)
        add("handoff/line-unlinked-mentions", unlinkedMentions)
        add("handoff/line-candidate-entities", candidateEntities)
        add("handoff/line-oversized", oversized)
        add("handoff/line-hubs", hubs)
        add("handoff/line-long-lines", longLines, extra: ["excerptLimit": String(GraphConstants.excerptLimit)])
        add("handoff/line-misfiled", misfiled)
        return result
    }
}
