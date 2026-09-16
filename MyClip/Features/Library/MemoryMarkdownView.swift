import SwiftUI
import Textual
import MyClipCore

struct MemoryMarkdownView: View {
    let markdown: String
    let baseURL: URL
    var openMemoryLink: ((URL) -> Void)?

    var body: some View {
        StructuredText(markdown: Wikilink.markdown(markdown), baseURL: baseURL)
            .font(.system(size: 15))
            .textual.structuredTextStyle(.default)
            .textual.tableStyle(.overflow)
            .textual.imageAttachmentLoader(.image(relativeTo: baseURL))
            .textual.textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "myclip-memory" {
                    guard let openMemoryLink else { return .discarded }
                    openMemoryLink(url)
                    return .handled
                }
                return .systemAction
            })
    }
}
