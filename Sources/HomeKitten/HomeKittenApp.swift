import SwiftUI

@main
struct HomeKittenApp: App {
    @State private var store = HomeStore()
    @State private var bridge = AgentBridge()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup("HomeKitten") {
            ContentView()
                .environment(store)
                .environment(bridge)
                #if targetEnvironment(macCatalyst)
                .frame(minWidth: 560, minHeight: 420)
                #endif
                .onChange(of: store.isReady, initial: true) { _, ready in
                    if ready && phase == .active { bridge.resume(store) }
                }
                .onChange(of: phase) { _, next in
                    if next == .active { bridge.resume(store) }
                    else if next == .background { bridge.background() }
                }
        }
    }
}
