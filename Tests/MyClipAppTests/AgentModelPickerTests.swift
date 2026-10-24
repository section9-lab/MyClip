import AppKit
import SwiftUI
import MyClipCore
@testable import MyClip

@main struct AgentModelPickerTests {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyClip-ModelPicker-\(UUID())")
        let suite = "MyClip.ModelPickerTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let preferences = ClipPreferences(preview: false, defaults: defaults)
        let model = try MyClipModel(root: root, preview: false, preferences: preferences)
        defer { model.stop() }
        let output = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        func settle() async {
            for _ in 0..<10 {
                window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        func snapshot(_ name: String) throws {
            guard let host = window.contentView, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                check(false, "Native panel renders: \(name)"); return
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            check(bitmap.pixelsWide >= Int(host.bounds.width), "Native panel renders: \(name)")
            if let output { try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png")) }
        }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        func searchField(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap(searchField).first
        }
        for agent in ClipAgent.allCases {
            model.agents[agent]?.phase = .ready
            model.agents[agent]?.modelsLoaded = true
            model.agents[agent]?.modelSelection = ACPModelSelection(currentID: "provider/model-1", options: (0..<60).map {
                ACPModelOption(id: "provider/model-\($0)", name: "Model \($0)", description: "Description returned by \(agent.name)",
                               group: "Provider", supportsImages: $0 == 0 ? false : $0 == 1 ? true : nil)
            }, configID: "returned-model-selector")
            preferences.setSelectedModel("provider/model-1", for: agent)
            window.contentView = NSHostingView(rootView: AgentModelPickerView(model: model, agent: agent))
            await settle()
            let scroll = scrollViews(window.contentView!).first
            check(scroll.map { ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height } == true,
                  "\(agent.name) keeps a long model catalog inside a scrollable list")
            try snapshot(agent.rawValue)
        }
        if let field = searchField(window.contentView!), let scroll = scrollViews(window.contentView!).first {
            let fullHeight = scroll.documentView?.bounds.height ?? 0
            field.stringValue = "provider/model-41"
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            await settle()
            check((scroll.documentView?.bounds.height ?? fullHeight) < fullHeight, "Typing a model ID filters the native list")
            try snapshot("search")
            let currentField = searchField(window.contentView!) ?? field
            currentField.stringValue = ""
            currentField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: currentField))
            await settle()
            let restored = scrollViews(window.contentView!).first
            check(restored.map { ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height } == true, "Clearing search restores the complete scrollable catalog")
        } else { check(false, "Model search exposes an editable native text field") }
        var textOnly = model.state(.opencode).modelSelection
        textOnly.currentID = "provider/model-0"
        for (name, phase, loaded, selection, error) in [
            ("loading", ClipAgentState.Phase.connecting, false, ACPModelSelection(), Optional<String>.none),
            ("empty", .ready, true, ACPModelSelection(), nil),
            ("error", .failed, true, ACPModelSelection(), "Fixture connection error. Refresh the list to retry."),
            ("text-only", .ready, true, textOnly, nil),
            ("working", .working, true, model.state(.opencode).modelSelection, nil)
        ] {
            model.agents[.opencode]?.phase = phase
            model.agents[.opencode]?.modelsLoaded = loaded
            model.agents[.opencode]?.modelSelection = selection
            model.agents[.opencode]?.modelError = error
            if name == "loading" { model.configuringAgentModels.insert(.opencode) }
            else { model.configuringAgentModels.remove(.opencode) }
            window.contentView = NSHostingView(rootView: AgentModelPickerView(model: model, agent: .opencode))
            await settle()
            try snapshot(name)
            if phase == .working { check(!model.canConfigureAgentModel(.opencode), "Working panel disables model changes") }
        }
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 680, height: 680))
        await settle()
        try snapshot("dark-wide")
        check(preferences.enabledAgent == nil, "Rendering every Agent's picker never enables organization")
        check(try await model.store.snapshot().jobs.isEmpty, "Rendering the picker never creates an organization job")
        print("Model picker checks: \(failures) failure(s)")
        if failures > 0 { exit(1) }
    }
}
