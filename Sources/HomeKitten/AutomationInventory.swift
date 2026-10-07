import Foundation
import CoreLocation
@preconcurrency import HomeKit

@MainActor
enum AutomationInventory {
    static func trigger(_ trigger: HMTrigger) -> [String: Any] {
        var result: [String: Any] = ["id": trigger.uniqueIdentifier.uuidString, "name": trigger.name,
                                    "enabled": trigger.isEnabled, "kind": String(describing: type(of: trigger)),
                                    "sceneIDs": trigger.actionSets.map { $0.uniqueIdentifier.uuidString },
                                    "actionSets": trigger.actionSets.map { actionSet($0) }]
        if let event = trigger as? HMEventTrigger {
            result["rulesStatus"] = "publicAPI"
            result["events"] = event.events.map { self.event($0) }
            result["endEvents"] = event.endEvents.map { self.event($0) }
            result["predicate"] = event.predicate.map { AutomationRules.predicate($0, object: object) } ?? (NSNull() as Any)
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
        let actions: [[String: Any]] = scene.actions.map { action in
            if let write = action as? HMCharacteristicWriteAction<NSCopying> {
                return ["kind": "characteristicWrite", "characteristicID": write.characteristic.uniqueIdentifier.uuidString,
                        "value": AutomationRules.value(write.targetValue, object: object)]
            }
            return ["kind": String(describing: type(of: action)), "supported": false]
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
