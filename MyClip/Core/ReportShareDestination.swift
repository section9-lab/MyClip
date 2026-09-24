import Foundation

/// Where a work report can be shared. None of these apps accept text from outside, so the report is copied with its
/// formatting and the app (or its web version when it is not installed) is opened for the user to paste into the
/// conversation or page they choose. Gmail additionally opens a draft with the subject filled in.
public enum ReportShareDestination: String, CaseIterable, Identifiable, Sendable {
    case gmail, notion, feishu, lark, dingTalk, weCom, weChat, slack

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .gmail: "Gmail"
        case .notion: "Notion"
        case .feishu: String(localized: "飞书")
        case .lark: "Lark"
        case .dingTalk: String(localized: "钉钉")
        case .weCom: String(localized: "企业微信")
        case .weChat: String(localized: "微信")
        case .slack: "Slack"
        }
    }

    /// The desktop app's bundle identifier. Feishu's China build still carries the Electron-era identifier.
    public var bundleID: String? {
        switch self {
        case .gmail: nil
        case .notion: "notion.id"
        case .feishu: "com.electron.lark"
        case .lark: "com.larksuite.larkApp"
        case .dingTalk: "com.alibaba.DingTalkMac"
        case .weCom: "com.tencent.WeWorkMac"
        case .weChat: "com.tencent.xinWeChat"
        case .slack: "com.tinyspeck.slackmacgap"
        }
    }

    /// Opened in the browser when the desktop app is missing. WeCom and WeChat have no usable web client.
    public func webURL(subject: String) -> URL? {
        switch self {
        case .gmail:
            // `+` must be encoded too: Gmail reads a literal plus in the query as a space.
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let query = [("view", "cm"), ("fs", "1"), ("su", subject)].map { name, value in
                "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
            }.joined(separator: "&")
            return URL(string: "https://mail.google.com/mail/?" + query)
        case .notion: return URL(string: "https://notion.new")
        case .feishu: return URL(string: "https://www.feishu.cn/messenger/")
        case .lark: return URL(string: "https://www.larksuite.com/messenger/")
        case .dingTalk: return URL(string: "https://im.dingtalk.com/")
        case .slack: return URL(string: "https://app.slack.com/client")
        case .weCom, .weChat: return nil
        }
    }

    /// The destinations worth offering: every installed app, plus web versions. Feishu and Lark are the same product
    /// for China and elsewhere, so with neither app installed only the one matching the interface language is offered.
    public static func available(language: AppLanguage = .current, isInstalled: (String) -> Bool) -> [Self] {
        let installed = allCases.filter { $0.bundleID.map(isInstalled) ?? false }
        let hasLark = installed.contains(.feishu) || installed.contains(.lark)
        return allCases.filter { destination in
            if installed.contains(destination) { return true }
            switch destination {
            case .feishu: return !hasLark && language == .chinese
            case .lark: return !hasLark && language != .chinese
            default: return destination.webURL(subject: "") != nil
            }
        }
    }
}
