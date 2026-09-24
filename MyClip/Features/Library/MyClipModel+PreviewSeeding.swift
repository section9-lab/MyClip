import AppKit
import MyClipCore

extension MyClipModel {
    func seedPreview() async throws {
        guard try await store.snapshot().captures.isEmpty else { return }
        let size = CGSize(width: 1200, height: 760)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.windowBackgroundColor.setFill(); rect.fill()
            let title = String(localized: "MyClip · 截图预览") as NSString
            title.draw(at: NSPoint(x: 80, y: 630), withAttributes: [.font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.labelColor])
            let content = String(localized: "用截图留住上下文\n\n应用中的焦点窗口 → 本地资料库 → Memory\n\n此画面为界面验证生成，不来自真实应用。") as NSString
            content.draw(at: NSPoint(x: 80, y: 330), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.secondaryLabelColor])
            return true
        }
        var rect = CGRect(origin: .zero, size: size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        let captured = try CapturedImage(image: cgImage)
        let context = CaptureContext(appName: String(localized: "预览示例"), bundleID: "myclip.preview", windowTitle: String(localized: "聚焦窗口的截图整理"), windowID: 1, reason: .pointerIdle)
        try await store.record(image: captured, context: context, agent: .codex, organize: true)
        guard let job = try await store.claimNextJob(immediately: true) else { return }
        try await store.commit(jobID: job.id, drafts: [
            KnowledgeDraft(kind: .memory, title: String(localized: "让工作中的上下文，成为可以找回的知识"), body: String(localized: "MyClip 将应用窗口中的信息，整理为有来源的本地知识。\n\n## 从一张截图开始\n\n鼠标移动后静止一秒，再点击或双击；上下滚动停止两秒；或按下回车，记录当前应用的焦点窗口。重复画面共享一份图片，每次出现的时间仍被保留。\n\n## 从记录到理解\n\nCodex 或 Claude 通过 ACP 读取截图，整理 Memory。点击下方来源，可以回到知识产生的那一刻。\n\n这是用于验证界面的示例内容。"), sourceIDs: [context.id]),
            KnowledgeDraft(kind: .memory, title: String(localized: "截图只来自当前焦点窗口"), body: String(localized: "MyClip 记录前台应用的焦点窗口。无法确认焦点时跳过该帧，不截取整个桌面。"), sourceIDs: [context.id]),
            KnowledgeDraft(kind: .memory, title: String(localized: "重复画面，保留每一次出现"), body: String(localized: "相同像素的截图共用一个图片文件，时间、应用和来源记录仍分别保存。"), sourceIDs: [context.id])
        ])
        try await store.ingestTaskSuggestions([
            WorkTaskDraft(title: String(localized: "补充客户提到的导出格式"), project: String(localized: "客户协作"), evidence: String(localized: "示例线索：导出时是否可以保留来源？"), sourceIDs: [context.id]),
            WorkTaskDraft(title: String(localized: "验证弱网下的资料同步"), project: "MyClip", evidence: String(localized: "示例线索：弱网场景尚未验证。"), sourceIDs: [context.id]),
            WorkTaskDraft(title: String(localized: "为截图时间线添加触发方式图标"), project: "MyClip", suggestedStatus: .doing, evidence: String(localized: "示例线索：时间线正在接入触发图标，还需要区分鼠标与键盘事件。"), sourceIDs: [context.id]),
            WorkTaskDraft(title: String(localized: "优化浮层磨砂与气泡对比度"), project: "chat-bridge", suggestedStatus: .done, evidence: String(localized: "示例线索：浮层背景与气泡对比度已调整，并已检查浅色与深色外观。"), sourceIDs: [context.id]),
            WorkTaskDraft(title: String(localized: "配置完成后自动发送命令指南"), project: "chat-bridge", suggestedStatus: .doing, evidence: String(localized: "示例线索：正在添加首次连接后的命令指南。"), sourceIDs: [context.id]),
            WorkTaskDraft(title: String(localized: "排查 iMessage 配对失败"), project: "chat-bridge", evidence: String(localized: "示例线索：配对后手机未收到消息，需要检查发送记录。"), sourceIDs: [context.id]),
            WorkTaskDraft(title: String(localized: "修复微信端 session 与 agent 切换"), project: "chat-bridge", evidence: String(localized: "示例线索：会话与 agent 切换未生效，问题已记录。"), sourceIDs: [context.id]),
            WorkTaskDraft(title: String(localized: "整理本周发布说明"), project: "MyClip", evidence: String(localized: "示例线索：需要汇总本周的界面与连接改动。"), sourceIDs: [context.id])
        ], allowedSourceIDs: [context.id], allowedMemoryIDs: [])
        let examples: [(String, String, WorkTaskStatus, Int)] = [
            (String(localized: "回归单击与双击的截图时机"), "MyClip", .todo, 0),
            (String(localized: "整理本周客户反馈"), String(localized: "客户协作"), .todo, 1),
            (String(localized: "补齐资料库的使用说明"), String(localized: "资料整理"), .todo, 3),
            (String(localized: "设计任务看板的第一版"), "MyClip", .doing, 1),
            (String(localized: "确认导出字段与交付范围"), String(localized: "客户协作"), .doing, 5),
            (String(localized: "调整鼠标静止时间为 1 秒"), "MyClip", .done, 6),
            (String(localized: "整理资料目录与命名"), String(localized: "资料整理"), .done, 7)
        ]
        for (title, project, status, days) in examples {
            let date = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
            let id = try await store.createWorkTask(title: title, project: project, waitingReason: title == String(localized: "确认导出字段与交付范围") ? String(localized: "客户确认字段") : "", at: date)
            if status != .todo { try await store.setWorkTaskStatus(id, status: status, at: date.addingTimeInterval(60)) }
        }
    }

    #if DEBUG
    func previewPanelState() async throws {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--panel-state=") }),
              let capture = library.captures.first else { return }
        let value = String(argument.dropFirst("--panel-state=".count))
        agents[.codex]?.phase = .ready
        agents[.codex]?.detail = String(localized: "已连接")
        agents[.codex]?.sessionID = "00000000-0000-0000-0000-000000000001"
        if ["waiting", "paused", "working", "permission", "failed"].contains(value) {
            _ = try await store.enqueue(sourceIDs: [capture.id], agent: .codex)
        }
        switch value {
        case "paused": try await store.setOrganizationPaused(true)
        case "working", "permission", "failed":
            currentJob = try await store.claimNextJob(immediately: true)
            agents[.codex]?.phase = value == "permission" ? .permission : .working
            if value == "failed", let job = currentJob {
                try await store.finishJob(id: job.id, state: .failed, error: String(localized: "示例：连接中断，来源截图已保留。"))
                try await store.setOrganizationPaused(true, reason: String(localized: "示例：连接中断"))
                currentJob = nil
                agents[.codex]?.phase = .failed
                agents[.codex]?.detail = String(localized: "示例：连接中断，来源截图已保留。")
            }
        case "done":
            agents[.codex]?.lastCompleted = .now
            agents[.codex]?.detail = String(localized: "本批新增了 3 篇记忆")
        case "disconnected": agents[.codex] = .init()
        case "connecting": agents[.codex]?.phase = .connecting
        case "installing": agents[.codex]?.phase = .installing
        default: break
        }
        await refresh()
    }
    #endif
}
