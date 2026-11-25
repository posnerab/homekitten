#if targetEnvironment(macCatalyst)
import Foundation
@preconcurrency import HomeKit

/// A local, expiring stream for the single Office Orb. The producer supplies colors only.
@MainActor
final class OrbStream {
    struct Frame: Codable {
        let id: UUID
        let owner: UUID
        let session: UUID
        let expires: Double
        let action: String
        let hsv: [Int]
    }
    private let homeID = "E4307963-3511-500E-B2B3-5443D5376E76"
    private let orbID = "89268581-06C1-5353-B944-263A09957A3C"
    private let guardIDs = ["A6A89246-59CA-5297-AAB8-6129BBE77B87", "791BB7B8-3343-570B-8E78-2A58D36F559D"]
    private let colorTypes = [HMCharacteristicTypeHue, HMCharacteristicTypeSaturation, HMCharacteristicTypeBrightness]
    private var owner: UUID?
    private var lastID: UUID?
    private var original: [Int]?
    private var expected: [Int]?
    private var generation = UUID()
    private(set) var busy = false

    func disconnect() {
        generation = UUID()
        owner = nil
        original = nil
        expected = nil
    }

    private func fail(_ reason: String) -> NSError {
        NSError(domain: "OfficeOrb", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }

    private func value(_ c: HMCharacteristic) async throws -> Int {
        try await c.readValue()
        guard let n = c.value as? NSNumber else { throw fail("HomeKit value unavailable") }
        return n.intValue
    }

    func poll(directory: URL, session: UUID, homes: [HMHome]) {
        let file = directory.appendingPathComponent("orb-frame.json")
        guard !busy, FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file), let frame = try? JSONDecoder().decode(Frame.self, from: data),
              frame.session == session, frame.id != lastID else { return }
        lastID = frame.id
        busy = true
        let current = generation
        Task { @MainActor in
            defer { busy = false }
            do {
                let state = try await apply(frame, homes: homes, directory: directory, generation: current)
                try receipt(state, frame: frame, directory: directory)
            } catch {
                if current == generation { disconnect() }
                try? receipt("Stopped · " + error.localizedDescription, frame: frame, directory: directory)
            }
        }
    }

    private func receipt(_ state: String, frame: Frame, directory: URL) throws {
        let record = ["id": frame.id.uuidString, "owner": frame.owner.uuidString, "state": state]
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("orb-result.json"), options: .atomic)
    }

    private func apply(_ f: Frame, homes: [HMHome], directory: URL, generation current: UUID) async throws -> String {
        func valid() throws {
            let remaining = f.expires - Date().timeIntervalSince1970
            guard current == generation, remaining > 0, remaining <= 45 else { throw fail("Session expired") }
        }
        try valid()
        if f.action == "start" {
            // Start carries no color write. The producer serializes ownership on this Mac.
            owner = f.owner
            original = nil
            expected = nil
            return "Starting"
        }
        guard owner == f.owner, ["frame", "release"].contains(f.action), f.hsv.count == 3,
              (0...360).contains(f.hsv[0]), (0...100).contains(f.hsv[1]), (1...100).contains(f.hsv[2])
        else { throw fail("Session ended") }
        if f.action == "release" && original == nil { disconnect(); return "Released" }
        guard let home = homes.first(where: { $0.uniqueIdentifier.uuidString == homeID }),
              let orb = home.accessories.first(where: { $0.uniqueIdentifier.uuidString == orbID && $0.isReachable }),
              let light = orb.services.first(where: { $0.serviceType == HMServiceTypeLightbulb })
        else { throw fail("Office Orb unavailable") }
        let all = home.accessories.flatMap(\.services).flatMap(\.characteristics)
        let guards = guardIDs.compactMap { id in all.first { $0.uniqueIdentifier.uuidString == id } }
        let colors = colorTypes.compactMap { type in light.characteristics.first { $0.characteristicType == type } }
        guard guards.count == 2, colors.count == 3,
              let power = light.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypePowerState })
        else { throw fail("HomeKit controls unavailable") }

        func permitted() async throws {
            for g in guards { guard try await value(g) == 0 else { throw fail("Shabbos or Yom Tov") } }
            guard try await value(power) == 1 else { throw fail("Orb turned off") }
            try valid()
        }
        if original == nil, try await value(power) == 0 { return "Waiting for Orb to turn on" }
        try await permitted()
        var observed = [Int]()
        for c in colors { observed.append(try await value(c)) }
        if let expected, observed != expected { throw fail("Manual color or brightness change") }
        if original == nil {
            // Save the fresh baseline before this session's first accessory write.
            let baseline = ["owner": f.owner.uuidString, "hsv": observed.map(String.init).joined(separator: ",")]
            try JSONEncoder().encode(baseline).write(to: directory.appendingPathComponent("orb-baseline.json"), options: .atomic)
            original = observed
        }
        let target = f.action == "release" ? original! : f.hsv
        for i in colors.indices where observed[i] != target[i] {
            try await permitted()
            // Re-read each component before replacing it, including during a restore.
            guard try await value(colors[i]) == observed[i] else { throw fail("Manual change") }
            try valid()
            try await colors[i].writeValue(NSNumber(value: target[i]))
            observed[i] = try await value(colors[i])
            guard observed[i] == target[i] else { throw fail("Color readback differed") }
        }
        expected = observed
        if f.action == "release" { disconnect(); return "Released" }
        return "Syncing"
    }
}
#endif
