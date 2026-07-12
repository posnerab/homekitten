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
        switch manager.authorizationStatus {
        case .authorized: "Authorized"
        case .restricted: "Restricted"
        case .determined: "Not authorized"
        default: "Waiting for permission"
        }
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        homes = manager.homes
        isReady = true
        errorMessage = nil
    }

    func homeManager(_ manager: HMHomeManager, didEncounterError error: any Error) {
        errorMessage = error.localizedDescription
    }
}
