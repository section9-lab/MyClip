import Foundation

/// Instructions and tool descriptions presented to clients of the read-only memory server.
enum MCPPrompt {
    /// The read-only instructions; a writable server appends what the two write tools are for.
    static func instructions(writable: Bool = false) -> String {
        PromptLibrary.text("recall/mcp-instructions")
            + (writable ? " " + PromptLibrary.text("recall/mcp-write-instructions") : "")
    }

    static var digestIntroduction: String {
        "\n\n" + PromptLibrary.text("recall/mcp-digest-introduction") + "\n"
    }

    static func tools(writable: Bool = false) -> [[String: Any]] {
        PromptLibrary.json("recall/tools-read") + (writable ? PromptLibrary.json("recall/tools-write") : [])
    }
}
