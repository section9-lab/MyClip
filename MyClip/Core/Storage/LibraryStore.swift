import Foundation

public actor LibraryStore {
    public nonisolated let root: URL
    let database: SQLiteConnection
    var textRecognitionTasks: [String: Task<String, Error>] = [:]

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Entries"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Memory"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Proposals"), withIntermediateDirectories: true)
        database = try SQLiteConnection(url: root.appendingPathComponent("Library.sqlite"))
        try Self.prepareDatabase(database)
        for row in try database.run("SELECT image_id,body FROM image_text JOIN images ON images.id=image_text.image_id WHERE available=1") {
            guard let id = row["image_id"], let text = row["body"] else { continue }
            let url = root.appendingPathComponent("Images/\(id).txt")
            if !FileManager.default.fileExists(atPath: url.path) {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    public func snapshot(query: String = "", captureFilter: CaptureFilter = CaptureFilter(), calendar: Calendar = .current) throws -> LibrarySnapshot {
        let invalid = try synchronizeMemoryFiles()
        var result = LibrarySnapshot()
        result.invalidMemoryFiles = invalid.map(\.description)
        result.memoryFolders = try MemoryLayout.folderPaths(in: root.appendingPathComponent("Memory"))
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = Self.tokens(term).split(separator: " ").map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " AND ")
        let captureMatch = words.isEmpty ? "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\"" : words
        var captureConditions: [String] = []
        var captureArguments: [String?] = []
        if !term.isEmpty {
            captureConditions.append("""
            (instr(lower(c.app_name || ' ' || c.window_title), ?) > 0 OR c.image_id IN (
                SELECT image_id FROM capture_search WHERE capture_search MATCH ?
                UNION SELECT image_id FROM image_text WHERE instr(lower(body),?)>0
            ))
            """)
            captureArguments += [term, captureMatch, term]
        }
        if let appName = captureFilter.appName {
            captureConditions.append("c.app_name=?")
            captureArguments.append(appName)
        }
        if let range = captureFilter.dateRange {
            guard let end = calendar.dateInterval(of: .day, for: range.upperBound)?.end else {
                throw LibraryError.invalidResult(String(localized: "无法解析筛选日期。"))
            }
            captureConditions.append("c.captured_at>=? AND c.captured_at<?")
            captureArguments += [String(calendar.startOfDay(for: range.lowerBound).timeIntervalSince1970), String(end.timeIntervalSince1970)]
        }
        let reasons: [CaptureReason]
        switch captureFilter.event {
        case .all: reasons = []
        case .mouse: reasons = [.pointerIdle, .clickIdle, .clickAfterIdle, .scrollIdle]
        case .keyboard: reasons = [.enter]
        }
        if !reasons.isEmpty {
            captureConditions.append("c.reason IN (\(reasons.map { _ in "?" }.joined(separator: ",")))")
            captureArguments += reasons.map(\.rawValue)
        }
        let captureWhere = captureConditions.isEmpty ? "" : "WHERE " + captureConditions.joined(separator: " AND ")
        result.captures = try database.run("""
            SELECT c.*, i.width, i.height FROM captures c JOIN images i ON c.image_id=i.id
            \(captureWhere) ORDER BY c.captured_at DESC, c.rowid DESC LIMIT 500
            """, captureArguments).map(capture)
        result.captureCount = Int(try database.run("SELECT count(*) AS count FROM captures c \(captureWhere)", captureArguments).first?["count"] ?? "0") ?? 0
        result.captureAppNames = try database.run("SELECT DISTINCT app_name FROM captures ORDER BY app_name").compactMap { $0["app_name"] }
        result.entries = try matchingMemories(query: query)
        result.jobs = try database.run("SELECT * FROM jobs ORDER BY created_at DESC, rowid DESC LIMIT 100").map(job)
        result.queue = try organizationQueue()
        result.imageCount = Int(try database.run("SELECT count(*) AS count FROM images WHERE available=1").first?["count"] ?? "0") ?? 0
        return result
    }
}
