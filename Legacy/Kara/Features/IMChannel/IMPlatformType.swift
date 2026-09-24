import Foundation

/// Supported IM platform types.
enum IMPlatformType: String, CaseIterable, Identifiable, Codable {
    case wechat
    case imessage
    case dingtalk
    case feishu
    case wecom       // WeCom
    case slack
    case telegram
    case line
    case whatsapp

    static var visibleIMCases: [IMPlatformType] {
        [.wechat, .feishu, .imessage, .telegram, .line, .whatsapp]
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wechat:    return "WeChat"
        case .imessage:  return "iMessage"
        case .dingtalk:  return "DingTalk"
        case .feishu:    return "Feishu"
        case .wecom:     return "WeCom"
        case .slack:     return "Slack"
        case .telegram:  return "Telegram"
        case .line:      return "LINE"
        case .whatsapp:  return "WhatsApp"
        }
    }

    var iconSystemName: String {
        switch self {
        case .wechat:    return "bubble.left.and.bubble.right.fill"
        case .imessage:  return "message.fill"
        case .dingtalk:  return "message.fill"
        case .feishu:    return "paperplane.fill"
        case .wecom:     return "bubble.left.and.bubble.right.fill"
        case .slack:     return "number"
        case .telegram:  return "airplane"
        case .line:      return "message.fill"
        case .whatsapp:  return "phone.bubble.left.fill"
        }
    }

    /// Placeholder text for webhook URL input.
    var webhookPlaceholder: String {
        switch self {
        case .wechat:    return "Open WeChat, scan to sign in, then select a conversation"
        case .imessage:  return "iMessage support coming later"
        case .dingtalk:  return "https://oapi.dingtalk.com/robot/send?access_token=..."
        case .feishu:    return "https://open.feishu.cn/open-apis/bot/v2/hook/..."
        case .wecom:     return "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=..."
        case .slack:     return "https://hooks.slack.com/services/..."
        case .telegram:  return "Bot Token (e.g. 123456:ABC-DEF...)"
        case .line:      return "LINE support coming later"
        case .whatsapp:  return "WhatsApp support coming later"
        }
    }
}
