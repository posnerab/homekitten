import SwiftUI

@main
struct HomeKittenApp: App {
    #if targetEnvironment(macCatalyst)
    @UIApplicationDelegateAdaptor(MacAgentLifecycle.self) private var lifecycle
    private var store: HomeStore { lifecycle.store }
    private var bridge: AgentBridge { lifecycle.bridge }
    #else
    @State private var store = HomeStore()
    @State private var bridge = AgentBridge()
    #endif
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

#if targetEnvironment(macCatalyst)
@MainActor
final class MacAgentLifecycle: NSObject, UIApplicationDelegate {
    let store = HomeStore()
    let bridge = AgentBridge()
    private var menuBar: NSObject?
    private var timer: Timer?
    private var activity: NSObjectProtocol?

    override init() {
        super.init()
        Task { @MainActor [weak self] in self?.configure() }
    }

    private func configure() {
        NSLog("HomeKitten starting Mac agent lifecycle")
        // The owner and readiness polling outlive every window. Never grant access here.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("HomeKittenMenuBar.bundle"),
              let bundle = Bundle(url: url),
              let type = bundle.principalClass as? NSObject.Type else {
            NSLog("HomeKitten menu bar bundle unavailable; use the main window.")
            return
        }
        let menu = type.init()
        let state: @convention(block) () -> NSDictionary = { [weak self] in
            guard let self else { return [:] }
            return ["connected": UserDefaults.standard.bool(forKey: "agentBridge.enabled"),
                    "running": self.bridge.running,
                    "busy": self.bridge.hasActiveOperation,
                    "status": self.bridge.status]
        }
        let action: @convention(block) (NSString) -> Bool = { [weak self] action in
            guard let self, !self.bridge.hasActiveOperation else { return false }
            self.bridge.stop(preserveConnection: action == "quit")
            return true
        }
        menu.perform(NSSelectorFromString("configure:action:"), with: state, with: action)
        menuBar = menu
        NSLog("HomeKitten menu bar loaded")
    }

    private func refresh() {
        if store.isReady { bridge.resume(store) }
        if let menuBar,
           let state = menuBar.perform(NSSelectorFromString("runtimeState"))?.takeUnretainedValue() as? [String: Any] {
            var runtime = state
            runtime["bridgeRunning"] = bridge.running
            runtime["busy"] = bridge.hasActiveOperation
            runtime["capturedAt"] = ISO8601DateFormatter().string(from: Date())
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentBridge/mac-runtime.json")
            if let data = try? JSONSerialization.data(withJSONObject: runtime) {
                try? data.write(to: file, options: .atomic)
            }
        }
        if bridge.running && activity == nil {
            // Prevent App Nap, not system sleep, while the file queue is connected.
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Serve authorized HomeKit agent requests")
        } else if !bridge.running, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
#endif
