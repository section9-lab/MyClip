import SwiftUI
import AppKit
import MyClipCore

/// Settings page: two columns per section, a short description on the left and a card of controls on the right.
struct MyClipSettingsView: View {
    @ObservedObject var model: MyClipModel
    @State private var showMCPHelp = false

    var body: some View {
        @ObservedObject var preferences = model.preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                captureSection
                excludedAppsSection
                mcpSection
                storageSection
                aboutSection
            }
            .padding(.horizontal, 40).padding(.top, 32).padding(.bottom, 40)
            .frame(maxWidth: 960).frame(maxWidth: .infinity)
        }
        .onChange(of: preferences.captureSettings) { _ in model.applyCaptureSettings() }
        .onChange(of: preferences.excludedApps) { _ in model.applyCaptureSettings() }
    }

    // MARK: Sections

    private var captureSection: some View {
        @ObservedObject var preferences = model.preferences
        return SettingsSection(symbol: "camera.viewfinder", tint: .blue, title: String(localized: "截图"),
                               description: String(localized: "应用打开后自动采集，退出后停止。MyClip、锁屏和排除的应用不会被记录。")) {
            SettingsRow(String(localized: "采集范围"), subtitle: String(localized: "全屏仅记录焦点窗口所在的显示器")) {
                Picker("采集范围", selection: $preferences.captureSettings.scope) {
                    ForEach(CaptureScope.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().fixedSize()
            }
            SettingsRow(String(localized: "鼠标触发"), subtitle: String(localized: "两项可独立勾选")) {
                Menu {
                    ForEach(MouseCaptureTrigger.allCases) { option in
                        Toggle(option.label, isOn: Binding(get: { preferences.captureSettings.mouseTriggers.contains(option) }, set: { selected in
                            if selected { preferences.captureSettings.mouseTriggers.insert(option) }
                            else { preferences.captureSettings.mouseTriggers.remove(option) }
                        }))
                    }
                } label: { Text(preferences.captureSettings.mouseSummary) }
                    .fixedSize()
                    .accessibilityLabel("鼠标触发")
                    .accessibilityValue(preferences.captureSettings.mouseSummary)
            }
            SettingsRow(String(localized: "键盘触发"), subtitle: String(localized: "忽略长按回车"), last: true) {
                Picker("键盘触发", selection: $preferences.captureSettings.keyboard) {
                    ForEach(KeyboardCaptureMode.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().fixedSize()
            }
        }
    }

    private var excludedAppsSection: some View {
        let ids = excludedBundleIDs
        return SettingsSection(symbol: "hand.raised", tint: .orange, title: String(localized: "排除应用"),
                               description: String(localized: "这些应用在前台时不截图。密码管理器默认已排除。")) {
            VStack(alignment: .leading, spacing: 12) {
                ExcludedAppChips(bundleIDs: ids, remove: removeExcludedApp) {
                    Menu {
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier!) { addExcludedApp(app.bundleIdentifier!) }
                        }
                    } label: { Label(String(localized: "添加正在运行的应用"), systemImage: "plus") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }.padding(14)
        }
    }

    private var mcpSection: some View {
        @ObservedObject var preferences = model.preferences
        let selected = MCPClient.allCases.filter { preferences.mcpClients.contains($0) }
        return SettingsSection(symbol: "point.3.connected.trianglepath.dotted", tint: .green, title: String(localized: "MCP 记忆访问"),
                               description: String(localized: "让你的 Agent 通过 MCP 搜索和阅读 MyClip 里的记忆。关闭开关即刻暂停查询，连接配置会保留。")) {
            Button { showMCPHelp = true } label: {
                Label(String(localized: "如何让 Agent 使用记忆？"), systemImage: "questionmark.circle").font(.callout)
            }.buttonStyle(.link)
                .popover(isPresented: $showMCPHelp, arrowEdge: .bottom) { MCPHelpView() }
        } content: {
            SettingsRow(String(localized: "启用 MyClip MCP 服务"), subtitle: String(localized: "已完成 \(model.statistics.mcpReads.formatted()) 次查询 · 仅在 Agent 实际读取 Memory 时计数"), emphasized: true, last: true) {
                Toggle("启用 MyClip MCP 服务", isOn: Binding(get: { model.mcpEnabled }, set: { model.setMCPEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }.disabled(model.configuringMCP)

            HStack(spacing: 10) {
                ForEach(MCPClient.allCases) { client in
                    MCPClientTile(client: client,
                                  selected: Binding(get: { preferences.mcpClients.contains(client) }, set: { selected in
                                      if selected { preferences.mcpClients.insert(client) }
                                      else { preferences.mcpClients.remove(client) }
                                  }),
                                  result: model.mcpSetupResults[client], mcpEnabled: model.mcpEnabled)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!model.mcpEnabled || model.configuringMCP)
            .overlay(alignment: .top) { Divider() }

            ForEach(MCPClient.allCases.filter { preferences.mcpClients.contains($0) }) { client in
                if case .failed(let message)? = model.mcpSetupResults[client] {
                    Label("\(client.name)：\(message)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }
            }

            HStack(spacing: 12) {
                Text(model.mcpEnabled ? String(localized: "配置完成后，请重启客户端或新建会话。") : String(localized: "MCP 已关闭，Agent 暂时无法通过 MCP 读取 Memory。"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.configuringMCP { ProgressView().controlSize(.small) }
                Button(model.configuringMCP ? String(localized: "正在开启…") : selected.isEmpty ? String(localized: "一键开启") : String(localized: "为 \(selected.count) 个 Agent 一键开启")) { model.configureMCP() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || model.preview || !model.mcpEnabled || model.configuringMCP)
                    .help(model.preview ? String(localized: "预览模式不写入客户端配置") : String(localized: "为所选 Agent 配置 MyClip 记忆访问"))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.primary.opacity(0.03))
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var storageSection: some View {
        @ObservedObject var preferences = model.preferences
        return SettingsSection(symbol: "internaldrive", tint: .gray, title: String(localized: "存储"),
                               description: String(localized: "Memory 和来源信息独立保存。原图过期后记忆仍可用；等待整理的截图会继续保留。")) {
            SettingsRow(String(localized: "原始截图保留"), subtitle: String(localized: "原图与识别文本一同到期清理")) {
                Picker("原始截图保留", selection: $preferences.retentionDays) {
                    Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90); Text("一直保留").tag(0)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            SettingsRow(String(localized: "本地资料库"), subtitle: model.store.root.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"), monospacedSubtitle: true) {
                Button(String(localized: "在访达中打开"), systemImage: "folder") { NSWorkspace.shared.open(model.store.root) }
            }
            SettingsRow(String(localized: "搜索索引"), subtitle: String(localized: "搜索结果缺失或异常时重建"), last: true) {
                Button(String(localized: "重建索引"), systemImage: "arrow.clockwise") { model.rebuildIndex() }
            }
        }
    }

    private var aboutSection: some View {
        SettingsSection(symbol: "paperclip", tint: .pink, title: String(localized: "关于 MyClip"),
                        description: String(localized: "截图，成为记忆。MyClip 根据你的操作自动截图，并交给已启用的 Agent 整理成可搜索的记忆。")) {
            SettingsRow(String(localized: "版本")) {
                Text(appVersion).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Button(String(localized: "重新打开设置向导"), systemImage: "slider.horizontal.3") {
                    NotificationCenter.default.post(name: .init("MyClipShowOnboarding"), object: nil)
                }.disabled(model.preview)
                Spacer()
                Button(String(localized: "退出 MyClip"), systemImage: "power") { NSApp.terminate(nil) }.tint(.red)
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    // MARK: Helpers

    private var excludedBundleIDs: [String] {
        var seen = Set<String>()
        return model.preferences.excludedApps.split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var runningApps: [NSRunningApplication] {
        let excluded = Set(excludedBundleIDs)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !excluded.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func addExcludedApp(_ id: String) {
        guard !excludedBundleIDs.contains(id) else { return }
        let text = model.preferences.excludedApps
        model.preferences.excludedApps = text.isEmpty || text.hasSuffix("\n") ? text + id : text + "\n" + id
    }

    private func removeExcludedApp(_ id: String) {
        model.preferences.excludedApps = excludedBundleIDs.filter { $0 != id }.joined(separator: "\n")
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

// MARK: - Building blocks

/// One settings group: icon, title and description on the left, a card of rows on the right.
private struct SettingsSection<Content: View, Aside: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let description: String
    @ViewBuilder var aside: Aside
    @ViewBuilder var content: Content

    init(symbol: String, tint: Color, title: String, description: String,
         @ViewBuilder aside: () -> Aside, @ViewBuilder content: () -> Content) {
        self.symbol = symbol; self.tint = tint; self.title = title; self.description = description
        self.aside = aside(); self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                        .frame(width: 28, height: 28).background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    Text(title).font(.system(size: 15, weight: .semibold))
                }
                Text(description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                aside
            }
            .frame(width: 250, alignment: .leading).padding(.top, 6)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
        }
    }
}

extension SettingsSection where Aside == EmptyView {
    init(symbol: String, tint: Color, title: String, description: String, @ViewBuilder content: () -> Content) {
        self.init(symbol: symbol, tint: tint, title: title, description: description, aside: { EmptyView() }, content: content)
    }
}

/// Explains the Memory MCP server: how to connect an Agent and what its two read-only tools can do.
private struct MCPHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("让 Agent 读取你的 Memory").font(.headline)
            Text("勾选你使用的 Agent，再点击“一键开启”。完成后重启客户端或新建会话，Agent 就能通过下面 2 个 MCP 工具查询 MyClip 里的记忆。")

            VStack(alignment: .leading, spacing: 10) {
                tool("memory_search", "用问题或关键词搜索记忆，可以按时间范围或来源应用筛选。返回命中的短片段、发生时间和引用的截图；还会顺着 Wikilink 带出相关记忆，并附上是哪一页的哪一句把它们关联起来的。")
                tool("memory_get", "按路径阅读一篇记忆，也可以只读其中一节。同时列出这一页链接到的记忆、引用它的记忆，以及支撑它的截图时间和来源应用。")
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Text("所有工具都是只读的：不会修改记忆，也不会触发截图或 AI 整理。").foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("可以这样问：")
                Text("· 请通过 MyClip 查找我最近的项目记录。")
                Text("· 用 MyClip 看看我上周在做什么，并说明依据来自哪天的截图。")
            }
            Text("关闭开关后，MCP 记忆查询会立即暂停；再次开启即可恢复。").foregroundStyle(.secondary)
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
        .padding(20).frame(width: 420)
    }

    private func tool(_ name: String, _ description: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: name).font(.callout.monospaced().weight(.semibold))
            Text(description).foregroundStyle(.secondary)
        }
    }
}

/// A label on the left, a control on the right, with an inset divider below unless it is the last row.
private struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var monospacedSubtitle = false
    var emphasized = false
    var last = false
    @ViewBuilder var control: Control

    init(_ title: String, subtitle: String? = nil, monospacedSubtitle: Bool = false, emphasized: Bool = false, last: Bool = false,
         @ViewBuilder control: () -> Control) {
        self.title = title; self.subtitle = subtitle; self.monospacedSubtitle = monospacedSubtitle
        self.emphasized = emphasized; self.last = last; self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(emphasized ? .semibold : .medium))
                if let subtitle {
                    Text(subtitle).font(monospacedSubtitle ? .system(.caption, design: .monospaced) : .caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 52)
        .overlay(alignment: .bottom) { if !last { Divider().padding(.leading, 16) } }
    }
}

private struct SettingsBadge: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Excluded apps as removable chips, resolved to app names and icons where the app is installed.
private struct ExcludedAppChips<Trailing: View>: View {
    let bundleIDs: [String]
    let remove: (String) -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        SettingsFlowLayout(spacing: 8) {
            ForEach(bundleIDs, id: \.self) { id in
                let app = InstalledApp(bundleID: id)
                HStack(spacing: 8) {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "app.dashed").foregroundStyle(.secondary).frame(width: 16, height: 16)
                    }
                    Text(app.name).font(.callout).lineLimit(1)
                    Button { remove(id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                    }.buttonStyle(.plain).accessibilityLabel("移除 \(app.name)")
                }
                .padding(.leading, 10).padding(.trailing, 6).frame(height: 30)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                .help(id)
            }
            trailing.frame(height: 30)
        }
    }
}

private struct InstalledApp {
    let name: String
    let icon: NSImage?

    init(bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            name = bundleID
            icon = nil
        }
    }
}

/// One Agent in the MCP strip: its icon alone, highlighted when selected, with a corner badge for the setup result.
private struct MCPClientTile: View {
    let client: MCPClient
    @Binding var selected: Bool
    let result: MCPSetupResult?
    let mcpEnabled: Bool

    var body: some View {
        Button { selected.toggle() } label: {
            icon.frame(width: 26, height: 26)
                .overlay(alignment: .bottomLeading) { variant }
                .frame(width: 46, height: 46)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: 1))
                .overlay(alignment: .topTrailing) { status.offset(x: 5, y: -5) }
                .opacity(selected ? 1 : 0.85)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(client.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var help: String {
        let state: String = switch result {
        case .configured? where selected: mcpEnabled ? String(localized: "已配置") : String(localized: "已配置 · 访问已暂停")
        case .failed? where selected: String(localized: "配置失败")
        default: String(localized: "未配置")
        }
        let note = client == .claudeDesktop ? String(localized: "配置后需完全退出并重开") : nil
        return ([client.name, state] + [note].compactMap { $0 }).joined(separator: " · ")
    }

    /// Claude Code and Claude Desktop share one mark, so each carries a small glyph telling the command line from the app.
    @ViewBuilder private var variant: some View {
        let symbol: String? = switch client {
        case .claudeCode: "terminal.fill"
        case .claudeDesktop: "macwindow"
        default: nil
        }
        if let symbol {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                .frame(width: 15, height: 15).background(Color(nsColor: .darkGray), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                .offset(x: -5, y: 5)
        }
    }

    @ViewBuilder private var status: some View {
        switch result {
        case .configured? where selected:
            Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, mcpEnabled ? .green : .secondary)
                .font(.system(size: 14)).background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(1))
        case .failed? where selected:
            Image(systemName: "exclamationmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .orange)
                .font(.system(size: 14)).background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(1))
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var icon: some View {
        switch client {
        case .codex: Image("CodexIcon").resizable().scaledToFit()
        case .claudeCode, .claudeDesktop: Image("ClaudeIcon").resizable().scaledToFit()
        case .cursor: Image("CursorIcon").resizable().scaledToFit()
        case .openCode: Image("OpenCodeIcon").renderingMode(.template).resizable().scaledToFit()
        case .workBuddy: Image("WorkBuddyIcon").resizable().scaledToFit()
        }
    }
}

/// Wraps fixed-size children onto as many rows as needed.
private struct SettingsFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
