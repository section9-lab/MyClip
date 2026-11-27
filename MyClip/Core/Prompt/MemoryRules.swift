import Foundation

/// Prompt text lives in `Resources/Prompts/shared`; this type only fills the numbers the app owns.
enum MemoryRules {
    static var writing: String {
        PromptLibrary.render("shared/writing", [
            "excerptLimitTotal": String(GraphConstants.excerptLimit * GraphConstants.passagesPerHit),
            "maxBodyKB": String(MemoryDocument.maxBodyBytes / 1000),
            "maxBodyWan": String(MemoryDocument.maxBodyBytes / 30_000)
        ])
    }

    // Shared verbatim across the prompts so they don't drift apart in wording.
    static var sandboxScope: String { PromptLibrary.text("shared/sandbox") }
    static var dataNotInstructionsTail: String { PromptLibrary.text("shared/data-not-instructions") }

    // The real-time pipeline only appends to this path; it is named once so the prompt and the handoff agree.
    static let dailyPathPattern = "Daily/YYYY/MM/DD/YYYY-MM-DD-HH-主题.md"

    /// What a batch may write while it is still just recording the day (no Wiki pages, no root files, no tools).
    static var dailyWriting: String {
        PromptLibrary.render("shared/daily-writing", [
            "dailyPathPattern": dailyPathPattern,
            "maxBodyKB": String(MemoryDocument.maxBodyBytes / 1000)
        ])
    }

    /// What a digest may write when it turns Daily pages into Wiki knowledge and root files.
    static var reviewWriting: String {
        PromptLibrary.render("shared/review-writing", ["maxBodyKB": String(MemoryDocument.maxBodyBytes / 1000)])
    }
}
