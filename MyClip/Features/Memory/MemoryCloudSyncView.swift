import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MyClipCore

struct MemoryCloudSyncView: View {
    @ObservedObject var sync: CloudSyncController
    @Environment(\.dismiss) private var dismiss
    @State private var connecting: CloudSyncProvider?
    @State private var disconnecting: CloudSyncProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("云端同步").font(.title2.bold())
                Text("把记忆摘要和主题正文同步到 Google Drive 或 Notion，供你的 Personal Agent 读取。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = sync.loadError {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                        Button("重新加载") { sync.start() }
                    } else if !sync.loaded {
                        ProgressView("正在读取同步设置…").frame(maxWidth: .infinity).padding()
                    } else {
                        ForEach(CloudSyncProvider.allCases) { provider in targetCard(provider) }
                    }
                    if sync.preview { Text("预览模式不连接账号或上传记忆。").font(.caption).foregroundStyle(.secondary) }
                    Text("MyClip 是记忆主库。同步只更新 MyClip 创建的专属目录和文件，云端修改不会回写本地；本地删除或取消同步某类内容后，对应云端副本会移入回收站。原始截图和 OCR 不上传。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(24)
            }
            Divider()
            HStack {
                Button("立即同步全部") { sync.syncAll() }
                    .disabled(!CloudSyncProvider.allCases.contains(where: sync.canSync))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
        }
        .frame(minWidth: 540, idealWidth: 620, maxWidth: 700, minHeight: 420, idealHeight: 620, maxHeight: 740)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { sync.start() }
        .sheet(item: $connecting) { CloudConnectionView(sync: sync, provider: $0) }
        .confirmationDialog("断开云端连接？", isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }), titleVisibility: .visible) {
            if let provider = disconnecting {
                Button("断开 \(provider.name)", role: .destructive) { sync.disconnect(provider); disconnecting = nil }
            }
        } message: { Text("停止此目标的同步并移除本机保存的令牌，已有云端副本和本地记忆会保留。") }
    }

    private func targetCard(_ provider: CloudSyncProvider) -> some View {
        let target = sync.target(provider)
        let connected = target?.connected == true
        let operation = sync.operations[provider]
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.name).font(.headline)
                        Text(connected ? target?.account ?? "" : String(localized: "未连接"))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if connected {
                        Menu("管理连接") {
                            Button("重新连接…") { connecting = provider }
                            Button("断开连接…", role: .destructive) { disconnecting = provider }
                        }.fixedSize().disabled(operation != nil || sync.preview)
                    } else {
                        Button("连接账号…") { connecting = provider }.disabled(sync.preview || operation != nil)
                    }
                }
                if connected, let target {
                    Divider()
                    Toggle("自动同步", isOn: option(provider, keyPath: \.automatic))
                        .disabled(operation != nil)
                    Text("Memory 变化后自动更新；MyClip 运行时生效。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("每日记录（Daily）", isOn: option(provider, keyPath: \.includeDaily))
                        .font(.callout).disabled(operation != nil)
                    Text("默认同步个人信息、当前关注和主题记忆。").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .center) {
                        status(provider, target: target)
                        Spacer(minLength: 12)
                        if sync.syncing.contains(provider) {
                            Button("停止") { sync.cancelSync(provider) }
                        } else {
                            Button("立即同步") { sync.sync(provider) }.disabled(!sync.canSync(provider))
                        }
                    }
                    if let url = target.rootURL.flatMap(URL.init(string:)) {
                        Link("打开云端目录", destination: url).font(.caption)
                    } else {
                        Text("首次同步会创建 MyClip Memory 专属目录。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = sync.errors[provider] {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(10)
                .disabled(sync.preview)
        }
        .accessibilityElement(children: .contain).accessibilityLabel("\(provider.name) 云端同步")
    }

    @ViewBuilder private func status(_ provider: CloudSyncProvider, target: CloudSyncTarget) -> some View {
        if let operation = sync.operations[provider] {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(operation).lineLimit(2) }.font(.caption)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                let pending = sync.pending(provider)
                if sync.errors[provider] != nil { Text("同步未完成").foregroundStyle(.red) }
                if pending > 0 { Text("\(pending) 项变更待同步") }
                else if sync.errors[provider] == nil {
                    if target.lastSyncedAt != nil { Text("已同步") }
                    else { Text("等待可同步的记忆") }
                }
                if let date = target.lastSyncedAt {
                    Text("上次成功：\(date.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                }
            }.font(.caption)
        }
    }
    private func option(_ provider: CloudSyncProvider, keyPath: WritableKeyPath<CloudSyncOptions, Bool>) -> Binding<Bool> {
        Binding(get: { sync.target(provider)?.options[keyPath: keyPath] ?? false }, set: { value in
            guard var options = sync.target(provider)?.options else { return }
            options[keyPath: keyPath] = value
            sync.setOptions(options, for: provider)
        })
    }
}

private struct CloudConnectionView: View {
    @ObservedObject var sync: CloudSyncController
    let provider: CloudSyncProvider
    @Environment(\.dismiss) private var dismiss
    @State private var googleClient: GoogleDesktopClient?
    @State private var clientFileName = ""
    @State private var folder = ""
    @State private var token = ""
    @State private var page = ""
    @State private var importError: String?
    @State private var connection: Task<Void, Never>?

    private var working: Bool { sync.operations[provider] != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("连接 \(provider.name)").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if provider == .googleDrive {
                        Text("首次连接需要 Google Cloud 的桌面 OAuth 客户端配置。启用 Google Drive API，创建“桌面应用”客户端并下载 JSON，然后在这里导入。")
                            .font(.callout).foregroundStyle(.secondary)
                        Link("查看 Google 桌面授权配置说明", destination: URL(string: "https://developers.google.com/identity/protocols/oauth2/native-app")!)
                        HStack {
                            Button("导入 OAuth 配置…", action: importGoogleClient)
                            Text(googleClient == nil ? String(localized: "尚未选择配置文件") : clientFileName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text("授权后自动创建 MyClip Memory 文件夹，并保存为 Google 文档；只申请访问 MyClip 创建或获授权的文件。")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("指定父文件夹（可选）") {
                            TextField("Google Drive 文件夹链接或 ID", text: $folder)
                                .accessibilityLabel("Google Drive 父文件夹")
                            Text("留空保存到我的云端硬盘；指定文件夹必须已授权此 OAuth 应用访问。也可以在首次同步后直接在 Drive 中移动专属目录。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("创建一个具备读取、插入和更新内容权限的 Notion 内部集成，并在目标页面的“连接”菜单中授权该集成。也可以使用个人访问令牌。")
                            .font(.callout).foregroundStyle(.secondary)
                        Link("查看 Notion 集成授权说明", destination: URL(string: "https://developers.notion.com/guides/get-started/authorization")!)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("集成令牌").font(.callout)
                            SecureField("Notion API 令牌", text: $token).accessibilityLabel("Notion 集成令牌")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("目标页面").font(.callout)
                            TextField("Notion 页面链接或 ID", text: $page).accessibilityLabel("Notion 目标页面")
                        }
                        Text("MyClip 会在目标页面下创建专属目录，并为摘要和每篇记忆创建子页面。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("令牌和授权凭据仅保存在此 Mac 的系统钥匙串中。连接后开始同步当前选定范围的记忆。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = importError ?? sync.errors[provider] {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let operation = sync.operations[provider] { ProgressView(operation).controlSize(.small) }
                }.padding(.vertical, 2)
                    .disabled(working)
            }
            HStack {
                Button("取消") { connection?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(working ? String(localized: "正在连接…") : String(localized: "连接并同步"), action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || sync.preview || (provider == .googleDrive ? googleClient == nil : token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24).frame(width: 540, height: 510)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(working)
        .onDisappear { connection?.cancel(); token = ""; googleClient = nil }
    }
    private func importGoogleClient() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = String(localized: "选择 Google Cloud 下载的桌面 OAuth 客户端 JSON 配置。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) < 65536 else { throw CloudSyncError.message(String(localized: "OAuth 配置文件过大，请选择客户端 JSON。")) }
            googleClient = try GoogleDesktopClient.decode(Data(contentsOf: url)); clientFileName = url.lastPathComponent; importError = nil
        } catch { googleClient = nil; importError = error.localizedDescription }
    }
    private func connect() {
        connection = Task {
            let success: Bool
            if provider == .googleDrive, let googleClient { success = await sync.connectGoogle(googleClient, folder: folder) }
            else { success = await sync.connectNotion(token: token, page: page) }
            if success { token = ""; sync.sync(provider); dismiss() }
        }
    }
}
