/* Fictional work examples shared by every HTML view. No personal library data. */
window.MYCLIP_APP_DATA = {
  documents: [
    { path: 'Memory.md', title: 'Memory', markdown: '# Memory\n\n## 最近的决定\n\n保留真实的应用窗口，让安装后的每一步都清楚可见。\n\n## 正在推进\n\n- 完成 MyClip 的使用演示，从首次启动到记忆召回。\n- 在 [[Now.md]] 中跟进今天的工作。\n- 将项目背景整理到 [[Wiki/MyClip.md]]。\n\n## 工作线索\n\n截图、记忆和待办保留相互关联的来源。需要回顾时，可以沿着线索回到当时的上下文。' },
    { path: 'Now.md', title: 'Now', markdown: '# Now\n\n## 当前关注\n\n完成 README 使用演示。\n\n## 下一步\n\n- 检查首次使用与权限引导。\n- 复核截图、记忆和待办之间的来源关系。\n- 整理日报，准备与团队同步进展。\n\n## 相关记忆\n\n[[Memory.md]] · [[Wiki/MyClip.md]]' },
    { path: 'Profile.md', title: 'Profile', markdown: '# Profile\n\n## 工作方式\n\n习惯在 macOS 上完成设计、开发与文档整理。\n\n## 沟通偏好\n\n- 使用简洁、清晰的中文。\n- 讨论决定时附上来源与上下文。\n\n## 长期目标\n\n让每天的工作自然积累成可以重新找到的知识。' },
    { path: 'Wiki/MyClip.md', title: 'MyClip', markdown: '# MyClip\n\n## 项目方向\n\n把工作中的截图整理成可以搜索和关联的 Markdown 记忆。\n\n## 演示计划\n\n从 macOS Dock 启动应用，完成权限与语言设置，再选择整理 Agent。\n\n### 从记录到召回\n\n1. Timeline 保留当时的工作画面。\n2. Memory 整理内容并连接相关知识。\n3. Kanban 跟进接下来的行动。\n4. Codex 和 Claude 通过 MCP 找回同一份记忆。\n\n## 相关记录\n\n[[Memory.md]] · [[Now.md]]' },
    { path: 'Daily/2026-09-24.md', title: '2026-09-24', markdown: '# 2026-09-24\n\n## 今天的工作\n\n上午完成应用流程梳理，下午核对 Timeline、看板与设置页。\n\n## 截图与决定\n\n演示使用完整的 macOS 软件桌面。启动后先设置权限，再选择 Agent。\n\n## 下一步\n\n检查每个页面的交互，并在 Codex 和 Claude 中演示记忆召回。\n\n[[Wiki/MyClip.md]] · [[Now.md]]' },
  ],
  captures: [
    { id:'c1', app:'Safari浏览器', time:'下午 3:42', date:'2026-09-24', title:'MyClip · README 演示计划', type:'browser', event:'回车触发', count:2 },
    { id:'c2', app:'Codex', time:'下午 3:36', date:'2026-09-24', title:'梳理首次使用流程', type:'chat', event:'回车触发', count:1 },
    { id:'c3', app:'备忘录', time:'下午 3:21', date:'2026-09-24', title:'今天的工作记录', type:'notes', event:'鼠标静止后点击', count:1 },
    { id:'c4', app:'VS Code', time:'下午 2:58', date:'2026-09-24', title:'CaptureOnboardingView.swift', type:'code', event:'回车触发', count:3 },
    { id:'c5', app:'Safari浏览器', time:'下午 2:30', date:'2026-09-24', title:'MyClip · 项目文档', type:'browser', event:'滚动停止', count:1 },
    { id:'c6', app:'Claude', time:'下午 2:12', date:'2026-09-24', title:'整理本周的工作进展', type:'chat', event:'回车触发', count:1 },
    { id:'c7', app:'备忘录', time:'下午 5:18', date:'2026-09-23', title:'项目回顾与下一步', type:'notes', event:'回车触发', count:1 },
    { id:'c8', app:'VS Code', time:'下午 4:40', date:'2026-09-23', title:'MemoryMarkdownView.swift', type:'code', event:'鼠标静止后点击', count:2 },
  ],
  candidates: [
    { id:'candidate1', title:'完成 README 使用演示', project:'MyClip', status:'doing', evidence:'今天的项目记录明确了演示顺序：从桌面启动，完成引导，再展示应用功能和记忆召回。', count:2 },
    { id:'candidate2', title:'核对截图、记忆与待办的来源关系', project:'MyClip', status:'todo', evidence:'Now.md 将来源关系的复核列为下一步工作。', count:1 },
    { id:'candidate3', title:'整理本周的工作报告', project:'工作记录', status:'todo', evidence:'在日常笔记中记录了与团队同步本周进展的计划。', count:1 },
  ],
  tasks: [
    {id:'t1', title:'检查首次使用与权限引导', project:'MyClip', status:'todo', count:2, evidence:'依次检查屏幕录制、辅助功能与语言设置，再验证 Agent 连接和稍后设置两条首次使用路径。'},
    {id:'t2', title:'验证 Codex 与 Claude 的记忆召回', project:'MyClip', status:'todo', count:2, evidence:'用两个桌面客户端提问同一个项目，核对检索片段、原始记忆和来源链接，确认上下文能够跨客户端延续。'},
    {id:'t3', title:'完善 Memory 的关联与来源展示', project:'MyClip', status:'doing', count:3, evidence:'根据近期工作记录补充 Markdown 之间的 Wikilink，让项目笔记、当日记录与原始截图保持关联。'},
    {id:'t4', title:'准备团队演示与文档', project:'工作记录', status:'doing', count:1, evidence:'整理本期的完成事项与下一步计划，准备通过工作报告同步项目进展。'},
    {id:'t5', title:'梳理应用功能与设置项', project:'MyClip', status:'done', count:2, evidence:'逐项核对 Memory、Timeline、Kanban、Backstage 和设置页，整理截图采集、记忆关联、任务进展与 Agent 配置的展示内容。'},
    {id:'t6', title:'明确演示的叙事顺序', project:'MyClip', status:'done', count:1, evidence:'从 macOS Dock 启动 MyClip，先完成权限和语言设置，再选择 Agent；随后浏览应用功能，最后通过 Codex 与 Claude 召回同一份记忆。'},
  ],
  agents: [
    {id:'codex', name:'Codex', detail:'使用 Codex / ChatGPT 的现有登录。'},
    {id:'claude', name:'Claude Code', detail:'使用 Claude Code 命令行的现有登录和网络设置。首次使用需先在终端完成登录。'},
    {id:'opencode', name:'OpenCode', detail:'通过 opencode acp 连接，使用 OpenCode 已登录的模型和服务商。'},
    {id:'cursor', name:'Cursor', detail:'通过 cursor-agent acp 连接，使用 Cursor 的现有登录。'},
  ],
  jobs: [
    {count:4, tokens:'18,420', ago:'5 分钟前', state:'已完成'},
    {count:2, tokens:'12,860', ago:'18 分钟前', state:'已完成'},
    {count:3, tokens:'21,360', ago:'42 分钟前', state:'已完成'},
    {count:1, tokens:'8,240', ago:'1 小时前', state:'已完成'},
    {count:5, tokens:'26,540', ago:'2 小时前', state:'已完成'},
  ],
};
