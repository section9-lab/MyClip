import SwiftUI
import AppKit
import MyClipCore

struct LibraryEmptyView: View {
    let symbol: String
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void
    var body: some View {
        VStack(spacing: 17) {
            Image(systemName: symbol).font(.system(size: 54, weight: .ultraLight)).foregroundStyle(.blue).padding(.bottom, 8)
            Text(title).font(.title2.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5).frame(maxWidth: 360)
            Button(action, action: perform).buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 5)
        }.frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}
