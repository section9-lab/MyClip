import SwiftUI
import Charts
import MyClipCore

struct AnalyticsView: View {
    @ObservedObject var model: MyClipModel
    var body: some View { TaskDashboardView(model: model) }
}

struct ProposalReviewView: View {
    @ObservedObject var model: MyClipModel
    let proposal: MemoryProposal
    @Environment(\.dismiss) private var dismiss
    @State private var originals: [UUID: KnowledgeEntry] = [:]
    @State private var ready = false
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("确认记忆修改").font(.title2.bold())
            Text("原记忆已有人工修改或新版本。检查建议后，再决定是否替换。").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(proposal.drafts.enumerated()), id: \.offset) { _, draft in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(draft.title).font(.headline)
                            if let id = draft.entryID, let original = originals[id] {
                                DisclosureGroup("当前内容 · 第 \(original.revision) 版") { Text(original.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            }
                            Text("建议内容").font(.caption).foregroundStyle(.secondary)
                            Text(draft.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(16).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            HStack {
                Button("保留原内容") {
                    Task { do { try await model.store.discardProposal(proposal.id); await model.refresh(); dismiss() } catch { model.notice = error.localizedDescription } }
                }.disabled(saving)
                Spacer()
                Button("稍后") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("采用这些修改") {
                    saving = true
                    Task {
                        do { try await model.store.acceptProposal(proposal.id, revisions: originals.mapValues(\.revision)); await model.refresh(); dismiss() }
                        catch { model.notice = error.localizedDescription }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(!ready || saving)
            }
        }.padding(24).frame(width: 660, height: 560)
        .task {
            do {
                for draft in proposal.drafts { if let id = draft.entryID { originals[id] = try await model.store.readMemory(id) } }
                ready = true
            } catch { model.notice = error.localizedDescription }
        }
    }
}
