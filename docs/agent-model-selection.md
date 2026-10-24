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
