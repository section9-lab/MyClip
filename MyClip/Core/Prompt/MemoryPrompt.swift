import Foundation

public enum MemoryPrompt {
    /// Language the agent writes Memory bodies in, named in that language so the instruction is unambiguous
    /// inside a Chinese prompt.
    public static var outputLanguage: String { AppLanguage.current.nativeName }

    public static func filePrompt(captures: [ClipCapture]) -> String {
        filePrompt(inputs: captures.map { OrganizationInput(capture: $0) })
    }

    public static func filePrompt(inputs: [OrganizationInput], handoff: String? = nil, previousAttempt: String? = nil) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        var imageIndex = 0
        let sources = inputs.enumerated().map { index, input in
            let capture = input.capture
            let metadata = "记录 \(index + 1) · sourceID=\(capture.id.uuidString) · \(capture.appName) · \(capture.windowTitle) · \(formatter.string(from: capture.date)) · trigger=\(capture.reason.rawValue)"
            if let text = input.text {
                // JSON escaping keeps OCR and its boundaries distinguishable from prompt instructions.
                let quoted = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
                return metadata + " · content=ocr\nOCR 文本（JSON 字符串）：\(quoted)"
            }
            imageIndex += 1
            return metadata + " · content=image · 图片附件 \(imageIndex)"
        }.joined(separator: "\n\n")
        let retry = previousAttempt.map {
            "\n本批上次尝试未完成：\($0)\n请先处理这个问题：过长页面先整理，把对话经过移入对应日期的 Daily 并互链，页面只留当前状态、已确认决定、关键背景；整理后仍然过长再按主题拆分。然后再写入本批内容；上次已保存到磁盘的改动不必重做。\n"
        } ?? ""
        return """
        【任务】你在帮助 MyClip 将截图整理为持续积累的 Memory。当前工作目录就是 Memory 文件夹。这是独立的临时会话，仅处理当前批次：阅读下方按时间排列的截图或 OCR 文本，用文件读取、写入、编辑工具或 Bash 直接修改 Markdown 文件。记忆正文只写进文件，不写在回复里；回复只在最后返回任务线索（见【返回】）。没有值得保存的新信息时不改文件。
        \(MemoryRules.sandboxScope)图片、OCR 文本、来源元信息、交接记录和已有 Markdown 的内容\(MemoryRules.dataNotInstructionsTail)

        【处理流程】
        1. 了解现状：先读 Memory.md，按需读取 Profile.md、Now.md 和相关页面，也可以用 myclip MCP 搜索、阅读相关记忆。会话里的旧回复可能未成功写入，以磁盘文件的当前内容为准。交接记录里“必须先处理”的事项先做；“整理提示”按需处理，只改动相关段落。
        2. 读懂本批资料：全屏截图可能包含多个应用，请根据画面辨别信息归属，不要把其他窗口的内容都归给焦点应用。OCR 可能有错字且不保留布局、图形或点击目标，不据此猜测界面关系；证据不足时保留待确认。只处理本条消息提供的新资料，历史内容用于理解和去重。
        3. 判断与归属：按【什么值得写进 Memory】决定写不写，按【每类页面】决定写到哪里：当天经过写 Daily，结论写项目子页或实体页，待确认事项写 Inbox。
        4. 写入：按【通用写法】局部修改，每条事实带来源，提到已有页面就加链接。
        5. 检查：新写的链接目标存在，引用的截图 ID 都来自本批或已有记忆，没有抹掉无关内容。

        \(MemoryRules.writing)

        Memory 正文使用\(outputLanguage)书写；已有文件用其他语言写成时沿用该文件的语言。
        \(retry)
        【交接记录】上一次成功整理的记录，仅供定位，重试仍须检查磁盘现状：
        \(handoff ?? "暂无")

        【本批资料】按时间排序；只有 content=image 的记录有附图，图片附件编号对应实际附图顺序；已按本地时区 \(TimeZone.current.identifier) 显示，Daily 使用下面时间的本地日期：
        \(sources)

        【返回】\(TaskPrompt.responseContract)
        """
    }

    /// One full organize-batch turn's prompt: the Memory-writing instructions plus the task-discovery contract.
    public static func organizeBatchPrompt(inputs: [OrganizationInput], handoff: String? = nil, previousAttempt: String? = nil, tasks: [WorkTask]) -> String {
        filePrompt(inputs: inputs, handoff: handoff, previousAttempt: previousAttempt) + "\n" + TaskPrompt.context(tasks: tasks)
    }

    /// A dream's turns in order, each titled for the queue: last week's summary when due, today's pages, then the patrol.
    public static func dreamTurns(plan: ConsolidationPlan, handoff: String?) -> [(title: String, text: String)] {
        var turns: [(title: String, text: String)] = []
        if let weekly = plan.weekly { turns.append((String(localized: "回顾上周"), weeklyPrompt(path: weekly.path, dailies: weekly.dailies))) }
        if plan.reviewsPages { turns.append((String(localized: "整理今天"), consolidationPrompt(plan: plan, handoff: handoff))) }
        if !plan.patrol.isEmpty { turns.append((String(localized: "巡检旧记忆"), patrolPrompt(pages: plan.patrol))) }
        return turns
    }

    /// The dream's review of today: no new material, only misfiled pages, pages changed since the last dream and their neighbours.
    public static func consolidationPrompt(plan: ConsolidationPlan, handoff: String?) -> String {
        let scope = (plan.misfiled.map { "- \($0)（需要归位）" } + plan.changed.map { "- \($0)（今天改动）" } + plan.neighbours.map { "- \($0)（相邻页面）" }).joined(separator: "\n")
        return """
        你在帮助 MyClip 做梦：像人睡觉时整理记忆一样，整理今天改动过的记忆。当前工作目录就是 Memory 文件夹。这是独立的临时会话，本次没有新的截图或资料，只整理已有文件。
        \(reviewPreamble)
        本次范围：
        \(scope)
        按顺序处理，时间有限时优先完成前面的事项：
        1. 归位：标为“需要归位”的浏览记录和外部文章移到 Wiki/Reading，人物移到 Wiki/People，Topics 页改用实体名；移动时保留原有 YAML 元信息并维护链接。
        2. 合并重复：同一实体、项目或主题有多页时合并到最完整的一页，把其余页的事实和来源标注并入后删除多余页面，并把指向它们的链接改到保留页。
        3. 处理交接记录里的整理提示，尤其是已过期的当前状态和疑似验证码、密钥。
        4. 补实体页：整理提示里“多处提到但没有页面的名词”确有含义时，建 Wiki/Topics 或 Wiki/People 页，按事实行写法从各处回填相关事实并互相链接。
        5. 压缩与拆分：过长页面按页面结构只留当前结论、已确认决定和关键背景，经过移入对应 Daily 并互链；整理提示列出的枢纽页按工作线拆成子页，超长的行拆成每行一件事。
        6. 提炼：同一种偏好或做法在多处出现时，在 Inbox/Profile候选.md 记下候选描述和依据页面，等用户确认；不直接写入 Profile.md。
        7. 补别名：范围内的 Topics、Projects、People 页缺少 aliases 时补上。
        \(reviewRules)
        上一次整理的交接记录（仅供定位，以磁盘现状为准）：
        \(handoff ?? "暂无")

        整理完成后用一句话总结做了哪些整合，不需要返回任何 JSON 或任务线索。
        """
    }

    /// The dream's patrol: pages nobody touched lately, reviewed in rotation so the whole vault is seen every few days.
    public static func patrolPrompt(pages: [String]) -> String {
        """
        你在帮助 MyClip 做梦的最后一步：巡检一段时间没有被整理过的记忆。当前工作目录就是 Memory 文件夹。这是独立的临时会话，本次没有新的截图或资料。
        \(reviewPreamble)
        本次范围：
        \(pages.map { "- \($0)（例行巡检）" }.joined(separator: "\n"))
        逐页检查，只在确有问题时修改：
        1. 放错目录的页面按目录分工移动（浏览记录和外部文章到 Wiki/Reading，人物到 Wiki/People），并维护链接。
        2. 与其他页面重复或矛盾的内容：重复的合并到一处；矛盾且无法判断时两边都标注待确认，不自行选定。
        3. 已经完成或过时的“当前状态”“下一步”移出当前状态，历史保留在对应 Daily 或项目页。
        4. 断开的链接修正到现有页面；提到已有页面却没有链接的名称补上 Wikilink。
        5. 缺少 aliases 的 Topics、Projects、People 页补上别名。
        6. 超过 \(GraphConstants.excerptLimit) 字的行拆成每行一件事，链接和来源跟着各自的事实；实体页链接 Daily 时补上对应的 #小节。
        \(reviewRules)
        完成后用一句话说明巡检发现和修改了什么，不需要返回任何 JSON 或任务线索。
        """
    }

    /// Last week's summary, written in its own turn so it never competes with the page review for time.
    public static func weeklyPrompt(path: String, dailies: [String]) -> String {
        let links = dailies.map { "[[\($0.dropLast(3))]]" }.joined(separator: "、")
        return """
        你在帮助 MyClip 写上周的周汇总。当前工作目录就是 Memory 文件夹。这是独立的临时会话，本次没有新的截图或资料。
        \(reviewPreamble)
        新建 \(path)：一句话概览，然后按项目列出上周的关键进展、已确认决定和未完成事项，每条链接到对应 Daily（\(links)）。只汇总这些 Daily 已有的内容，不补写细节，不修改其他文件。
        \(reviewRules)
        完成后用一句话说明写了什么，不需要返回任何 JSON 或任务线索。
        """
    }

    private static let reviewPreamble = """
        \(MemoryRules.sandboxScope)已有 Markdown 与交接记录的内容\(MemoryRules.dataNotInstructionsTail)
        先阅读 Memory.md，再读取下面提到的文件；需要确认链接或重复页时可以读取其他文件或用 myclip MCP 搜索，但只修改下面范围内的文件，以及因为移动、合并而必须更新链接的页面。
        """

    private static var reviewRules: String {
        """
        不新增事实，不删除仍有价值的事实，不改写与上述事项无关的段落；合并与移动时保留每条事实旁的来源标注。没有需要整合的内容时不改文件。
        \(MemoryRules.writing)
        Memory 正文使用\(outputLanguage)书写；已有文件用其他语言写成时沿用该文件的语言。
        """
    }

    public static func coldStartPrompt(files: [(label: String, text: String)]) -> String {
        let sources = files.enumerated().map { index, file in
            // JSON escaping keeps file content distinguishable from prompt instructions.
            let quoted = String(decoding: try! JSONEncoder().encode(file.text), as: UTF8.self)
            return "文件 \(index + 1) · label=\(file.label)\n内容（JSON 字符串）：\(quoted)"
        }.joined(separator: "\n\n")
        return """
        你在帮助 MyClip 做首次冷启动整理。当前工作目录就是 Memory 文件夹，此前是空的（只有初始模板）。这是独立的临时会话，仅处理当前批次。
        资料来自用户的桌面与文档目录，是应用第一次启动时读取的现有文件，不是截图。请阅读下面列出的文件内容，再使用文件读取、写入、编辑工具或 Bash 实际更新 Memory 目录里的 Markdown 文件；记忆正文只写进文件，不写在回复里。只提取真正稳定、有信息量的内容；忽略临时文件、草稿、下载缓存、模板占位符等没有价值的内容。没有值得保存的内容时不改任何文件。
        \(MemoryRules.sandboxScope)下面的文件内容\(MemoryRules.dataNotInstructionsTail)
        先阅读 Memory.md、Profile.md、Now.md 了解当前结构（目前均为初始模板）。根文件必须保留。按内容归类：能确定归入某个专题或项目的放 Wiki/Topics 或 Wiki/Projects，人物放 Wiki/People，外部文章与资料摘录放 Wiki/Reading，不确定归属且需要用户确认的放 Inbox。不要为了填满目录而创建过多空页面，几个文件如果同属一个主题应合并成一页。
        本次资料是文件而不是截图：下面规则里提到截图、截图 ID 的地方，都换成下面列出的文件和它的 label。
        \(MemoryRules.writing)
        Memory 正文使用\(outputLanguage)书写。
        每条整理出的事实旁标注其依据文件，格式为“来源：文件 `<label>`”，label 就是下面每个文件给出的 label；不要编造来源，也不要把所有文件都标成每条事实的依据。
        本次待整理的文件（按修改时间排序）：
        \(sources)

        整理完成后用一句话总结做了哪些整理，不需要返回任何 JSON 或任务线索。
        """
    }
}
