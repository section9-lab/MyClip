# 测试

统一入口为仓库根目录的 `bash Scripts/test.sh`，CI 使用相同入口。

| 命令 | 范围 |
|---|---|
| `bash Scripts/test.sh core` | SwiftPM 核心测试，子目录与 Core 职责对应 |
| `bash Scripts/test.sh cloud-sync` | Google Drive / Notion 同步协议、恢复、自动调度、OAuth 回调及原生云端面板，不需要账号或 XCTest |
| `bash Scripts/test.sh scripts` | `Adapters/` 下的 Node 适配器测试与 `Packaging/` 下的 Python 打包测试 |
| `bash Scripts/test.sh benchmark` | 构建真实 MCP，运行 `benchmark/tests/`，不调用付费模型 |
| `bash Scripts/test.sh app` | 八组原生应用测试，包含模型生命周期、过滤、文档、目录、滚动和 Backstage 响应性 |

单独执行某组核心测试或某个应用测试：

```sh
bash Scripts/test.sh core --filter MemoryPromptTests
bash Scripts/test.sh app MemoryDirectoryTests
bash Scripts/test.sh app AgentActivationTests CaptureLifecycleTests
bash Scripts/test.sh app TaskBoardScrollTests -- /tmp/myclip-task-board.png
bash Scripts/test.sh app BackstageResponsivenessTests
```

`MyClipCoreTests/Support/` 放共享 Swift 夹具，`Fixtures/` 放测试 ACP 进程。`Live/` 中的真实 Agent 测试继续通过原有环境变量显式启用，默认跳过；需要登录和模型服务，不能用其跳过结果证明真实 Agent 已通过验收。

`MyClipAppTests/run.sh` 维护唯一一份原生测试编译逻辑。Agent 激活和采集生命周期测试替换系统采集边界；其余测试直接导入构建好的 MyClip 应用模块。所有测试使用临时资料库，编译目标为 macOS 13。

`BackstageResponsivenessTests` 验证静态图标更新不会触发重复重绘、鼠标跟踪区域能够复用，以及执行记录在嵌套滚动、进度变化、完成、缩放、隐藏和重新显示时保持固定高度。它通过父子关系定位内层记录列表，避免将侧边栏或外层页面当成被测列表；独立计时器会在主线程失去响应时终止测试。相关问题见 [Backstage 布局卡顿](../docs/backstage-layout-hang.md)。

`CloudSync/` 使用可注入的 REST 和凭据存储验证云端协议，并验证真实的本机 OAuth 回调。原生面板检查需要 macOS GUI 会话，截图写入 `build/cloud-sync-verification/`。这些检查不表示真实云端账号已通过端到端验收，接入说明见 [Memory 云端同步](../docs/memory-cloud-sync.md)。
