import Foundation

extension LibraryStore {
    /// Captures of one window closer together than this continue the previous scene.
    public static let sceneGap: TimeInterval = 300
    /// A scene is cut after this many frames or this much time so an animating window cannot swallow a whole afternoon.
    public static let sceneFrameLimit = 40
    public static let sceneDuration: TimeInterval = 1800

    /// Where a new capture lands: which scene it joins and whether it is a fresh picture or another look at the previous one.
    public struct RecordingDecision: Sendable, Equatable {
        public var sceneID: String
        /// The image the capture is stored against; the previous frame's image when this one adds nothing.
        public var imageID: String
        public var reusedImage: Bool
        public var verdict: BlockComparison.Verdict?
    }

    public func record(image: CapturedImage, context: CaptureContext, agent: ClipAgent, organize: Bool, extractedText: String? = nil) throws {
        let decision = try database.transaction { () -> RecordingDecision in
            let decision = try recordingDecision(for: image, context: context)
            if !decision.reusedImage {
                try database.run("INSERT INTO images(id,width,height,block_hash) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET available=1,block_hash=coalesce(images.block_hash,excluded.block_hash)",
                                 [image.fingerprint, String(image.width), String(image.height), image.blockHash?.hex])
            }
            try database.run("INSERT INTO captures(id,image_id,app_name,bundle_id,window_title,window_id,reason,captured_at,scene_id) VALUES(?,?,?,?,?,?,?,?,?)", [
                context.id.uuidString, decision.imageID, context.appName, context.bundleID,
                context.windowTitle, String(context.windowID), context.reason.rawValue, String(context.date.timeIntervalSince1970), decision.sceneID
            ])
            if let extractedText, !decision.reusedImage {
                try database.run("INSERT INTO image_text VALUES(?,?) ON CONFLICT(image_id) DO UPDATE SET body=excluded.body", [image.fingerprint, extractedText])
                try database.run("DELETE FROM capture_search WHERE image_id=?", [image.fingerprint])
                try database.run("INSERT INTO capture_search VALUES(?,?,?)", [image.fingerprint, extractedText, Self.tokens(extractedText)])
            }
            // Another look at a picture the Agent already has (or will get) is not organized twice.
            if try organize && !(decision.reusedImage && hasOrganizedDuplicate(imageID: decision.imageID, context: context, agent: agent)) {
                try database.run("INSERT INTO pending_captures VALUES(?,?,?)", [context.id.uuidString, agent.rawValue, String(context.date.timeIntervalSince1970)])
            }
            return decision
        }
        guard !decision.reusedImage else { return }
        let imageURL = root.appendingPathComponent("Images/\(image.fingerprint).png")
        if !FileManager.default.fileExists(atPath: imageURL.path) {
            try image.pngData.write(to: imageURL, options: .atomic)
        }
        if let extractedText {
            try extractedText.write(to: imageURL.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        }
    }

    /// Compares against the newest capture of the same window. Manual screenshots always keep their own image.
    func recordingDecision(for image: CapturedImage, context: CaptureContext) throws -> RecordingDecision {
        var decision = RecordingDecision(sceneID: UUID().uuidString, imageID: image.fingerprint, reusedImage: false, verdict: nil)
        guard let previous = try database.run("""
            SELECT c.image_id,c.captured_at,c.scene_id,i.block_hash FROM captures c JOIN images i ON i.id=c.image_id
            WHERE c.bundle_id=? AND c.window_id=? ORDER BY c.captured_at DESC, c.rowid DESC LIMIT 1
            """, [context.bundleID, String(context.windowID)]).first,
              let previousTime = previous["captured_at"].flatMap(Double.init) else { return decision }
        let elapsed = context.date.timeIntervalSince1970 - previousTime
        guard elapsed >= 0, elapsed < Self.sceneGap else { return decision }
        if let scene = previous["scene_id"] {
            let bounds = try database.run("SELECT count(*) n, min(captured_at) started FROM captures WHERE scene_id=?", [scene]).first
            let frames = Int(bounds?["n"] ?? "0") ?? 0
            let started = bounds?["started"].flatMap(Double.init) ?? previousTime
            if frames < Self.sceneFrameLimit, context.date.timeIntervalSince1970 - started < Self.sceneDuration { decision.sceneID = scene }
        }
        guard context.reason != .manual, let previousImage = previous["image_id"] else { return decision }
        if previousImage == image.fingerprint {
            decision.verdict = .identical
        } else if let current = image.blockHash, let stored = previous["block_hash"].flatMap(BlockHash.init(hex:)) {
            decision.verdict = stored.compare(to: current).verdict
        }
        if decision.verdict == .identical || decision.verdict == .sameScene {
            decision.imageID = previousImage
            decision.reusedImage = true
        }
        return decision
    }

    /// Groups pre-v11 captures into scenes by window and time so the Timeline folds history too.
    public func nextImageForTextIndex(excluding: Set<String> = []) throws -> (id: String, url: URL)? {
        let placeholders = excluding.map { _ in "?" }.joined(separator: ",")
        let filter = excluding.isEmpty ? "" : " AND id NOT IN (\(placeholders))"
        guard let id = try database.run("SELECT id FROM images WHERE available=1 AND id NOT IN (SELECT image_id FROM image_text)\(filter) ORDER BY rowid LIMIT 1", Array(excluding)).first?["id"] else { return nil }
        return (id, root.appendingPathComponent("Images/\(id).png"))
    }

    public func recognizeImageText(id: String) async throws -> String {
        guard try !database.run("SELECT id FROM images WHERE id=? AND available=1", [id]).isEmpty else { throw LibraryError.missingSource }
        let documentURL = root.appendingPathComponent("Images/\(id).txt")
        if let text = try database.run("SELECT body FROM image_text WHERE image_id=?", [id]).first?["body"] {
            if !FileManager.default.fileExists(atPath: documentURL.path) {
                try text.write(to: documentURL, atomically: true, encoding: .utf8)
            }
            return text
        }
        let task: Task<String, Error>
        if let running = textRecognitionTasks[id] {
            task = running
        } else {
            let imageURL = root.appendingPathComponent("Images/\(id).png")
            task = Task.detached(priority: .utility) {
                let data = try Data(contentsOf: imageURL)
                guard let text = CaptureTextRecognizer.recognize(data) else { throw LibraryError.textRecognitionFailed }
                return text
            }
            textRecognitionTasks[id] = task
        }
        defer { textRecognitionTasks[id] = nil }
        let text = try await task.value
        try Task.checkCancellation()
        guard try !database.run("SELECT id FROM images WHERE id=? AND available=1", [id]).isEmpty else { throw LibraryError.missingSource }
        try indexImageText(id: id, text: text)
        return text
    }

    public func indexImageText(id: String, text: String) throws {
        try database.transaction {
            guard try !database.run("SELECT id FROM images WHERE id=? AND available=1", [id]).isEmpty else { return }
            try database.run("INSERT INTO image_text VALUES(?,?) ON CONFLICT(image_id) DO UPDATE SET body=excluded.body", [id, text])
            try database.run("DELETE FROM capture_search WHERE image_id=?", [id])
            try database.run("INSERT INTO capture_search VALUES(?,?,?)", [id, text, Self.tokens(text)])
            try text.write(to: root.appendingPathComponent("Images/\(id).txt"), atomically: true, encoding: .utf8)
        }
    }

    public func imageNeedsTextIndex(_ id: String) throws -> Bool {
        try database.run("SELECT image_id FROM image_text WHERE image_id=?", [id]).isEmpty
    }

    /// Rebuilds every derived search table from entry files: passages, full text, link edges and anchor text.
    public func expireImages(before date: Date) throws {
        let rows = try database.run("""
            SELECT i.id FROM images i JOIN captures c ON c.image_id=i.id WHERE i.available=1
            GROUP BY i.id HAVING max(c.captured_at) < CAST(? AS REAL) AND i.id NOT IN (
                SELECT c.image_id FROM captures c JOIN job_sources s ON s.capture_id=c.id
                JOIN jobs j ON j.id=s.job_id WHERE j.state IN ('queued','running','failed')
                UNION SELECT c.image_id FROM captures c JOIN pending_captures p ON p.capture_id=c.id
            )
            """, [String(date.timeIntervalSince1970)])
        for row in rows {
            guard let id = row["id"] else { continue }
            let url = root.appendingPathComponent("Images/\(id).png")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            let documentURL = url.deletingPathExtension().appendingPathExtension("txt")
            if FileManager.default.fileExists(atPath: documentURL.path) { try FileManager.default.removeItem(at: documentURL) }
            try database.transaction {
                try database.run("UPDATE images SET available=0 WHERE id=?", [id])
                try database.run("DELETE FROM image_text WHERE image_id=?", [id])
                try database.run("DELETE FROM capture_search WHERE image_id=?", [id])
            }
        }
    }

    public func captures(ids: [UUID]) throws -> [ClipCapture] {
        try ids.map { id in
            guard let row = try database.run("SELECT c.*,i.width,i.height FROM captures c JOIN images i ON i.id=c.image_id WHERE c.id=?", [id.uuidString]).first else {
                throw LibraryError.missingSource
            }
            return try capture(row)
        }
    }

    public func availableCaptures(ids: [UUID]) throws -> [ClipCapture] {
        var result: [ClipCapture] = []
        for id in ids {
            do { result += try captures(ids: [id]) }
            catch LibraryError.missingSource { continue }
        }
        return result
    }

    func capture(_ row: [String: String]) throws -> ClipCapture {
        guard let id = row["id"].flatMap(UUID.init(uuidString:)), let imageID = row["image_id"],
              let reason = CaptureReason(rawValue: row["reason"] ?? "") else { throw LibraryError.database(String(localized: "截图记录格式错误")) }
        return ClipCapture(id: id, appName: row["app_name"] ?? "", bundleID: row["bundle_id"] ?? "",
                           windowTitle: row["window_title"] ?? "", windowID: UInt32(row["window_id"] ?? "0") ?? 0,
                           reason: reason, date: Date(timeIntervalSince1970: Double(row["captured_at"] ?? "0") ?? 0),
                           imageID: imageID, imageURL: root.appendingPathComponent("Images/\(imageID).png"),
                           width: Int(row["width"] ?? "0") ?? 0, height: Int(row["height"] ?? "0") ?? 0, sceneID: row["scene_id"])
    }
}
