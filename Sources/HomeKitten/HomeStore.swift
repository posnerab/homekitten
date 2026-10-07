@preconcurrency import HomeKit
import Observation

@MainActor
@Observable
final class HomeStore: NSObject, @preconcurrency HMHomeManagerDelegate {
    private(set) var homes: [HMHome] = []
    private(set) var isReady = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var manager: HMHomeManager!

    override init() {
        super.init()
        manager = HMHomeManager()
        manager.delegate = self
    }

    var authorizationDescription: String {
        if isAuthorized { return "Authorized" }
        if manager.authorizationStatus.contains(.restricted) { return "Restricted" }
        if manager.authorizationStatus.contains(.determined) { return "Not authorized" }
        return "Waiting for permission"
    }

    var isAuthorized: Bool { manager.authorizationStatus.contains(.authorized) }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        homes = manager.homes
        isReady = true
        errorMessage = nil
    }

    func homeManager(_ manager: HMHomeManager, didEncounterError error: any Error) {
        errorMessage = error.localizedDescription
    }
}
