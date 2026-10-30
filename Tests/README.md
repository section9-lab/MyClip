# 测试

统一入口为仓库根目录的 `bash Scripts/test.sh`，CI 使用相同入口。

| 命令 | 范围 |
|---|---|
| `bash Scripts/test.sh core` | SwiftPM 核心测试，子目录与 Core 职责对应 |
| `bash Scripts/test.sh cloud-sync` | Google Drive / Notion 同步协议、恢复、自动调度、OAuth 回调及原生云端面板，不需要账号或 XCTest |
| `bash Scripts/test.sh scripts` | `Adapters/` 下的 Node 适配器测试与 `Packaging/` 下的 Python 打包测试 |
| `bash Scripts/test.sh benchmark` | 构建真实 MCP，运行 `benchmark/tests/`，不调用付费模型 |
| `bash Scripts/test.sh performance` | 真实 Core、应用模型与 Backstage 的省电回归及 CPU 微基准；不需要 XCTest 或完整 Xcode，需要 macOS GUI 会话 |
| `bash Scripts/test.sh app` | 原生应用测试，包含 Agent 激活、模型选择与失败恢复、采集生命周期、过滤、文档、目录、看板与菜单栏、滚动和 Backstage 响应性 |

单独执行某组核心测试或某个应用测试：

```sh
bash Scripts/test.sh core --filter MemoryPromptTests
bash Scripts/test.sh app MemoryDirectoryTests
bash Scripts/test.sh app AgentActivationTests CaptureLifecycleTests
bash Scripts/test.sh app AgentModelTests
bash Scripts/test.sh app AgentRecoveryTests
bash Scripts/test.sh app AgentModelPickerTests -- build/agent-model-picker/screenshots
bash Scripts/test.sh app TaskBoardScrollTests -- /tmp/myclip-task-board.png
bash Scripts/test.sh app MenuBarBoardTests -- build/menu-bar-validation
bash Scripts/test.sh app BackstageResponsivenessTests
```

`Performance/` 验证空闲刷新不发布状态、不读 Markdown、不写数据库；按域失效；独立 SQLite 连接与外部文件增删改名；校验缓存与敏感信息检查；低电量/温度策略；流式进度去重仍更新活跃时间；50 条执行记录的固定高度、窄窗口以及显示/隐藏 CPU。采集边界和未打开的执行详情 sheet 使用测试替身，其余使用真实 Core、模型和 Backstage。数字是短时合成 CPU 基准，不代表整机功耗或续航；对照方法见 [性能与能耗](../docs/performance-and-energy.md)。

`MyClipCoreTests/Support/` 放共享 Swift 夹具，`Fixtures/` 放测试 ACP 进程。`Live/` 中的真实 Agent 测试继续通过原有环境变量显式启用，默认跳过；需要登录和模型服务，不能用其跳过结果证明真实 Agent 已通过验收。

`MyClipAppTests/run.sh` 维护唯一一份原生测试编译逻辑。Agent 激活和采集生命周期测试替换系统采集边界；菜单栏测试直接编译真实模型、菜单栏控制器和只读看板；其余测试直接导入构建好的 MyClip 应用模块。所有测试使用临时资料库，编译目标为 macOS 13。

`MenuBarBoardTests` 检查三列独立滚动、窄窗口、加载与读取失败、菜单栏展开收起及打开和退出应用的行为，不需要完整 Xcode 或 XCTest。传入截图目录可保存原生浅色、深色和错误状态截图。

`AgentModelTests` 使用真实 ACP 夹具子进程、独立偏好域和临时资料库，验证六种 Agent 的动态列表与独立保存、新会话重应用、新旧协议、配置更新、失败保留、失效模型、工作中禁用和图片能力拦截；不调用付费模型。`AgentModelPickerTests` 验证六个 Agent 的长列表滚动及加载、空、错误、工作中和深色面板，并可保存截图。这些结果不表示六家服务的账号均已通过真实端到端调用。

`AgentRecoveryTests` 使用真实应用调度器、SQLite 队列和 ACP 子进程，验证连接失败退避恢复、证书错误自动重试、登录失败保留、手动暂停与停用保护，以及启动后自动恢复旧版本误暂停的队列。不需要完整 Xcode，不修改真实资料库或调用付费模型。

`AgentSwitchingTests` 验证停用和切换时会中断旧 Agent、保留最终用量、把未完成截图交给新 Agent，并覆盖不响应取消、连接卡住、快速连续切换、旧重试阻塞和任务补处理中断。测试使用独立资料库和 ACP 子进程，不调用真实模型。

`BackstageResponsivenessTests` 验证静态图标更新不会触发重复重绘、鼠标跟踪区域能够复用，以及执行记录在嵌套滚动、进度变化、完成、缩放、隐藏和重新显示时保持固定高度。它通过父子关系定位内层记录列表，避免将侧边栏或外层页面当成被测列表；独立计时器会在主线程失去响应时终止测试。相关问题见 [Backstage 布局卡顿](../docs/backstage-layout-hang.md)。

`CloudSync/` 使用可注入的 REST 和凭据存储验证云端协议，并验证真实的本机 OAuth 回调。原生面板检查需要 macOS GUI 会话，截图写入 `build/cloud-sync-verification/`。这些检查不表示真实云端账号已通过端到端验收，接入说明见 [Memory 云端同步](../docs/memory-cloud-sync.md)。
