import Foundation
import SwiftUI
@preconcurrency import HomeKit

// The paired-device file service is the transport. No network listener or token.
enum AgentValue: Codable, Sendable {
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

struct AgentRequest: Codable, Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let operation: String
    let homeID: UUID
    let objectID: UUID?
    let name: String?
    let value: AgentValue?
    let actions: [AgentAction]?
    let sceneIDs: [UUID]?
    let fireDate: Date?
    let recurrenceMinutes: Int?
    let enabled: Bool?
}

@MainActor
@Observable
final class AgentBridge {
    private(set) var running = false
    private(set) var status = "Disconnected"
    private(set) var pending: AgentRequest?
    private(set) var preview = ""
    private(set) var busy = false
    private var sessionID = UUID()
    private var timer: Timer?
    private var store: HomeStore?
    private var pendingSince: Date?
    private let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AgentBridge", isDirectory: true)

    func start(_ store: HomeStore) {
        guard !running, store.isAuthorized, store.isReady else {
            if !store.isAuthorized { status = "Home access is required." }
            return
        }
        self.store = store
        sessionID = UUID()
        do {
            for name in ["incoming", "responses", "backups"] {
                try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            running = true
            status = "Connected over paired device access"
            tick()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch { status = error.localizedDescription }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        running = false
        if let request = pending, !busy { respond(request, state: "rejected", message: "Session closed") }
        pending = nil
        status = "Disconnected"
        try? write(["active": false, "capturedAt": isoNow(), "sessionID": sessionID.uuidString], to: "inventory.json")
    }

    private func tick() {
        guard running, let store, store.isAuthorized else { stop(); return }
        do {
            try publish(store)
            if let pendingSince, Date().timeIntervalSince(pendingSince) > 300, let pending, !busy {
                respond(pending, state: "expired", message: "Approval expired")
                self.pending = nil
            }
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
                do {
                    preview = try describe(request)
                    pending = request; pendingSince = Date()
                    // Approval is memory-only. Never write an executable approval token.
                    try write(["id": request.id.uuidString, "state": "pending", "preview": preview], to: "pending.json")
                    break
                } catch { respond(request, state: "rejected", message: error.localizedDescription) }
            }
        } catch { status = error.localizedDescription }
    }

    func reject() {
        guard let pending, !busy else { return }
        respond(pending, state: "rejected", message: "Declined on phone")
        self.pending = nil
    }

    func approve() async {
        guard let request = pending, !busy, running, let store, store.isAuthorized,
              let pendingSince, Date().timeIntervalSince(pendingSince) <= 300 else { return }
        busy = true
        // Persist consumption before the first HomeKit write: no replay after a crash.
        do {
            guard try describe(request) == preview else { throw failure("Home configuration changed; submit a fresh request") }
            try write(["id": request.id.uuidString, "state": "executing", "message": "Approved on phone", "updatedAt": isoNow()], to: "responses/\(request.id.uuidString).json")
            let home = try resolveHome(request)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(HomeBackupService.makeBackup(home: home))
                .write(to: directory.appendingPathComponent("backups/\(request.id.uuidString).json"), options: .atomic)
            let result = try await execute(request, home: home)
            respond(request, state: "completed", message: result)
            try publish(store)
        } catch {
            respond(request, state: "failed", message: "\(error.localizedDescription). A multi-step operation may have partially completed; inspect Home before retrying.")
        }
        busy = false; pending = nil
    }

    private func resolveHome(_ r: AgentRequest) throws -> HMHome {
        guard let home = store?.homes.first(where: { $0.uniqueIdentifier == r.homeID }) else { throw failure("Home UUID not found") }
        return home
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
    private func describe(_ r: AgentRequest) throws -> String {
        let home = try resolveHome(r)
        var text = "\(r.operation) in \(home.name)\nHome: \(r.homeID)\n"
        switch r.operation {
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
        case "update_automation":
            let trigger = try trigger(r.objectID, in: home)
            text += "Automation: \(trigger.name)\n"
            text += "Currently enabled: \(trigger.isEnabled); current scenes: \(trigger.actionSets.map { $0.uniqueIdentifier.uuidString }.sorted().joined(separator: ", "))\n"
            guard r.name != nil || r.enabled != nil || r.sceneIDs != nil else { throw failure("Provide name, enabled, or sceneIDs") }
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
        case "update_automation":
            let target = try trigger(r.objectID, in: home)
            let wasEnabled = target.isEnabled
            if r.sceneIDs != nil && wasEnabled { try await target.enable(false) }
            if r.name != nil { try await target.updateName(newName(r)) }
            if let ids = r.sceneIDs {
                for current in target.actionSets where !ids.contains(current.uniqueIdentifier) { try await target.removeActionSet(current) }
                for id in ids where !target.actionSets.contains(where: { $0.uniqueIdentifier == id }) { try await target.addActionSet(scene(id, in: home)) }
            }
            if r.enabled != nil || r.sceneIDs != nil { try await target.enable(r.enabled ?? wasEnabled) }
        default: throw failure("Unsupported operation")
        }
        return "HomeKit operation completed"
    }

    private func publish(_ store: HomeStore) throws {
        let homes: [[String: Any]] = store.homes.map { home in
            let accessories: [[String: Any]] = home.accessories.map { accessory in
                let services: [[String: Any]] = accessory.services.map { service in
                    let characteristics: [[String: Any]] = service.characteristics.map { c in
                        ["id": c.uniqueIdentifier.uuidString, "name": c.localizedDescription,
                         "type": c.characteristicType, "properties": c.properties,
                         "cachedValue": jsonValue(c.value), "format": c.metadata?.format ?? "",
                         "min": jsonValue(c.metadata?.minimumValue), "max": jsonValue(c.metadata?.maximumValue)]
                    }
                    return ["id": service.uniqueIdentifier.uuidString, "name": service.name, "type": service.serviceType, "characteristics": characteristics]
                }
                return ["id": accessory.uniqueIdentifier.uuidString, "name": accessory.name, "reachable": accessory.isReachable,
                        "roomID": accessory.room?.uniqueIdentifier.uuidString ?? "", "services": services]
            }
            let scenes: [[String: Any]] = home.actionSets.map { scene in
                let actions: [[String: Any]] = scene.actions.compactMap { action in
                    guard let action = action as? HMCharacteristicWriteAction<NSCopying> else { return nil }
                    return ["characteristicID": action.characteristic.uniqueIdentifier.uuidString, "value": jsonValue(action.targetValue)]
                }
                return ["id": scene.uniqueIdentifier.uuidString, "name": scene.name, "actions": actions]
            }
            let automations: [[String: Any]] = home.triggers.map { trigger in
                ["id": trigger.uniqueIdentifier.uuidString, "name": trigger.name, "enabled": trigger.isEnabled,
                 "kind": String(describing: type(of: trigger)), "sceneIDs": trigger.actionSets.map { $0.uniqueIdentifier.uuidString }]
            }
            let rooms: [[String: Any]] = home.rooms.map { ["id": $0.uniqueIdentifier.uuidString, "name": $0.name] }
            let groups: [[String: Any]] = home.serviceGroups.map { ["id": $0.uniqueIdentifier.uuidString, "name": $0.name, "serviceIDs": $0.services.map { $0.uniqueIdentifier.uuidString }] }
            return ["id": home.uniqueIdentifier.uuidString, "name": home.name, "rooms": rooms, "groups": groups,
                    "accessories": accessories, "scenes": scenes, "automations": automations]
        }
        try write(["version": 1, "active": true, "capturedAt": isoNow(), "sessionID": sessionID.uuidString,
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
    @Environment(\.scenePhase) private var phase
    @State private var bridge = AgentBridge()

    var body: some View {
        Form {
            Section("Mac Connection") {
                Text("Keep HomeKitten open here while your paired Mac reads your Home or sends a change for review.")
                Text(bridge.status).font(.caption)
                if bridge.running { Button("Disconnect") { bridge.stop() }.disabled(bridge.busy) }
                else { Button("Connect Paired Mac") { bridge.start(store) } }
            }
            if bridge.pending != nil {
                Section("Proposed Change") {
                    Text(bridge.preview).font(.callout).textSelection(.enabled)
                    Text("A configuration backup is saved before this change. Scenes can control physical accessories.").font(.caption)
                    Button("Approve Change") { Task { await bridge.approve() } }.disabled(bridge.busy)
                    Button("Decline", role: .cancel) { bridge.reject() }.disabled(bridge.busy)
                    if bridge.busy { ProgressView("Applying…") }
                }
            }
        }
        .navigationTitle("Agent Access")
        .onDisappear { bridge.stop() }
        .onChange(of: phase) { _, next in if next != .active { bridge.stop() } }
    }
}
