import Foundation
@preconcurrency import HomeKit

@MainActor
enum HomeBridgeRemoval {
    static func scenes(in home: HMHome) -> [HMActionSet] {
        var ids = Set<UUID>()
        return (home.actionSets + home.triggers.flatMap(\.actionSets)).filter { ids.insert($0.uniqueIdentifier).inserted }
    }

    static func validate(_ request: AgentRequest, home: HMHome) throws -> HMAccessory {
        guard let bridge = home.accessories.first(where: { $0.uniqueIdentifier == request.objectID }),
              let expected = request.bridgedAccessoryIDs, let audited = request.auditedOpaqueSceneIDs,
              !bridge.bridgedAccessories.isEmpty else { throw failure("Exact populated bridge and both audit UUID lists required") }
        let childIDs = Set(bridge.bridgedAccessories.map(\.uniqueIdentifier))
        try BridgeRemovalAudit.validateIDs(expected, actual: childIDs, nonempty: true, label: "Bridged accessories")
        let removing = childIDs.union([bridge.uniqueIdentifier])
        let sourceAccessories = home.accessories.filter { removing.contains($0.uniqueIdentifier) }
        let serviceIDs = Set(sourceAccessories.flatMap(\.services).map(\.uniqueIdentifier))
        let characteristicIDs = Set(sourceAccessories.flatMap(\.services).flatMap(\.characteristics).map(\.uniqueIdentifier))
        let sourceIDs = removing.union(serviceIDs).union(characteristicIDs)
        let allScenes = scenes(in: home)
        let opaque = Set(allScenes.filter { $0.actions.isEmpty || $0.actions.contains { !($0 is HMCharacteristicWriteAction<NSCopying>) } }.map(\.uniqueIdentifier))
        try BridgeRemovalAudit.validateIDs(audited, actual: opaque, nonempty: false, label: "Audited opaque scenes")
        for group in home.serviceGroups where group.services.contains(where: { serviceIDs.contains($0.uniqueIdentifier) }) {
            throw failure("Bridge still belongs to service group: \(group.name)")
        }
        for scene in allScenes {
            if scene.actions.contains(where: { action in
                guard let write = action as? HMCharacteristicWriteAction<NSCopying> else { return false }
                return characteristicIDs.contains(write.characteristic.uniqueIdentifier)
            }) { throw failure("Scene still references this bridge: \(scene.name)") }
        }
        for trigger in home.triggers {
            guard let event = trigger as? HMEventTrigger else {
                if trigger is HMTimerTrigger { continue }
                throw failure("Unknown native trigger; bridge references cannot be certified")
            }
            for value in event.events + event.endEvents {
                if let characteristic = value as? HMCharacteristicEvent<NSCopying> {
                    if characteristicIDs.contains(characteristic.characteristic.uniqueIdentifier) { throw failure("Automation event still references bridge: \(trigger.name)") }
                } else if let threshold = value as? HMCharacteristicThresholdRangeEvent {
                    if characteristicIDs.contains(threshold.characteristic.uniqueIdentifier) { throw failure("Automation threshold still references bridge: \(trigger.name)") }
                } else if !["HMCalendarEvent", "HMSignificantTimeEvent", "HMDurationEvent", "HMPresenceEvent", "HMLocationEvent"].contains(String(describing: type(of: value))) {
                    throw failure("Unknown native event; bridge references cannot be certified")
                }
            }
            if let predicate = event.predicate, try BridgeRemovalAudit.predicateUses(predicate, ids: sourceIDs, matches: { value in
                if let c = value as? HMCharacteristic { return characteristicIDs.contains(c.uniqueIdentifier) }
                if let s = value as? HMService { return serviceIDs.contains(s.uniqueIdentifier) }
                if let a = value as? HMAccessory { return removing.contains(a.uniqueIdentifier) }
                return false
            }) { throw failure("Automation predicate still references bridge: \(trigger.name)") }
        }
        return bridge
    }

    static func remove(_ request: AgentRequest, home: HMHome) async throws -> String {
        let bridge = try validate(request, home: home)
        try HomeBackupService.saveDeletionBackup(home: home)
        _ = try validate(request, home: home)
        let removing = Set(bridge.bridgedAccessories.map(\.uniqueIdentifier)).union([bridge.uniqueIdentifier])
        let keepAccessories = Set(home.accessories.map(\.uniqueIdentifier)).subtracting(removing)
        let keepScenes = Dictionary(uniqueKeysWithValues: scenes(in: home).map { ($0.uniqueIdentifier, Set($0.actions.map(\.uniqueIdentifier))) })
        let keepGroups = Dictionary(uniqueKeysWithValues: home.serviceGroups.map { ($0.uniqueIdentifier, Set($0.services.map(\.uniqueIdentifier))) })
        let keepTriggers = Set(home.triggers.map(\.uniqueIdentifier))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.removeAccessory(bridge) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        for _ in 0..<50 {
            if removing.isDisjoint(with: Set(home.accessories.map(\.uniqueIdentifier))) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard removing.isDisjoint(with: Set(home.accessories.map(\.uniqueIdentifier))),
              keepAccessories.isSubset(of: Set(home.accessories.map(\.uniqueIdentifier))),
              keepTriggers.isSubset(of: Set(home.triggers.map(\.uniqueIdentifier))) else {
            throw failure("Bridge deletion absence/preservation check failed; inspect Home before retrying")
        }
        let afterScenes = Dictionary(uniqueKeysWithValues: scenes(in: home).map { ($0.uniqueIdentifier, Set($0.actions.map(\.uniqueIdentifier))) })
        let afterGroups = Dictionary(uniqueKeysWithValues: home.serviceGroups.map { ($0.uniqueIdentifier, Set($0.services.map(\.uniqueIdentifier))) })
        guard keepScenes.allSatisfy({ afterScenes[$0.key] == $0.value }),
              keepGroups.allSatisfy({ afterGroups[$0.key] == $0.value }) else {
            throw failure("Unrelated scene/group changed during bridge deletion; inspect Home before retrying")
        }
        return "Bridge removed: \(bridge.uniqueIdentifier); \(removing.count - 1) children absent; unrelated accessories, scenes, groups and automation UUIDs retained"
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "HomeKitten.HomeBridgeRemoval", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
