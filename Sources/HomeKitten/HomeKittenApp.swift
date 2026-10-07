import SwiftUI

@main
struct HomeKittenApp: App {
    @State private var store = HomeStore()

    var body: some Scene {
        WindowGroup("HomeKitten") {
            ContentView()
                .environment(store)
                #if targetEnvironment(macCatalyst)
                .frame(minWidth: 560, minHeight: 420)
                #endif
        }
    }
}
