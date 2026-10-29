"""Exercise the production characteristic resolver with HomeKit-shaped fixtures."""
import pathlib
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "Swift compiler requires macOS")
class ButtonEventAccessTests(unittest.TestCase):
    def test_notification_only_buttons_and_read_guards(self):
        source = (pathlib.Path(__file__).parents[1] / "Sources/HomeKitten/AgentBridge.swift").read_text()
        resolver = source[source.index("    private func readableCharacteristic("):source.index("    private func makeEvents(")]
        fixture = r'''
import Foundation
let HMCharacteristicPropertyReadable = "read"
let HMCharacteristicPropertySupportsEventNotification = "notify"
let HMCharacteristicTypeInputEvent = "input-event"
struct HMCharacteristic {
    let uniqueIdentifier: UUID
    let properties: [String]
    let characteristicType: String
}
struct Service { let characteristics: [HMCharacteristic] }
struct Accessory { let services: [Service] }
struct HMHome { let accessories: [Accessory] }
struct Resolver {
    func failure(_ message: String) -> Error { NSError(domain: message, code: 1) }
    RESOLVER
    func resolve(_ c: HMCharacteristic, readable: Bool = false, notifying: Bool = true,
                 home: HMHome? = nil) throws -> HMCharacteristic {
        try readableCharacteristic(c.uniqueIdentifier,
            in: home ?? HMHome(accessories: [Accessory(services: [Service(characteristics: [c])])]),
            notifying: notifying, allowInputEvent: !readable)
    }
}
let resolver = Resolver()
let button = HMCharacteristic(uniqueIdentifier: UUID(), properties: ["notify"], characteristicType: "input-event")
let resolved = try resolver.resolve(button)
assert(resolved.uniqueIdentifier == button.uniqueIdentifier)
func rejected(_ work: () throws -> Void) {
    do { try work(); fatalError("Invalid characteristic was accepted") } catch {}
}
rejected { _ = try resolver.resolve(button, readable: true) } // conditions/thresholds
rejected { _ = try resolver.resolve(button, notifying: false) }
rejected { _ = try resolver.resolve(button, home: HMHome(accessories: [])) }
rejected { _ = try resolver.resolve(HMCharacteristic(uniqueIdentifier: UUID(), properties: [], characteristicType: "input-event")) }
rejected { _ = try resolver.resolve(HMCharacteristic(uniqueIdentifier: UUID(), properties: ["notify"], characteristicType: "custom")) }
let state = HMCharacteristic(uniqueIdentifier: UUID(), properties: ["read", "notify"], characteristicType: "power")
let resolvedState = try resolver.resolve(state)
assert(resolvedState.uniqueIdentifier == state.uniqueIdentifier)
print("Button event access passed")
'''.replace("    RESOLVER", resolver)
        with tempfile.TemporaryDirectory() as temp:
            main = pathlib.Path(temp) / "main.swift"
            main.write_text(fixture)
            subprocess.run(["swift", str(main)], check=True, capture_output=True, text=True)
