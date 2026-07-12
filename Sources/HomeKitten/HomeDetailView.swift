import SwiftUI
import UIKit

#if canImport(HomeKit)
@preconcurrency import HomeKit

struct HomeDetailView: View {
    let home: HMHome

    var body: some View {
        List {
            Section("Browse") {
                NavigationLink {
                    RoomsListView(home: home)
                } label: {
                    LabeledContent("Rooms", value: "\(home.rooms.count)")
                }
                NavigationLink {
                    GroupsListView(home: home)
                } label: {
                    LabeledContent("Groups", value: "\(home.serviceGroups.count)")
                }
                NavigationLink {
                    ScenesListView(home: home)
                } label: {
                    LabeledContent("Scenes", value: "\(home.actionSets.count)")
                }
                NavigationLink {
                    AutomationsListView(home: home)
                } label: {
                    LabeledContent("Automations", value: "\(home.triggers.count)")
                }
            }

            Section("Accessories") {
                ForEach(home.accessories, id: \.uniqueIdentifier) { accessory in
                    NavigationLink {
                        AccessoryDetailView(home: home, accessory: accessory)
                    } label: {
                        LabeledContent(accessory.name, value: "\(accessory.services.count) services")
                    }
                }
            }
        }
        .navigationTitle(home.name)
        .homeKittenBackButton()
    }
}

struct RoomsListView: View {
    let home: HMHome
    @State private var query = ""

    var body: some View {
        List(home.rooms.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }, id: \.uniqueIdentifier) { room in
            NavigationLink {
                RoomDetailView(home: home, room: room)
            } label: {
                LabeledContent(room.name, value: "\(room.accessories.count) accessories")
            }
        }
        .navigationTitle("Rooms")
        .searchable(text: $query, prompt: "Search rooms")
        .homeKittenBackButton()
    }
}

struct RoomDetailView: View {
    let home: HMHome
    let room: HMRoom
    @State private var query = ""
    @State private var editedName = ""
    @State private var renameStatus = ""

    var body: some View {
        List {
            Section("Room Name") {
                TextField("Name", text: $editedName)
                Button("Rename Room") { room.updateName(editedName) { renameStatus = $0?.localizedDescription ?? "Renamed" } }
                if !renameStatus.isEmpty { Text(renameStatus).foregroundStyle(.secondary) }
            }
            Section("Accessories") {
                ForEach(room.accessories.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }, id: \.uniqueIdentifier) { accessory in
                    NavigationLink { AccessoryDetailView(home: home, accessory: accessory) } label: {
                        LabeledContent(accessory.name, value: "\(accessory.services.count) services")
                    }
                }
            }
        }
        .navigationTitle(room.name)
        .searchable(text: $query, prompt: "Search accessories")
        .homeKittenBackButton()
        .onAppear { if editedName.isEmpty { editedName = room.name } }
    }
}

struct GroupsListView: View {
    let home: HMHome
    @State private var query = ""
    @State private var showingNewGroup = false

    var body: some View {
        List(home.serviceGroups.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }, id: \.uniqueIdentifier) { group in
            NavigationLink {
                ServiceGroupDetailView(home: home, group: group)
            } label: {
                LabeledContent(group.name, value: "\(group.services.count) services")
            }
        }
        .navigationTitle("Groups")
        .searchable(text: $query, prompt: "Search groups")
        .homeKittenBackButton()
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("New Group", systemImage: "plus") { showingNewGroup = true } } }
        .sheet(isPresented: $showingNewGroup) { NavigationStack { NewGroupView(home: home) } }
    }
}

struct ScenesListView: View {
    let home: HMHome
    @State private var query = ""

    var body: some View {
        List(home.actionSets.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.actionSetType.localizedCaseInsensitiveContains(query) }, id: \.uniqueIdentifier) { scene in
            NavigationLink {
                SceneDetailView(home: home, scene: scene)
            } label: {
                LabeledContent(scene.name, value: "\(scene.actions.count) actions")
            }
        }
        .navigationTitle("Scenes")
        .searchable(text: $query, prompt: "Search scenes")
        .homeKittenBackButton()
    }
}

struct NewGroupView: View {
    let home: HMHome
    @Environment(\.dismiss) private var dismiss
    @State private var name = "New Group"
    @State private var status = ""

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Button("Create Group") {
                home.addServiceGroup(withName: name) { _, error in
                    Task { @MainActor in if let error { status = error.localizedDescription } else { dismiss() } }
                }
            }
            if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            Button("Cancel") { dismiss() }
        }
        .navigationTitle("New Group")
    }
}

struct AddGroupServicesView: View {
    let home: HMHome
    let group: HMServiceGroup
    @Environment(\.dismiss) private var dismiss
    @State private var status = ""

    var body: some View {
        List {
            ForEach(home.accessories, id: \.uniqueIdentifier) { accessory in
                Section(accessory.name) {
                    ForEach(accessory.services.filter { service in !group.services.contains { $0.uniqueIdentifier == service.uniqueIdentifier } }, id: \.uniqueIdentifier) { service in
                        Button {
                            group.addService(service) { error in
                                Task { @MainActor in status = error?.localizedDescription ?? "Added \(service.localizedDescription)" }
                            }
                        } label: {
                            Label(service.localizedDescription, systemImage: "plus.circle")
                        }
                    }
                }
            }
        }
        .navigationTitle("Add Services")
        .safeAreaInset(edge: .bottom) {
            VStack { if !status.isEmpty { Text(status) }; Button("Done") { dismiss() } }.padding()
        }
    }
}

struct AutomationsListView: View {
    let home: HMHome
    @State private var query = ""
    @State private var showingBuilder = false

    var body: some View {
        List(home.triggers.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || String(describing: type(of: $0)).localizedCaseInsensitiveContains(query) }, id: \.uniqueIdentifier) { trigger in
            NavigationLink {
                AutomationDetailView(home: home, trigger: trigger)
            } label: {
                LabeledContent(trigger.name, value: trigger.isEnabled ? "Enabled" : "Disabled")
            }
        }
        .navigationTitle("Automations")
        .searchable(text: $query, prompt: "Search automations")
        .homeKittenBackButton()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Automation", systemImage: "plus") { showingBuilder = true }
            }
        }
        .sheet(isPresented: $showingBuilder) {
            NavigationStack { NewAutomationView(home: home) }
        }
    }
}

struct NewAutomationView: View {
    let home: HMHome
    @Environment(\.dismiss) private var dismiss
    @State private var name = "New Automation"
    @State private var kind = "Time of Day"
    @State private var time = Date().addingTimeInterval(300)
    @State private var offsetMinutes = 0
    @State private var status = ""

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Picker("Trigger", selection: $kind) {
                ForEach(["Time of Day", "Sunrise", "Sunset", "First Person Arrives", "Last Person Leaves"], id: \.self) { Text($0) }
            }
            if kind == "Time of Day" { DatePicker("Time", selection: $time) }
            if kind == "Sunrise" || kind == "Sunset" {
                Stepper("Offset: \(offsetMinutes) minutes", value: $offsetMinutes, in: -720...720)
                Text("Negative is before; positive is after.").font(.caption)
            }
            Button("Create Automation") { create() }
            if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            Button("Cancel") { dismiss() }
        }
        .navigationTitle("New Automation")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private func create() {
        let trigger: HMTrigger
        switch kind {
        case "Time of Day":
            trigger = HMTimerTrigger(name: name, fireDate: time, recurrence: nil)
        case "Sunrise", "Sunset":
            let significant: HMSignificantEvent = kind == "Sunrise" ? .sunrise : .sunset
            let event = HMSignificantTimeEvent(significantEvent: significant, offset: DateComponents(minute: offsetMinutes))
            trigger = HMEventTrigger(name: name, events: [event], predicate: nil)
        default:
            let type: HMPresenceEventType = kind.contains("Leaves") ? .lastExit : .firstEntry
            let event = HMPresenceEvent(presenceEventType: type, presenceUserType: .homeUsers)
            trigger = HMEventTrigger(name: name, events: [event], predicate: nil)
        }
        home.addTrigger(trigger) { error in
            Task { @MainActor in if let error { status = error.localizedDescription } else { dismiss() } }
        }
    }
}

struct AccessoryDetailView: View {
    let home: HMHome
    let accessory: HMAccessory
    @State private var query = ""
    @State private var editedName = ""
    @State private var renameStatus = ""

    var body: some View {
        List {
            Section("Accessory") {
                TextField("Name", text: $editedName)
                Button("Rename Accessory") { accessory.updateName(editedName) { renameStatus = $0?.localizedDescription ?? "Renamed" } }
                if !renameStatus.isEmpty { Text(renameStatus).foregroundStyle(.secondary) }
                LabeledContent("Room", value: accessory.room?.name ?? "None")
                LabeledContent("Manufacturer", value: accessory.manufacturer ?? "Unknown")
                LabeledContent("Model", value: accessory.model ?? "Unknown")
                LabeledContent("Reachable", value: accessory.isReachable ? "Yes" : "No")
            }
            Section("Services") {
                ForEach(accessory.services.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.localizedDescription.localizedCaseInsensitiveContains(query) || serviceSummary($0).localizedCaseInsensitiveContains(query) }, id: \.uniqueIdentifier) { service in
                    NavigationLink {
                        ServiceDetailView(service: service)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(service.localizedDescription)
                            Text(serviceSummary(service))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ForEach(accessory.services.filter(hasWritableCharacteristics), id: \.uniqueIdentifier) { service in
                Section("Control · \(service.localizedDescription)") {
                    ForEach(service.characteristics.filter { $0.properties.contains(HMCharacteristicPropertyWritable) }, id: \.uniqueIdentifier) { characteristic in
                        if characteristic.characteristicType == HMCharacteristicTypeHue {
                            AccessoryColorControl(hueCharacteristic: characteristic)
                        } else {
                            AccessoryQuickControl(characteristic: characteristic)
                        }
                    }
                }
            }
            Section("Used by Scenes") {
                ForEach(home.actionSets.filter { sceneUses($0, accessory: accessory) }, id: \.uniqueIdentifier) { scene in
                    NavigationLink(scene.name) { SceneDetailView(home: home, scene: scene) }
                }
            }
            Section("Used by Automations") {
                ForEach(home.triggers.filter { triggerUses($0, accessory: accessory) }, id: \.uniqueIdentifier) { trigger in
                    NavigationLink(trigger.name) { AutomationDetailView(home: home, trigger: trigger) }
                }
            }
        }
        .navigationTitle(accessory.name)
        .searchable(text: $query, prompt: "Search services")
        .homeKittenBackButton()
        .onAppear { if editedName.isEmpty { editedName = accessory.name } }
    }
}

struct ServiceGroupDetailView: View {
    let home: HMHome
    let group: HMServiceGroup
    @State private var editedName = ""
    @State private var status = ""
    @State private var showingAddServices = false

    var body: some View {
        List {
            Section("Group") {
                TextField("Name", text: $editedName)
                Button("Rename Group") { group.updateName(editedName) { report($0, "Renamed") } }
                Button("Add Constituent Services") { showingAddServices = true }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            }
            Section("Constituent Accessories") {
                ForEach(constituents, id: \.uniqueIdentifier) { accessory in
                    NavigationLink {
                        AccessoryDetailView(home: home, accessory: accessory)
                    } label: {
                        LabeledContent(accessory.name, value: "\(accessory.services.count) services")
                    }
                }
            }
            Section("Grouped Services") {
                ForEach(group.services, id: \.uniqueIdentifier) { service in
                    HStack {
                        NavigationLink { ServiceDetailView(service: service) } label: {
                            VStack(alignment: .leading) {
                                Text(service.localizedDescription)
                                Text("\(service.accessory?.name ?? "Unknown accessory") · \(serviceSummary(service))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button(role: .destructive) { group.removeService(service) { report($0, "Service removed") } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle(group.name)
        .homeKittenBackButton()
        .onAppear { if editedName.isEmpty { editedName = group.name } }
        .sheet(isPresented: $showingAddServices) { NavigationStack { AddGroupServicesView(home: home, group: group) } }
    }

    private var constituents: [HMAccessory] {
        var seen = Set<UUID>()
        return group.services.compactMap(\.accessory).filter { seen.insert($0.uniqueIdentifier).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func report(_ error: Error?, _ success: String) {
        Task { @MainActor in status = error?.localizedDescription ?? success }
    }
}

struct ServiceDetailView: View {
    let service: HMService
    @State private var query = ""
    @State private var editedName = ""
    @State private var renameStatus = ""

    var body: some View {
        List {
            Section("Service") {
                TextField("Name", text: $editedName)
                Button("Rename Service") { service.updateName(editedName) { renameStatus = $0?.localizedDescription ?? "Renamed" } }
                if !renameStatus.isEmpty { Text(renameStatus).foregroundStyle(.secondary) }
                LabeledContent("Accessory", value: service.accessory?.name ?? "Unknown")
                LabeledContent("Type", value: service.serviceType)
                LabeledContent("Primary", value: service.isPrimaryService ? "Yes" : "No")
            }
            Section("Characteristics") {
                ForEach(service.characteristics.filter { characteristic in
                    query.isEmpty || characteristic.localizedDescription.localizedCaseInsensitiveContains(query) || characteristic.characteristicType.localizedCaseInsensitiveContains(query)
                }, id: \.uniqueIdentifier) { characteristic in
                    NavigationLink {
                        CharacteristicDetailView(characteristic: characteristic)
                    } label: {
                        CharacteristicRow(characteristic: characteristic)
                    }
                }
            }
        }
        .navigationTitle(service.localizedDescription)
        .searchable(text: $query, prompt: "Search characteristics")
        .homeKittenBackButton()
        .onAppear { if editedName.isEmpty { editedName = service.name } }
    }
}

private struct CharacteristicRow: View {
    let characteristic: HMCharacteristic
    @State private var displayValue = "—"

    var body: some View {
        LabeledContent(characteristic.localizedDescription, value: displayValue)
            .task { await read() }
    }

    private func read() async {
        guard characteristic.properties.contains(HMCharacteristicPropertyReadable) else {
            displayValue = "Not readable"
            return
        }
        await withCheckedContinuation { continuation in
            characteristic.readValue { _ in
                Task { @MainActor in
                    displayValue = formatted(characteristic.value)
                    continuation.resume()
                }
            }
        }
    }
}

struct CharacteristicDetailView: View {
    let characteristic: HMCharacteristic
    @State private var valueText = ""
    @State private var status = ""
    @State private var isBusy = false

    private var readable: Bool { characteristic.properties.contains(HMCharacteristicPropertyReadable) }
    private var writable: Bool { characteristic.properties.contains(HMCharacteristicPropertyWritable) }

    var body: some View {
        Form {
            Section("Characteristic") {
                LabeledContent("Type", value: characteristic.characteristicType)
                LabeledContent("Readable", value: readable ? "Yes" : "No")
                LabeledContent("Writable", value: writable ? "Yes" : "No")
                LabeledContent("Notifications", value: characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification) ? "Yes" : "No")
                if let metadata = characteristic.metadata {
                    LabeledContent("Format", value: metadata.format ?? "Unknown")
                    if let units = metadata.units { LabeledContent("Units", value: units) }
                    if let minimum = metadata.minimumValue { LabeledContent("Minimum", value: minimum.stringValue) }
                    if let maximum = metadata.maximumValue { LabeledContent("Maximum", value: maximum.stringValue) }
                    if let step = metadata.stepValue { LabeledContent("Step", value: step.stringValue) }
                }
            }
            Section("Value") {
                if characteristic.characteristicType == HMCharacteristicTypeHue {
                    AccessoryColorControl(hueCharacteristic: characteristic)
                } else {
                    CharacteristicValueInput(characteristic: characteristic, valueText: $valueText)
                        .disabled(!writable || isBusy)
                    HStack {
                        Button("Read") { Task { await readValue() } }
                            .disabled(!readable || isBusy)
                        Button("Write") { Task { await writeValue() } }
                            .disabled(!writable || isBusy)
                    }
                }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(characteristic.localizedDescription)
        .task { await readValue() }
        .homeKittenBackButton()
    }

    @MainActor
    private func readValue() async {
        guard readable else { status = "Not readable"; return }
        isBusy = true
        await withCheckedContinuation { continuation in
            characteristic.readValue { error in
                Task { @MainActor in
                    isBusy = false
                    if let error { status = error.localizedDescription }
                    else { valueText = formatted(characteristic.value); status = "Read complete" }
                    continuation.resume()
                }
            }
        }
    }

    @MainActor
    private func writeValue() async {
        guard let value = parsedValue(valueText, format: characteristic.metadata?.format) else {
            status = "Invalid value for this format"
            return
        }
        isBusy = true
        await withCheckedContinuation { continuation in
            characteristic.writeValue(value) { error in
                Task { @MainActor in
                    isBusy = false
                    status = error?.localizedDescription ?? "Write complete"
                    continuation.resume()
                }
            }
        }
    }
}

struct SceneDetailView: View {
    let home: HMHome
    let scene: HMActionSet
    @State private var status = ""
    @State private var showingAddAction = false
    @State private var editedName = ""

    var body: some View {
        List {
            Section("Scene Name") {
                TextField("Name", text: $editedName)
                Button("Rename Scene") {
                    scene.updateName(editedName) { error in Task { @MainActor in status = error?.localizedDescription ?? "Renamed" } }
                }
            }
            Section {
                Button("Run Scene") {
                    home.executeActionSet(scene) { error in
                        Task { @MainActor in status = error?.localizedDescription ?? "Scene executed" }
                    }
                }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
                Button("Add Accessory Action") { showingAddAction = true }
            }
            ForEach(groupedActions) { group in
                Section(group.name) {
                    ForEach(group.characteristics) { characteristicGroup in
                        NavigationLink {
                            SceneCharacteristicGroupEditor(scene: scene, group: characteristicGroup)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: characteristicIcon(characteristicGroup.actions[0].characteristic))
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading) {
                                    Text(characteristicGroup.name)
                                    Text(characteristicGroup.valueSummary)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            Section("Used by Automations") {
                ForEach(home.triggers.filter { $0.actionSets.contains(where: { $0.uniqueIdentifier == scene.uniqueIdentifier }) }, id: \.uniqueIdentifier) { trigger in
                    NavigationLink(trigger.name) { AutomationDetailView(home: home, trigger: trigger) }
                }
            }
        }
        .navigationTitle(scene.name)
        .homeKittenBackButton()
        .sheet(isPresented: $showingAddAction) {
            NavigationStack { AddSceneActionView(home: home, scene: scene) }
        }
        .onAppear { if editedName.isEmpty { editedName = scene.name } }
    }

    private var groupedActions: [SceneLogicalGroup] {
        let actions = scene.actions.compactMap { $0 as? HMCharacteristicWriteAction<NSCopying> }
        return Dictionary(grouping: actions) { action in
            home.serviceGroups.first { group in
                group.services.contains { $0.uniqueIdentifier == action.characteristic.service?.uniqueIdentifier }
            }?.uniqueIdentifier ?? action.characteristic.service?.accessory?.uniqueIdentifier ?? UUID()
        }
            .map { id, actions in
                let serviceGroup = home.serviceGroups.first { $0.uniqueIdentifier == id }
                let name = serviceGroup?.name ?? actions.first?.characteristic.service?.accessory?.name ?? "Unknown Accessory"
                let characteristicGroups = Dictionary(grouping: actions, by: { $0.characteristic.characteristicType })
                    .map { type, values in SceneCharacteristicGroup(id: type, name: values[0].characteristic.localizedDescription, actions: values) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                return SceneLogicalGroup(id: id, name: name, characteristics: characteristicGroups)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct SceneLogicalGroup: Identifiable {
    let id: UUID
    let name: String
    let characteristics: [SceneCharacteristicGroup]
}

struct SceneCharacteristicGroup: Identifiable {
    let id: String
    let name: String
    let actions: [HMCharacteristicWriteAction<NSCopying>]

    var valueSummary: String {
        let values = Set(actions.map { formatted($0.targetValue) })
        return values.count == 1 ? values.first! : "Mixed · \(actions.count) constituents"
    }
}

struct SceneCharacteristicGroupEditor: View {
    let scene: HMActionSet
    let group: SceneCharacteristicGroup
    @State private var bulkValue: String
    @State private var status = ""

    init(scene: HMActionSet, group: SceneCharacteristicGroup) {
        self.scene = scene
        self.group = group
        _bulkValue = State(initialValue: formatted(group.actions.first?.targetValue))
    }

    var body: some View {
        Form {
            Section("Bulk Group Setting") {
                if let characteristic = group.actions.first?.characteristic {
                    if characteristic.characteristicType == HMCharacteristicTypeHue {
                        SceneHueEditor(scene: scene, hueActions: group.actions, status: $status)
                    } else {
                        CharacteristicValueInput(characteristic: characteristic, valueText: $bulkValue)
                        Button("Apply to All Constituents") { applyBulk() }
                    }
                }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            }
            Section("Constituents") {
                ForEach(group.actions, id: \.uniqueIdentifier) { action in
                    NavigationLink {
                        SceneActionEditor(scene: scene, action: action)
                    } label: {
                        HStack {
                            Image(systemName: characteristicIcon(action.characteristic)).frame(width: 24)
                            VStack(alignment: .leading) {
                                Text(action.characteristic.service?.accessory?.name ?? "Unknown Accessory")
                                Text("\(action.characteristic.service?.localizedDescription ?? "Service") → \(formatted(action.targetValue))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(group.name)
        .homeKittenBackButton()
    }

    private func applyBulk() {
        let dispatch = DispatchGroup()
        let errors = SendableErrorBox()
        for action in group.actions {
            guard let value = parsedValue(bulkValue, format: action.characteristic.metadata?.format) as? NSCopying else { continue }
            dispatch.enter()
            action.updateTargetValue(value) { error in errors.record(error); dispatch.leave() }
        }
        dispatch.notify(queue: .main) { status = errors.error?.localizedDescription ?? "Updated \(group.actions.count) constituents" }
    }
}

private struct SceneHueEditor: View {
    let scene: HMActionSet
    let hueActions: [HMCharacteristicWriteAction<NSCopying>]
    @Binding var status: String
    @State private var color: Color
    @State private var hex: String

    init(scene: HMActionSet, hueActions: [HMCharacteristicWriteAction<NSCopying>], status: Binding<String>) {
        self.scene = scene
        self.hueActions = hueActions
        _status = status
        let hue = (hueActions.first?.targetValue as? NSNumber)?.doubleValue ?? 0
        let uiColor = UIColor(hue: hue / 360, saturation: 1, brightness: 1, alpha: 1)
        _color = State(initialValue: Color(uiColor))
        _hex = State(initialValue: uiColor.hexString)
    }

    var body: some View {
        HStack {
            ColorPicker("Color", selection: $color, supportsOpacity: false)
            Circle().fill(color).frame(width: 34, height: 34)
        }
        TextField("Hex color (#RRGGBB)", text: $hex)
            .onSubmit { if let parsed = UIColor(hex: hex) { color = Color(parsed) } }
        Button("Apply Color to All Constituents") { apply() }
    }

    private func apply() {
        let uiColor = UIColor(color)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard uiColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            status = "Unable to convert color"; return
        }
        hex = uiColor.hexString
        let all = scene.actions.compactMap { $0 as? HMCharacteristicWriteAction<NSCopying> }
        let accessoryIDs = Set(hueActions.compactMap { $0.characteristic.service?.accessory?.uniqueIdentifier })
        let related = all.filter { action in
            guard let id = action.characteristic.service?.accessory?.uniqueIdentifier, accessoryIDs.contains(id) else { return false }
            return [HMCharacteristicTypeHue, HMCharacteristicTypeSaturation, HMCharacteristicTypeBrightness].contains(action.characteristic.characteristicType)
        }
        let dispatch = DispatchGroup()
        let errors = SendableErrorBox()
        for action in related {
            let number: NSNumber
            switch action.characteristic.characteristicType {
            case HMCharacteristicTypeHue: number = NSNumber(value: Double(hue * 360))
            case HMCharacteristicTypeSaturation: number = NSNumber(value: Double(saturation * 100))
            default: number = NSNumber(value: Double(brightness * 100))
            }
            dispatch.enter()
            action.updateTargetValue(number) { error in errors.record(error); dispatch.leave() }
        }
        dispatch.notify(queue: .main) { status = errors.error?.localizedDescription ?? "Color updated" }
    }
}

private final class SendableErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    var error: Error? { lock.withLock { stored } }
    func record(_ error: Error?) { lock.withLock { if stored == nil { stored = error } } }
}

struct SceneActionEditor: View {
    let scene: HMActionSet
    let action: HMCharacteristicWriteAction<NSCopying>
    @State private var valueText: String
    @State private var status = ""

    init(scene: HMActionSet, action: HMCharacteristicWriteAction<NSCopying>) {
        self.scene = scene
        self.action = action
        _valueText = State(initialValue: formatted(action.targetValue))
    }

    var body: some View {
        Form {
            Section("Target") {
                LabeledContent("Accessory", value: action.characteristic.service?.accessory?.name ?? "Unknown")
                LabeledContent("Service", value: action.characteristic.service?.localizedDescription ?? "Unknown")
                LabeledContent("Characteristic", value: action.characteristic.localizedDescription)
                CharacteristicValueInput(characteristic: action.characteristic, valueText: $valueText)
                Button("Save Target Value") { save() }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            }
            Section {
                Button("Remove Action", role: .destructive) {
                    scene.removeAction(action) { error in
                        Task { @MainActor in status = error?.localizedDescription ?? "Action removed" }
                    }
                }
            }
        }
        .navigationTitle("Edit Scene Action")
        .homeKittenBackButton()
    }

    private func save() {
        guard let value = parsedValue(valueText, format: action.characteristic.metadata?.format) as? NSCopying else {
            status = "Invalid value"
            return
        }
        action.updateTargetValue(value) { error in
            Task { @MainActor in status = error?.localizedDescription ?? "Target updated" }
        }
    }
}

struct AddSceneActionView: View {
    let home: HMHome
    let scene: HMActionSet
    @Environment(\.dismiss) private var dismiss
    @State private var accessoryID: UUID?
    @State private var serviceID: UUID?
    @State private var characteristicID: UUID?
    @State private var valueText = ""
    @State private var status = ""

    private var selectedServices: [HMService] { accessoryChoices(home: home).first { $0.id == accessoryID }?.services ?? [] }
    private var service: HMService? { selectedServices.first { $0.uniqueIdentifier == serviceID } }
    private var characteristic: HMCharacteristic? { service?.characteristics.first { $0.uniqueIdentifier == characteristicID } }

    var body: some View {
        Form {
            Picker("Accessory", selection: $accessoryID) {
                Text("Select").tag(UUID?.none)
                ForEach(accessoryChoices(home: home)) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Service", selection: $serviceID) {
                Text("Select").tag(UUID?.none)
                ForEach(selectedServices.filter(hasWritableCharacteristics), id: \.uniqueIdentifier) { Text(serviceChoiceName($0)).tag(Optional($0.uniqueIdentifier)) }
            }
            Picker("Characteristic", selection: $characteristicID) {
                Text("Select").tag(UUID?.none)
                ForEach((service?.characteristics ?? []).filter { $0.properties.contains(HMCharacteristicPropertyWritable) }, id: \.uniqueIdentifier) {
                    Text($0.localizedDescription).tag(Optional($0.uniqueIdentifier))
                }
            }
            if let characteristic { CharacteristicValueInput(characteristic: characteristic, valueText: $valueText) }
            Button("Add Action") { add() }
                .disabled(characteristic == nil)
            if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            Button("Cancel") { dismiss() }
        }
        .navigationTitle("Add Scene Action")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .onChange(of: accessoryID) { _, _ in serviceID = nil; characteristicID = nil }
        .onChange(of: serviceID) { _, _ in characteristicID = nil }
    }

    private func add() {
        guard let characteristic,
              let value = parsedValue(valueText, format: characteristic.metadata?.format) as? NSCopying else {
            status = "Select a writable characteristic and enter a valid value"
            return
        }
        let action = HMCharacteristicWriteAction<NSCopying>(characteristic: characteristic, targetValue: value)
        scene.addAction(action) { error in
            Task { @MainActor in
                if let error { status = error.localizedDescription }
                else { dismiss() }
            }
        }
    }
}

struct AutomationDetailView: View {
    let home: HMHome
    let trigger: HMTrigger
    @State private var enabled: Bool
    @State private var status = ""
    @State private var fireDate: Date
    @State private var recurrenceMinutes = ""
    @State private var durationMinutes = ""
    @State private var executeOnce = false
    @State private var showingEventEditor = false
    @State private var showingConditionEditor = false
    @State private var showingScenePicker = false
    @State private var editedName: String

    init(home: HMHome, trigger: HMTrigger) {
        self.home = home
        self.trigger = trigger
        _enabled = State(initialValue: trigger.isEnabled)
        let timer = trigger as? HMTimerTrigger
        _fireDate = State(initialValue: timer?.fireDate ?? Date().addingTimeInterval(300))
        _recurrenceMinutes = State(initialValue: timer?.recurrence?.minute.map(String.init) ?? "")
        let event = trigger as? HMEventTrigger
        _durationMinutes = State(initialValue: event?.endEvents.compactMap { ($0 as? HMDurationEvent)?.duration }.first.map { String(Int($0 / 60)) } ?? "")
        _executeOnce = State(initialValue: event?.executeOnce ?? false)
        _editedName = State(initialValue: trigger.name)
    }

    var body: some View {
        Form {
            Section("Automation") {
                TextField("Name", text: $editedName)
                Button("Rename Automation") { trigger.updateName(editedName) { report($0, success: "Renamed") } }
                LabeledContent("Type", value: String(describing: type(of: trigger)))
                Toggle("Enabled", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        trigger.enable(newValue) { error in
                            Task { @MainActor in
                                if let error { status = error.localizedDescription; enabled = trigger.isEnabled }
                                else { status = newValue ? "Enabled" : "Disabled" }
                            }
                        }
                    }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            }
            Section("Scenes") {
                ForEach(trigger.actionSets, id: \.uniqueIdentifier) { scene in
                    HStack {
                        NavigationLink { SceneDetailView(home: home, scene: scene) } label: {
                            LabeledContent(scene.name, value: "\(scene.actions.count) actions")
                        }
                        Button(role: .destructive) { removeScene(scene) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Scene") { showingScenePicker = true }
            }
            if let timer = trigger as? HMTimerTrigger {
                Section("Schedule") {
                    DatePicker("Fire date", selection: $fireDate)
                    TextField("Repeat every N minutes (blank for once)", text: $recurrenceMinutes)
                    Button("Save Schedule") { saveTimer(timer) }
                }
            }
            if let event = trigger as? HMEventTrigger {
                Section("Trigger Events") {
                    ForEach(Array(event.events.enumerated()), id: \.offset) { _, item in
                        NavigationLink {
                            AutomationEventDetailView(trigger: event, event: item)
                        } label: {
                            Text(eventDescription(item))
                        }
                    }
                    Button("Add Trigger Event") { showingEventEditor = true }
                }
                Section("Conditions") {
                    Text(conditionDescription(event.predicate, home: home))
                    Button(event.predicate == nil ? "Add Condition" : "Edit Condition") { showingConditionEditor = true }
                    if event.predicate != nil {
                        Button("Clear Condition", role: .destructive) {
                            event.updatePredicate(nil) { report($0, success: "Condition cleared") }
                        }
                    }
                }
                Section("Behavior") {
                    Toggle("Execute Once", isOn: $executeOnce)
                        .onChange(of: executeOnce) { _, value in
                            event.updateExecuteOnce(value) { report($0, success: "Execute-once updated") }
                        }
                    TextField("Turn off after N minutes", text: $durationMinutes)
                    Button("Save Turn-Off Duration") { saveDuration(event) }
                }
            }
        }
        .navigationTitle(trigger.name)
        .homeKittenBackButton()
        .sheet(isPresented: $showingEventEditor) {
            NavigationStack { AutomationEventEditor(home: home, trigger: trigger as? HMEventTrigger) }
        }
        .sheet(isPresented: $showingConditionEditor) {
            NavigationStack { AutomationConditionEditor(home: home, trigger: trigger as? HMEventTrigger) }
        }
        .sheet(isPresented: $showingScenePicker) {
            NavigationStack { AutomationScenePicker(home: home, trigger: trigger) }
        }
    }

    private func removeScene(_ scene: HMActionSet) {
        trigger.removeActionSet(scene) { report($0, success: "Scene removed") }
    }

    private func saveTimer(_ timer: HMTimerTrigger) {
        timer.updateFireDate(fireDate) { error in
            if let error { report(error, success: ""); return }
            let recurrence = Int(recurrenceMinutes).map { DateComponents(minute: $0) }
            timer.updateRecurrence(recurrence) { report($0, success: "Schedule updated") }
        }
    }

    private func saveDuration(_ event: HMEventTrigger) {
        let retained = event.endEvents.filter { !($0 is HMDurationEvent) }
        let duration = Double(durationMinutes).map { HMDurationEvent(duration: $0 * 60) }
        event.updateEndEvents(retained + (duration.map { [$0] } ?? [])) { report($0, success: "Turn-off duration updated") }
    }

    private func report(_ error: Error?, success: String) {
        Task { @MainActor in status = error?.localizedDescription ?? success }
    }
}

struct AutomationScenePicker: View {
    let home: HMHome
    let trigger: HMTrigger
    @Environment(\.dismiss) private var dismiss
    @State private var status = ""

    var body: some View {
        List(home.actionSets.filter { scene in !trigger.actionSets.contains { $0.uniqueIdentifier == scene.uniqueIdentifier } }, id: \.uniqueIdentifier) { scene in
            Button(scene.name) {
                trigger.addActionSet(scene) { error in
                    Task { @MainActor in
                        if let error { status = error.localizedDescription } else { dismiss() }
                    }
                }
            }
        }
        .navigationTitle("Add Scene")
        .overlay(alignment: .bottom) { if !status.isEmpty { Text(status).padding() } }
        .safeAreaInset(edge: .bottom) {
            Button("Cancel") { dismiss() }.padding()
        }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

struct AutomationEventEditor: View {
    let home: HMHome
    let trigger: HMEventTrigger?
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "Time of Day"
    @State private var time = Date()
    @State private var offsetMinutes = 0
    @State private var presence = "First Person Arrives"
    @State private var accessoryID: UUID?
    @State private var serviceID: UUID?
    @State private var characteristicID: UUID?
    @State private var valueText = ""
    @State private var status = ""

    private var selectedServices: [HMService] { accessoryChoices(home: home).first { $0.id == accessoryID }?.services ?? [] }
    private var service: HMService? { selectedServices.first { $0.uniqueIdentifier == serviceID } }
    private var characteristic: HMCharacteristic? { service?.characteristics.first { $0.uniqueIdentifier == characteristicID } }

    var body: some View {
        Form {
            Picker("Trigger", selection: $kind) {
                ForEach(["Time of Day", "Sunrise", "Sunset", "Presence", "Accessory State"], id: \.self) { Text($0) }
            }
            if kind == "Time of Day" { DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute) }
            if kind == "Sunrise" || kind == "Sunset" {
                Stepper("Offset: \(offsetMinutes) minutes", value: $offsetMinutes, in: -720...720)
                Text("Use negative minutes for before, positive for after.").font(.caption)
            }
            if kind == "Presence" {
                Picker("Presence", selection: $presence) {
                    ForEach(["First Person Arrives", "Last Person Leaves", "Current User Arrives", "Current User Leaves"], id: \.self) { Text($0) }
                }
            }
            if kind == "Accessory State" {
                characteristicPicker
                if let characteristic { CharacteristicValueInput(characteristic: characteristic, valueText: $valueText) }
            }
            Button("Add Trigger") { addEvent() }
            if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            Button("Cancel") { dismiss() }
        }
        .navigationTitle("Add Trigger Event")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    @ViewBuilder private var characteristicPicker: some View {
        Picker("Accessory", selection: $accessoryID) {
            Text("Select").tag(UUID?.none)
            ForEach(accessoryChoices(home: home)) { Text($0.name).tag(Optional($0.id)) }
        }
        Picker("Service", selection: $serviceID) {
            Text("Select").tag(UUID?.none)
            ForEach(selectedServices.filter(hasWritableCharacteristics), id: \.uniqueIdentifier) { Text(serviceChoiceName($0)).tag(Optional($0.uniqueIdentifier)) }
        }
        Picker("Characteristic", selection: $characteristicID) {
            Text("Select").tag(UUID?.none)
            ForEach((service?.characteristics ?? []).filter { $0.properties.contains(HMCharacteristicPropertyWritable) && $0.properties.contains(HMCharacteristicPropertySupportsEventNotification) }, id: \.uniqueIdentifier) {
                Text($0.localizedDescription).tag(Optional($0.uniqueIdentifier))
            }
        }
    }

    private func addEvent() {
        guard let trigger else { status = "This automation is not event-based"; return }
        let newEvent: HMEvent?
        switch kind {
        case "Time of Day":
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            newEvent = HMCalendarEvent(fire: parts)
        case "Sunrise", "Sunset":
            let significant: HMSignificantEvent = kind == "Sunrise" ? .sunrise : .sunset
            newEvent = HMSignificantTimeEvent(significantEvent: significant, offset: DateComponents(minute: offsetMinutes))
        case "Presence":
            let eventType: HMPresenceEventType = presence.contains("Leaves") ? .lastExit : .firstEntry
            let userType: HMPresenceEventUserType = presence.contains("Current") ? .currentUser : .homeUsers
            newEvent = HMPresenceEvent(presenceEventType: eventType, presenceUserType: userType)
        default:
            guard let characteristic,
                  let value = parsedValue(valueText, format: characteristic.metadata?.format) as? NSCopying else {
                status = "Select a notifying characteristic and valid value"; return
            }
            newEvent = HMCharacteristicEvent<NSCopying>(characteristic: characteristic, triggerValue: value)
        }
        guard let newEvent else { return }
        trigger.updateEvents(trigger.events + [newEvent]) { error in
            Task { @MainActor in if let error { status = error.localizedDescription } else { dismiss() } }
        }
    }
}

struct AutomationConditionEditor: View {
    let home: HMHome
    let trigger: HMEventTrigger?
    @Environment(\.dismiss) private var dismiss
    @State private var accessoryID: UUID?
    @State private var serviceID: UUID?
    @State private var characteristicID: UUID?
    @State private var comparison = "Equals"
    @State private var valueText = ""
    @State private var status = ""

    private var selectedServices: [HMService] { accessoryChoices(home: home).first { $0.id == accessoryID }?.services ?? [] }
    private var service: HMService? { selectedServices.first { $0.uniqueIdentifier == serviceID } }
    private var characteristic: HMCharacteristic? { service?.characteristics.first { $0.uniqueIdentifier == characteristicID } }

    var body: some View {
        Form {
            Picker("Accessory", selection: $accessoryID) {
                Text("Select").tag(UUID?.none)
                ForEach(accessoryChoices(home: home)) { Text($0.name).tag(Optional($0.id)) }
            }
            Picker("Service", selection: $serviceID) {
                Text("Select").tag(UUID?.none)
                ForEach(selectedServices.filter(hasReadableCharacteristics), id: \.uniqueIdentifier) { Text(serviceChoiceName($0)).tag(Optional($0.uniqueIdentifier)) }
            }
            Picker("Characteristic", selection: $characteristicID) {
                Text("Select").tag(UUID?.none)
                ForEach((service?.characteristics ?? []).filter { $0.properties.contains(HMCharacteristicPropertyReadable) }, id: \.uniqueIdentifier) { Text($0.localizedDescription).tag(Optional($0.uniqueIdentifier)) }
            }
            Picker("Comparison", selection: $comparison) {
                ForEach(["Equals", "Not Equal", "Less Than", "Greater Than", "At Most", "At Least"], id: \.self) { Text($0) }
            }
            if let characteristic { CharacteristicValueInput(characteristic: characteristic, valueText: $valueText) }
            Button("Save Condition") { save() }
            if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            Button("Cancel") { dismiss() }
        }
        .navigationTitle("Accessory Condition")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private func save() {
        guard let trigger, let characteristic,
              let value = parsedValue(valueText, format: characteristic.metadata?.format) else {
            status = "Select a characteristic and valid value"; return
        }
        let operators: [String: NSComparisonPredicate.Operator] = [
            "Equals": .equalTo, "Not Equal": .notEqualTo, "Less Than": .lessThan,
            "Greater Than": .greaterThan, "At Most": .lessThanOrEqualTo, "At Least": .greaterThanOrEqualTo
        ]
        let predicate = HMEventTrigger.predicateForEvaluatingTrigger(characteristic, relatedBy: operators[comparison] ?? .equalTo, toValue: value)
        trigger.updatePredicate(predicate) { error in
            Task { @MainActor in if let error { status = error.localizedDescription } else { dismiss() } }
        }
    }
}

struct AutomationEventDetailView: View {
    let trigger: HMEventTrigger
    let event: HMEvent
    @Environment(\.dismiss) private var dismiss
    @State private var time = Date()
    @State private var offsetMinutes = 0
    @State private var significantKind = "Sunrise"
    @State private var presenceKind = "First Person Arrives"
    @State private var valueText = ""
    @State private var status = ""

    var body: some View {
        Form {
            Section("Existing Trigger") {
                Text(eventDescription(event))
                if let calendar = event as? HMCalendarEvent {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    Button("Save Time") {
                        replace(with: HMCalendarEvent(fire: Calendar.current.dateComponents([.hour, .minute], from: time)))
                    }
                    .onAppear {
                        time = Calendar.current.date(from: calendar.fireDateComponents) ?? Date()
                    }
                } else if let significant = event as? HMSignificantTimeEvent {
                    Picker("Event", selection: $significantKind) {
                        Text("Sunrise").tag("Sunrise"); Text("Sunset").tag("Sunset")
                    }
                    Stepper("Offset: \(offsetMinutes) minutes", value: $offsetMinutes, in: -720...720)
                    Button("Save Significant Time") {
                        let type: HMSignificantEvent = significantKind == "Sunrise" ? .sunrise : .sunset
                        replace(with: HMSignificantTimeEvent(significantEvent: type, offset: DateComponents(minute: offsetMinutes)))
                    }
                    .onAppear {
                        significantKind = significant.significantEvent == .sunrise ? "Sunrise" : "Sunset"
                        offsetMinutes = significant.offset?.minute ?? 0
                    }
                } else if event is HMPresenceEvent {
                    Picker("Presence", selection: $presenceKind) {
                        ForEach(["First Person Arrives", "Last Person Leaves", "Current User Arrives", "Current User Leaves"], id: \.self) { Text($0) }
                    }
                    Button("Save Presence Trigger") {
                        let type: HMPresenceEventType = presenceKind.contains("Leaves") ? .lastExit : .firstEntry
                        let users: HMPresenceEventUserType = presenceKind.contains("Current") ? .currentUser : .homeUsers
                        replace(with: HMPresenceEvent(presenceEventType: type, presenceUserType: users))
                    }
                } else if let characteristicEvent = event as? HMCharacteristicEvent<NSCopying> {
                    LabeledContent("Accessory", value: characteristicEvent.characteristic.service?.accessory?.name ?? "Unknown")
                    LabeledContent("Characteristic", value: characteristicEvent.characteristic.localizedDescription)
                    CharacteristicValueInput(characteristic: characteristicEvent.characteristic, valueText: $valueText)
                    Button("Save Trigger Value") {
                        guard let value = parsedValue(valueText, format: characteristicEvent.characteristic.metadata?.format) as? NSCopying else {
                            status = "Invalid value"; return
                        }
                        replace(with: HMCharacteristicEvent<NSCopying>(characteristic: characteristicEvent.characteristic, triggerValue: value))
                    }
                    .onAppear { valueText = formatted(characteristicEvent.triggerValue) }
                }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            }
            Section {
                Button("Remove Trigger Event", role: .destructive) {
                    trigger.updateEvents(trigger.events.filter { $0 !== event }) { finish($0, message: "Trigger removed") }
                }
            }
        }
        .navigationTitle("Edit Trigger")
        .homeKittenBackButton()
    }

    private func replace(with replacement: HMEvent) {
        let events = trigger.events.map { $0 === event ? replacement : $0 }
        trigger.updateEvents(events) { finish($0, message: "Trigger updated") }
    }

    private func finish(_ error: Error?, message: String) {
        Task { @MainActor in
            if let error { status = error.localizedDescription } else { status = message; dismiss() }
        }
    }
}

private struct AccessoryQuickControl: View {
    let characteristic: HMCharacteristic
    @State private var valueText = ""
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(characteristic.localizedDescription).font(.headline)
            CharacteristicValueInput(characteristic: characteristic, valueText: $valueText)
            Button("Apply") { write() }.disabled(busy)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }

    private func write() {
        guard let value = parsedValue(valueText, format: characteristic.metadata?.format) else {
            status = "Invalid value"; return
        }
        busy = true
        characteristic.writeValue(value) { error in
            Task { @MainActor in busy = false; status = error?.localizedDescription ?? "Updated" }
        }
    }
}

struct AccessoryColorControl: View {
    let hueCharacteristic: HMCharacteristic
    var compact = false
    @State private var color = Color.white
    @State private var hex = "#FFFFFF"
    @State private var status = ""
    @State private var loading = true

    var body: some View {
        if compact {
            ColorPicker("Color", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 34, height: 34)
                .task { readColor() }
                .onChange(of: color) { _, _ in if !loading { writeColor() } }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Color").font(.headline)
                    Spacer()
                    ColorPicker("Color spectrum", selection: $color, supportsOpacity: false)
                    Circle().fill(color).frame(width: 38, height: 38)
                }
                TextField("Hex color (#RRGGBB)", text: $hex)
                    .onSubmit {
                        if let parsed = UIColor(hex: hex) { color = Color(parsed); writeColor() }
                        else { status = "Enter a six-digit hex color" }
                    }
                Button("Apply Color") { writeColor() }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            .task { readColor() }
        }
    }

    private var serviceCharacteristics: [HMCharacteristic] {
        hueCharacteristic.service?.characteristics ?? [hueCharacteristic]
    }

    private func characteristic(_ type: String) -> HMCharacteristic? {
        serviceCharacteristics.first { $0.characteristicType == type }
    }

    private func readColor() {
        let hue = characteristic(HMCharacteristicTypeHue)
        let saturation = characteristic(HMCharacteristicTypeSaturation)
        let brightness = characteristic(HMCharacteristicTypeBrightness)
        let values = [hue, saturation, brightness].compactMap { $0 }
        let dispatch = DispatchGroup()
        for item in values where item.properties.contains(HMCharacteristicPropertyReadable) {
            dispatch.enter(); item.readValue { _ in dispatch.leave() }
        }
        dispatch.notify(queue: .main) {
            let h = (hue?.value as? NSNumber)?.doubleValue ?? 0
            let s = (saturation?.value as? NSNumber)?.doubleValue ?? 100
            let b = (brightness?.value as? NSNumber)?.doubleValue ?? 100
            let uiColor = UIColor(hue: h / 360, saturation: s / 100, brightness: b / 100, alpha: 1)
            color = Color(uiColor); hex = uiColor.hexString
            DispatchQueue.main.async { loading = false }
        }
    }

    private func writeColor() {
        let uiColor = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard uiColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { status = "Invalid color"; return }
        hex = uiColor.hexString
        let writes: [(String, NSNumber)] = [
            (HMCharacteristicTypeHue, NSNumber(value: Double(h * 360))),
            (HMCharacteristicTypeSaturation, NSNumber(value: Double(s * 100))),
            (HMCharacteristicTypeBrightness, NSNumber(value: Double(b * 100)))
        ]
        let dispatch = DispatchGroup()
        let errors = SendableErrorBox()
        for (type, value) in writes {
            guard let item = characteristic(type), item.properties.contains(HMCharacteristicPropertyWritable) else { continue }
            dispatch.enter(); item.writeValue(value) { error in errors.record(error); dispatch.leave() }
        }
        dispatch.notify(queue: .main) { status = errors.error?.localizedDescription ?? "Color updated" }
    }
}

private func eventDescription(_ event: HMEvent) -> String {
    if let calendar = event as? HMCalendarEvent { return "Time of day: \(calendar.fireDateComponents.description)" }
    if let significant = event as? HMSignificantTimeEvent {
        let name = significant.significantEvent == .sunrise ? "Sunrise" : "Sunset"
        let offset = significant.offset?.minute ?? 0
        if offset == 0 { return name }
        return "\(abs(offset)) minutes \(offset < 0 ? "before" : "after") \(name.lowercased())"
    }
    if let presence = event as? HMPresenceEvent {
        let action: String
        switch presence.presenceEventType {
        case .everyEntry: action = "A person arrives"
        case .everyExit: action = "A person leaves"
        case .firstEntry: action = "First person arrives"
        case .lastExit: action = "Last person leaves"
        @unknown default: action = "Presence changes"
        }
        let people = presence.presenceUserType == .currentUser ? "current user" : "home members"
        return "\(action) · \(people)"
    }
    if let characteristic = event as? HMCharacteristicEvent<NSCopying> {
        return "\(characteristic.characteristic.service?.accessory?.name ?? "Accessory") · \(characteristic.characteristic.localizedDescription) = \(formatted(characteristic.triggerValue))"
    }
    if let duration = event as? HMDurationEvent { return "Duration: \(Int(duration.duration / 60)) minutes" }
    return String(describing: type(of: event))
}

private func conditionDescription(_ predicate: NSPredicate?, home: HMHome) -> String {
    guard let predicate else { return "No conditions" }
    let raw = predicate.predicateFormat
        .replacingOccurrences(of: "HMSignificantEventSunrise", with: "sunrise")
        .replacingOccurrences(of: "HMSignificantEventSunset", with: "sunset")
        .replacingOccurrences(of: "characteristicValue", with: "value")
        .replacingOccurrences(of: "HMPresenceTypeAnyUserAtHome", with: "anyone is home")
        .replacingOccurrences(of: "HMPresenceTypeAnyUserNotAtHome", with: "nobody is home")
        .replacingOccurrences(of: "HMPresenceTypeCurrentUserAtHome", with: "you are home")
        .replacingOccurrences(of: "HMPresenceTypeCurrentUserNotAtHome", with: "you are away")
        .replacingOccurrences(of: "HMPResenceTypeAnyUserAtHome", with: "anyone is home")
        .replacingOccurrences(of: "HMPResenceTypeAnyUserNotAtHome", with: "nobody is home")
        .replacingOccurrences(of: "HMPresenceEventTypeFirstEntry", with: "first person arrives")
        .replacingOccurrences(of: "HMPresenceEventTypeLastExit", with: "last person leaves")
        .replacingOccurrences(of: "HMPresenceEventUserTypeCurrentUser", with: "you")
        .replacingOccurrences(of: "HMPresenceEventUserTypeHomeUsers", with: "home members")
        .replacingOccurrences(of: "Presence-Event:", with: "Presence:")

    for accessory in home.accessories {
        for service in accessory.services {
            for characteristic in service.characteristics {
                if raw.contains(characteristic.uniqueIdentifier.uuidString) || raw.contains(characteristic.characteristicType) {
                    let comparison = humanComparison(from: raw)
                    return "Only if \(accessory.name) · \(characteristic.localizedDescription) \(comparison)"
                }
            }
        }
    }

    return raw
        .replacingOccurrences(of: "==", with: "is")
        .replacingOccurrences(of: "!=", with: "is not")
        .replacingOccurrences(of: ">=", with: "is at least")
        .replacingOccurrences(of: "<=", with: "is at most")
        .replacingOccurrences(of: " AND ", with: " and ")
        .replacingOccurrences(of: " OR ", with: " or ")
}

private func humanComparison(from text: String) -> String {
    let value = text.split(separator: " ").last.map(String.init) ?? "the selected value"
    if text.contains(">=") { return "is at least \(value)" }
    if text.contains("<=") { return "is at most \(value)" }
    if text.contains("!=") { return "is not \(value)" }
    if text.contains(">") { return "is greater than \(value)" }
    if text.contains("<") { return "is less than \(value)" }
    return "is \(value)"
}

private func hasWritableCharacteristics(_ service: HMService) -> Bool {
    service.characteristics.contains { $0.properties.contains(HMCharacteristicPropertyWritable) }
}

private func hasReadableCharacteristics(_ service: HMService) -> Bool {
    service.characteristics.contains { $0.properties.contains(HMCharacteristicPropertyReadable) }
}

private func homeKitIcon(_ accessory: HMAccessory) -> String {
    let types = Set(accessory.services.map(\.serviceType))
    if types.contains(HMServiceTypeLightbulb) { return "lightbulb.fill" }
    if types.contains(HMServiceTypeOutlet) { return "poweroutlet.type.b.fill" }
    if types.contains(HMServiceTypeSwitch) { return "switch.2" }
    if types.contains(HMServiceTypeThermostat) { return "thermometer.medium" }
    if types.contains(HMServiceTypeFan) { return "fan.fill" }
    if types.contains(HMServiceTypeGarageDoorOpener) { return "door.garage.closed" }
    if types.contains(HMServiceTypeLockMechanism) { return "lock.fill" }
    return "sensor.fill"
}

private func characteristicIcon(_ characteristic: HMCharacteristic) -> String {
    switch characteristic.characteristicType {
    case HMCharacteristicTypePowerState, HMCharacteristicTypeActive: return "power"
    case HMCharacteristicTypeBrightness: return "sun.max.fill"
    case HMCharacteristicTypeHue: return "paintpalette.fill"
    case HMCharacteristicTypeSaturation: return "drop.fill"
    case HMCharacteristicTypeColorTemperature: return "lightbulb.fill"
    case HMCharacteristicTypeTargetTemperature, HMCharacteristicTypeCurrentTemperature: return "thermometer.medium"
    case HMCharacteristicTypeTargetLockMechanismState: return "lock.fill"
    default: return "slider.horizontal.3"
    }
}

private extension UIColor {
    convenience init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}

struct AccessoryChoice: Identifiable {
    let id: UUID
    let name: String
    let services: [HMService]
    let accessory: HMAccessory?
    let group: HMServiceGroup?
}

func accessoryChoices(home: HMHome, room: HMRoom? = nil) -> [AccessoryChoice] {
    let groups = home.serviceGroups.filter { group in
        guard let room else { return true }
        return group.services.contains { $0.accessory?.room?.uniqueIdentifier == room.uniqueIdentifier }
    }
    let groupedIDs = Set(groups.flatMap(\.services).compactMap { $0.accessory?.uniqueIdentifier })
    let accessories = home.accessories.filter { accessory in
        !groupedIDs.contains(accessory.uniqueIdentifier) && (room == nil || accessory.room?.uniqueIdentifier == room?.uniqueIdentifier)
    }
    var choices = groups.map { AccessoryChoice(id: $0.uniqueIdentifier, name: $0.name, services: $0.services, accessory: nil, group: $0) }
    choices += accessories.map { AccessoryChoice(id: $0.uniqueIdentifier, name: $0.name, services: $0.services, accessory: $0, group: nil) }
    return choices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

private func serviceChoiceName(_ service: HMService) -> String {
    let accessory = service.accessory?.name ?? "Unknown"
    return "\(accessory) · \(service.localizedDescription)"
}

private struct CharacteristicValueInput: View {
    let characteristic: HMCharacteristic
    @Binding var valueText: String
    @State private var currentValue = "Reading…"

    private var metadata: HMCharacteristicMetadata? { characteristic.metadata }
    private var format: String? { metadata?.format }
    private var isBoolean: Bool { format == HMCharacteristicMetadataFormatBool }
    private var isNumeric: Bool {
        [HMCharacteristicMetadataFormatInt, HMCharacteristicMetadataFormatFloat,
         HMCharacteristicMetadataFormatUInt8, HMCharacteristicMetadataFormatUInt16,
         HMCharacteristicMetadataFormatUInt32, HMCharacteristicMetadataFormatUInt64].contains(format)
    }
    private var validValues: [NSNumber] { metadata?.validValues ?? [] }
    private var minimum: Double { metadata?.minimumValue?.doubleValue ?? 0 }
    private var maximum: Double { metadata?.maximumValue?.doubleValue ?? 100 }
    private var step: Double { max(metadata?.stepValue?.doubleValue ?? (format == HMCharacteristicMetadataFormatFloat ? 0.1 : 1), 0.0001) }

    var body: some View {
        Group {
            LabeledContent("Current value", value: currentValue)
            if isBoolean {
                Toggle("Target value", isOn: Binding(
                    get: { ["true", "yes", "on", "1"].contains(valueText.lowercased()) },
                    set: { valueText = $0 ? "true" : "false" }
                ))
            } else if !validValues.isEmpty {
                Picker("Target value", selection: $valueText) {
                    ForEach(validValues, id: \.self) { value in
                        Text(categoricalLabel(value.intValue, characteristic: characteristic)).tag(value.stringValue)
                    }
                }
            } else if isNumeric {
                HStack {
                    Button { adjust(-step) } label: { Image(systemName: "minus") }
                    TextField("Value", text: $valueText).multilineTextAlignment(.center)
                    Button { adjust(step) } label: { Image(systemName: "plus") }
                }
                if maximum > minimum && maximum - minimum <= 1_000_000 {
                    Slider(value: numericBinding, in: minimum...maximum, step: step)
                    HStack { Text(formatNumber(minimum)); Spacer(); Text(formatNumber(maximum)) }
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                TextField("Target value", text: $valueText)
            }
        }
        .task(id: characteristic.uniqueIdentifier) { await readCurrentValue() }
    }

    private var numericBinding: Binding<Double> {
        Binding(
            get: { min(max(Double(valueText) ?? minimum, minimum), maximum) },
            set: { valueText = formatNumber($0) }
        )
    }

    private func adjust(_ amount: Double) {
        let updated = min(max((Double(valueText) ?? minimum) + amount, minimum), maximum)
        valueText = formatNumber(updated)
    }

    private func formatNumber(_ value: Double) -> String {
        format == HMCharacteristicMetadataFormatFloat ? String(format: "%g", value) : String(Int(value))
    }

    private func readCurrentValue() async {
        guard characteristic.properties.contains(HMCharacteristicPropertyReadable) else {
            currentValue = "Not readable"
            return
        }
        await withCheckedContinuation { continuation in
            characteristic.readValue { error in
                Task { @MainActor in
                    if let error { currentValue = error.localizedDescription }
                    else {
                        if let number = characteristic.value as? NSNumber, !validValues.isEmpty {
                            currentValue = categoricalLabel(number.intValue, characteristic: characteristic)
                        } else {
                            currentValue = formatted(characteristic.value)
                        }
                        if valueText.isEmpty { valueText = formatted(characteristic.value) }
                    }
                    continuation.resume()
                }
            }
        }
    }
}

private func categoricalLabel(_ value: Int, characteristic: HMCharacteristic) -> String {
    switch characteristic.characteristicType {
    case HMCharacteristicTypePowerState, HMCharacteristicTypeActive:
        return value == 0 ? "Off" : "On"
    case HMCharacteristicTypeTargetHeatingCooling:
        return [0: "Off", 1: "Heat", 2: "Cool", 3: "Auto"][value] ?? "Value \(value)"
    case HMCharacteristicTypeCurrentHeatingCooling:
        return [0: "Off", 1: "Heating", 2: "Cooling"][value] ?? "Value \(value)"
    case HMCharacteristicTypeTargetDoorState:
        return value == 0 ? "Open" : "Closed"
    case HMCharacteristicTypeCurrentDoorState:
        return [0: "Open", 1: "Closed", 2: "Opening", 3: "Closing", 4: "Stopped"][value] ?? "Value \(value)"
    case HMCharacteristicTypeTargetLockMechanismState:
        return value == 0 ? "Unsecured" : "Secured"
    case HMCharacteristicTypeCurrentLockMechanismState:
        return [0: "Unsecured", 1: "Secured", 2: "Jammed", 3: "Unknown"][value] ?? "Value \(value)"
    default:
        return "Value \(value)"
    }
}

private func formatted(_ value: Any?) -> String {
    guard let value else { return "nil" }
    if let data = value as? Data { return data.base64EncodedString() }
    return String(describing: value)
}

private func serviceSummary(_ service: HMService) -> String {
    let names = service.characteristics.map(\.localizedDescription)
    return names.isEmpty ? "No characteristics" : names.joined(separator: " · ")
}

private func sceneUses(_ scene: HMActionSet, accessory: HMAccessory) -> Bool {
    scene.actions.contains { action in
        (action as? HMCharacteristicWriteAction<NSCopying>)?.characteristic.service?.accessory?.uniqueIdentifier == accessory.uniqueIdentifier
    }
}

private func triggerUses(_ trigger: HMTrigger, accessory: HMAccessory) -> Bool {
    if trigger.actionSets.contains(where: { sceneUses($0, accessory: accessory) }) { return true }
    guard let eventTrigger = trigger as? HMEventTrigger else { return false }
    let characteristicEvents = (eventTrigger.events + eventTrigger.endEvents).compactMap { $0 as? HMCharacteristicEvent<NSCopying> }
    return characteristicEvents.contains { $0.characteristic.service?.accessory?.uniqueIdentifier == accessory.uniqueIdentifier }
}

private func parsedValue(_ text: String, format: String?) -> Any? {
    switch format {
    case HMCharacteristicMetadataFormatBool:
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "on", "1": return NSNumber(value: true)
        case "false", "no", "off", "0": return NSNumber(value: false)
        default: return nil
        }
    case HMCharacteristicMetadataFormatInt, HMCharacteristicMetadataFormatUInt8,
         HMCharacteristicMetadataFormatUInt16, HMCharacteristicMetadataFormatUInt32,
         HMCharacteristicMetadataFormatUInt64:
        guard let value = Int64(text) else { return nil }
        return NSNumber(value: value)
    case HMCharacteristicMetadataFormatFloat:
        guard let value = Double(text) else { return nil }
        return NSNumber(value: value)
    case HMCharacteristicMetadataFormatData:
        return Data(base64Encoded: text)
    default:
        return text
    }
}

private struct HomeKittenBackButton: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Go Back", systemImage: "chevron.left")
                    }
                }
            }
    }
}

private extension View {
    func homeKittenBackButton() -> some View {
        modifier(HomeKittenBackButton())
    }
}
#endif
