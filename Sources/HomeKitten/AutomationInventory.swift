import Foundation
import CoreLocation
@preconcurrency import HomeKit

@MainActor
enum AutomationInventory {
    static func configuration(_ home: HMHome, metadataReadStatus: [String: String] = [:]) -> [String: Any] {
        let bridges = Dictionary(uniqueKeysWithValues: home.accessories.flatMap { bridge in
            bridge.bridgedAccessories.map { ($0.uniqueIdentifier, bridge) }
        })
        let accessories: [[String: Any]] = home.accessories.map { accessory in
            let services: [[String: Any]] = accessory.services.map { service in
                let characteristics: [[String: Any]] = service.characteristics.map { c in
                    ["id": c.uniqueIdentifier.uuidString, "name": c.localizedDescription,
                     "type": c.characteristicType, "properties": c.properties,
                     "cachedValue": AutomationRules.value(c.value), "metadataReadStatus": metadataReadStatus[c.uniqueIdentifier.uuidString] ?? "not_requested", "format": c.metadata?.format ?? "",
                     "min": AutomationRules.value(c.metadata?.minimumValue), "max": AutomationRules.value(c.metadata?.maximumValue),
                     "step": AutomationRules.value(c.metadata?.stepValue), "validValues": c.metadata?.validValues ?? [],
                     "unit": c.metadata?.units ?? "", "maxLength": AutomationRules.value(c.metadata?.maxLength), "manufacturerDescription": c.metadata?.manufacturerDescription ?? ""]
                }
                return ["id": service.uniqueIdentifier.uuidString, "name": service.name, "type": service.serviceType, "associatedServiceType": service.associatedServiceType ?? "", "isPrimary": service.isPrimaryService, "isUserInteractive": service.isUserInteractive, "linkedServiceIDs": (service.linkedServices ?? []).map { $0.uniqueIdentifier.uuidString }, "characteristics": characteristics]
            }
            return ["id": accessory.uniqueIdentifier.uuidString, "name": accessory.name, "reachable": accessory.isReachable,
                    "roomID": accessory.room?.uniqueIdentifier.uuidString ?? "", "services": services,
                    "manufacturer": accessory.manufacturer ?? "", "model": accessory.model ?? "",
                    "firmwareVersion": accessory.firmwareVersion ?? "",
                    "categoryType": accessory.category.categoryType,
                    "bridgeID": bridges[accessory.uniqueIdentifier]?.uniqueIdentifier.uuidString ?? "",
                    "bridgeName": bridges[accessory.uniqueIdentifier]?.name ?? "", "isBlocked": accessory.isBlocked, "supportsIdentify": accessory.supportsIdentify]
        }
        // Trigger-owned action sets are not necessarily listed in home.actionSets.
        var actionSets = home.actionSets
        var actionSetIDs = Set(actionSets.map(\.uniqueIdentifier))
        for scene in home.triggers.flatMap(\.actionSets) where actionSetIDs.insert(scene.uniqueIdentifier).inserted {
            actionSets.append(scene)
        }
        let scenes = actionSets.map { AutomationInventory.actionSet($0) }
        let automations = home.triggers.map { AutomationInventory.trigger($0) }
        var allRooms = home.rooms
        let defaultRoom = home.roomForEntireHome()
        if !allRooms.contains(where: { $0.uniqueIdentifier == defaultRoom.uniqueIdentifier }) { allRooms.append(defaultRoom) }
        let rooms: [[String: Any]] = allRooms.map { ["id": $0.uniqueIdentifier.uuidString, "name": $0.name, "isDefaultRoom": $0.uniqueIdentifier == defaultRoom.uniqueIdentifier] }
        let zones: [[String: Any]] = home.zones.map {
            ["id": $0.uniqueIdentifier.uuidString, "name": $0.name,
             "roomIDs": $0.rooms.map { $0.uniqueIdentifier.uuidString }]
        }
        let groups: [[String: Any]] = home.serviceGroups.map { ["id": $0.uniqueIdentifier.uuidString, "name": $0.name, "serviceIDs": $0.services.map { $0.uniqueIdentifier.uuidString }] }
        return ["id": home.uniqueIdentifier.uuidString, "name": home.name, "isPrimary": home.isPrimary, "valuesAreCached": true, "source": "HomeKit public API", "rooms": rooms, "entireHomeRoomID": home.roomForEntireHome().uniqueIdentifier.uuidString, "groups": groups,
                "zones": zones, "accessories": accessories, "scenes": scenes, "automations": automations]
    }

    static func trigger(_ trigger: HMTrigger) -> [String: Any] {
        var result: [String: Any] = ["id": trigger.uniqueIdentifier.uuidString, "name": trigger.name,
                                    "enabled": trigger.isEnabled, "kind": String(describing: type(of: trigger)),
                                    "sceneIDs": trigger.actionSets.map { $0.uniqueIdentifier.uuidString },
                                    "actionSets": trigger.actionSets.map { actionSet($0) }]
        if let event = trigger as? HMEventTrigger {
            result["rulesStatus"] = "publicAPI"
            result["events"] = event.events.map { self.event($0) }
            result["endEvents"] = event.endEvents.map { self.event($0) }
            let tree = event.predicate.map { AutomationRules.predicate($0, object: object) }
            result["predicate"] = tree ?? (NSNull() as Any)
            result["conditionSummary"] = tree.map { AutomationRules.conditionSummary($0) } ?? "No conditions"
            result["conditionIssues"] = tree.map { AutomationRules.conditionIssues($0) } ?? []
            result["recurrences"] = event.recurrences.map { $0.map { AutomationRules.components($0) } } ?? (NSNull() as Any)
            result["executeOnce"] = event.executeOnce
            result["activationStateRawValue"] = event.triggerActivationState.rawValue
            result["activationState"] = activationState(event.triggerActivationState)
        } else if let timer = trigger as? HMTimerTrigger {
            result["rulesStatus"] = "publicAPI"
            result["fireDate"] = ISO8601DateFormatter().string(from: timer.fireDate)
            result["timeZone"] = timer.timeZone?.identifier ?? (NSNull() as Any)
            result["recurrence"] = timer.recurrence.map { AutomationRules.components($0) } ?? (NSNull() as Any)
        } else {
            result["rulesStatus"] = "unsupportedTrigger"
        }
        return result
    }

    static func actionSet(_ scene: HMActionSet) -> [String: Any] {
        let actions: [[String: Any]] = scene.actions.sorted { $0.uniqueIdentifier.uuidString < $1.uniqueIdentifier.uuidString }.map { action in
            if let write = action as? HMCharacteristicWriteAction<NSCopying> {
                return ["id": action.uniqueIdentifier.uuidString, "kind": "characteristicWrite", "characteristicID": write.characteristic.uniqueIdentifier.uuidString,
                        "value": AutomationRules.value(write.targetValue, object: object)]
            }
            return ["id": action.uniqueIdentifier.uuidString, "kind": String(describing: type(of: action)), "supported": false]
        }
        return ["id": scene.uniqueIdentifier.uuidString, "name": scene.name,
                "type": scene.actionSetType, "actions": actions]
    }

    static func event(_ event: HMEvent) -> [String: Any] {
        var result: [String: Any] = ["id": event.uniqueIdentifier.uuidString, "kind": String(describing: type(of: event))]
        switch event {
        case let characteristic as HMCharacteristicEvent<NSCopying>:
            result["characteristic"] = reference(characteristic.characteristic)
            result["characteristicID"] = characteristic.characteristic.uniqueIdentifier.uuidString
            result["triggerValue"] = AutomationRules.value(characteristic.triggerValue, object: object)
        case let threshold as HMCharacteristicThresholdRangeEvent:
            result["characteristic"] = reference(threshold.characteristic)
            result["characteristicID"] = threshold.characteristic.uniqueIdentifier.uuidString
            result["thresholdRange"] = ["min": AutomationRules.value(threshold.thresholdRange.minValue),
                                         "max": AutomationRules.value(threshold.thresholdRange.maxValue)]
        case let calendar as HMCalendarEvent:
            result["fireDateComponents"] = AutomationRules.components(calendar.fireDateComponents)
        case let significant as HMSignificantTimeEvent:
            result["significantEvent"] = significant.significantEvent.rawValue
            result["offset"] = significant.offset.map { AutomationRules.components($0) } ?? (NSNull() as Any)
        case let duration as HMDurationEvent:
            result["durationSeconds"] = duration.duration
        case let presence as HMPresenceEvent:
            result["presenceEventTypeRawValue"] = presence.presenceEventType.rawValue
            result["presenceUserTypeRawValue"] = presence.presenceUserType.rawValue
            result["presenceEventType"] = presenceType(presence.presenceEventType)
            result["presenceUserType"] = presenceUserType(presence.presenceUserType)
            if presence.presenceUserType == .customUsers { result["customUsersStatus"] = "notExposedByPublicAPI" }
        case let location as HMLocationEvent:
            if let region = location.region {
                var data: [String: Any] = ["identifier": region.identifier, "notifyOnEntry": region.notifyOnEntry,
                                          "notifyOnExit": region.notifyOnExit]
                if let circle = region as? CLCircularRegion {
                    data["latitude"] = circle.center.latitude; data["longitude"] = circle.center.longitude
                    data["radiusMeters"] = circle.radius
                } else { data["geometryStatus"] = "unsupportedRegion" }
                result["region"] = data
            } else { result["region"] = NSNull() }
        default:
            result["supported"] = false
        }
        return result
    }

    static func conditionSummary(_ predicate: NSPredicate) -> String {
        AutomationRules.conditionSummary(AutomationRules.predicate(predicate, object: object))
    }

    private static func reference(_ c: HMCharacteristic) -> [String: Any] {
        ["kind": "characteristic", "id": c.uniqueIdentifier.uuidString, "type": c.characteristicType,
         "name": c.localizedDescription, "serviceID": c.service?.uniqueIdentifier.uuidString ?? "",
         "accessoryID": c.service?.accessory?.uniqueIdentifier.uuidString ?? "",
         "accessoryName": c.service?.accessory?.name ?? ""]
    }

    private static func object(_ value: Any) -> [String: Any]? {
        if let c = value as? HMCharacteristic { return reference(c) }
        if let event = value as? HMEvent { return self.event(event) }
        if let range = value as? HMNumberRange {
            return ["kind": "numberRange", "min": AutomationRules.value(range.minValue), "max": AutomationRules.value(range.maxValue)]
        }
        return nil
    }

    private static func activationState(_ state: HMEventTriggerActivationState) -> String {
        switch state {
        case .disabled: "disabled"
        case .disabledNoHomeHub: "noHomeHub"
        case .disabledNoCompatibleHomeHub: "noCompatibleHomeHub"
        case .disabledNoLocationServicesAuthorization: "noLocationAuthorization"
        case .enabled: "enabled"
        @unknown default: "unknown"
        }
    }
    private static func presenceType(_ type: HMPresenceEventType) -> String {
        switch type {
        case .everyEntry: "everyEntry"
        case .everyExit: "everyExit"
        case .firstEntry: "firstEntryOrAtHome"
        case .lastExit: "lastExitOrNotAtHome"
        @unknown default: "unknown"
        }
    }
    private static func presenceUserType(_ type: HMPresenceEventUserType) -> String {
        switch type {
        case .currentUser: "currentUser"
        case .homeUsers: "homeUsers"
        case .customUsers: "customUsers"
        @unknown default: "unknown"
        }
    }
}
