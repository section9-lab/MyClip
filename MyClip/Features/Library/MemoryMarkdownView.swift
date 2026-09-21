import SwiftUI
import MarkdownUI
import MyClipCore

struct MemoryMarkdownView: View {
    let markdown: String
    let baseURL: URL
    var openMemoryLink: ((URL) -> Void)?

    var body: some View {
        Markdown(Wikilink.markdown(markdown), baseURL: baseURL, imageBaseURL: baseURL)
            .markdownTextStyle { FontSize(15) }
            .markdownImageProvider(MemoryImageProvider())
            .textSelection(.enabled)
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

private struct MemoryImageProvider: ImageProvider {
    @ViewBuilder func makeImage(url: URL?) -> some View {
        if let url, url.isFileURL, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            DefaultImageProvider.default.makeImage(url: url)
        }
    }
}
