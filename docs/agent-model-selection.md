# Agent 模型选择

Backstage 的每张 Agent 卡片都有模型入口。Codex、Claude Code、OpenCode、Cursor、WorkBuddy、千问办公共用同一套动态选择流程，模型 ID 和名称均由该 Agent 的实际会话返回，不包含静态模型清单。

打开面板可搜索名称、ID、服务商分组和描述，刷新列表或选择模型。选择仅在 Agent 确认成功后保存，并按 Agent 独立存储；后续每批独立会话都会重新应用。选择“跟随 Agent 默认”会建立无覆盖的新会话，并清除该 Agent 的 MyClip 偏好，不修改命令行全局配置。读取列表和选择模型本身不会发送整理提示词或启用 Agent。

正在整理、识别任务或安装组件时禁止切换。模型被服务商移除、账号无权使用或连接失败时，显示错误并保留原选择；不会自动选择另一个模型。可从现有列表重选、刷新，或恢复默认。没有返回可选模型的 Agent 会显示说明，需在该 Agent 中配置或更新连接组件。

截图整理需要模型支持图片。模型列表协议没有通用的逐模型图片能力字段，因此未声明能力时显示“图片能力未知”，不按名称猜测。OpenCode 可额外使用其本地模型目录的输入模态，按完整服务商/模型 ID 匹配能力；无法读取时仍为未知。已确认不支持图片的条目禁用，当前模型已知不支持图片时，会在提交截图前阻止运行并将批次记为失败。

## 协议与兼容性

- 优先使用 ACP v1 `configOptions` 中 `category: model` 的首个 `select`，支持平铺与分组条目，并监听 `config_option_update` 的完整更新。设置时使用 Agent 返回的配置 ID，调用 `session/set_config_option`，验证返回状态。
- 兼容旧版 `models.availableModels` / `models.currentModelId` 与 `session/set_model`。不要求 Agent 使用固定的模型 ID、服务商或显示名称。
- 会话创建、恢复和模式变更均读取其返回的模型状态。未提供列表时保留 Agent 默认行为，显式保存但已失效的模型不会静默降级。

协议依据：[ACP v1 Session Config Options](https://agentclientprotocol.com/protocol/v1/session-config-options)。当前实现使用协议版本 1；不混用版本 2 草案的字段。

## 验证边界

`AgentModelTests` 覆盖六个 Agent 的连接入口，以及新旧协议、配置通知、按 Agent 保存、重连重应用、选择失败、工作中限制和已知文本模型拦截。全部使用夹具进程、独立偏好域和临时资料库。`AgentModelPickerTests` 使用真实 SwiftUI 面板验证长列表与各状态。

本机已通过独立 OpenCode 会话读取实际可用列表，未发送提示词。其他服务的最终模型列表与可用性仍由其当前连接组件、账号权限及服务端决定；夹具验证不等于真实账号端到端验收。

## 桌面应用与后台整理

桌面 Agent 通过 MCP 读取 MyClip 记忆，和 MyClip 调用 Agent 自动整理截图，是两个方向。前者只需桌面客户端支持 MCP；后者还需要可由程序调用的执行接口。后台进程不要求用户打开终端，但桌面应用的安装与登录也不必然使其后台接口可用。

| Agent | 当前接入方式与边界 |
| --- | --- |
| Codex | 自动识别桌面包内的新旧引擎路径，兼容应用改名；首次连接仍会准备现有 ACP 连接组件，需要可用的 Node.js 环境。连接组件附带的 Codex 依赖不会覆盖桌面引擎，无需另装一份 Codex CLI。MCP 配置也复用同一发现逻辑。 |
| 千问办公 | 默认通过 MyClip 自有 ACP 账号连接组件，由应用自动准备并校验运行组件，无需预装 Node、CLI 或桌面应用；同一千问办公账号授权后动态获取模型及额度。真实图文生成与增量编辑已验证。 |
| WorkBuddy | 默认通过 MyClip 自有 ACP 账号连接组件，自动下载并校验独立运行组件，同一 WorkBuddy 产品账号授权后获取模型和额度；无需预装其他软件。真实图文生成与增量编辑已验证。自定义 CodeBuddy CLI 路径保留原行为。 |
| Claude / Cursor | 桌面 MCP 记忆访问与 Backstage 自动整理分开配置；当前自动整理依赖各自的命令行或连接组件，不表示已接入桌面会话控制。 |
| OpenCode | 当前使用其 ACP 接口，保留原有连接与模型选择流程。 |

OpenAI Docs 的 [Codex App Server](https://learn.chatgpt.com/docs/app-server) 提供构建客户端的执行接口；这不表示外部程序可以直接接管用户当前打开的桌面聊天。MyClip 当前自动整理仍沿用 ACP 适配流程。WorkBuddy 的 [Open API](https://open.workbuddy.cn/docs/openapi) 提供经过 OAuth 授权的本地助手状态、消息与历史接口，适合后续独立接入；当前尚未实现该 OAuth 流程。独立 CLI 的接口见 [CodeBuddy ACP](https://www.codebuddy.cn/docs/cli/acp)。

本次本机验证使用 Codex 桌面包实际可执行文件，在隔离的临时配置目录中重复配置 MCP，并保留其他服务配置。WorkBuddy 5.8.3 内置组件可执行版本命令，但独立 ACP 初始化未返回协议消息，因此保持“桌面端已检测到、自动整理接口待接入”的状态。探测未发送整理提示词，也未修改用户的 Agent 配置。发现逻辑与模型回归测试通过，不等于全部真实服务账号的端到端验收。

### 记忆生成实测（2026-10-24）

另用隔离资料库、独立偏好域和人工生成的图片调用实际生产 `MyClipModel.processNext`，不启动采集、自动队列或云同步，并关闭该测试库的 MCP 召回。图片中的项目参考编号随机生成，没有写入 OCR 或提示词；验收同时检查任务完成、事实与编号写入 Markdown、截图来源关联和工具执行记录。

Codex 桌面引擎实测通过：约 88 秒完成，回传 6 次 `exec_command` 工具调用，写入 Daily、Cedar 项目页并更新 Memory 导航；新记忆成功入库并关联对应截图。测试过程中发现并修复了连接组件附带引擎覆盖桌面引擎的问题，以及 ACP 的 `end_turn` 携带结构化终止错误却被当作成功的问题。后者通过协商连接组件的 `sessionFailure` 元数据处理，不根据回复正文中的错误关键词猜测；普通 warning 不会被误判为失败。

千问办公的内置引擎能够连接，但本次生成在约 4 分钟的测试期限内没有结果、工具调用或记忆写入，不能据此认定其实际生成可用。OpenCode 使用用户当前保存的视觉模型也在相同期限内未完成，尚未确定服务端原因；这不是永久不可用的结论。WorkBuddy 自动整理接口仍待接入；本机没有发现可供验证的 Claude / Cursor 安装。

用户后续确认正式应用中的 OpenCode 正常使用，不能将上述单次隔离测试的期限作为服务不可用的结论。千问办公和 WorkBuddy 的接入要求进一步明确为 ACP 生成且复用桌面账号与额度，当前握手测试尚未验证这种身份绑定；详见 [桌面 ACP 记忆生成约束](desktop-acp-memory-generation.md)。

完整测试素材、任务库、执行记录及 JSON 验收结果保存在本地 Git 忽略目录 `build/diagnostics/memory-generation-20261024/`。这些结论针对当前源码；已安装的 0.6.19 不包含本次修复。

### 千问办公与 WorkBuddy 后续验证（2026-10-25）

此前握手及超时探测不代表当前实现的状态。MyClip 已独立实现账号授权、动态模型、额度和图文工具协议适配，不依赖 Magpie。两个产品均通过首次生成与增量编辑的真实账号测试，随机图片事实、Markdown 文件、来源关联和入库校验全部通过。执行器与账号来源在界面分别显示；实现、验证范围和证据见 [桌面账号 ACP 记忆生成](desktop-acp-memory-generation.md)。
