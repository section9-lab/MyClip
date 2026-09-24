# 开发与目录结构

所有命令从仓库根目录执行。开发环境为 macOS、Xcode 26、Swift 6.2、XcodeGen、Python 3 和 Node.js。

## 源码

| 目录 | 职责 |
|---|---|
| `MyClip/App/` | 应用入口、窗口、菜单栏、权限；`Model/` 协调各项功能 |
| `MyClip/Features/` | 按 Agent、Capture、Memory、Tasks、Analytics、Settings、Onboarding 划分的界面与系统服务 |
| `MyClip/UI/` | 多个界面共用的视图和 macOS 兼容辅助代码 |
| `MyClip/Core/` | Swift Package `MyClipCore`，不依赖应用界面；按职责划分子目录 |
| `MyClip/Core/Storage/` | `LibraryStore` 的初始化、数据库结构与迁移、资料库快照、SQLite 封装 |
| `MyClip/Core/Capture/` | 截图、触发规则、过滤、OCR、截图存储 |
| `MyClip/Core/Memory/` | Markdown 文件、检索、链接、索引、校验、整理后的写回 |
| `MyClip/Core/Organization/` | 整理队列、批次、交接与重试 |
| `MyClip/Core/Agent/` | ACP 通信、会话、执行记录、用量 |
| `MyClip/Core/Tasks/` | 用户工作任务、任务响应解析、报告与分享目标 |
| `MyClip/Core/MCP/` | 只读记忆服务与客户端配置 |
| `MyClip/Core/Localization/` | 应用语言选择 |
| `MyClip/Core/Prompt/` | 应用发给 Agent 的提示词和 MCP 工具说明 |
| `Sources/MyClipMCP/` | 独立的 `myclip-mcp` 命令行入口 |
| `Legacy/Kara/` | 旧 Kara 源码，保留供查阅，不参与构建 |

核心仍是一个 Swift Package，数据仍由同一个 `LibraryStore` actor 管理。各领域目录里的 `LibraryStore` 扩展负责相应操作，没有增加数据库、服务层或新的模块依赖。

`project.yml` 是 Xcode 项目的来源。新增、移动应用源文件后运行 `xcodegen generate`，将生成的 `MyClip.xcodeproj` 一起保留。Core 的 Swift 文件由 SwiftPM 自动发现。

## 提示词

提示词使用 Swift 多行字符串，可以直接插入语言、时间、任务、来源和限制值，无需额外的模板加载器。

| 文件 | 修改内容 |
|---|---|
| [MemoryRules.swift](../MyClip/Core/Prompt/MemoryRules.swift) | 所有记忆写入场景共享的事实、目录、来源、链接和安全规则 |
| [MemoryPrompt.swift](../MyClip/Core/Prompt/MemoryPrompt.swift) | 截图整理、冷启动、做梦、巡检、周汇总的流程与上下文组装 |
| [HandoffPrompt.swift](../MyClip/Core/Prompt/HandoffPrompt.swift) | 整理交接、回退处理与记忆检查结果的提示文字 |
| [TaskPrompt.swift](../MyClip/Core/Prompt/TaskPrompt.swift) | 任务识别、已有任务上下文、JSON 返回约定 |
| [MCPPrompt.swift](../MyClip/Core/Prompt/MCPPrompt.swift) | MCP 初始化指引、资料摘要说明、工具描述和参数定义 |

调用方只传入数据。任务 JSON 的解析留在 `Core/Tasks/TaskResponse.swift`；文件读取、检索、执行 Agent 和写回数据库不放进 Prompt。

修改共享写入规则时只改 `MemoryRules`，避免各个流程的规则产生分歧。纯提示词测试在 `Tests/MyClipCoreTests/Prompt/`；需要真实存储或队列的联动测试留在对应领域。评测专用提示词在 `benchmark/prompts/`，不进入应用。

## 构建与验证

```sh
xcodegen generate
bash Scripts/test.sh
```

`Scripts/test.sh` 是本地与 CI 共用的入口，默认依次运行核心、脚本、benchmark 和原生应用测试。原生测试需要 macOS 图形会话。分组运行和单项筛选见 [测试说明](../Tests/README.md)。

```sh
xcodebuild -project MyClip.xcodeproj -scheme MyClip -configuration Debug build
bash Scripts/package_dmg.sh
```

评测入口、数据隔离和计分口径见 [benchmark](../benchmark/README.md)。公开数据、派生语料、历史运行、缓存、二进制及 API 密钥都留在原位置，由 `benchmark/.gitignore` 排除。
