import SwiftUI
import AppKit
import MyClipCore

struct PermissionRequestView: View {
    @ObservedObject var model: MyClipModel
    let permission: ClipPermission
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(String(localized: "\(permission.agent.name) 需要确认"), systemImage: "hand.raised").font(.headline)
            Text(permission.request.title).font(.subheadline)
            ForEach(permission.request.options) { option in
                Button(option.name) { model.resolve(permission, optionID: option.id) }.focusable()
                    .onActivationKey { model.resolve(permission, optionID: option.id) }
            }
            Button("取消此次请求", role: .cancel) { model.resolve(permission, optionID: nil) }.buttonStyle(.borderless).focusable()
                .onActivationKey { model.resolve(permission, optionID: nil) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
