import SwiftUI

#if canImport(HomeKit)
import HomeKit

private enum HomeSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case scenes = "Scenes"
    case groups = "Groups"
    case automations = "Automations"
    var id: Self { self }
}

struct ContentView: View {
    @Environment(HomeStore.self) private var store
    @State private var selectedHomeID: UUID?
    @State private var selectedRoomID: UUID?
    @State private var section: HomeSection = .home
    @State private var showingNewScene = false
    @State private var showingNewAutomation = false
    @State private var syncMessage = ""
    @State private var showingSyncResult = false
    @State private var attemptedAutomaticSync = false

    private var selectedHome: HMHome? {
        store.homes.first { $0.uniqueIdentifier == selectedHomeID }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
        } detail: {
            NavigationStack {
                detail
                    .toolbar { sectionToolbar }
            }
        }
        .onChange(of: store.homes.map(\.uniqueIdentifier), initial: true) { _, _ in
            selectDefaultHomeIfNeeded()
        }
        .onChange(of: selectedHomeID) { _, _ in
            selectedRoomID = nil
            section = .home
            guard !attemptedAutomaticSync, let home = selectedHome else { return }
            attemptedAutomaticSync = true
            Task {
                do { syncMessage = try await WizNameSync.sync(home: home) }
                catch { syncMessage = error.localizedDescription }
                showingSyncResult = true
            }
        }
        .sheet(isPresented: $showingNewScene) {
            if let home = selectedHome { NavigationStack { NewSceneView(home: home) } }
        }
        .sheet(isPresented: $showingNewAutomation) {
            if let home = selectedHome { NavigationStack { NewAutomationView(home: home) } }
        }
        .alert("WiZ Name Sync", isPresented: $showingSyncResult) { Button("OK") {} } message: { Text(syncMessage) }
    }

    private var sidebar: some View {
        Group {
            if let home = selectedHome {
                List(selection: $selectedRoomID) {
                    Section("Rooms") {
                        ForEach(home.rooms, id: \.uniqueIdentifier) { room in
                            Button {
                                selectedRoomID = room.uniqueIdentifier
                            } label: {
                                HStack {
                                    Label(room.name, systemImage: "door.left.hand.open")
                                    Spacer()
                                    Text("\(room.accessories.count)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .tag(Optional(room.uniqueIdentifier))
                        }
                    }
                }
                .navigationTitle(home.name)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        homeMenu
                    }
                }
            } else if store.isReady {
                ContentUnavailableView("No Homes", systemImage: "house")
            } else {
                ProgressView("Loading homes…")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let home = selectedHome {
            if let room = home.rooms.first(where: { $0.uniqueIdentifier == selectedRoomID }) {
                RoomWorkspaceView(home: home, room: room)
            } else {
                switch section {
                case .home: HomeWorkspaceView(home: home)
                case .scenes: ScenesListView(home: home)
                case .groups: GroupsListView(home: home)
                case .automations: AutomationsListView(home: home)
                }
            }
        } else {
            ContentUnavailableView("Select a Home", systemImage: "house")
        }
    }

    private var homeMenu: some View {
        Menu {
            ForEach(store.homes, id: \.uniqueIdentifier) { home in
                Button {
                    selectedHomeID = home.uniqueIdentifier
                } label: {
                    if selectedHomeID == home.uniqueIdentifier {
                        Label(home.name, systemImage: "checkmark")
                    } else {
                        Text(home.name)
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.circle.fill")
                .font(.title2)
                .accessibilityLabel("Choose Home")
        }
        .menuStyle(.borderlessButton)
    }

    @ToolbarContentBuilder private var sectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("New Scene", systemImage: "sparkles") { showingNewScene = true }
                Button("New Automation", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") { showingNewAutomation = true }
                Divider()
                Button("Sync WiZ Names to Homebridge", systemImage: "arrow.triangle.2.circlepath") {
                    guard let home = selectedHome else { return }
                    Task {
                        do { syncMessage = try await WizNameSync.sync(home: home) }
                        catch { syncMessage = error.localizedDescription }
                        showingSyncResult = true
                    }
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .accessibilityLabel("Create")
            }
            .disabled(selectedHome == nil)
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 4) {
                ForEach(HomeSection.allCases) { item in
                    Button(item.rawValue) {
                        selectedRoomID = nil
                        section = item
                    }
                    .buttonStyle(.bordered)
                    .tint(section == item && selectedRoomID == nil ? .accentColor : .secondary)
                }
            }
            .padding(4)
            .background(.regularMaterial, in: Capsule())
        }
    }

    private func selectDefaultHomeIfNeeded() {
        guard !store.homes.isEmpty else { selectedHomeID = nil; return }
        if let selectedHomeID, store.homes.contains(where: { $0.uniqueIdentifier == selectedHomeID }) { return }
        selectedHomeID = store.homes.first(where: \.isPrimary)?.uniqueIdentifier ?? store.homes.first?.uniqueIdentifier
    }
}

private enum WizNameSync {
    private static let endpoint = URL(string: "http://192.168.1.162:51828/names")!
    private static let token = "f538fc65f3c273c9db64774b77f5b66e4db924b9a0f92b55"

    static func sync(home: HMHome) async throws -> String {
        var names: [String: String] = [:]
        for accessory in home.accessories {
            let vendor = "\(accessory.manufacturer ?? "") \(accessory.model ?? "")".lowercased()
            guard vendor.contains("wiz") else { continue }
            guard let serialCharacteristic = accessory.services.flatMap(\.characteristics).first(where: { $0.characteristicType == HMCharacteristicTypeSerialNumber }) else { continue }
            let serial = try await read(serialCharacteristic)
            let mac = serial.components(separatedBy: CharacterSet.alphanumerics.inverted).joined().lowercased()
            guard mac.count == 12 else { continue }
            let existing = names[mac]
            if existing == nil || isGeneric(existing!) { names[mac] = accessory.name }
        }
        guard !names.isEmpty else { throw SyncError.noDevices }
        let devices = names.sorted(by: { $0.key < $1.key }).map { ["mac": $0.key, "name": $0.value] }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["devices": devices])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SyncError.server(String(data: data, encoding: .utf8) ?? "Homebridge rejected the sync")
        }
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return "Persisted \(result?["updated"] as? Int ?? devices.count) accessory names on Homebridge."
    }

    private static func read(_ characteristic: HMCharacteristic) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            characteristic.readValue { error in
                if let error { continuation.resume(throwing: error) }
                else if let value = characteristic.value as? String { continuation.resume(returning: value) }
                else { continuation.resume(throwing: SyncError.invalidSerial) }
            }
        }
    }

    private static func isGeneric(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("Wiz RGB Bulb") || name.localizedCaseInsensitiveContains("Wiz Light Pole")
    }

    private enum SyncError: LocalizedError {
        case noDevices, invalidSerial, server(String)
        var errorDescription: String? {
            switch self {
            case .noDevices: "No WiZ serial numbers were available from HomeKit."
            case .invalidSerial: "A WiZ accessory returned an invalid serial number."
            case .server(let message): message
            }
        }
    }
}

struct NewSceneView: View {
    let home: HMHome
    @Environment(\.dismiss) private var dismiss
    @State private var name = "New Scene"
    @State private var status = ""

    var body: some View {
        Form {
            Section("Scene") {
                TextField("Name", text: $name)
                Button("Create Scene") { create() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            }
            Button("Cancel") { dismiss() }
        }
        .navigationTitle("New Scene")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }

    private func create() {
        home.addActionSet(withName: name.trimmingCharacters(in: .whitespacesAndNewlines)) { _, error in
            Task { @MainActor in
                if let error { status = error.localizedDescription }
                else { dismiss() }
            }
        }
    }
}

private struct HomeWorkspaceView: View {
    let home: HMHome
    @State private var query = ""

    var body: some View {
        List {
            ForEach(roomGroups, id: \.name) { room in
                Section(room.name) {
                    ForEach(room.items) { item in
                        switch item {
                        case .accessory(let accessory):
                            NavigationLink {
                                AccessoryDetailView(home: home, accessory: accessory)
                            } label: {
                                HomeAccessoryControl(accessory: accessory)
                            }
                        case .group(let group):
                            NavigationLink {
                                ServiceGroupDetailView(home: home, group: group)
                            } label: {
                                HomeGroupControl(group: group)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(home.name)
        .searchable(text: $query, prompt: "Search accessories")
    }

    private var roomGroups: [(name: String, items: [HomeItem])] {
        let rooms = Set(home.accessories.map { $0.room?.name ?? "No Room" })
        return rooms.compactMap { roomName in
            let roomAccessories = home.accessories.filter { ($0.room?.name ?? "No Room") == roomName }
            let groups = home.serviceGroups.filter { group in
                let roomNames = Set(group.services.compactMap { $0.accessory?.room?.name ?? "No Room" })
                return roomNames.sorted().first == roomName
            }
            let groupedIDs = Set(groups.flatMap(\.services).compactMap { $0.accessory?.uniqueIdentifier })
            var items = groups.map(HomeItem.group)
            items += roomAccessories.filter { !groupedIDs.contains($0.uniqueIdentifier) }.map(HomeItem.accessory)
            items = items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || roomName.localizedCaseInsensitiveContains(query) }
            items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return items.isEmpty ? nil : (roomName, items)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private enum HomeItem: Identifiable {
    case accessory(HMAccessory)
    case group(HMServiceGroup)

    var id: UUID {
        switch self { case .accessory(let value): value.uniqueIdentifier; case .group(let value): value.uniqueIdentifier }
    }
    var name: String {
        switch self { case .accessory(let value): value.name; case .group(let value): value.name }
    }
}

private struct HomeAccessoryControl: View {
    let accessory: HMAccessory

    var body: some View {
        HStack(spacing: 12) {
            HomePowerButton(characteristics: powerCharacteristics, icon: accessoryIcon(accessory))
            VStack(alignment: .leading) {
                Text(accessory.name)
                Text(accessory.services.map(\.localizedDescription).joined(separator: " · "))
                    .lineLimit(1).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let hueCharacteristic {
                AccessoryColorControl(hueCharacteristic: hueCharacteristic, compact: true)
            }
        }
    }

    private var powerCharacteristics: [HMCharacteristic] {
        accessory.services.flatMap(\.characteristics).filter(isPowerCharacteristic)
    }

    private var hueCharacteristic: HMCharacteristic? {
        accessory.services.flatMap(\.characteristics).first { $0.characteristicType == HMCharacteristicTypeHue }
    }
}

private struct HomeGroupControl: View {
    let group: HMServiceGroup

    var body: some View {
        HStack(spacing: 12) {
            HomePowerButton(characteristics: powerCharacteristics, icon: "square.stack.3d.up.fill")
            VStack(alignment: .leading) {
                Text(group.name)
                Text("Group · \(Set(group.services.compactMap { $0.accessory?.uniqueIdentifier }).count) accessories")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var powerCharacteristics: [HMCharacteristic] {
        group.services.flatMap(\.characteristics).filter(isPowerCharacteristic)
    }
}

private struct HomePowerButton: View {
    let characteristics: [HMCharacteristic]
    let icon: String
    @State private var isOn = false
    @State private var isBusy = false

    var body: some View {
        Button { toggle() } label: {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 38, height: 38)
                .foregroundStyle(isOn ? .black : .secondary)
                .background(isOn ? Color.yellow : Color.secondary.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(writable.isEmpty || isBusy)
        .task { read() }
        .accessibilityLabel(isOn ? "Turn off" : "Turn on")
    }

    private var writable: [HMCharacteristic] {
        characteristics.filter { $0.properties.contains(HMCharacteristicPropertyWritable) }
    }

    private func read() {
        let readable = characteristics.filter { $0.properties.contains(HMCharacteristicPropertyReadable) }
        guard !readable.isEmpty else { return }
        var foundOn = false
        let group = DispatchGroup()
        for characteristic in readable {
            group.enter()
            characteristic.readValue { _ in
                if (characteristic.value as? NSNumber)?.boolValue == true { foundOn = true }
                group.leave()
            }
        }
        group.notify(queue: .main) { isOn = foundOn }
    }

    private func toggle() {
        let target = !isOn
        isBusy = true
        let group = DispatchGroup()
        for characteristic in writable {
            group.enter()
            characteristic.writeValue(NSNumber(value: target)) { _ in group.leave() }
        }
        group.notify(queue: .main) { isOn = target; isBusy = false }
    }
}

private func isPowerCharacteristic(_ characteristic: HMCharacteristic) -> Bool {
    characteristic.characteristicType == HMCharacteristicTypePowerState || characteristic.characteristicType == HMCharacteristicTypeActive
}

private func accessoryIcon(_ accessory: HMAccessory) -> String {
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

private struct RoomWorkspaceView: View {
    let home: HMHome
    let room: HMRoom
    @State private var query = ""

    var body: some View {
        List(accessoryChoices(home: home, room: room).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { item in
            if let group = item.group {
                NavigationLink {
                    ServiceGroupDetailView(home: home, group: group)
                } label: {
                    LabeledContent(item.name, value: "Group")
                }
            } else if let accessory = item.accessory {
                NavigationLink {
                    AccessoryDetailView(home: home, accessory: accessory)
                } label: {
                    LabeledContent(item.name, value: "\(accessory.services.count) services")
                }
            }
        }
        .navigationTitle(room.name)
        .searchable(text: $query, prompt: "Search this room")
    }
}

#else
struct ContentView: View {
    var body: some View {
        ContentUnavailableView("HomeKit Unavailable", systemImage: "house.slash")
    }
}
#endif
