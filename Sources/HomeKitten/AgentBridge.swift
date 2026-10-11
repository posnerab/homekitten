import Foundation
import SwiftUI
import UIKit
@preconcurrency import HomeKit

// The paired-device file service is the transport. No network listener or token.
enum AgentValue: Codable, Sendable, Equatable {
    case bool(Bool), number(Double), string(String)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else { self = .string(try c.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }
    var value: NSCopying {
        switch self {
        case .bool(let v): NSNumber(value: v)
        case .number(let v): NSNumber(value: v)
        case .string(let v): v as NSString
        }
    }
}

struct AgentAction: Codable, Sendable {
    let characteristicID: UUID
    let value: AgentValue
}

// Declarative rules only: never accept executable/raw predicate expressions.
struct AgentEvent: Codable, Sendable, Equatable {
    let kind: String
    let characteristicID: UUID?
    let value: AgentValue?
    let hour: Int?
    let minute: Int?
    let significantEvent: String?
    let offsetMinutes: Int?
    let presenceEvent: String?
    let presenceUser: String?
    let durationSeconds: Double?
}

struct AgentCondition: Codable, Sendable {
    let kind: String
    let presence: String?
    let presenceUser: String?
    let characteristicID: UUID?
    let comparison: String?
    let value: AgentValue?
    let children: [AgentCondition]?
}

struct AgentRequest: Codable, Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let operation: String
    let homeID: UUID
    let objectID: UUID?
    let roomID: UUID?
    let name: String?
    let value: AgentValue?
    let actions: [AgentAction]?
    let sceneIDs: [UUID]?
    let fireDate: Date?
    let recurrenceMinutes: Int?
    let enabled: Bool?
    let events: [AgentEvent]?
    let endEvents: [AgentEvent]?
    let conditions: AgentCondition?
    let additionalConditions: AgentCondition?
    let clearConditions: Bool?
    let recurrenceWeekdays: [Int]?
    let executeOnce: Bool?

    var changesEventRules: Bool {
        events != nil || endEvents != nil || conditions != nil || additionalConditions != nil || clearConditions != nil || recurrenceWeekdays != nil || executeOnce != nil
    }
}

struct AgentReadRequest: Codable, Sendable {
    let id: UUID
    let sessionID: UUID
    let homeID: UUID
    let characteristicIDs: [UUID]
}

@MainActor
private final class AgentReadCompletion {
    private var continuation: CheckedContinuation<String?, Never>?
    init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
    func finish(error: String?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: error)
    }
}

@MainActor
@Observable
final class AgentBridge {
    private(set) var running = false
    private(set) var status = "Disconnected"
    private(set) var pending: AgentRequest?
    private(set) var preview = ""
    private(set) var busy = false
    private(set) var writesAllowed = false
    private var sessionID = UUID()
    private var metadataReads = Set<UUID>()
    private var metadataReadStatus = [String: String]()
    private var timer: Timer?
    private var reading = false
    private var store: HomeStore?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var wantsConnection = UserDefaults.standard.bool(forKey: "agentBridge.enabled")
    private var requestedChanges = UserDefaults.standard.bool(forKey: "agentBridge.allowChanges")
    private let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AgentBridge", isDirectory: true)

    func start(_ store: HomeStore, allowChanges: Bool) {
        guard !running, store.isAuthorized, store.isReady else {
            if !store.isAuthorized { status = "Home access is required." }
            return
        }
        self.store = store
        wantsConnection = true
        requestedChanges = allowChanges
        UserDefaults.standard.set(true, forKey: "agentBridge.enabled")
        UserDefaults.standard.set(allowChanges, forKey: "agentBridge.allowChanges")
        sessionID = UUID()
        metadataReads.removeAll()
        metadataReadStatus.removeAll()
        writesAllowed = allowChanges
        do {
            for name in ["incoming", "responses", "backups", "reads", "read-responses"] {
                try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            running = true
            status = allowChanges ? "Connected — changes allowed for this session" : "Connected — read only"
            tick()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch { status = error.localizedDescription }
    }

    func stop(preserveConnection: Bool = false) {
        if !preserveConnection {
            wantsConnection = false
            UserDefaults.standard.set(false, forKey: "agentBridge.enabled")
        }
        timer?.invalidate(); timer = nil
        running = false
        writesAllowed = false
        if let request = pending, !busy { respond(request, state: "rejected", message: "Session closed") }
        pending = nil
        status = "Disconnected"
        try? write(["active": false, "capturedAt": isoNow(), "sessionID": sessionID.uuidString], to: "inventory.json")
        endBackgroundTask()
    }

    func resume(_ store: HomeStore) {
        endBackgroundTask()
        if wantsConnection && !running { start(store, allowChanges: requestedChanges) }
    }

    func background() {
        #if targetEnvironment(macCatalyst)
        // A desktop process can keep serving files while its window is minimized.
        return
        #else
        guard running, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "HomeKitten Agent Connection") { [weak self] in
            Task { @MainActor in
                self?.stop(preserveConnection: true)
                self?.status = "Paused by iOS — resumes when the app opens"
            }
        }
        if backgroundTask == .invalid { stop(preserveConnection: true) }
        #endif
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func tick() {
        guard running, let store, store.isAuthorized else { stop(preserveConnection: true); return }
        do {
            refreshAccessoryMetadata(store)
            try publish(store)
            processReads()
            guard pending == nil, !busy else { return }
            let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("incoming"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("responses/\($0.lastPathComponent)").path) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for url in files.prefix(100) {
                guard let data = try? Data(contentsOf: url), data.count <= 65536 else { continue }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                guard let request = try? decoder.decode(AgentRequest.self, from: data),
                      url.lastPathComponent == "\(request.id.uuidString).json" else { continue }
                if FileManager.default.fileExists(atPath: responseURL(request).path) { continue }
                guard request.sessionID == sessionID else {
                    respond(request, state: "rejected", message: "Stale session; read inventory again")
                    continue
                }
                guard writesAllowed else {
                    respond(request, state: "rejected", message: "Read-only session; reconnect with changes allowed")
                    continue
                }
                do {
                    preview = try describe(request)
                    pending = request
                    Task { await self.apply(request) }
                    break
                } catch { respond(request, state: "rejected", message: error.localizedDescription) }
            }
        } catch { status = error.localizedDescription }
    }

    private func apply(_ request: AgentRequest) async {
        guard pending?.id == request.id, request.sessionID == sessionID,
              !busy, running, writesAllowed, let store, store.isAuthorized else { return }
        busy = true
        // Persist consumption before the first HomeKit write: no replay after a crash.
        do {
            guard try describe(request) == preview else { throw failure("Home configuration changed; submit a fresh request") }
            try write(["id": request.id.uuidString, "state": "executing", "message": "Authorized connection session", "updatedAt": isoNow()], to: "responses/\(request.id.uuidString).json")
            let home = try resolveHome(request)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(HomeBackupService.makeBackup(home: home))
                .write(to: directory.appendingPathComponent("backups/\(request.id.uuidString).json"), options: .atomic)
            let result = try await execute(request, home: home)
            respond(request, state: "completed", message: result)
            if running { try publish(store) }
        } catch {
            respond(request, state: "failed", message: "\(error.localizedDescription). A multi-step operation may have partially completed; inspect Home before retrying.")
        }
        busy = false; pending = nil
    }

    private func resolveHome(_ r: AgentRequest) throws -> HMHome {
        guard let home = store?.homes.first(where: { $0.uniqueIdentifier == r.homeID }) else { throw failure("Home UUID not found") }
        return home
    }

    // Read requests have a separate queue and never enter the write/backup path.
    private func processReads() {
        guard !reading else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("reads"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("read-responses/\($0.lastPathComponent)").path) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files.prefix(100) {
                guard let data = try? Data(contentsOf: file), data.count <= 65536,
                      let request = try? JSONDecoder().decode(AgentReadRequest.self, from: data),
                      file.lastPathComponent == "\(request.id.uuidString).json" else { continue }
                reading = true
                Task { await performRead(request) }
                break
            }
        } catch { status = "Could not read live-read queue: \(error.localizedDescription)" }
    }

    private func performRead(_ request: AgentReadRequest) async {
        defer { reading = false }
        let path = "read-responses/\(request.id.uuidString).json"
        do {
            guard running, request.sessionID == sessionID, let store, store.isAuthorized else { throw failure("Stale or disconnected session; read inventory again") }
            guard (1...10).contains(request.characteristicIDs.count), Set(request.characteristicIDs).count == request.characteristicIDs.count else { throw failure("Provide 1–10 unique characteristic UUIDs") }
            guard let home = store.homes.first(where: { $0.uniqueIdentifier == request.homeID }) else { throw failure("Home UUID not found") }
            try write(["id": request.id.uuidString, "state": "executing", "updatedAt": isoNow()], to: path)
            var results = [[String: Any]]()
            for id in request.characteristicIDs {
                guard running, request.sessionID == sessionID else { throw failure("Session closed during live read") }
                guard let c = home.accessories.flatMap(\.services).flatMap(\.characteristics).first(where: { $0.uniqueIdentifier == id }),
                      c.properties.contains(HMCharacteristicPropertyReadable) else {
                    results.append(["characteristicID": id.uuidString, "state": "failed", "error": "Readable characteristic UUID not found in this Home"])
                    continue
                }
                results.append(await readCurrentValue(c))
            }
            guard running, request.sessionID == sessionID else { throw failure("Session closed during live read") }
            try write(["id": request.id.uuidString, "state": "completed", "homeID": home.uniqueIdentifier.uuidString,
                       "source": "homekit_read", "results": results, "updatedAt": isoNow()], to: path)
            try publish(store)
        } catch {
            try? write(["id": request.id.uuidString, "state": "failed", "error": error.localizedDescription, "updatedAt": isoNow()], to: path)
        }
    }

    private func readCurrentValue(_ characteristic: HMCharacteristic) async -> [String: Any] {
        let error: String? = await withCheckedContinuation { continuation in
            let completion = AgentReadCompletion(continuation)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                completion.finish(error: "HomeKit read timed out after 3 seconds")
            }
            characteristic.readValue { error in
                Task { @MainActor in
                    completion.finish(error: error?.localizedDescription)
                }
            }
        }
        if let error {
            return ["characteristicID": characteristic.uniqueIdentifier.uuidString, "state": "failed", "error": error]
        }
        return ["characteristicID": characteristic.uniqueIdentifier.uuidString, "state": "read",
                "value": jsonValue(characteristic.value), "readAt": isoNow()]
    }
    private func characteristic(_ id: UUID?, in home: HMHome) throws -> HMCharacteristic {
        guard let id, let c = home.accessories.flatMap(\.services).flatMap(\.characteristics).first(where: { $0.uniqueIdentifier == id }),
              c.properties.contains(HMCharacteristicPropertyWritable) else { throw failure("Writable characteristic UUID not found") }
        return c
    }
    private func scene(_ id: UUID?, in home: HMHome) throws -> HMActionSet {
        guard let id, let scene = home.actionSets.first(where: { $0.uniqueIdentifier == id }) else { throw failure("Scene UUID not found") }
        return scene
    }
    private func trigger(_ id: UUID?, in home: HMHome) throws -> HMTrigger {
        guard let id, let trigger = home.triggers.first(where: { $0.uniqueIdentifier == id }) else { throw failure("Automation UUID not found") }
        return trigger
    }
    private func newName(_ r: AgentRequest) throws -> String {
        guard let name = r.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 128 else { throw failure("Name must contain 1–128 characters") }
        return name
    }
    private func validate(_ value: AgentValue, for c: HMCharacteristic) throws {
        let format = c.metadata?.format
        switch value {
        case .bool: guard format == HMCharacteristicMetadataFormatBool else { throw failure("Expected numeric or string value") }
        case .string: guard format == HMCharacteristicMetadataFormatString else { throw failure("String unsupported for this characteristic") }
        case .number(let number):
            let numeric = [HMCharacteristicMetadataFormatInt, HMCharacteristicMetadataFormatFloat, HMCharacteristicMetadataFormatUInt8, HMCharacteristicMetadataFormatUInt16, HMCharacteristicMetadataFormatUInt32, HMCharacteristicMetadataFormatUInt64]
            guard let format, numeric.contains(format), number.isFinite else { throw failure("Numeric value unsupported") }
            if format != HMCharacteristicMetadataFormatFloat && number.rounded() != number { throw failure("Integer required") }
            if let min = c.metadata?.minimumValue, number < min.doubleValue { throw failure("Value below minimum") }
            if let max = c.metadata?.maximumValue, number > max.doubleValue { throw failure("Value above maximum") }
            if let step = c.metadata?.stepValue?.doubleValue, step > 0 {
                let steps = (number - (c.metadata?.minimumValue?.doubleValue ?? 0)) / step
                guard abs(steps - steps.rounded()) < 0.00001 else { throw failure("Value does not match characteristic step size") }
            }
            if let valid = c.metadata?.validValues, !valid.isEmpty, !valid.contains(where: { $0.doubleValue == number }) { throw failure("Value outside valid choices") }
        }
    }
    private func readableCharacteristic(_ id: UUID?, in home: HMHome, notifying: Bool = false) throws -> HMCharacteristic {
        guard let id, let c = home.accessories.flatMap(\.services).flatMap(\.characteristics).first(where: { $0.uniqueIdentifier == id }),
              c.properties.contains(HMCharacteristicPropertyReadable),
              !notifying || c.properties.contains(HMCharacteristicPropertySupportsEventNotification) else {
            throw failure("Readable\(notifying ? " notifying" : "") characteristic UUID not found in this Home")
        }
        return c
    }

    private func makeEvents(_ specs: [AgentEvent], home: HMHome, end: Bool = false) throws -> [HMEvent] {
        guard specs.count <= 32, end || !specs.isEmpty else { throw failure("Provide 1–32 trigger events (0–32 end events)") }
        guard specs.enumerated().allSatisfy({ index, item in !specs.prefix(index).contains(item) }) else { throw failure("Duplicate events") }
        return try specs.map { spec in
            switch spec.kind {
            case "characteristic":
                let c = try readableCharacteristic(spec.characteristicID, in: home, notifying: true)
                guard let value = spec.value else { throw failure("Characteristic event requires value") }
                try validate(value, for: c)
                return HMCharacteristicEvent<NSCopying>(characteristic: c, triggerValue: value.value)
            case "calendar":
                guard let hour = spec.hour, (0...23).contains(hour), let minute = spec.minute, (0...59).contains(minute) else { throw failure("Calendar event requires hour 0–23 and minute 0–59") }
                return HMCalendarEvent(fire: DateComponents(hour: hour, minute: minute))
            case "significant_time":
                guard let name = spec.significantEvent, ["sunrise", "sunset"].contains(name), (-720...720).contains(spec.offsetMinutes ?? 0) else { throw failure("Use sunrise/sunset and offsetMinutes -720–720") }
                return HMSignificantTimeEvent(significantEvent: name == "sunrise" ? .sunrise : .sunset, offset: DateComponents(minute: spec.offsetMinutes ?? 0))
            case "presence":
                guard let name = spec.presenceEvent, ["first_entry", "last_exit"].contains(name), ["home_users", "current_user"].contains(spec.presenceUser ?? "home_users") else { throw failure("Unsupported presence event/user scope") }
                return HMPresenceEvent(presenceEventType: name == "first_entry" ? .firstEntry : .lastExit, presenceUserType: spec.presenceUser == "current_user" ? .currentUser : .homeUsers)
            case "duration":
                guard end, let seconds = spec.durationSeconds, seconds.isFinite, seconds > 0, seconds <= 86400 else { throw failure("Duration is an end event with 0 < durationSeconds <= 86400") }
                return HMDurationEvent(duration: seconds)
            default: throw failure("Unsupported event kind")
            }
        }
    }

    private func makeCondition(_ spec: AgentCondition, home: HMHome, depth: Int = 0) throws -> NSPredicate {
        guard depth < 8 else { throw failure("Condition tree is too deep") }
        if spec.kind == "presence" {
            guard ["at_home", "not_home"].contains(spec.presence ?? ""),
                  ["home_users", "current_user"].contains(spec.presenceUser ?? "home_users"),
                  spec.children == nil, spec.characteristicID == nil, spec.value == nil, spec.comparison == nil else {
                throw failure("Presence condition requires at_home/not_home and home_users/current_user")
            }
            let event = HMPresenceEvent(presenceEventType: spec.presence == "at_home" ? .firstEntry : .lastExit,
                                        presenceUserType: spec.presenceUser == "current_user" ? .currentUser : .homeUsers)
            return HMEventTrigger.predicateForEvaluatingTrigger(withPresence: event)
        }
        guard spec.presence == nil, spec.presenceUser == nil else { throw failure("Presence fields require a presence condition") }
        if spec.kind == "characteristic" {
            guard spec.children == nil else { throw failure("Characteristic conditions cannot have children") }
            let c = try readableCharacteristic(spec.characteristicID, in: home)
            guard let value = spec.value else { throw failure("Condition requires value") }
            try validate(value, for: c)
            let operators: [String: NSComparisonPredicate.Operator] = ["equal": .equalTo, "not_equal": .notEqualTo, "less_than": .lessThan, "greater_than": .greaterThan, "at_most": .lessThanOrEqualTo, "at_least": .greaterThanOrEqualTo]
            guard let comparison = operators[spec.comparison ?? "equal"] else { throw failure("Unsupported condition comparison") }
            if case .number = value {} else if !["equal", "not_equal"].contains(spec.comparison ?? "equal") { throw failure("Ordering requires a numeric characteristic") }
            return HMEventTrigger.predicateForEvaluatingTrigger(c, relatedBy: comparison, toValue: value.value)
        }
        guard ["all", "any", "not"].contains(spec.kind), spec.characteristicID == nil, spec.value == nil, spec.comparison == nil,
              let children = spec.children, !children.isEmpty, children.count <= 32, spec.kind != "not" || children.count == 1 else { throw failure("Use all/any with 1–32 children or not with one child") }
        let predicates = try children.map { try makeCondition($0, home: home, depth: depth + 1) }
        switch spec.kind {
        case "all": return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        case "any": return NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        default: return NSCompoundPredicate(notPredicateWithSubpredicate: predicates[0])
        }
    }

    private func validateEventRules(_ r: AgentRequest, home: HMHome) throws -> String {
        guard [r.conditions != nil, r.additionalConditions != nil, r.clearConditions == true].filter({ $0 }).count <= 1 else {
            throw failure("conditions, additionalConditions and clearConditions are mutually exclusive")
        }
        if r.additionalConditions != nil && r.operation != "update_automation" { throw failure("additionalConditions requires update_automation") }
        if let events = r.events { _ = try makeEvents(events, home: home) }
        if let events = r.endEvents { _ = try makeEvents(events, home: home, end: true) }
        if let conditions = r.conditions { _ = try makeCondition(conditions, home: home) }
        if let conditions = r.additionalConditions { _ = try makeCondition(conditions, home: home) }
        if let days = r.recurrenceWeekdays {
            guard days.count <= 7, Set(days).count == days.count, days.allSatisfy({ (1...7).contains($0) }) else { throw failure("recurrenceWeekdays must be unique weekdays 1–7; [] means every day") }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        if let events = r.events { lines.append("Replace trigger events: " + String(decoding: try encoder.encode(events), as: UTF8.self)) }
        if let events = r.endEvents { lines.append("Replace end events: " + String(decoding: try encoder.encode(events), as: UTF8.self)) }
        if let condition = r.conditions { lines.append("Replace conditions: " + String(decoding: try encoder.encode(condition), as: UTF8.self)) }
        if let condition = r.additionalConditions { lines.append("AND additional conditions with the existing native predicate: " + String(decoding: try encoder.encode(condition), as: UTF8.self)) }
        if r.clearConditions == true { lines.append("Remove conditions") }
        if let days = r.recurrenceWeekdays { lines.append("Weekdays: \(days)") }
        if let once = r.executeOnce { lines.append("Execute once: \(once)") }
        return lines.joined(separator: "\n")
    }

    private func describe(_ r: AgentRequest) throws -> String {
        let home = try resolveHome(r)
        if r.operation == "delete_scene" || r.operation == "delete_automation" {
            guard r.objectID != nil, r.roomID == nil, r.name == nil, r.value == nil,
                  r.actions == nil, r.sceneIDs == nil, r.fireDate == nil, r.recurrenceMinutes == nil,
                  r.enabled == nil, !r.changesEventRules else {
                throw failure("Deletion requires objectID and no other change fields")
            }
        }
        var text = "\(r.operation) in \(home.name)\nHome: \(r.homeID)\n"
        switch r.operation {
        case "delete_scene":
            let target = try scene(r.objectID, in: home)
            if let reason = HomeDeletion.sceneBlockReason(target, in: home) { throw failure(reason) }
            text += "Permanently delete scene \(target.name) with \(target.actions.count) actions"
        case "delete_automation":
            let target = try trigger(r.objectID, in: home)
            text += "Permanently delete automation \(target.name); enabled: \(target.isEnabled); attached scenes: \(target.actionSets.map { $0.uniqueIdentifier.uuidString }.sorted().joined(separator: ", "))"
        case "create_room":
            let name = try newName(r)
            guard !home.rooms.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw failure("Room name already exists") }
            text += "Create room \(name)"
        case "assign_accessory":
            guard let accessory = home.accessories.first(where: { $0.uniqueIdentifier == r.objectID }) else { throw failure("Accessory UUID not found") }
            guard let room = home.rooms.first(where: { $0.uniqueIdentifier == r.roomID }) else { throw failure("Room UUID not found in this Home") }
            text += "Move \(accessory.name) from \(accessory.room?.name ?? "Default Room") to \(room.name) [\(room.uniqueIdentifier)]"
        case "rename_accessory":
            guard let a = home.accessories.first(where: { $0.uniqueIdentifier == r.objectID }) else { throw failure("Accessory UUID not found") }
            text += "Rename \(a.name) to \(try newName(r))"
        case "set_characteristic":
            let c = try characteristic(r.objectID, in: home)
            guard let value = r.value else { throw failure("Value required") }
            try validate(value, for: c)
            text += "\(c.service?.accessory?.name ?? "Accessory") / \(c.localizedDescription)\nCached value: \(String(describing: c.value ?? "unknown"))\nNew value: \(value.value)"
        case "create_scene", "update_scene":
            if r.operation == "update_scene" {
                let scene = try scene(r.objectID, in: home)
                text += "Replace all \(scene.actions.count) actions in \(scene.name)\n"
                text += "Current actions:\n"
                for action in scene.actions {
                    guard let write = action as? HMCharacteristicWriteAction<NSCopying> else { throw failure("Scene contains unsupported actions; use the app UI") }
                    text += "\(write.characteristic.uniqueIdentifier) → \(write.targetValue)\n"
                }
            } else {
                let name = try newName(r)
                guard !home.actionSets.contains(where: { $0.name == name }) else { throw failure("Scene name already exists") }
                text += "Create scene \(name)\n"
            }
            guard let actions = r.actions, !actions.isEmpty, actions.count <= 100 else { throw failure("Provide 1–100 actions") }
            guard Set(actions.map(\.characteristicID)).count == actions.count else { throw failure("Duplicate characteristics") }
            for action in actions {
                let c = try characteristic(action.characteristicID, in: home)
                try validate(action.value, for: c)
                text += "\(c.service?.accessory?.name ?? "Accessory") / \(c.localizedDescription) [\(c.uniqueIdentifier)] → \(action.value.value)\n"
            }
            if r.name != nil { _ = try newName(r) }
        case "rename_scene", "run_scene":
            text += "Scene: \(try scene(r.objectID, in: home).name)"
            if r.operation == "rename_scene" { text += " → \(try newName(r))" }
        case "create_timer":
            let name = try newName(r)
            guard !home.triggers.contains(where: { $0.name == name }) else { throw failure("Automation name already exists") }
            text += "Create timer \(name)\n"
            guard let date = r.fireDate, date > Date() else { throw failure("Future ISO 8601 fireDate required") }
            if let minutes = r.recurrenceMinutes, !(1...525600).contains(minutes) { throw failure("Invalid recurrenceMinutes") }
            guard let ids = r.sceneIDs, !ids.isEmpty, Set(ids).count == ids.count else { throw failure("Unique sceneIDs required") }
            for id in ids { text += "Scene: \(try scene(id, in: home).name) [\(id)]\n" }
            text += "Fire: \(ISO8601DateFormatter().string(from: date)); repeat minutes: \(r.recurrenceMinutes ?? 0); enabled: \(r.enabled ?? false)"
        case "create_event_automation":
            let name = try newName(r)
            guard !home.triggers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw failure("Automation name already exists") }
            guard r.events != nil else { throw failure("Trigger events required") }
            guard let ids = r.sceneIDs, !ids.isEmpty, Set(ids).count == ids.count else { throw failure("Unique nonempty sceneIDs required") }
            for id in ids { _ = try scene(id, in: home) }
            text += "Create event automation \(name); enabled: \(r.enabled ?? false)\n"
            text += try validateEventRules(r, home: home)
        case "update_automation":
            let trigger = try trigger(r.objectID, in: home)
            text += "Automation: \(trigger.name)\n"
            text += "Currently enabled: \(trigger.isEnabled); current scenes: \(trigger.actionSets.map { $0.uniqueIdentifier.uuidString }.sorted().joined(separator: ", "))\n"
            guard r.name != nil || r.enabled != nil || r.sceneIDs != nil || r.changesEventRules else { throw failure("Provide name, enabled, sceneIDs, or event rules") }
            if r.changesEventRules {
                guard let event = trigger as? HMEventTrigger else { throw failure("Event rules require an event automation") }
                text += "Current event rules: " + String(decoding: try JSONSerialization.data(withJSONObject: AutomationInventory.trigger(event), options: [.sortedKeys]), as: UTF8.self) + "\n"
                text += try validateEventRules(r, home: home)
            }
            if r.name != nil { text += "Name → \(try newName(r))\n" }
            if let enabled = r.enabled { text += "Enabled → \(enabled)\n" }
            if let ids = r.sceneIDs {
                guard !ids.isEmpty, Set(ids).count == ids.count else { throw failure("Unique nonempty sceneIDs required") }
                text += "Replace attached scenes:\n"
                for id in ids { text += "\(try scene(id, in: home).name) [\(id)]\n" }
            }
        default: throw failure("Unsupported operation")
        }
        if let id = r.objectID { text += "\nTarget UUID: \(id)" }
        return text
    }

    private func execute(_ r: AgentRequest, home: HMHome) async throws -> String {
        switch r.operation {
        case "delete_scene":
            let target = try scene(r.objectID, in: home)
            try await HomeDeletion.deleteScene(target, in: home)
            return "Scene deleted: \(target.uniqueIdentifier)"
        case "delete_automation":
            let target = try trigger(r.objectID, in: home)
            try await HomeDeletion.deleteAutomation(target, in: home)
            return "Automation deleted: \(target.uniqueIdentifier); shared scenes retained"
        case "create_room":
            let name = try newName(r)
            let room: HMRoom = try await withCheckedThrowingContinuation { continuation in
                home.addRoom(withName: name) { room, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let room { continuation.resume(returning: room) }
                    else { continuation.resume(throwing: self.failure("Room creation returned no room")) }
                }
            }
            return "Room saved: \(room.uniqueIdentifier)"
        case "assign_accessory":
            guard let accessory = home.accessories.first(where: { $0.uniqueIdentifier == r.objectID }),
                  let room = home.rooms.first(where: { $0.uniqueIdentifier == r.roomID }) else { throw failure("Accessory or room UUID not found in this Home") }
            if accessory.room?.uniqueIdentifier != room.uniqueIdentifier { try await home.assignAccessory(accessory, to: room) }
            guard accessory.room?.uniqueIdentifier == room.uniqueIdentifier else { throw failure("Room assignment read-back did not confirm the target") }
            return "Accessory assigned to room: \(room.uniqueIdentifier)"
        case "rename_accessory":
            let a = home.accessories.first { $0.uniqueIdentifier == r.objectID }!
            try await a.updateName(newName(r))
        case "set_characteristic":
            let c = try characteristic(r.objectID, in: home)
            try await c.writeValue(r.value!.value)
            if c.properties.contains(HMCharacteristicPropertyReadable) {
                try await c.readValue()
                return "Write completed; read-back: \(String(describing: c.value ?? "unknown"))"
            }
            return "Write completed; characteristic does not support read-back"
        case "create_scene", "update_scene":
            let target: HMActionSet
            if r.operation == "create_scene" { target = try await home.addActionSet(named: newName(r)) }
            else { target = try scene(r.objectID, in: home) }
            if r.operation == "update_scene" {
                for action in target.actions { try await target.removeAction(action) }
                if r.name != nil { try await target.updateName(newName(r)) }
            }
            for action in r.actions! {
                let c = try characteristic(action.characteristicID, in: home)
                try await target.addAction(HMCharacteristicWriteAction<NSCopying>(characteristic: c, targetValue: action.value.value))
            }
            return "Scene saved: \(target.uniqueIdentifier)"
        case "rename_scene": try await scene(r.objectID, in: home).updateName(newName(r))
        case "run_scene": try await home.executeActionSet(scene(r.objectID, in: home))
        case "create_timer":
            let timer = HMTimerTrigger(name: try newName(r), fireDate: r.fireDate!, recurrence: r.recurrenceMinutes.map { DateComponents(minute: $0) })
            try await home.addTrigger(timer)
            for id in r.sceneIDs! { try await timer.addActionSet(scene(id, in: home)) }
            if r.enabled == true { try await timer.enable(true) }
            return "Timer saved: \(timer.uniqueIdentifier)"
        case "create_event_automation":
            let target = HMEventTrigger(name: try newName(r), events: try makeEvents(r.events!, home: home), predicate: try r.conditions.map { try makeCondition($0, home: home) })
            try await home.addTrigger(target)
            if let events = r.endEvents { try await target.updateEndEvents(makeEvents(events, home: home, end: true)) }
            if let days = r.recurrenceWeekdays { try await target.updateRecurrences(days.isEmpty ? nil : days.map { DateComponents(weekday: $0) }) }
            if let once = r.executeOnce { try await target.updateExecuteOnce(once) }
            for id in r.sceneIDs! { try await target.addActionSet(scene(id, in: home)) }
            if r.enabled == true { try await target.enable(true) }
            return "Event automation saved: \(target.uniqueIdentifier)"
        case "update_automation":
            let target = try trigger(r.objectID, in: home)
            let wasEnabled = target.isEnabled
            if (r.sceneIDs != nil || r.changesEventRules) && wasEnabled { try await target.enable(false) }
            if r.changesEventRules, let event = target as? HMEventTrigger {
                if let events = r.events { try await event.updateEvents(makeEvents(events, home: home)) }
                if let events = r.endEvents { try await event.updateEndEvents(makeEvents(events, home: home, end: true)) }
                if let condition = r.conditions { try await event.updatePredicate(makeCondition(condition, home: home)) }
                else if let condition = r.additionalConditions {
                    let added = try makeCondition(condition, home: home)
                    let predicate = event.predicate.map { NSCompoundPredicate(andPredicateWithSubpredicates: [$0, added]) } ?? added
                    try await event.updatePredicate(predicate)
                }
                else if r.clearConditions == true { try await event.updatePredicate(nil) }
                if let days = r.recurrenceWeekdays { try await event.updateRecurrences(days.isEmpty ? nil : days.map { DateComponents(weekday: $0) }) }
                if let once = r.executeOnce { try await event.updateExecuteOnce(once) }
            }
            if r.name != nil { try await target.updateName(newName(r)) }
            if let ids = r.sceneIDs {
                for current in target.actionSets where !ids.contains(current.uniqueIdentifier) { try await target.removeActionSet(current) }
                for id in ids where !target.actionSets.contains(where: { $0.uniqueIdentifier == id }) { try await target.addActionSet(scene(id, in: home)) }
            }
            if r.enabled != nil || r.sceneIDs != nil || r.changesEventRules { try await target.enable(r.enabled ?? wasEnabled) }
        default: throw failure("Unsupported operation")
        }
        return "HomeKit operation completed"
    }

    // Read only identifying metadata once per connection; leave sensor values cached.
    private func refreshAccessoryMetadata(_ store: HomeStore) {
        let types = Set([HMCharacteristicTypeManufacturer, HMCharacteristicTypeModel,
                         HMCharacteristicTypeSerialNumber, HMCharacteristicTypeFirmwareVersion,
                         HMCharacteristicTypeHardwareVersion])
        for home in store.homes {
            for accessory in home.accessories {
                for c in accessory.services.flatMap(\.characteristics)
                    where types.contains(c.characteristicType) && c.properties.contains(HMCharacteristicPropertyReadable) {
                    guard metadataReads.insert(c.uniqueIdentifier).inserted else { continue }
                    let key = c.uniqueIdentifier.uuidString
                    metadataReadStatus[key] = "pending"
                    c.readValue { [weak self] error in
                        Task { @MainActor in
                            self?.metadataReadStatus[key] = error == nil ? "read" : "failed"
                        }
                    }
                }
            }
        }
    }

    private func publish(_ store: HomeStore) throws {
        let homes: [[String: Any]] = store.homes.map { home in
            let bridges = Dictionary(uniqueKeysWithValues: home.accessories.flatMap { bridge in
                bridge.bridgedAccessories.map { ($0.uniqueIdentifier, bridge) }
            })
            let accessories: [[String: Any]] = home.accessories.map { accessory in
                let services: [[String: Any]] = accessory.services.map { service in
                    let characteristics: [[String: Any]] = service.characteristics.map { c in
                        ["id": c.uniqueIdentifier.uuidString, "name": c.localizedDescription,
                         "type": c.characteristicType, "properties": c.properties,
                         "cachedValue": jsonValue(c.value), "metadataReadStatus": metadataReadStatus[c.uniqueIdentifier.uuidString] ?? "not_requested", "format": c.metadata?.format ?? "",
                         "min": jsonValue(c.metadata?.minimumValue), "max": jsonValue(c.metadata?.maximumValue)]
                    }
                    return ["id": service.uniqueIdentifier.uuidString, "name": service.name, "type": service.serviceType, "characteristics": characteristics]
                }
                return ["id": accessory.uniqueIdentifier.uuidString, "name": accessory.name, "reachable": accessory.isReachable,
                        "roomID": accessory.room?.uniqueIdentifier.uuidString ?? "", "services": services,
                        "manufacturer": accessory.manufacturer ?? "", "model": accessory.model ?? "",
                        "firmwareVersion": accessory.firmwareVersion ?? "",
                        "categoryType": accessory.category.categoryType,
                        "bridgeID": bridges[accessory.uniqueIdentifier]?.uniqueIdentifier.uuidString ?? "",
                        "bridgeName": bridges[accessory.uniqueIdentifier]?.name ?? ""]
            }
            // Trigger-owned action sets are not necessarily listed in home.actionSets.
            var actionSets = home.actionSets
            var actionSetIDs = Set(actionSets.map(\.uniqueIdentifier))
            for scene in home.triggers.flatMap(\.actionSets) where actionSetIDs.insert(scene.uniqueIdentifier).inserted {
                actionSets.append(scene)
            }
            let scenes = actionSets.map { AutomationInventory.actionSet($0) }
            let automations = home.triggers.map { AutomationInventory.trigger($0) }
            let rooms: [[String: Any]] = home.rooms.map { ["id": $0.uniqueIdentifier.uuidString, "name": $0.name] }
            let zones: [[String: Any]] = home.zones.map {
                ["id": $0.uniqueIdentifier.uuidString, "name": $0.name,
                 "roomIDs": $0.rooms.map { $0.uniqueIdentifier.uuidString }]
            }
            let groups: [[String: Any]] = home.serviceGroups.map { ["id": $0.uniqueIdentifier.uuidString, "name": $0.name, "serviceIDs": $0.services.map { $0.uniqueIdentifier.uuidString }] }
            return ["id": home.uniqueIdentifier.uuidString, "name": home.name, "rooms": rooms, "groups": groups,
                    "zones": zones, "accessories": accessories, "scenes": scenes, "automations": automations]
        }
        try write(["version": 2, "active": true, "writesAllowed": writesAllowed, "capturedAt": isoNow(), "sessionID": sessionID.uuidString,
                   "liveReadsSupported": true,
                   "automationRulesVersion": 1, "automationWritesVersion": 1, "deletionWritesVersion": 1, "conditionCompositionVersion": 1, "automationRulesSource": "HomeKit public API",
                   "valuesAreCached": true, "homes": homes], to: "inventory.json")
    }
    private func jsonValue(_ value: Any?) -> Any {
        if let v = value as? NSNumber { return v }
        if let v = value as? String { return v }
        return NSNull()
    }
    private func write(_ object: [String: Any], to name: String) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    private func responseURL(_ r: AgentRequest) -> URL { directory.appendingPathComponent("responses/\(r.id.uuidString).json") }
    private func respond(_ r: AgentRequest, state: String, message: String) {
        do {
            try write(["id": r.id.uuidString, "state": state, "message": message, "updatedAt": isoNow()], to: "responses/\(r.id.uuidString).json")
            status = message
        } catch { status = "Could not record outcome: \(error.localizedDescription)" }
    }
    private func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }
    private func failure(_ message: String) -> NSError { NSError(domain: "HomeKitten.AgentBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

struct AgentAccessView: View {
    @Environment(HomeStore.self) private var store
    @Environment(AgentBridge.self) private var bridge
    @State private var allowChanges = true

    var body: some View {
        Form {
            Section("Mac Connection") {
                #if targetEnvironment(macCatalyst)
                Text("The local Mac client can work with your Home while this app runs, including with its window minimized. Access pauses when the Mac sleeps or the app quits.")
                #else
                Text("Your paired Mac can work with your Home from any screen. iOS may pause the connection in the background; opening the app resumes it.")
                #endif
                Text(bridge.status).font(.caption)
                if bridge.running { Button("Disconnect") { bridge.stop() }.disabled(bridge.busy) }
                else {
                    Toggle("Allow changes for this session", isOn: $allowChanges)
                    Text("Requests run automatically while connected. This setting is remembered until you disconnect.").font(.caption)
                    Button(allowChanges ? "Connect & Allow Changes" : "Connect Read Only") { bridge.start(store, allowChanges: allowChanges) }
                }
            }
            if bridge.pending != nil {
                Section("Applying Change") {
                    Text(bridge.preview).font(.callout).textSelection(.enabled)
                    Text("A configuration backup is saved before this change. Scenes can control physical accessories.").font(.caption)
                    if bridge.busy { ProgressView("Applying…") }
                }
            }
            else if !bridge.preview.isEmpty {
                Section("Last Request") { Text(bridge.preview).font(.callout).textSelection(.enabled) }
            }
        }
        .navigationTitle("Agent Access")
    }
}
