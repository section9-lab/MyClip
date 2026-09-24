import AppKit
import SwiftUI
import MyClipCore

/// The share card of a work report: a preview of what leaves MyClip, the apps it can go to, and the system share
/// menu for everything else (Mail, Messages, Notes, AirDrop).
struct ReportSharePanel: View {
    let document: WorkTaskReportDocument
    let shared: () -> Void
    @State private var apps: [ReportShareDestination: URL] = ReportSharing.installedApps()
    @State private var moreAnchor = ViewAnchor()
    @State private var copied = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)
    private var installed: Set<String> { Set(apps.keys.compactMap(\.bundleID)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("分享报告").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(action: shared) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary).frame(width: 24, height: 24).contentShape(Circle())
                }
                .buttonStyle(.plain).accessibilityLabel(String(localized: "关闭"))
                .keyboardShortcut(.cancelAction).help(String(localized: "关闭"))
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preview
                    VStack(alignment: .leading, spacing: 12) {
                        Text("分享到").font(.callout.weight(.medium))
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ShareTile(title: copied ? String(localized: "已复制") : String(localized: "复制"), help: String(localized: "复制报告")) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 22, weight: .regular))
                                    .foregroundStyle(copied ? Color.accentColor : Color.primary)
                            } action: {
                                copied = ReportSharing.copy(document)
                            }
                            ForEach(ReportShareDestination.available { installed.contains($0) }) { destination in
                                ShareTile(title: destination.name, help: help(destination)) {
                                    DestinationIcon(destination: destination, app: apps[destination])
                                } action: {
                                    ReportSharing.share(document, to: destination, app: apps[destination])
                                    shared()
                                }
                            }
                            ShareTile(title: String(localized: "更多"), help: String(localized: "通过邮件、信息、备忘录或隔空投送分享")) {
                                Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary)
                            } action: {
                                guard let view = moreAnchor.view else { return }
                                ReportSharingPicker.show(document, from: view, chosen: shared)
                            }
                            .background(ViewAnchorView(anchor: moreAnchor))
                        }
                    }
                    Text("报告会带格式复制并打开所选应用，在会话、邮件或文档中粘贴（⌘V）即可。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: document) { _ in copied = false }
    }

    private func help(_ destination: ReportShareDestination) -> String {
        if destination == .gmail { return String(localized: "复制报告并新建 Gmail 邮件") }
        return apps[destination] == nil
            ? String(localized: "复制报告并在浏览器中打开 \(destination.name)")
            : String(localized: "复制报告并打开 \(destination.name)")
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(document.title).font(.system(size: 18, weight: .semibold))
            Text(document.dateTitle).font(.system(size: 11)).foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            ForEach(Array(previewRows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .section(let title):
                    Text(title).font(.system(size: 12, weight: .medium)).padding(.top, 2)
                case .item(let item):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.status == .done ? "checkmark.circle.fill" : item.status == .doing ? "circle.lefthalf.filled" : "circle")
                            .font(.system(size: 10)).foregroundStyle(item.status.tint)
                        Text(item.title).font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(2).lineSpacing(3)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(18).frame(width: 224, height: 200, alignment: .topLeading)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 0.97)], startPoint: .top, endPoint: .bottom))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor))
            .shadow(color: .black.opacity(0.06), radius: 14, y: 6))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
        .overlay(alignment: .topLeading) {
            Image(systemName: "paperclip").font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary).rotationEffect(.degrees(-20))
                .offset(x: 9, y: -10).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private enum PreviewRow {
        case section(String)
        case item(WorkTaskReportDocument.Item)
    }

    private var previewRows: [PreviewRow] {
        // Empty outlines are left out so the preview shows the report's actual content.
        let rows = document.sections.filter { !$0.projects.isEmpty }.flatMap { section in
            [PreviewRow.section(section.title)] + section.projects.flatMap(\.items).map(PreviewRow.item)
        }
        return Array(rows.prefix(7))
    }
}

private struct ShareTile<Icon: View>: View {
    let title: String
    let help: String
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                icon()
                    .accessibilityHidden(true)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0.035)))
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
        .onHover { hovering = $0 }
    }
}

private struct DestinationIcon: View {
    let destination: ReportShareDestination
    let app: URL?

    var body: some View {
        if let app {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 32, height: 32)
        } else if destination == .gmail {
            GmailMark().frame(width: 26, height: 20)
        } else {
            // Web-only destinations get a monogram in the product's colour rather than a copy of its artwork.
            let (letter, color): (String, Color) = switch destination {
            case .notion: ("N", Color(white: 0.1))
            case .feishu: ("飞", Color(red: 0.2, green: 0.44, blue: 1))
            case .lark: ("L", Color(red: 0.2, green: 0.44, blue: 1))
            case .dingTalk: ("钉", Color(red: 0, green: 0.54, blue: 1))
            case .weCom: ("企", Color(red: 0.18, green: 0.49, blue: 0.96))
            case .weChat: ("微", Color(red: 0.03, green: 0.76, blue: 0.38))
            case .slack: ("S", Color(red: 0.29, green: 0.08, blue: 0.29))
            case .gmail: ("M", Color(red: 0.92, green: 0.26, blue: 0.21))
            }
            RoundedRectangle(cornerRadius: 8).fill(color).frame(width: 32, height: 32)
                .overlay(Text(letter).font(.system(size: 17, weight: .bold, design: destination == .notion ? .serif : .default)).foregroundStyle(.white))
                .drawingGroup()
        }
    }
}

/// The Gmail "M", drawn from its published 88 × 66 vector geometry.
private struct GmailMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 88, size.height / 66)
            context.translateBy(x: (size.width - 88 * scale) / 2, y: (size.height - 66 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            func shape(_ color: UInt32, _ build: (inout Path) -> Void) {
                var path = Path()
                build(&path)
                path.closeSubpath()
                context.fill(path, with: .color(Color(red: Double(color >> 16 & 0xFF) / 255, green: Double(color >> 8 & 0xFF) / 255, blue: Double(color & 0xFF) / 255)))
            }
            shape(0x4285F4) {
                $0.move(to: CGPoint(x: 6, y: 66)); $0.addLine(to: CGPoint(x: 20, y: 66)); $0.addLine(to: CGPoint(x: 20, y: 32))
                $0.addLine(to: CGPoint(x: 0, y: 17)); $0.addLine(to: CGPoint(x: 0, y: 60))
                $0.addCurve(to: CGPoint(x: 6, y: 66), control1: CGPoint(x: 0, y: 63.32), control2: CGPoint(x: 2.69, y: 66))
            }
            shape(0x34A853) {
                $0.move(to: CGPoint(x: 68, y: 66)); $0.addLine(to: CGPoint(x: 82, y: 66))
                $0.addCurve(to: CGPoint(x: 88, y: 60), control1: CGPoint(x: 85.32, y: 66), control2: CGPoint(x: 88, y: 63.31))
                $0.addLine(to: CGPoint(x: 88, y: 17)); $0.addLine(to: CGPoint(x: 68, y: 32))
            }
            shape(0xFBBC04) {
                $0.move(to: CGPoint(x: 68, y: 6)); $0.addLine(to: CGPoint(x: 68, y: 32)); $0.addLine(to: CGPoint(x: 88, y: 17))
                $0.addLine(to: CGPoint(x: 88, y: 9))
                $0.addCurve(to: CGPoint(x: 73.6, y: 1.8), control1: CGPoint(x: 88, y: 1.58), control2: CGPoint(x: 79.53, y: -2.65))
            }
            shape(0xEA4335) {
                $0.move(to: CGPoint(x: 20, y: 32)); $0.addLine(to: CGPoint(x: 20, y: 6)); $0.addLine(to: CGPoint(x: 44, y: 24))
                $0.addLine(to: CGPoint(x: 68, y: 6)); $0.addLine(to: CGPoint(x: 68, y: 32)); $0.addLine(to: CGPoint(x: 44, y: 50))
            }
            shape(0xC5221F) {
                $0.move(to: CGPoint(x: 0, y: 9)); $0.addLine(to: CGPoint(x: 0, y: 17)); $0.addLine(to: CGPoint(x: 20, y: 32))
                $0.addLine(to: CGPoint(x: 20, y: 6)); $0.addLine(to: CGPoint(x: 14.4, y: 1.8))
                $0.addCurve(to: CGPoint(x: 0, y: 9), control1: CGPoint(x: 8.46, y: -2.65), control2: CGPoint(x: 0, y: 1.58))
            }
        }
        .accessibilityHidden(true)
    }
}

@MainActor
enum ReportSharing {
    static func appURL(_ destination: ReportShareDestination) -> URL? {
        destination.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    static func installedApps() -> [ReportShareDestination: URL] {
        Dictionary(uniqueKeysWithValues: ReportShareDestination.allCases.compactMap { destination in
            appURL(destination).map { (destination, $0) }
        })
    }

    /// Copies the report and opens the destination, falling back to its web version when the app will not launch.
    static func share(_ document: WorkTaskReportDocument, to destination: ReportShareDestination, app: URL?) {
        copy(document)
        let web = destination.webURL(subject: document.shareSubject)
        guard let app else {
            if let web { NSWorkspace.shared.open(web) }
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil, let web else { return }
            Task { @MainActor in NSWorkspace.shared.open(web) }
        }
    }

    /// Puts HTML for web-based apps (Slack, Notion, Feishu, DingTalk, Gmail), RTF for native text views and plain text
    /// for everything else on the pasteboard, so each app pastes the richest form it understands.
    @discardableResult
    static func copy(_ document: WorkTaskReportDocument, to pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        item.setString(document.html, forType: .html)
        if let rich = richText(document),
           let rtf = try? rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            item.setData(rtf, forType: .rtf)
        }
        item.setString(document.plainText, forType: .string)
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static func richText(_ document: WorkTaskReportDocument) -> NSAttributedString? {
        let page = "<html><head><meta charset=\"utf-8\"><style>body { font-family: -apple-system, 'PingFang SC', sans-serif; font-size: 13px; }</style></head><body>\(document.html)</body></html>"
        return try? NSAttributedString(data: Data(page.utf8), options: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ], documentAttributes: nil)
    }
}

/// Shows the system share menu with the formatted report, and fills in the subject for services that have one (Mail).
@MainActor
final class ReportSharingPicker: NSObject, @preconcurrency NSSharingServicePickerDelegate {
    // The picker holds its delegate weakly, so the one being shown is kept here until the next.
    private static var current: ReportSharingPicker?
    private let subject: String
    private let chosen: () -> Void

    private init(subject: String, chosen: @escaping () -> Void) {
        self.subject = subject
        self.chosen = chosen
    }

    static func show(_ document: WorkTaskReportDocument, from view: NSView, chosen: @escaping () -> Void) {
        let picker = NSSharingServicePicker(items: [ReportSharing.richText(document) ?? NSAttributedString(string: document.plainText)])
        let delegate = ReportSharingPicker(subject: document.shareSubject, chosen: chosen)
        current = delegate
        picker.delegate = delegate
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard let service else { return }
        service.subject = subject
        chosen()
    }
}

final class ViewAnchor {
    weak var view: NSView?
}

/// Exposes the AppKit view behind a SwiftUI view, for AppKit menus that need something to anchor to.
struct ViewAnchorView: NSViewRepresentable {
    let anchor: ViewAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
