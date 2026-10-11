import Foundation
import SwiftUI
@preconcurrency import HomeKit

struct HomeBackup: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let homeID: UUID
    let homeName: String
    let accessories: [BackupAccessory]
    let rooms: [BackupRoom]
    let scenes: [BackupScene]
    let groups: [BackupGroup]
    let automations: [BackupAutomation]
}

struct BackupAccessory: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let roomID: UUID?
    let roomName: String?
    let manufacturer: String?
    let model: String?
    let categoryType: String?
    let serviceTypes: [String]
    let serialNumber: String?
    let firmwareVersion: String?
    let isReachable: Bool
    let bridgeID: UUID?
    let bridgeName: String?
}

struct BackupRoom: Codable, Identifiable, Sendable { let id: UUID; let name: String }

struct BackupServiceReference: Codable, Hashable, Sendable {
    let accessoryID: UUID
    let serviceID: UUID
}

struct BackupGroup: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let services: [BackupServiceReference]
}

enum BackupValue: Codable, Hashable, Sendable {
    case bool(Bool), integer(Int), double(Double), string(String)

    init?(_ value: NSCopying) {
        if let value = value as? Bool { self = .bool(value) }
        else if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .bool(value.boolValue) }
            else if value.doubleValue.rounded() == value.doubleValue { self = .integer(value.intValue) }
            else { self = .double(value.doubleValue) }
        } else if let value = value as? String { self = .string(value) }
        else { return nil }
    }

    var homeKitValue: NSCopying {
        switch self {
        case .bool(let value): NSNumber(value: value)
        case .integer(let value): NSNumber(value: value)
        case .double(let value): NSNumber(value: value)
        case .string(let value): value as NSString
        }
    }
}

struct BackupSceneAction: Codable, Hashable, Sendable {
    let accessoryID: UUID
    let serviceID: UUID
    let characteristicID: UUID
    let value: BackupValue
}

struct BackupScene: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let actions: [BackupSceneAction]
}

struct BackupAutomation: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let enabled: Bool
    let kind: String
    let fireDate: Date?
    let sceneIDs: [UUID]
    let sceneNames: [String]
}

@MainActor
enum HomeBackupService {
    static func makeBackup(home: HMHome) -> HomeBackup {
        let bridgeByAccessoryID = Dictionary(uniqueKeysWithValues: home.accessories.flatMap { bridge in
            bridge.bridgedAccessories.map { child in (child.uniqueIdentifier, bridge) }
        })
        return HomeBackup(
            id: UUID(), createdAt: Date(), homeID: home.uniqueIdentifier, homeName: home.name,
            accessories: home.accessories.map {
                let bridge = bridgeByAccessoryID[$0.uniqueIdentifier]
                return BackupAccessory(id: $0.uniqueIdentifier, name: $0.name, roomID: $0.room?.uniqueIdentifier,
                                roomName: $0.room?.name, manufacturer: $0.manufacturer, model: $0.model,
                                categoryType: $0.category.categoryType,
                                serviceTypes: Array(Set($0.services.map(\.serviceType))).sorted(),
                                serialNumber: characteristicValue(HMCharacteristicTypeSerialNumber, for: $0),
                                firmwareVersion: characteristicValue(HMCharacteristicTypeFirmwareVersion, for: $0),
                                isReachable: $0.isReachable, bridgeID: bridge?.uniqueIdentifier, bridgeName: bridge?.name)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            rooms: allRooms(home).map { BackupRoom(id: $0.uniqueIdentifier, name: $0.name) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            scenes: home.actionSets.map { scene in
                let actions = scene.actions.compactMap { action -> BackupSceneAction? in
                    guard let action = action as? HMCharacteristicWriteAction<NSCopying>,
                          let service = action.characteristic.service,
                          let accessory = service.accessory,
                          let value = BackupValue(action.targetValue) else { return nil }
                    return BackupSceneAction(accessoryID: accessory.uniqueIdentifier, serviceID: service.uniqueIdentifier,
                                             characteristicID: action.characteristic.uniqueIdentifier, value: value)
                }
                return BackupScene(id: scene.uniqueIdentifier, name: scene.name, actions: actions)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            groups: home.serviceGroups.map { group in
                BackupGroup(id: group.uniqueIdentifier, name: group.name, services: group.services.compactMap { service in
                    guard let accessory = service.accessory else { return nil }
                    return BackupServiceReference(accessoryID: accessory.uniqueIdentifier, serviceID: service.uniqueIdentifier)
                })
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            automations: home.triggers.map { trigger in
                let scenes = trigger.actionSets
                return BackupAutomation(id: trigger.uniqueIdentifier, name: trigger.name, enabled: trigger.isEnabled,
                                        kind: automationKind(trigger), fireDate: (trigger as? HMTimerTrigger)?.fireDate,
                                        sceneIDs: scenes.map(\.uniqueIdentifier), sceneNames: scenes.map(\.name))
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        )
    }

    static func save(_ backup: HomeBackup) throws {
        let directory = try backupDirectory()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(backup).write(to: directory.appendingPathComponent("\(backup.id.uuidString).json"), options: .atomic)
    }

    // Retain public-API rule details as evidence; event rules cannot all be restored automatically.
    static func saveDeletionBackup(home: HMHome) throws {
        let backup = makeBackup(home: home)
        try save(backup)
        let rules: [String: Any] = ["homeID": home.uniqueIdentifier.uuidString,
                                   "automations": home.triggers.map { AutomationInventory.trigger($0) }]
        try JSONSerialization.data(withJSONObject: rules, options: [.prettyPrinted, .sortedKeys])
            .write(to: try backupDirectory().appendingPathComponent("\(backup.id.uuidString).rules.json"), options: .atomic)
    }

    static func load() throws -> [HomeBackup] {
        let directory = try backupDirectory()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(HomeBackup.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func restore(_ item: BackupAccessory, to home: HMHome) async throws {
        guard let accessory = home.accessories.first(where: { $0.uniqueIdentifier == item.id }) else { throw RestoreError.accessoryUnavailable }
        if accessory.name != item.name { try await updateName(accessory, item.name) }
        if let room = room(id: item.roomID, name: item.roomName, in: home), accessory.room?.uniqueIdentifier != room.uniqueIdentifier {
            try await assign(accessory, to: room, in: home)
        }
    }

    static func restore(_ item: BackupRoom, to home: HMHome) async throws {
        if let existing = allRooms(home).first(where: { $0.uniqueIdentifier == item.id }) ?? home.rooms.first(where: { $0.name == item.name }) {
            if existing.name != item.name { try await updateName(existing, item.name) }
        } else { _ = try await addRoom(item.name, to: home) }
    }

    static func restore(_ item: BackupGroup, to home: HMHome) async throws {
        let existing = home.serviceGroups.first(where: { $0.uniqueIdentifier == item.id })
            ?? home.serviceGroups.first(where: { $0.name == item.name })
        let group: HMServiceGroup
        if let existing { group = existing } else { group = try await addGroup(item.name, to: home) }
        if group.name != item.name { try await updateName(group, item.name) }
        let desired = Set(item.services)
        for service in group.services where !desired.contains(reference(service)) { try await remove(service, from: group) }
        for ref in desired where !group.services.contains(where: { reference($0) == ref }) {
            if let service = service(ref, in: home) { try await add(service, to: group) }
        }
    }

    static func restore(_ item: BackupScene, to home: HMHome) async throws {
        let existing = home.actionSets.first(where: { $0.uniqueIdentifier == item.id })
            ?? home.actionSets.first(where: { $0.name == item.name })
        let scene: HMActionSet
        if let existing { scene = existing } else { scene = try await addScene(item.name, to: home) }
        if scene.name != item.name { try await updateName(scene, item.name) }
        for action in scene.actions { try await remove(action, from: scene) }
        for action in item.actions {
            guard let characteristic = characteristic(action, in: home) else { continue }
            try await add(HMCharacteristicWriteAction<NSCopying>(characteristic: characteristic, targetValue: action.value.homeKitValue), to: scene)
        }
    }

    static func restore(_ item: BackupAutomation, to home: HMHome) async throws {
        var trigger = home.triggers.first(where: { $0.uniqueIdentifier == item.id }) ?? home.triggers.first(where: { $0.name == item.name })
        if trigger == nil, item.kind == "Timer", let fireDate = item.fireDate {
            let created = HMTimerTrigger(name: item.name, fireDate: fireDate, recurrence: nil)
            try await add(created, to: home); trigger = created
        }
        guard let trigger else { throw RestoreError.automationCannotBeRecreated(item.kind) }
        if trigger.name != item.name { try await updateName(trigger, item.name) }
        if trigger.isEnabled != item.enabled { try await enable(trigger, item.enabled) }
        let desiredScenes = item.sceneIDs.compactMap { id in home.actionSets.first(where: { $0.uniqueIdentifier == id }) }
            + item.sceneNames.compactMap { name in home.actionSets.first(where: { $0.name == name }) }
        let desiredIDs = Set(desiredScenes.map(\.uniqueIdentifier))
        for scene in trigger.actionSets where !desiredIDs.contains(scene.uniqueIdentifier) { try await remove(scene, from: trigger) }
        for scene in desiredScenes where !trigger.actionSets.contains(where: { $0.uniqueIdentifier == scene.uniqueIdentifier }) { try await add(scene, to: trigger) }
    }

    static func differs(_ item: BackupAccessory, from home: HMHome) -> Bool {
        guard let current = home.accessories.first(where: { $0.uniqueIdentifier == item.id }) else { return true }
        return current.name != item.name || current.room?.name != item.roomName
    }
    static func differs(_ item: BackupRoom, from home: HMHome) -> Bool { !allRooms(home).contains { $0.uniqueIdentifier == item.id && $0.name == item.name } }
    static func differs(_ item: BackupGroup, from home: HMHome) -> Bool {
        guard let current = home.serviceGroups.first(where: { $0.uniqueIdentifier == item.id }) else { return true }
        return current.name != item.name || Set(current.services.map(reference)) != Set(item.services)
    }
    static func differs(_ item: BackupScene, from home: HMHome) -> Bool {
        guard let current = home.actionSets.first(where: { $0.uniqueIdentifier == item.id }) else { return true }
        let actions = Set(current.actions.compactMap { action -> BackupSceneAction? in
            guard let action = action as? HMCharacteristicWriteAction<NSCopying>, let service = action.characteristic.service,
                  let accessory = service.accessory, let value = BackupValue(action.targetValue) else { return nil }
            return BackupSceneAction(accessoryID: accessory.uniqueIdentifier, serviceID: service.uniqueIdentifier,
                                     characteristicID: action.characteristic.uniqueIdentifier, value: value)
        })
        return current.name != item.name || actions != Set(item.actions)
    }
    static func differs(_ item: BackupAutomation, from home: HMHome) -> Bool {
        guard let current = home.triggers.first(where: { $0.uniqueIdentifier == item.id }) else { return true }
        return current.name != item.name || current.isEnabled != item.enabled || Set(current.actionSets.map(\.uniqueIdentifier)) != Set(item.sceneIDs)
    }

    private static func backupDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("HomeKitten/Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private static func allRooms(_ home: HMHome) -> [HMRoom] { Array(Dictionary(grouping: home.rooms + [home.roomForEntireHome()], by: \.uniqueIdentifier).values.compactMap(\.first)) }
    private static func characteristicValue(_ type: String, for accessory: HMAccessory) -> String? {
        accessory.services.flatMap(\.characteristics).first { $0.characteristicType == type }?.value as? String
    }
    private static func automationKind(_ trigger: HMTrigger) -> String { trigger is HMTimerTrigger ? "Timer" : trigger is HMEventTrigger ? "Event" : String(describing: type(of: trigger)) }
    private static func room(id: UUID?, name: String?, in home: HMHome) -> HMRoom? { allRooms(home).first { $0.uniqueIdentifier == id } ?? allRooms(home).first { $0.name == name } }
    private static func reference(_ service: HMService) -> BackupServiceReference { BackupServiceReference(accessoryID: service.accessory?.uniqueIdentifier ?? UUID(), serviceID: service.uniqueIdentifier) }
    private static func service(_ ref: BackupServiceReference, in home: HMHome) -> HMService? { home.accessories.first { $0.uniqueIdentifier == ref.accessoryID }?.services.first { $0.uniqueIdentifier == ref.serviceID } }
    private static func characteristic(_ action: BackupSceneAction, in home: HMHome) -> HMCharacteristic? { service(.init(accessoryID: action.accessoryID, serviceID: action.serviceID), in: home)?.characteristics.first { $0.uniqueIdentifier == action.characteristicID } }

    private static func updateName(_ value: HMAccessory, _ name: String) async throws { try await callback { value.updateName(name, completionHandler: $0) } }
    private static func updateName(_ value: HMRoom, _ name: String) async throws { try await callback { value.updateName(name, completionHandler: $0) } }
    private static func updateName(_ value: HMServiceGroup, _ name: String) async throws { try await callback { value.updateName(name, completionHandler: $0) } }
    private static func updateName(_ value: HMActionSet, _ name: String) async throws { try await callback { value.updateName(name, completionHandler: $0) } }
    private static func updateName(_ value: HMTrigger, _ name: String) async throws { try await callback { value.updateName(name, completionHandler: $0) } }
    private static func assign(_ accessory: HMAccessory, to room: HMRoom, in home: HMHome) async throws { try await callback { home.assignAccessory(accessory, to: room, completionHandler: $0) } }
    private static func addRoom(_ name: String, to home: HMHome) async throws -> HMRoom { try await result { home.addRoom(withName: name, completionHandler: $0) } }
    private static func addGroup(_ name: String, to home: HMHome) async throws -> HMServiceGroup { try await result { home.addServiceGroup(withName: name, completionHandler: $0) } }
    private static func addScene(_ name: String, to home: HMHome) async throws -> HMActionSet { try await result { home.addActionSet(withName: name, completionHandler: $0) } }
    private static func add(_ service: HMService, to group: HMServiceGroup) async throws { try await callback { group.addService(service, completionHandler: $0) } }
    private static func remove(_ service: HMService, from group: HMServiceGroup) async throws { try await callback { group.removeService(service, completionHandler: $0) } }
    private static func add(_ action: HMAction, to scene: HMActionSet) async throws { try await callback { scene.addAction(action, completionHandler: $0) } }
    private static func remove(_ action: HMAction, from scene: HMActionSet) async throws { try await callback { scene.removeAction(action, completionHandler: $0) } }
    private static func add(_ trigger: HMTrigger, to home: HMHome) async throws { try await callback { home.addTrigger(trigger, completionHandler: $0) } }
    private static func enable(_ trigger: HMTrigger, _ enabled: Bool) async throws { try await callback { trigger.enable(enabled, completionHandler: $0) } }
    private static func add(_ scene: HMActionSet, to trigger: HMTrigger) async throws { try await callback { trigger.addActionSet(scene, completionHandler: $0) } }
    private static func remove(_ scene: HMActionSet, from trigger: HMTrigger) async throws { try await callback { trigger.removeActionSet(scene, completionHandler: $0) } }

    private static func callback(_ body: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in body { error in error.map { continuation.resume(throwing: $0) } ?? continuation.resume() } }
    }
    private static func result<T: Sendable>(_ body: (@escaping @Sendable (T?, Error?) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in body { value, error in
            if let error { continuation.resume(throwing: error) } else if let value { continuation.resume(returning: value) } else { continuation.resume(throwing: RestoreError.noResult) }
        } }
    }

    enum RestoreError: LocalizedError {
        case accessoryUnavailable, automationCannotBeRecreated(String), noResult
        var errorDescription: String? {
            switch self {
            case .accessoryUnavailable: "The physical accessory is not currently available in this home."
            case .automationCannotBeRecreated(let kind): "HomeKit does not expose enough data to recreate this \(kind.lowercased()) automation. Existing copies can still be restored."
            case .noResult: "HomeKit completed without returning the restored object."
            }
        }
    }
}

struct BackupsWorkspaceView: View {
    let home: HMHome
    @State private var backups: [HomeBackup] = []
    @State private var message = ""
    @State private var showingMessage = false

    var body: some View {
        List(backups) { backup in
            NavigationLink { BackupDetailView(home: home, backup: backup) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "icloud.fill").foregroundStyle(.blue).font(.title2)
                    VStack(alignment: .leading) {
                        Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Text("\(backup.accessories.count) accessories · \(backup.rooms.count) rooms")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay { if backups.isEmpty { ContentUnavailableView("No Backups", systemImage: "icloud") } }
        .navigationTitle("Backups")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Back Up Now", systemImage: "icloud.and.arrow.up") { createBackup() } } }
        .task { reload() }
        .alert("HomeKit Backup", isPresented: $showingMessage) { Button("OK") {} } message: { Text(message) }
    }

    private func createBackup() {
        do { try HomeBackupService.save(HomeBackupService.makeBackup(home: home)); reload(); message = "Backup created." }
        catch { message = error.localizedDescription }
        showingMessage = true
    }
    private func reload() { do { backups = try HomeBackupService.load() } catch { message = error.localizedDescription; showingMessage = true } }
}

private struct BackupDetailView: View {
    let home: HMHome
    let backup: HomeBackup
    @State private var message = ""
    @State private var showingMessage = false

    var body: some View {
        List {
            backupSection("Accessories", items: backup.accessories, name: \.name, differs: { HomeBackupService.differs($0, from: home) }, restore: { try await HomeBackupService.restore($0, to: home) })
            backupSection("Rooms", items: backup.rooms, name: \.name, differs: { HomeBackupService.differs($0, from: home) }, restore: { try await HomeBackupService.restore($0, to: home) })
            backupSection("Scenes", items: backup.scenes, name: \.name, differs: { HomeBackupService.differs($0, from: home) }, restore: { try await HomeBackupService.restore($0, to: home) })
            backupSection("Groups", items: backup.groups, name: \.name, differs: { HomeBackupService.differs($0, from: home) }, restore: { try await HomeBackupService.restore($0, to: home) })
            backupSection("Automations", items: backup.automations, name: \.name, differs: { HomeBackupService.differs($0, from: home) }, restore: { try await HomeBackupService.restore($0, to: home) })
        }
        .navigationTitle(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
        .alert("Restore", isPresented: $showingMessage) { Button("OK") {} } message: { Text(message) }
    }

    @ViewBuilder private func backupSection<T: Identifiable & Sendable>(_ title: String, items: [T], name: KeyPath<T, String>, differs: @MainActor @escaping (T) -> Bool, restore: @MainActor @escaping (T) async throws -> Void) -> some View {
        Section(title) {
            ForEach(items) { item in
                let changed = differs(item)
                HStack {
                    VStack(alignment: .leading) {
                        Text(item[keyPath: name])
                        Label(changed ? "Differs from current home" : "Matches current home", systemImage: changed ? "exclamationmark.arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(changed ? .orange : .green)
                    }
                    Spacer()
                    Button("Restore") { Task { await perform { try await restore(item) } } }.disabled(!changed)
                }
            }
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        do { try await operation(); message = "Restored successfully." } catch { message = error.localizedDescription }
        showingMessage = true
    }
}

// Shared by the app and AgentBridge. Never delete attached scenes implicitly.
@MainActor
enum HomeDeletion {
    static func sceneBlockReason(_ scene: HMActionSet, in home: HMHome) -> String? {
        guard home.actionSets.contains(where: { $0.uniqueIdentifier == scene.uniqueIdentifier }) else {
            return "Scene UUID not found in this Home"
        }
        guard scene.actionSetType == HMActionSetTypeUserDefined else {
            return "HomeKit-owned scenes cannot be deleted here"
        }
        let references = home.triggers.filter { $0.actionSets.contains { $0.uniqueIdentifier == scene.uniqueIdentifier } }
        if !references.isEmpty {
            return "Remove this scene from these automations first (including disabled ones): " + references.map(\.name).sorted().joined(separator: ", ")
        }
        return nil
    }

    static func deleteScene(_ scene: HMActionSet, in home: HMHome) async throws {
        if let reason = sceneBlockReason(scene, in: home) { throw error(reason) }
        try HomeBackupService.saveDeletionBackup(home: home)
        if let reason = sceneBlockReason(scene, in: home) { throw error(reason) }
        try await home.removeActionSet(scene)
        guard !home.actionSets.contains(where: { $0.uniqueIdentifier == scene.uniqueIdentifier }) else {
            throw error("Deletion callback succeeded but the scene is still present; inspect Home before retrying")
        }
    }

    static func deleteAutomation(_ trigger: HMTrigger, in home: HMHome) async throws {
        guard home.triggers.contains(where: { $0.uniqueIdentifier == trigger.uniqueIdentifier }) else {
            throw error("Automation UUID not found in this Home")
        }
        try HomeBackupService.saveDeletionBackup(home: home)
        let sharedSceneIDs = Set(home.actionSets.filter { $0.actionSetType == HMActionSetTypeUserDefined }.map(\.uniqueIdentifier))
        try await home.removeTrigger(trigger)
        guard sharedSceneIDs.isSubset(of: Set(home.actionSets.map(\.uniqueIdentifier))) else {
            throw error("A shared scene disappeared during automation deletion; inspect Home before retrying")
        }
        guard !home.triggers.contains(where: { $0.uniqueIdentifier == trigger.uniqueIdentifier }) else {
            throw error("Deletion callback succeeded but the automation is still present; inspect Home before retrying")
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "HomeKittenDeletion", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
