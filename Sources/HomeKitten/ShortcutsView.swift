import SwiftUI
#if canImport(ScriptingBridge)
import ScriptingBridge

struct ShortcutRecord: Identifiable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let acceptsInput: Bool
    let actionCount: Int
}

@MainActor
@Observable
final class ShortcutsStore {
    private(set) var shortcuts: [ShortcutRecord] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var objects: [String: SBObject] = [:]

    func load() {
        isLoading = true; errorMessage = nil
        guard let application = SBApplication(bundleIdentifier: "com.apple.shortcuts") else {
            errorMessage = "The Shortcuts app is unavailable."; isLoading = false; return
        }
        application.timeout = 30 * 60
        guard let elements = application.value(forKey: "shortcuts") as? SBElementArray,
              let values = elements.get() as? [SBObject] else {
            errorMessage = permissionMessage(nil); isLoading = false; return
        }
        var nextObjects: [String: SBObject] = [:]
        shortcuts = values.compactMap { object in
            guard let id = object.value(forKey: "id") as? String,
                  let name = object.value(forKey: "name") as? String else { return nil }
            nextObjects[id] = object
            return ShortcutRecord(
                id: id,
                name: name,
                subtitle: object.value(forKey: "subtitle") as? String ?? "",
                acceptsInput: (object.value(forKey: "acceptsInput") as? NSNumber)?.boolValue ?? false,
                actionCount: (object.value(forKey: "actionCount") as? NSNumber)?.intValue ?? 0
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        objects = nextObjects
        isLoading = false
    }

    func run(_ shortcut: ShortcutRecord) -> String {
        guard let object = objects[shortcut.id] else { return "Shortcut is no longer available. Refresh and try again." }
        let selector = NSSelectorFromString("runWithInput:")
        guard object.responds(to: selector) else { return "This shortcut cannot be run through Automation." }
        _ = object.perform(selector, with: nil)
        return "Ran \(shortcut.name)."
    }

    private func permissionMessage(_ error: Error?) -> String {
        guard let error else { return "Allow HomeKitten to control Shortcuts in System Settings → Privacy & Security → Automation, then refresh." }
        let nsError = error as NSError
        if nsError.code == -1743 {
            return "Shortcuts access was denied. Enable HomeKitten under System Settings → Privacy & Security → Automation."
        }
        return error.localizedDescription
    }
}

struct ShortcutsWorkspaceView: View {
    @State private var store = ShortcutsStore()
    @State private var query = ""
    @State private var message = ""
    @State private var showingMessage = false

    var body: some View {
        List(filteredShortcuts) { shortcut in
            HStack(spacing: 12) {
                Image(systemName: "command.square.fill")
                    .font(.title2).foregroundStyle(.indigo).frame(width: 32)
                VStack(alignment: .leading) {
                    Text(shortcut.name)
                    Text(detailText(for: shortcut))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if shortcut.acceptsInput { Image(systemName: "arrow.down.doc").foregroundStyle(.secondary).help("Accepts input") }
                Button("Run", systemImage: "play.fill") {
                    message = store.run(shortcut); showingMessage = true
                }.buttonStyle(.bordered)
            }
        }
        .overlay {
            if store.isLoading { ProgressView("Loading Shortcuts…") }
            else if let error = store.errorMessage {
                ContentUnavailableView("Shortcuts Access", systemImage: "lock.shield", description: Text(error))
            } else if filteredShortcuts.isEmpty {
                ContentUnavailableView("No Shortcuts", systemImage: "command.square")
            }
        }
        .navigationTitle("Shortcuts")
        .searchable(text: $query, prompt: "Search shortcuts")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Refresh", systemImage: "arrow.clockwise") { store.load() } } }
        .task { store.load() }
        .alert("Shortcuts", isPresented: $showingMessage) { Button("OK") {} } message: { Text(message) }
    }

    private var filteredShortcuts: [ShortcutRecord] {
        store.shortcuts.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query) }
    }

    private func detailText(for shortcut: ShortcutRecord) -> String {
        if shortcut.subtitle.isEmpty { return "\(shortcut.actionCount) actions" }
        if shortcut.subtitle.localizedCaseInsensitiveContains("action") { return shortcut.subtitle }
        return "\(shortcut.subtitle) · \(shortcut.actionCount) actions"
    }
}
#else
struct ShortcutsWorkspaceView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Shortcuts", systemImage: "command.square")
        } description: {
            Text("Open Shortcuts to browse and run your shortcuts on this device.")
        } actions: {
            Link("Open Shortcuts", destination: URL(string: "shortcuts://")!)
        }
        .navigationTitle("Shortcuts")
    }
}
#endif
