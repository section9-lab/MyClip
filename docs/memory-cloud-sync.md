# Memory 云端同步

在 **Memory → 云端同步** 中连接 Google Drive 或 Notion。每个目标独立管理连接、自动同步和同步范围，也可以点击**立即同步**或**立即同步全部**。

这是从 MyClip 到云端的单向发布。Personal Agent 需要通过自己的 Google Drive 或 Notion 连接器读取云端文档；MyClip 不会直接写入这些 Agent 的原生 Memory。

## Google Drive 接入

1. 在 [Google Cloud Console](https://console.cloud.google.com/) 创建或选择项目，启用 **Google Drive API**。
2. 配置 OAuth 同意屏幕。在测试模式下，将实际使用的 Google 账号添加为测试用户。
3. 创建类型为**桌面应用**的 OAuth 客户端，下载客户端 JSON。
4. 在 MyClip 的 Google Drive 卡片点击**连接账号… → 导入 OAuth 配置…**，选择该 JSON，再点击**连接并同步**。
5. 在默认浏览器中选择账号并授权，返回 MyClip 查看同步结果。

MyClip 使用桌面 OAuth 的浏览器授权、PKCE 和本机回环回调，并保存刷新令牌以便后续自动同步。不要导入 Web 应用客户端配置。

权限仅申请 `drive.file`，用于 MyClip 创建或明确获授权的文件。默认在“我的云端硬盘”创建 `MyClip Memory · <资料库标识>` 文件夹，记忆保存为可供连接器读取的 **Google 文档**。最先阅读 `00-MyClip-Memory.md` 文档，再按其中链接读取各篇正文。

“指定父文件夹”是可选项，目标必须已向此 OAuth 应用授权。仅粘贴现有文件夹链接不会扩大权限；无法访问时请留空。首次同步后，可以在 Drive 中移动 MyClip 创建的专属文件夹，后续继续按其 ID 更新。

Google 接入与权限说明：[桌面 OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)、[Drive 权限范围](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)、[文件上传与格式转换](https://developers.google.com/workspace/drive/api/guides/manage-uploads)。

## Notion 接入

1. 在 [Notion 集成管理](https://www.notion.so/profile/integrations) 创建内部集成，启用**读取内容、插入内容、更新内容**权限。也支持具有相应访问权限的个人访问令牌。
2. 在 Notion 选一个普通页面作为目标，从该页面的**连接**菜单添加集成。目标应为页面，而非数据库或数据源。
3. 在 MyClip 的 Notion 卡片点击**连接账号…**，在令牌输入框填写令牌，并粘贴目标页面链接或 ID。
4. 点击**连接并同步**。MyClip 会在该页面下创建专属的 `MyClip Memory · <资料库标识>` 页面，并为摘要和每篇记忆创建子页面。

当前是适合个人使用的应用内配置方式，需要自行创建集成；未提供需要服务端保管客户端密钥的公开 Notion OAuth 注册服务。

Notion 接入说明：[授权方式](https://developers.notion.com/guides/get-started/authorization)、[Markdown 内容更新](https://developers.notion.com/reference/update-page-markdown)。

## 内容、自动更新与删除

- 默认发布已编辑的个人信息、当前关注和主题记忆。空文件和初始模板不发布；Daily 默认关闭，可开启。旧版 Inbox 仅保留本地读取兼容，不再提供同步选项，也不会因升级而开始上传。
- 云端入口包含 Profile、Now 的简短摘录和记忆目录；每篇正文保留来源路径、版本及观察时间。笔记链接转换为对应的云端链接。不会读取或上传原始截图、独立 OCR 文本文件；记忆正文中的文字和来源引用会随正文发布。
- 自动同步在 MyClip 运行时生效。应用读取到本地记忆变化后，短暂合并变更再发布；不要求打开 Memory 页面。关闭自动同步后仍可立即同步。
- 每次仅写入发生变化的文档。改名保留远端文档 ID；中断或网络失败会保留已完成进度。自动模式下失败后延迟重试，也可以手动重试。点击**停止**后，需立即同步或重新启用自动同步才会继续。
- MyClip 是内容主库。云端编辑不会回写本地，后续本地更新会替换对应受管文档的内容。不建议直接编辑这些云端副本。
- 本地删除记忆或取消 Daily 的同步范围后，下次同步会将对应的受管云端文档移入回收站。旧版曾开启 Inbox 同步的受管副本也会在下次同步时移入回收站，本地原文件不受影响。MyClip 不会清理用户自行添加的文件或页面。
- **断开连接**停止后续同步并删除此 Mac 保存的令牌，保留本地记忆、已有云端副本和不含凭据的同步映射；重新连接同一账号与目标可继续更新。切换账号或父目录会创建新的同步目标，旧副本保留。
- 凭据保存在此 Mac 的系统钥匙串中。资料库仅保存目标位置、账号标识、文档映射、范围和同步进度，不保存令牌。预览模式不会读取凭据或连接云端。

如果出现权限错误，请检查 Google OAuth 配置，或确认 Notion 集成已加入目标页面，然后重新连接。若云端目录被移入回收站，请先恢复原目录。MyClip 会拒绝接管无法确认归属的同名页面；遇到文档过大或 Notion 格式转换警告时会显示错误，不会将该次同步标为成功。

## 验证

```sh
bash Scripts/test.sh cloud-sync
```

该检查覆盖导出范围、增量更新、改名和删除、重启恢复、部分失败、刷新令牌、取消授权、自动同步及原生面板。REST 响应使用可注入的模拟服务；OAuth 回调使用真实的本机监听器。所有检查使用临时资料库，不需要账号或真实云端写入。

真实账号的授权、Google 文档转换和 Notion 页面写入，仍需配置账号后做端到端验证。签名应用与安装包继续使用项目的 Xcode 构建流程。
