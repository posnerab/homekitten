import SwiftUI
@preconcurrency import HomeKit

struct ReassignToolView: View {
    let home: HMHome
    let sourceName: String
    let sourceID: UUID
    let sourceServices: [HMService]
    @Environment(\.dismiss) private var dismiss
    @State private var targetID: UUID?
    @State private var status = ""
    @State private var isRunning = false
    @State private var showingConfirmation = false

    var body: some View {
        Form {
            Section("Reassign Everywhere") {
                LabeledContent("Replace", value: sourceName)
                Picker("With", selection: $targetID) {
                    Text("Choose replacement").tag(UUID?.none)
                    ForEach(targets) { target in Text(target.name).tag(Optional(target.id)) }
                }
                Text("Compatible services and characteristics are mapped by type. Scene actions, automation events, and group membership will be rewritten.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Review and Reassign", role: .destructive) { showingConfirmation = true }
                    .disabled(target == nil || isRunning)
                if isRunning { ProgressView("Reassigning…") }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            }
            Button("Cancel") { dismiss() }
        }
        .navigationTitle("Reassign")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .confirmationDialog("Replace \(sourceName) everywhere?", isPresented: $showingConfirmation, titleVisibility: .visible) {
            Button("Reassign", role: .destructive) { run() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes HomeKit scenes, automations, and groups. A fresh HomeKit backup is recommended first.")
        }
    }

    private var targets: [ReassignmentTarget] {
        let accessories = home.accessories
            .filter { $0.uniqueIdentifier != sourceID }
            .map { ReassignmentTarget(id: $0.uniqueIdentifier, name: $0.name, services: $0.services, kind: "Accessory") }
        let groups = home.serviceGroups
            .filter { $0.uniqueIdentifier != sourceID }
            .map { ReassignmentTarget(id: $0.uniqueIdentifier, name: $0.name, services: $0.services, kind: "Group") }
        return (accessories + groups).sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.kind < $1.kind : comparison == .orderedAscending
        }
    }

    private var target: ReassignmentTarget? { targets.first { $0.id == targetID } }

    private func run() {
        guard let target else { return }
        isRunning = true; status = ""
        Task {
            do {
                let result = try await HomeKitReassignment.reassign(
                    sourceServices: sourceServices, sourceName: sourceName,
                    targetServices: target.services, targetName: target.name, home: home
                )
                status = result.summary
            } catch { status = error.localizedDescription }
            isRunning = false
        }
    }
}

private struct ReassignmentTarget: Identifiable {
    let id: UUID
    let name: String
    let services: [HMService]
    let kind: String
}

@MainActor
enum HomeKitReassignment {
    struct Result {
        var sceneActions = 0
        var automationEvents = 0
        var groupServices = 0
        var skipped = 0
        var conditionsNeedingReview = 0
        var summary: String {
            var text = "Reassigned \(sceneActions) scene actions, \(automationEvents) automation events, and \(groupServices) grouped services."
            if skipped > 0 { text += " \(skipped) incompatible references were left unchanged." }
            if conditionsNeedingReview > 0 { text += " \(conditionsNeedingReview) automation conditions still reference the source and need manual review." }
            return text
        }
    }

    static func reassign(sourceServices: [HMService], sourceName: String, targetServices: [HMService], targetName: String, home: HMHome) async throws -> Result {
        guard !sourceServices.isEmpty, !targetServices.isEmpty else { throw ReassignError.noServices }
        let mapper = ServiceMapper(source: sourceServices, target: targetServices)
        var result = Result()

        for scene in home.actionSets {
            let actions = scene.actions.compactMap { $0 as? HMCharacteristicWriteAction<NSCopying> }
            for action in actions where mapper.contains(action.characteristic.service) {
                guard let replacement = mapper.characteristic(for: action.characteristic) else { result.skipped += 1; continue }
                let newAction = HMCharacteristicWriteAction<NSCopying>(characteristic: replacement, targetValue: action.targetValue)
                try await add(newAction, to: scene)
                try await remove(action, from: scene)
                result.sceneActions += 1
            }
        }

        for trigger in home.triggers.compactMap({ $0 as? HMEventTrigger }) {
            let start = replacementEvents(trigger.events, mapper: mapper)
            if start.changed > 0 { try await updateEvents(start.events, on: trigger); result.automationEvents += start.changed }
            result.skipped += start.skipped
            let end = replacementEvents(trigger.endEvents, mapper: mapper)
            if end.changed > 0 { try await updateEndEvents(end.events, on: trigger); result.automationEvents += end.changed }
            result.skipped += end.skipped
            if mapper.references(trigger.predicate) { result.conditionsNeedingReview += 1 }
        }

        for group in home.serviceGroups {
            let sourceMembers = group.services.filter { mapper.contains($0) }
            for service in sourceMembers {
                guard let replacement = mapper.service(for: service) else { result.skipped += 1; continue }
                if !group.services.contains(where: { $0.uniqueIdentifier == replacement.uniqueIdentifier }) { try await add(replacement, to: group) }
                try await remove(service, from: group)
                result.groupServices += 1
            }
        }
        return result
    }

    private static func replacementEvents(_ events: [HMEvent], mapper: ServiceMapper) -> (events: [HMEvent], changed: Int, skipped: Int) {
        var changed = 0, skipped = 0
        let updated = events.map { event -> HMEvent in
            if let event = event as? HMCharacteristicEvent<NSCopying>, mapper.contains(event.characteristic.service) {
                guard let characteristic = mapper.characteristic(for: event.characteristic) else { skipped += 1; return event }
                changed += 1
                return HMCharacteristicEvent<NSCopying>(characteristic: characteristic, triggerValue: event.triggerValue)
            }
            if let event = event as? HMCharacteristicThresholdRangeEvent, mapper.contains(event.characteristic.service) {
                guard let characteristic = mapper.characteristic(for: event.characteristic) else { skipped += 1; return event }
                changed += 1
                return HMCharacteristicThresholdRangeEvent(characteristic: characteristic, thresholdRange: event.thresholdRange)
            }
            return event
        }
        return (updated, changed, skipped)
    }

    private static func add(_ action: HMAction, to scene: HMActionSet) async throws { try await callback { scene.addAction(action, completionHandler: $0) } }
    private static func remove(_ action: HMAction, from scene: HMActionSet) async throws { try await callback { scene.removeAction(action, completionHandler: $0) } }
    private static func add(_ service: HMService, to group: HMServiceGroup) async throws { try await callback { group.addService(service, completionHandler: $0) } }
    private static func remove(_ service: HMService, from group: HMServiceGroup) async throws { try await callback { group.removeService(service, completionHandler: $0) } }
    private static func updateEvents(_ events: [HMEvent], on trigger: HMEventTrigger) async throws { try await callback { trigger.updateEvents(events, completionHandler: $0) } }
    private static func updateEndEvents(_ events: [HMEvent], on trigger: HMEventTrigger) async throws { try await callback { trigger.updateEndEvents(events, completionHandler: $0) } }
    private static func callback(_ body: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in body { error in error.map { continuation.resume(throwing: $0) } ?? continuation.resume() } }
    }

    enum ReassignError: LocalizedError {
        case noServices
        var errorDescription: String? { "The source or replacement has no HomeKit services to map." }
    }
}

@MainActor
private struct ServiceMapper {
    let source: [HMService]
    let target: [HMService]
    private let sourceIDs: Set<UUID>

    init(source: [HMService], target: [HMService]) {
        self.source = source.filter { $0.serviceType != HMServiceTypeAccessoryInformation }
        self.target = target.filter { $0.serviceType != HMServiceTypeAccessoryInformation }
        sourceIDs = Set(self.source.map(\.uniqueIdentifier))
    }

    func contains(_ service: HMService?) -> Bool { service.map { sourceIDs.contains($0.uniqueIdentifier) } ?? false }

    func references(_ predicate: NSPredicate?) -> Bool {
        guard let predicate else { return false }
        let raw = predicate.predicateFormat
        return source.flatMap(\.characteristics).contains {
            raw.localizedCaseInsensitiveContains($0.uniqueIdentifier.uuidString)
                || raw.localizedCaseInsensitiveContains($0.characteristicType)
        }
    }

    func service(for service: HMService) -> HMService? {
        let siblings = source.filter { $0.serviceType == service.serviceType }
        let ordinal = siblings.firstIndex { $0.uniqueIdentifier == service.uniqueIdentifier } ?? 0
        let matches = target.filter { $0.serviceType == service.serviceType }
        return matches.indices.contains(ordinal) ? matches[ordinal] : matches.first
    }

    func characteristic(for characteristic: HMCharacteristic) -> HMCharacteristic? {
        guard let oldService = characteristic.service, let newService = service(for: oldService) else { return nil }
        let siblings = oldService.characteristics.filter { $0.characteristicType == characteristic.characteristicType }
        let ordinal = siblings.firstIndex { $0.uniqueIdentifier == characteristic.uniqueIdentifier } ?? 0
        let matches = newService.characteristics.filter { $0.characteristicType == characteristic.characteristicType }
        return matches.indices.contains(ordinal) ? matches[ordinal] : matches.first
    }
}
