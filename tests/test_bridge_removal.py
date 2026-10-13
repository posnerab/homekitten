import copy
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / 'scripts'))
import homekit_agent as agent
import homekit_backup as backup


class BridgeRemovalClientTests(unittest.TestCase):
    def setUp(self):
        self.home, self.bridge, self.child, self.other, self.opaque = [str(uuid.uuid4()).upper() for _ in range(5)]
        self.inventory = {'active': True, 'writesAllowed': True, 'sessionID': 'session', 'bridgeRemovalVersion': 1,
                          'homes': [{'id': self.home, 'accessories': [{'id': self.bridge, 'services': []},
                                     {'id': self.child, 'bridgeID': self.bridge, 'services': []},
                                     {'id': self.other, 'services': []}],
                                     'scenes': [{'id': self.opaque, 'actions': []}]}]}
        self.request = {'operation': 'remove_bridge', 'homeID': self.home, 'objectID': self.bridge,
                        'bridgedAccessoryIDs': [self.child], 'auditedOpaqueSceneIDs': [self.opaque]}
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        env = patch.dict(agent.os.environ, {'HOMEKITTEN_BACKUP_DIR': self.temp.name}); env.start(); self.addCleanup(env.stop)

    def test_missing_stale_duplicate_and_unrelated_fields_cannot_transfer(self):
        bad = [dict(self.request, bridgedAccessoryIDs=[]), dict(self.request, bridgedAccessoryIDs=[self.other]),
               dict(self.request, bridgedAccessoryIDs=[self.child, self.child]),
               dict(self.request, auditedOpaqueSceneIDs=[]), dict(self.request, enabled=False)]
        missing = copy.deepcopy(self.request); missing.pop('auditedOpaqueSceneIDs'); bad.append(missing)
        client = agent.Client('device')
        with patch.object(client, 'inventory', return_value=self.inventory), patch.object(client, 'transfer') as transfer:
            for request in bad:
                with self.assertRaises(ValueError): client.submit(request)
            transfer.assert_not_called()

    def test_old_app_and_bridge_fields_on_other_operations_cannot_transfer(self):
        client = agent.Client('device')
        with patch.object(client, 'inventory', return_value=dict(self.inventory, bridgeRemovalVersion=0)), patch.object(client, 'transfer') as transfer:
            with self.assertRaises(RuntimeError): client.submit(self.request)
            transfer.assert_not_called()
        request = dict(self.request, operation='rename_accessory', name='Other')
        with patch.object(client, 'inventory', return_value=self.inventory), patch.object(client, 'transfer') as transfer:
            with self.assertRaises(ValueError): client.submit(request)
            transfer.assert_not_called()

    def test_authorized_exact_scope_has_durable_receipt_and_no_claimed_inverse(self):
        client = agent.Client('device'); sent = []
        def transfer(_, source, destination):
            request = json.loads(pathlib.Path(source).read_text())
            record = backup.BackupStore().load(request['id'])
            self.assertEqual(record['status'], 'submission_indeterminate')
            self.assertEqual(record['inventory'], self.inventory)
            self.assertEqual(record['recoveryScope']['state'], 'manual')
            self.assertIn('pairing', record['recoveryScope']['reason'])
            sent.append(request)
        with patch.object(client, 'inventory', return_value=self.inventory), patch.object(client, 'transfer', side_effect=transfer):
            result = client.submit(self.request)
        self.assertEqual(sent[0]['bridgedAccessoryIDs'], [self.child])
        self.assertEqual(result['recovery']['state'], 'manual')
        schema = next(t for t in agent.tool_definitions() if t['name'] == 'home_change_execute')['inputSchema']
        self.assertIn('remove_bridge', schema['properties']['operation']['enum'])
        self.assertIn('auditedOpaqueSceneIDs', schema['properties'])


@unittest.skipUnless(sys.platform == 'darwin', 'Native Foundation audit needs macOS')
class BridgeRemovalNativeTests(unittest.TestCase):
    def test_nested_native_references_stale_membership_and_opaque_predicates_fail_closed(self):
        fixture = r'''
import Foundation
final class Reference: NSObject {
    let id: UUID
    init(_ id: UUID) { self.id = id }
    override var description: String { "reference without exposed UUID" }
}
let source = Reference(UUID()), unrelated = Reference(UUID())
let ids: Set<UUID> = [source.id]
func matches(_ value: Any) -> Bool { (value as? Reference) === source }
func uses(_ value: NSPredicate) -> Bool { try! BridgeRemovalAudit.predicateUses(value, ids: ids, matches: matches) }
let direct = NSComparisonPredicate(leftExpression: NSExpression(forConstantValue: source), rightExpression: NSExpression(forConstantValue: true), modifier: .direct, type: .equalTo, options: [])
assert(uses(direct))
let function = NSExpression(forFunction: NSExpression(forConstantValue: source), selectorName: "unexecuted:", arguments: [NSExpression(forConstantValue: unrelated)])
let nested = NSComparisonPredicate(leftExpression: function, rightExpression: NSExpression(forConstantValue: true), modifier: .direct, type: .equalTo, options: [])
assert(uses(nested))
let container = NSExpression(forConstantValue: ["nested": NSSet(array: [unrelated, source])])
let inCollection = NSComparisonPredicate(leftExpression: container, rightExpression: NSExpression(forConstantValue: true), modifier: .direct, type: .equalTo, options: [])
assert(uses(inCollection))
let time = NSPredicate(format: "sunset <= now()")
assert(!uses(time))
let combined = NSCompoundPredicate(orPredicateWithSubpredicates: [time, nested])
assert(uses(combined))
var evaluated = false
let opaque = NSPredicate { _, _ in evaluated = true; return true }
do { _ = try BridgeRemovalAudit.predicateUses(opaque, ids: ids, matches: matches); assertionFailure("Opaque predicate must reject") } catch {}
assert(!evaluated)
try BridgeRemovalAudit.validateIDs([source.id], actual: ids, nonempty: true, label: "children")
for supplied in [[], [unrelated.id], [source.id, source.id]] {
    do { try BridgeRemovalAudit.validateIDs(supplied, actual: ids, nonempty: true, label: "children"); assertionFailure("Stale/ambiguous children must reject") } catch {}
}
try BridgeRemovalAudit.validateIDs([], actual: [], nonempty: false, label: "opaque")
print("Bridge removal audit passed")
'''
        source = pathlib.Path(__file__).parents[1] / 'Sources/HomeKitten/BridgeRemovalAudit.swift'
        with tempfile.TemporaryDirectory() as directory:
            temp = pathlib.Path(directory); (temp / 'main.swift').write_text(fixture)
            compiled = subprocess.run(['xcrun', 'swiftc', str(source), str(temp / 'main.swift'), '-o', str(temp / 'check')], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(temp / 'check')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('audit passed', result.stdout)


if __name__ == '__main__': unittest.main()
