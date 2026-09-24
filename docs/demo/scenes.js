/* One source of truth for the review player and the renderable composition. */
window.MYCLIP_DEMO = {
  width: 1600,
  height: 1000,
  duration: 45,
  chapters: [
    { time: 0, title: "桌面启动" },
    { time: 2, title: "首次使用" },
    { time: 8, title: "Memory" },
    { time: 9.5, title: "Timeline" },
    { time: 12, title: "Kanban" },
    { time: 13.5, title: "Reports" },
    { time: 18, title: "Backstage" },
    { time: 21, title: "Settings" },
    { time: 24, title: "Codex 召回" },
    { time: 34.5, title: "Claude 召回" },
  ],
  scenes: [
    {
      id: "desktop",
      time: 0,
      kind: "desktop",
      title: "从 macOS 桌面开始",
      description: "点击 Dock 里的 MyClip；图标跳动两次，再打开首次使用引导。",
    },
    {
      id: "dock-launch",
      time: 0.72,
      kind: "desktop",
      title: "点击 MyClip · 两次跳动",
      description: "MyClip 从 Dock 启动，完成两次跳动后展开 Onboarding 窗口。",
    },
    {
      id: "onboarding",
      time: 2,
      title: "第 1 步 · 权限与语言",
      description:
        "先开启屏幕录制与辅助功能权限；文件访问为推荐选项，语言也在这一步设置。",
    },
    {
      id: "onboarding-ready",
      time: 4.5,
      title: "权限已就绪",
      description:
        "两项必需权限已完成，点击「下一步」选择 Agent。文件访问未开启也可继续。",
    },
    {
      id: "onboarding-agent",
      time: 5.2,
      title: "第 2 步 · 选择 Agent",
      description:
        "选择整理 Agent，也可以稍后设置。点击「开始使用」进入资料库，或返回上一步检查授权。",
    },
    {
      id: "memory",
      time: 8,
      title: "本地 Memory",
      description:
        "概览本地 Markdown 目录与记忆正文，不展开来源或编辑器。",
    },
    {
      id: "timeline",
      time: 9.5,
      title: "截图时间线",
      description: "按应用、日期和触发事件筛选截图，点击缩略图查看详情。",
    },
    {
      id: "capture-ocr",
      time: 11,
      title: "读取 OCR 文本",
      description: "切换到识别文本，查看同一张截图提取出的内容。",
    },
    {
      id: "kanban",
      time: 12,
      title: "任务看板",
      description:
        "概览待确认区域和三个任务状态，不展开卡片或任务详情。",
    },
    {
      id: "reports",
      time: 13.5,
      title: "查看日报",
      description: "查看当天的工作报告，随后切换周报和分享入口。",
    },
    {
      id: "reports-weekly",
      time: 14.7,
      title: "切换到周报",
      description: "切换到周报，概览本周的工作进展。",
    },
    {
      id: "report-share",
      time: 15.9,
      title: "查看分享入口",
      description:
        "预览报告，查看 Gmail、Notion、飞书等分享入口。",
    },
    {
      id: "backstage",
      time: 18,
      title: "Agent 与整理记录",
      description: "管理四种整理 Agent，查看任务队列、完成记录和整理状态。",
    },
    {
      id: "backstage-usage",
      time: 19.6,
      title: "查看 Token 用量",
      description: "查看用量趋势、输入与输出、缓存命中率和回传完整度。",
    },
    {
      id: "settings",
      time: 21,
      title: "完整设置页",
      description:
        "从侧边栏底部的齿轮进入设置：截图、排除应用、MCP、存储与关于。",
    },
    {
      id: "settings-bottom",
      time: 22.5,
      title: "存储、索引与版本",
      description:
        "截图保留时长、本地资料库、重建索引与版本信息，都沿用当前应用的真实设置页。",
    },
    {
      id: "codex-launch",
      time: 24,
      kind: "recall",
      client: "codex",
      title: "从 Dock 打开 Codex",
      description:
        "完成 MyClip 设置，切换到 Codex 桌面端。客户端画面为交互示意。",
    },
    {
      id: "codex-question",
      time: 25.3,
      kind: "recall",
      client: "codex",
      title: "Codex · 询问之前的决定",
      description:
        "在 Codex 中询问演示方向和下一步，由 MyClip 的本地记忆提供上下文。",
    },
    {
      id: "codex-search",
      time: 26.3,
      kind: "recall",
      client: "codex",
      title: "Codex · 搜索 MyClip 记忆",
      description:
        "memory_search 搜索「演示」；这里呈现独立示例资料库的实际 MCP 返回。",
    },
    {
      id: "codex-read",
      time: 27.1,
      kind: "recall",
      client: "codex",
      title: "Codex · 读取原始记忆",
      description:
        "通过 memory_get 读取 Memory.md 的「最近的决定」与 Now.md，核对原文。",
    },
    {
      id: "codex-answer",
      time: 28,
      kind: "recall",
      client: "codex",
      title: "Codex · 带来源的召回",
      description:
        "根据同一份示例记忆呈现回答，来源按钮可展开实际返回的 Markdown。",
    },
    {
      id: "claude-launch",
      time: 34.5,
      kind: "recall",
      client: "claude",
      title: "切换到 Claude 桌面端",
      description:
        "从 Dock 打开 Claude，继续查询同一份 MyClip 本地记忆。客户端画面为交互示意。",
    },
    {
      id: "claude-question",
      time: 35.8,
      kind: "recall",
      client: "claude",
      title: "Claude · 召回相同的上下文",
      description:
        "切换客户端后，仍能使用同一份 MyClip 记忆，找回之前的决定与待办。",
    },
    {
      id: "claude-search",
      time: 36.8,
      kind: "recall",
      client: "claude",
      title: "Claude · 搜索 MyClip 记忆",
      description: "Claude 的交互示意沿用已验证的 memory_search 调用与结果。",
    },
    {
      id: "claude-read",
      time: 37.6,
      kind: "recall",
      client: "claude",
      title: "Claude · 读取决定与下一步",
      description: "读取 Memory.md 与 Now.md，将回答建立在实际的记忆原文上。",
    },
    {
      id: "claude-answer",
      time: 38.5,
      kind: "recall",
      client: "claude",
      title: "Claude · 记忆跨客户端延续",
      description:
        "两个桌面客户端、一份本地记忆。回答为演示编排；工具数据来自真实 MyClip MCP。",
    },
  ],
};
