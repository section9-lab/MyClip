import SwiftUI
import AppKit
import MyClipCore

/// One Timeline card: every look at the same window inside `LibraryStore.sceneGap`, newest frame first.
struct CaptureScene: Identifiable {
    let id: String
    let frames: [ClipCapture]
    var latest: ClipCapture { frames[0] }
    var earliest: ClipCapture { frames[frames.count - 1] }
    var imageCount: Int { Set(frames.map(\.imageID)).count }

    /// Folds consecutive captures by scene; a filter on the trigger event shows every occurrence instead.
    static func fold(_ captures: [ClipCapture], folding: Bool) -> [CaptureScene] {
        guard folding else { return captures.map { CaptureScene(id: $0.id.uuidString, frames: [$0]) } }
        var order: [String] = []
        var frames: [String: [ClipCapture]] = [:]
        for capture in captures {
            if frames[capture.sceneID] == nil { order.append(capture.sceneID) }
            frames[capture.sceneID, default: []].append(capture)
        }
        return order.map { CaptureScene(id: $0, frames: frames[$0]!) }
    }
}

struct CaptureLibraryView: View {
    @ObservedObject var model: MyClipModel
    @Environment(\.locale) private var locale
    @State private var source: CaptureScene?
    @State private var showDateFilter = false
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    @State private var endDate = Calendar.current.startOfDay(for: Date())
    var captures: [ClipCapture] { model.results.captures }
    var folding: Bool { model.captureFilter.event == .all }
    var scenes: [CaptureScene] { CaptureScene.fold(captures, folding: folding) }
    var days: [Date] { Array(Set(scenes.map { Calendar.current.startOfDay(for: $0.latest.date) })).sorted(by: >) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ViewThatFits(in: .horizontal) {
                    HStack { resultSummary; Spacer(minLength: 20); filterControls }
                    VStack(alignment: .leading, spacing: 12) {
                        filterControls.frame(maxWidth: .infinity, alignment: .trailing)
                        resultSummary
                    }
                }
                if captures.isEmpty {
                    if model.captureFilter.isActive {
                        LibraryEmptyView(symbol: "line.3.horizontal.decrease", title: String(localized: "没有符合条件的截图"), detail: String(localized: "试试其他应用、日期或触发事件，或清除筛选条件。"), action: String(localized: "清除筛选")) { model.captureFilter = CaptureFilter() }
                    } else if !model.search.isEmpty {
                        LibraryEmptyView(symbol: "magnifyingglass", title: String(localized: "没有找到相关截图"), detail: String(localized: "试试其他关键词，或清除搜索查看全部截图。"), action: String(localized: "清除搜索")) { model.search = "" }
                    } else {
                        LibraryEmptyView(symbol: model.capturing ? "record.circle" : "macwindow", title: model.capturing ? String(localized: "等待第一张截图") : String(localized: "等待自动采集"), detail: model.preferences.captureSettings.description, action: String(localized: "查看采集设置")) { model.open(.settings) }
                    }
                } else {
                    ForEach(days, id: \.self) { day in
                        Text(day, format: .dateTime.year().month().day().weekday()).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 20)], alignment: .leading, spacing: 26) {
                        ForEach(scenes.filter { Calendar.current.isDate($0.latest.date, inSameDayAs: day) }) { scene in
                            let capture = scene.latest
                            Button { source = scene } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    CaptureThumbnail(capture: capture).frame(height: 166).clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(alignment: .topTrailing) {
                                            if scene.frames.count > 1 {
                                                Text("×\(scene.frames.count)").font(.caption.weight(.semibold)).monospacedDigit()
                                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                                    .background(.thinMaterial, in: Capsule()).padding(8)
                                                    .accessibilityLabel("\(scene.frames.count) 次出现")
                                            }
                                        }
                                    HStack {
                                        Text(capture.appName).font(.headline)
                                        Spacer()
                                        if scene.frames.count > 1 {
                                            Text("\(scene.earliest.date.formatted(.dateTime.hour().minute())) – \(capture.date.formatted(.dateTime.hour().minute()))")
                                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                        } else {
                                            Text(capture.date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(capture.windowTitle.isEmpty ? String(localized: "未命名窗口") : capture.windowTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    HStack {
                                        Text(capture.date, format: .dateTime.month().day()).font(.caption2).foregroundStyle(.tertiary)
                                        if scene.frames.count > 1 {
                                            Text("· \(scene.imageCount) 张不同画面").font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                        Label(capture.reason.label, systemImage: capture.reason.systemImage)
                                            .labelStyle(.iconOnly).font(.caption).foregroundStyle(.secondary)
                                            .help(capture.reason.label)
                                    }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("\(capture.appName)，\(scene.frames.count) 次出现，\(capture.windowTitle)")
                        }
                    }
                    }
                }
            }.padding(36).frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }
        .sheet(item: $source) { CaptureDetailView(model: model, frames: $0.frames) }
    }

    private var resultSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if folding, scenes.count < captures.count {
                Text("\(scenes.count) 个画面 · \(captures.count) 次出现")
            } else {
                Text(model.search.isEmpty && !model.captureFilter.isActive ? String(localized: "\(model.library.imageCount) 张独立图片") : String(localized: "\(model.results.captureCount) 条结果"))
            }
            if model.results.captureCount > captures.count { Text("显示最近 \(captures.count) 条记录") }
        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
    }

    private var filterControls: some View {
        HStack(spacing: 8) {
            Picker("应用", selection: $model.captureFilter.appName) {
                Text("全部应用").tag(String?.none)
                ForEach(model.library.captureAppNames, id: \.self) { Text($0).tag(Optional($0)) }
            }.labelsHidden().frame(width: 150, alignment: .trailing).help("按应用筛选").accessibilityLabel("应用筛选")
            Button {
                startDate = model.captureFilter.dateRange?.lowerBound ?? Calendar.current.startOfDay(for: Date())
                endDate = model.captureFilter.dateRange?.upperBound ?? startDate
                showDateFilter = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(dateFilterLabel).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.caption2)
                }.frame(maxWidth: 170)
            }
            .help(model.captureFilter.dateRange.map { "\($0.lowerBound.formatted(.dateTime.year().month().day().locale(locale))) – \($0.upperBound.formatted(.dateTime.year().month().day().locale(locale)))" } ?? String(localized: "按日期筛选"))
            .accessibilityLabel("日期筛选：\(dateFilterLabel)")
            .popover(isPresented: $showDateFilter, arrowEdge: .bottom) { dateFilterEditor }
            Picker("触发事件", selection: $model.captureFilter.event) {
                ForEach(CaptureFilter.Event.allCases, id: \.self) { Text($0.label).tag($0) }
            }.labelsHidden().frame(width: 100, alignment: .trailing).help("按触发事件筛选").accessibilityLabel("触发事件筛选")
            if model.captureFilter.isActive {
                Button { model.captureFilter = CaptureFilter() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless).help("清除筛选").accessibilityLabel("清除筛选")
            }
        }
    }

    private var dateFilterLabel: String {
        guard let range = model.captureFilter.dateRange else { return String(localized: "全部日期") }
        let format: Date.FormatStyle = Calendar.current.isDate(range.lowerBound, equalTo: range.upperBound, toGranularity: .year)
            ? .dateTime.month().day() : .dateTime.year().month().day()
        let start = range.lowerBound.formatted(format.locale(locale))
        return Calendar.current.isDate(range.lowerBound, inSameDayAs: range.upperBound) ? start : "\(start) – \(range.upperBound.formatted(format.locale(locale)))"
    }

    private var dateFilterEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("日期范围").font(.headline)
            DatePicker("开始日期", selection: $startDate, in: ...endDate, displayedComponents: .date)
            DatePicker("结束日期", selection: $endDate, in: startDate..., displayedComponents: .date)
            HStack {
                Button("全部日期") { model.captureFilter.dateRange = nil; showDateFilter = false }
                Spacer()
                // "确定" rather than "应用": the same word labels the app filter above, and one catalog key cannot mean both.
                Button("确定") { model.captureFilter.dateRange = startDate...endDate; showDateFilter = false }
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 300)
    }
}

struct CaptureThumbnail: View {
    let capture: ClipCapture
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Label(String(localized: "图片已过期"), systemImage: "photo").font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: capture.imageID) { image = NSImage(contentsOf: capture.imageURL) }
        .accessibilityLabel("\(capture.appName) 的窗口截图")
    }
}

struct CaptureDetailView: View {
    @ObservedObject var model: MyClipModel
    /// Newest first; a single element for an unfolded capture.
    let frames: [ClipCapture]
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var showText = false
    @State private var extractedText: String?
    @State private var textError: String?
    @State private var recognizing = false

    init(model: MyClipModel, frames: [ClipCapture]) {
        self.model = model
        self.frames = frames
    }

    init(model: MyClipModel, capture: ClipCapture) { self.init(model: model, frames: [capture]) }

    private var capture: ClipCapture { frames[min(index, frames.count - 1)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(capture.appName).font(.title2.bold())
                    Text(capture.windowTitle).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if frames.count > 1 {
                    HStack(spacing: 6) {
                        Button { index = min(frames.count - 1, index + 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(index >= frames.count - 1).help("更早一次").keyboardShortcut(.leftArrow, modifiers: [])
                        Text("第 \(frames.count - index) / \(frames.count) 次").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        Button { index = max(0, index - 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(index == 0).help("更晚一次").keyboardShortcut(.rightArrow, modifiers: [])
                    }.buttonStyle(.borderless)
                }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if frames.count > 1 { frameStrip }
            if !model.library.entries.filter({ $0.sourceIDs.contains(capture.id) }).isEmpty {
                HStack {
                    Text("关联记忆").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.library.entries.filter { $0.sourceIDs.contains(capture.id) }) { entry in
                        Button(entry.title) { dismiss(); model.open(.memory); Task { @MainActor in model.selectedEntry = entry.id } }.buttonStyle(.borderless)
                    }
                }
            }
            Picker("截图附件", selection: $showText) {
                Text("截图").tag(false)
                Text("OCR 文档").tag(true)
            }.pickerStyle(.segmented).frame(width: 220)
            if showText {
                textDocument
            } else {
                CaptureThumbnail(capture: capture).frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(capture.date, format: .dateTime.year().month().day().hour().minute().second())
                    HStack(spacing: 5) {
                        Text("\(capture.width) × \(capture.height) ·")
                        Label(capture.reason.label, systemImage: capture.reason.systemImage)
                    }.foregroundStyle(.secondary)
                }.font(.caption)
                Spacer()
                Button(String(localized: "显示原图"), systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([capture.imageURL]) }
                    .disabled(!FileManager.default.fileExists(atPath: capture.imageURL.path))
                Button("按图片重新整理") { model.enqueue(capture); dismiss() }
                    .help("将原图交给 Agent，适合图表、布局等 OCR 无法保留的内容")
                    .disabled(!model.canStartOrganization || !FileManager.default.fileExists(atPath: capture.imageURL.path))
                    .help(model.preferences.enabledAgent.map { String(localized: "使用已启用的 \($0.name) 整理") } ?? String(localized: "请先连接并启用 Agent"))
            }
        }.padding(24).frame(minWidth: 640, idealWidth: 840, maxWidth: 1000, minHeight: 500, idealHeight: 680, maxHeight: 800)
        .task(id: capture.imageID) { await recognizeText() }
    }

    /// Every look at the window, oldest on the left.
    private var frameStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(frames.enumerated().reversed()), id: \.element.id) { position, frame in
                        Button { index = position } label: {
                            VStack(spacing: 4) {
                                CaptureThumbnail(capture: frame).frame(width: 96, height: 60).clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(position == index ? Color.accentColor : .clear, lineWidth: 2))
                                Text(frame.date, format: .dateTime.hour().minute().second()).font(.caption2).monospacedDigit()
                                    .foregroundStyle(position == index ? .primary : .secondary)
                            }
                        }.buttonStyle(.plain).id(frame.id)
                            .help(position + 1 < frames.count && frame.imageID == frames[position + 1].imageID ? String(localized: "与前一次画面相同") : frame.reason.label)
                    }
                }.padding(.vertical, 2)
            }
            .onChange(of: index) { proxy.scrollTo(frames[$0].id) }
            .onAppear { proxy.scrollTo(frames[index].id) }
        }.frame(height: 84)
    }

    private var textDocument: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(String(localized: "提取的文字"), systemImage: "doc.text").font(.headline)
                Spacer()
                Button(String(localized: "复制文字"), systemImage: "doc.on.doc") {
                    guard let extractedText else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(extractedText, forType: .string)
                }.disabled(extractedText?.isEmpty != false)
                Button(String(localized: "打开文档"), systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(capture.textURL) }
                    .disabled(extractedText == nil)
            }
            Divider()
            if recognizing {
                ProgressView("正在提取文字…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let textError {
                VStack(spacing: 12) {
                    Text(textError).foregroundStyle(.secondary)
                    Button("重试") { Task { await recognizeText() } }
                        .disabled(!FileManager.default.fileExists(atPath: capture.imageURL.path))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let extractedText, !extractedText.isEmpty {
                ScrollView {
                    Text(verbatim: extractedText).font(.system(size: 14)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                LibraryUnavailableView(String(localized: "未识别到文字"), systemImage: "doc.text", description: Text("已为这张截图保存空白文档。"))
            }
            Text("文字在本机提取，与原图一同保存和到期清理。").font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func recognizeText() async {
        recognizing = true
        textError = nil
        extractedText = nil
        defer { recognizing = false }
        do { extractedText = try await model.store.recognizeImageText(id: capture.imageID) }
        catch is CancellationError { return }
        catch { textError = error.localizedDescription }
    }
}
