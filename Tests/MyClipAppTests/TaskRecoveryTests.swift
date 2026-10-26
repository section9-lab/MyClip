import AppKit
@testable import MyClipCore

@MainActor enum MyClipAppDelegate { static func relaunch() {} }
@MainActor final class FocusedCaptureService {
    var hasScreenPermission = false
    var hasAccessibilityPermission = false
    var isRunning = false
    var onCapture: ((CapturedImage, CaptureContext) async -> Void)?
    var onStatus: ((String) -> Void)?
    func configure(settings: CaptureSettings, excludedBundleIDs: Set<String>) {}
    func requestScreenPermission() {}
    func requestAccessibilityPermission() {}
    func start() -> Bool { false }
    func stop() {}
}

/// Runs with Command Line Tools: real storage, transactions, restart recovery and the real application dispatcher.
@main struct TaskRecoveryTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-TaskRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        func envelope(_ drafts: [WorkTaskDraft]) throws -> String {
            "{\"tasks\":" + String(decoding: try JSONEncoder().encode(drafts), as: UTF8.self) + "}"
        }
        let graphics = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        graphics.setFillColor(CGColor(gray: 0.5, alpha: 1)); graphics.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try CapturedImage(image: graphics.makeImage()!)
        func source(_ store: LibraryStore, _ time: TimeInterval, organize: Bool = false) async throws -> CaptureContext {
            let context = CaptureContext(appName: "Fixture", bundleID: "test.task-recovery", windowTitle: "验收",
                                         windowID: UInt32(time), reason: .manual, date: Date(timeIntervalSince1970: time))
            try await store.record(image: image, context: context, agent: .codex, organize: organize)
            return context
        }
        let store = try LibraryStore(root: root.appendingPathComponent("Library"))
        let current = try await source(store, 200), previous = try await source(store, 150)
        let task = try await store.createWorkTask(title: "已有目标", project: "项目", at: Date(timeIntervalSince1970: 100))
        let memories = try await store.snapshot().entries
        let memory = memories.first!
        let good = WorkTaskDraft(taskID: task, title: "换一种说法", project: "项目", suggestedStatus: .done,
                                 evidence: "核验通过，包含 } 和 \"引号\"。", sourceIDs: [current.id])
        let crossBatch = WorkTaskDraft(title: "跨批候选", evidence: "旧资料待核实", sourceIDs: [previous.id])
        let wrongNamespace = WorkTaskDraft(title: "编号混用", evidence: "不能把任务号当资料", sourceIDs: [current.id], memoryIDs: [task])
        let text = try "前置说明\n```json\n" + envelope([good, crossBatch, wrongNamespace]) + "\n```\n整理完成。"
        check(try TaskResponse.parse(text).count == 3, "Balanced JSON survives trailing prose, fences, braces and escaped quotes")
        for ambiguous in ["{\"tasks\":[]}\n{\"tasks\":[]}", "{\"tasks\":[", "没有结果"] {
            do { _ = try TaskResponse.parse(ambiguous); check(false, "Ambiguous or malformed response must be rejected") }
            catch { check(true, "Ambiguous/malformed/missing JSON is rejected explicitly") }
        }
        let stageID = try await store.enqueueTaskIngestion(response: text, sourceIDs: [current.id], memoryIDs: [memory.id])
        let partial = try await store.applyTaskIngestion(stageID)
        let tasks = try await store.workTasks()
        check(partial.state == .pending && partial.rejectedCount == 2 && partial.changedCount == 1, "Valid candidate commits while two invalid candidates remain durable")
        check(tasks.count == 1 && tasks.first?.id == task && tasks.first?.status == .done, "Explicit taskID merges renamed progress without duplicates")
        check(tasks.first?.evidence.count == 1, "Cross-batch and task-as-memory references are never silently accepted")
        check(partial.error?.contains("不属于本批") == true && partial.error?.contains("taskID") == true, "Errors distinguish source scope and ID namespace")
        check(try TaskResponse.parse(partial.response).count == 2, "Retry payload contains only rejected candidates")
        let reopened = try LibraryStore(root: store.root)
        check(try await reopened.taskIngestion(stageID).rejectedCount == 2, "Partial failure survives reopening the library")
        let corrected = WorkTaskDraft(taskID: task, title: "新的措辞", project: "项目", evidence: "核验补充记录", sourceIDs: [current.id])
        let settled = try await reopened.applyTaskIngestion(stageID, response: envelope([corrected]))
        _ = try await reopened.applyTaskIngestion(stageID, response: envelope([corrected]))
        check(settled.state == .completed && settled.rejectedCount == 0, "Corrected reply settles the same stage")
        check(try await reopened.workTasks().first?.evidence.count == 2, "Completed stage replay does not duplicate evidence")
        try await reopened.setWorkTaskStatus(task, status: .todo)
        let staleID = try await reopened.enqueueTaskIngestion(response: envelope([good]), sourceIDs: [current.id], memoryIDs: [])
        _ = try await reopened.applyTaskIngestion(staleID)
        check(try await reopened.workTasks().first(where: { $0.id == task })?.status == .todo, "Reprocessing old screenshots cannot overwrite a newer manual status")

        let malformed = "{\"tasks\":[" + String(decoding: try JSONEncoder().encode(WorkTaskDraft(title: "有效新任务", evidence: "明确待办", sourceIDs: [current.id])), as: UTF8.self)
            + ",{\"title\":7,\"sourceIDs\":[\"not-a-uuid\"]}]}"
        let malformedID = try await store.enqueueTaskIngestion(response: malformed, sourceIDs: [current.id], memoryIDs: [])
        let malformedStage = try await store.applyTaskIngestion(malformedID)
        check(malformedStage.rejectedCount == 1 && malformedStage.changedCount == 1, "A malformed item does not prevent a valid sibling from importing")

        let queueStore = try LibraryStore(root: root.appendingPathComponent("Retry"))
        let retryID = try await queueStore.enqueueTaskIngestion(response: "bad JSON", sourceIDs: [], memoryIDs: [])
        var now = Date(timeIntervalSince1970: 10_000)
        _ = try await queueStore.applyTaskIngestion(retryID, at: now)
        check(try await queueStore.claimNextTaskIngestion(at: now) == nil, "Backoff prevents a busy retry loop")
        for attempt in 1...RetryPolicy.maxAttempts {
            now.addTimeInterval(10_000)
            let claimed = try await queueStore.claimNextTaskIngestion(at: now)
            check(claimed?.id == retryID && claimed?.attempts == attempt, "Durable retry attempt \(attempt) is claimed")
            check(try await queueStore.claimNextTaskIngestion(at: now) == nil, "Only one recovery worker can own a stage")
            try await queueStore.failTaskIngestion(retryID, error: "仍需核实", at: now)
        }
        check(try await queueStore.taskIngestion(retryID).state == .failed, "Retry limit is persisted without pausing screenshot organization")
        try await queueStore.retryFailedTaskIngestions(at: now)
        _ = try await queueStore.claimNextTaskIngestion(at: now)
        try await queueStore.recoverInterruptedTaskIngestions(at: now)
        check(try await queueStore.taskIngestion(retryID).state == .pending, "An interrupted recovery returns to the queue")
        try await queueStore.failTaskIngestion(retryID, error: "需要重新登录", retryable: false, at: now)
        check(try await queueStore.taskIngestion(retryID).state == .failed, "Permanent failures stop automatic retries while keeping the candidate recoverable")

        let atomicStore = try LibraryStore(root: root.appendingPathComponent("Atomic"))
        _ = try await source(atomicStore, 300, organize: true)
        let job = try await atomicStore.claimNextJob(immediately: true)!
        let revisions = try await atomicStore.beginMemoryEditing(jobID: job.id)
        _ = try await atomicStore.finishMemoryEditing(jobID: job.id, previousRevisions: revisions, taskResponse: "{\"tasks\":[]}")
        let atomicReopened = try LibraryStore(root: atomicStore.root)
        let atomicStage = try await atomicReopened.taskIngestion(job.id)
        check(atomicStage.jobID == job.id && atomicStage.state == .pending, "Memory completion atomically leaves a durable task stage")
        _ = try await atomicReopened.applyTaskIngestion(job.id)

        // Simulate an older installed build: completed Memory and a saved reply, without task-stage metadata.
        let legacySource = try await source(atomicStore, 400, organize: true)
        let legacyJob = try await atomicStore.claimNextJob(immediately: true)!
        let legacyRevisions = try await atomicStore.beginMemoryEditing(jobID: legacyJob.id)
        _ = try await atomicStore.finishMemoryEditing(jobID: legacyJob.id, previousRevisions: legacyRevisions)
        let database = try SQLiteConnection(url: atomicStore.root.appendingPathComponent("Library.sqlite"))
        let legacyDraft = WorkTaskDraft(title: "补回旧任务", evidence: "真实旧依据", sourceIDs: [legacySource.id])
        try database.run("INSERT INTO execution_records(id,job_id,session_id,started_at,finished_at,stop_reason,response) VALUES(?,?,'legacy',10,11,'end_turn',?)",
                         [UUID().uuidString, legacyJob.id.uuidString, try envelope([legacyDraft]) + "\n尾部总结"])
        check(try await atomicStore.recoverHistoricalTaskIngestions() == 1, "Legacy completed batch is found even when its task outcome was never recorded")
        check(try await atomicStore.workTasks().isEmpty, "Unseen legacy candidates are reconciled before import, avoiding semantic duplicates")
        let recovered = try await atomicStore.applyTaskIngestion(legacyJob.id, response: envelope([legacyDraft]))
        check(recovered.state == .completed && recovered.changedCount == 1, "Corrected legacy evidence imports successfully")
        check(try await atomicStore.recoverHistoricalTaskIngestions() == 0, "Historical scan is idempotent")
        try database.run("DELETE FROM task_ingestions WHERE id=?", [legacyJob.id.uuidString])
        check(try await atomicStore.recoverHistoricalTaskIngestions() == 1, "A missing metadata row can be rebuilt")
        check(try await atomicStore.taskIngestion(legacyJob.id).state == .completed, "Already-imported legacy evidence skips correction and new writes")
        let summary = try await atomicStore.taskIngestionSummary()
        check(summary.pendingCount == 0 && summary.failedCount == 0 && summary.observedThrough == legacySource.date, "Persistent summary reports settled work and actual screenshot time")
        let catalogID = try await atomicStore.enqueueTaskIngestion(response: "bad", sourceIDs: [legacySource.id], memoryIDs: [])
        let catalogStage = try await atomicStore.taskIngestion(catalogID)
        let freshCatalog = try await atomicStore.taskIngestionMemories(catalogStage)
        let frozenCatalog = try await atomicStore.taskIngestion(catalogID).memoryIDs
        check(!freshCatalog.isEmpty && frozenCatalog == Set(freshCatalog.map(\.id)), "Correction freezes the current Memory catalog, including pages created after the initial prompt")
        let originalCaptures = try await atomicStore.taskIngestionCaptures(catalogStage)
        for capture in originalCaptures { try FileManager.default.removeItem(at: capture.imageURL) }
        check(try await atomicStore.taskIngestionCaptures(catalogStage).isEmpty, "Expired images do not prevent a Memory-based correction")

        let suite = "MyClip.TaskRecoveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let executable = root.appendingPathComponent("codex-acp")
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/MyClipCoreTests/Fixtures/acp_agent.py")
        try "#!/bin/sh\nexport MYCLIP_ACP_SCENARIO=task_recovery_empty\nexec /usr/bin/python3 '\(fixture.path)'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defaults.set(executable.path, forKey: "myclip.codexPath")
        let preferences = ClipPreferences(preview: false, defaults: defaults)
        preferences.enabledAgent = .codex
        let model = try MyClipModel(root: root.appendingPathComponent("Model"), preview: false, preferences: preferences)
        defer { model.stop() }
        let modelStageID = try await model.store.enqueueTaskIngestion(response: "old bad reply", sourceIDs: [], memoryIDs: [])
        await model.processNext()
        check(try await model.store.taskIngestion(modelStageID).state == .completed, "Application dispatcher repairs a queued stage through a real ACP fixture subprocess")
        check(!model.discoveringTasks && !model.dispatching && model.currentJob == nil, "Recovery releases application busy states")
        check(model.taskIngestionSummary.pendingCount == 0 && !model.taskDiscoveryFailed, "Application refresh reads the durable recovery outcome")
        check(try await model.store.workTasks().isEmpty, "Groundless old candidates may resolve to no tasks without inventing work")
        if failures > 0 { throw LibraryError.invalidResult("\(failures) task recovery checks failed") }
    }
}
