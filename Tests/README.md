# 测试

统一入口为仓库根目录的 `bash Scripts/test.sh`，CI 使用相同入口。

| 命令 | 范围 |
|---|---|
| `bash Scripts/test.sh core` | SwiftPM 核心测试，子目录与 Core 职责对应 |
| `bash Scripts/test.sh scripts` | `Adapters/` 下的 Node 适配器测试与 `Packaging/` 下的 Python 打包测试 |
| `bash Scripts/test.sh benchmark` | 构建真实 MCP，运行 `benchmark/tests/`，不调用付费模型 |
| `bash Scripts/test.sh app` | 七组原生应用测试，包含模型生命周期、过滤、文档、目录和滚动 |

单独执行某组核心测试或某个应用测试：

```sh
bash Scripts/test.sh core --filter MemoryPromptTests
bash Scripts/test.sh app MemoryDirectoryTests
bash Scripts/test.sh app AgentActivationTests CaptureLifecycleTests
bash Scripts/test.sh app TaskBoardScrollTests -- /tmp/myclip-task-board.png
```

`MyClipCoreTests/Support/` 放共享 Swift 夹具，`Fixtures/` 放测试 ACP 进程。`Live/` 中的真实 Agent 测试继续通过原有环境变量显式启用，默认跳过；需要登录和模型服务，不能用其跳过结果证明真实 Agent 已通过验收。

`MyClipAppTests/run.sh` 维护唯一一份原生测试编译逻辑。Agent 激活和采集生命周期测试替换系统采集边界；其余测试直接导入构建好的 MyClip 应用模块。所有测试使用临时资料库，编译目标为 macOS 13。
