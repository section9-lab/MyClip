import Foundation

public enum MemoryPrompt {
    /// Language the agent writes Memory bodies in, named in that language so the instruction is unambiguous
    /// inside a Chinese prompt.
    public static var outputLanguage: String { AppLanguage.current.nativeName }

    /// Legacy single-turn pipeline: one call writes Daily, Wiki and the root files at once. The app now runs the two
    /// pipelines in `DayPrompt` (batch → Daily, hourly digest → Wiki/root/board/calendar); this stays for the live
    /// harness and for libraries whose prompts are still being compared.
    public static func filePrompt(captures: [ClipCapture], handoff: String? = nil, previousAttempt: String? = nil) -> String {
        let retry = previousAttempt.map {
            "\n" + PromptLibrary.render("generation/retry-legacy", ["error": $0]) + "\n"
        } ?? ""
        return PromptLibrary.render("generation/legacy-file", [
            "sandbox": MemoryRules.sandboxScope,
            "dataRule": MemoryRules.dataNotInstructionsTail,
            "writing": MemoryRules.writing,
            "outputLanguage": outputLanguage,
            "retry": retry,
            "handoff": handoff ?? PromptLibrary.text("shared/none"),
            "timezone": TimeZone.current.identifier,
            "sources": DayPrompt.sources(captures, timeZone: .current),
            "taskResponseContract": TaskPrompt.responseContract
        ])
    }

    /// One full organize-batch turn's prompt: the Memory-writing instructions plus the task-discovery contract.
    public static func organizeBatchPrompt(captures: [ClipCapture], handoff: String? = nil, previousAttempt: String? = nil,
                                           tasks: [WorkTask], memories: [KnowledgeEntry] = []) -> String {
        filePrompt(captures: captures, handoff: handoff, previousAttempt: previousAttempt) + "\n" + TaskPrompt.context(tasks: tasks)
            + "\n" + TaskPrompt.memoryCatalog(memories)
    }

    /// A dream's turns in order, each titled for the queue: last week's summary when due, today's pages, then the patrol.
    /// An hourly digest owns its plan's `dailies` instead and runs a single turn.
    public static func dreamTurns(plan: ConsolidationPlan, handoff: String?, board: [WorkTask] = [],
                                  calendar: [CalendarEvent] = []) -> [(title: String, text: String)] {
        if !plan.dailies.isEmpty {
            return [(String(localized: "整理当天的 Daily"),
                     digestPrompt(dailies: plan.dailies, handoff: handoff, board: board, calendar: calendar))]
        }
        var turns: [(title: String, text: String)] = []
        if let weekly = plan.weekly { turns.append((String(localized: "回顾上周"), weeklyPrompt(path: weekly.path, dailies: weekly.dailies))) }
        if plan.reviewsPages { turns.append((String(localized: "整理今天"), consolidationPrompt(plan: plan, handoff: handoff))) }
        if !plan.patrol.isEmpty { turns.append((String(localized: "巡检旧记忆"), patrolPrompt(pages: plan.patrol))) }
        return turns
    }

    /// The hourly digest: today's Daily pages become Wiki knowledge, root files and board/calendar entries.
    public static func digestPrompt(dailies: [String], handoff: String? = nil, previousAttempt: String? = nil,
                                    board: [WorkTask] = [], calendar: [CalendarEvent] = []) -> String {
        DayPrompt.digest(dailies: dailies, handoff: handoff, previousAttempt: previousAttempt, board: board, calendar: calendar)
    }

    /// The dream's review of today: no new material, only misfiled pages, pages changed since the last dream and their neighbours.
    public static func consolidationPrompt(plan: ConsolidationPlan, handoff: String?) -> String {
        let scope = (plan.misfiled.map { PromptLibrary.render("generation/scope-misfiled", ["path": $0]) }
            + plan.changed.map { PromptLibrary.render("generation/scope-changed", ["path": $0]) }
            + plan.neighbours.map { PromptLibrary.render("generation/scope-neighbour", ["path": $0]) })
            .joined(separator: "\n")
        return PromptLibrary.render("generation/dream-review", [
            "reviewPreamble": reviewPreamble,
            "scope": scope,
            "reviewRules": reviewRules,
            "handoff": handoff ?? PromptLibrary.text("shared/none")
        ])
    }

    /// The dream's patrol: pages nobody touched lately, reviewed in rotation so the whole vault is seen every few days.
    public static func patrolPrompt(pages: [String]) -> String {
        let list = pages.map { PromptLibrary.render("generation/patrol-page", ["path": $0]) }.joined(separator: "\n")
        return PromptLibrary.render("generation/dream-patrol", [
            "reviewPreamble": reviewPreamble,
            "pages": list,
            "excerptLimit": String(GraphConstants.excerptLimit),
            "reviewRules": reviewRules
        ])
    }

    /// Last week's summary, written in its own turn so it never competes with the page review for time.
    public static func weeklyPrompt(path: String, dailies: [String]) -> String {
        let links = dailies.map { "[[\($0.dropLast(3))]]" }.joined(separator: "、")
        return PromptLibrary.render("generation/dream-weekly", [
            "reviewPreamble": reviewPreamble,
            "path": path,
            "links": links,
            "reviewRules": reviewRules
        ])
    }

    private static var reviewPreamble: String {
        PromptLibrary.render("shared/review-preamble", [
            "sandbox": MemoryRules.sandboxScope,
            "dataRule": MemoryRules.dataNotInstructionsTail
        ])
    }

    private static var reviewRules: String {
        PromptLibrary.render("shared/review-rules", [
            "writing": MemoryRules.writing,
            "outputLanguage": outputLanguage
        ])
    }

    public static func coldStartPrompt(files: [(label: String, text: String)]) -> String {
        let sources = files.enumerated().map { index, file in
            // JSON escaping keeps file content distinguishable from prompt instructions.
            let quoted: String
            do {
                quoted = String(decoding: try JSONEncoder().encode(file.text), as: UTF8.self)
            } catch {
                preconditionFailure("Encoding a String as JSON cannot fail: \(error)")
            }
            return PromptLibrary.render("generation/cold-start-source", [
                "index": String(index + 1),
                "label": file.label,
                "quoted": quoted
            ])
        }.joined(separator: "\n\n")
        return PromptLibrary.render("generation/cold-start", [
            "sandbox": MemoryRules.sandboxScope,
            "dataRule": MemoryRules.dataNotInstructionsTail,
            "writing": MemoryRules.writing,
            "outputLanguage": outputLanguage,
            "sources": sources
        ])
    }
}
