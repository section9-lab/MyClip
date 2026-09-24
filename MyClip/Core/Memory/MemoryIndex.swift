import Foundation
import NaturalLanguage

extension LibraryStore {
    func rebuildMemorySearchTables() throws {
        try database.run("DELETE FROM entry_search")
        try database.run("DELETE FROM memory_passage_search")
        try database.run("DELETE FROM memory_passages")
        try database.run("DELETE FROM memory_links")
        try database.run("DELETE FROM memory_edge_search")
        let items = try database.run("SELECT * FROM entries").map(entry)
        for item in items {
            let searchBody = try indexMemoryPassages(id: item.id, title: item.title, body: item.body, revision: item.revision, sourceIDs: item.sourceIDs)
            try database.run("INSERT INTO entry_search(id,title,body,terms,anchors,aliases) VALUES(?,?,?,?,'',?)", [item.id.uuidString, item.title, searchBody, Self.tokens(item.title + " " + searchBody), Self.aliasSearchText(item.aliases)])
        }
        // Links resolve against the complete entry set, then anchors are attached to their targets.
        for item in items { try indexLinks(id: item.id, body: item.body) }
    }

    public func rebuildSearchIndex() throws {
        try synchronizeMemoryFiles()
        try database.transaction {
            try rebuildMemorySearchTables()
            try database.run("DELETE FROM capture_search")
            for row in try database.run("SELECT * FROM image_text") {
                let body = row["body"] ?? ""
                try database.run("INSERT INTO capture_search VALUES(?,?,?)", [row["image_id"], body, Self.tokens(body)])
            }
        }
    }

    static func aliasSearchText(_ aliases: [String]) -> String {
        aliases.isEmpty ? "" : "\n" + aliases.map { $0.lowercased() }.joined(separator: "\n") + "\n" + tokens(aliases.joined(separator: " "))
    }

    static func tokens(_ text: String) -> String {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]).lowercased() }.joined(separator: " ")
    }
}
