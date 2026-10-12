import copy
import json
import pathlib
import sys
import tempfile
import unittest
import uuid
from unittest.mock import Mock, patch

sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / "scripts"))
import homekit_agent as agent
import homekit_backup as backup


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = backup.BackupStore(self.temp.name)
        self.environment = patch.dict(agent.os.environ, {"HOMEKITTEN_BACKUP_DIR": self.temp.name})
        self.environment.start(); self.addCleanup(self.environment.stop)
        self.home, self.accessory, self.scene, self.automation, self.characteristic, self.room = [str(uuid.uuid4()).upper() for _ in range(6)]
        self.inventory = {"active": True, "sessionID": "session", "writesAllowed": True, "automationWritesVersion": 1,
                          "homes": [{"id": self.home, "accessories": [{"id": self.accessory, "name": "Original", "roomID": self.room, "services": [{"characteristics": [{"id": self.characteristic}]}]}],
                                     "rooms": [{"id": self.room, "name": "Room"}], "scenes": [{"id": self.scene, "name": "Scene",
                                     "type": "HMActionSetTypeUserDefined", "actions": [{"kind": "characteristicWrite", "characteristicID": self.characteristic, "value": True}]}],
                                     "automations": [{"id": self.automation, "name": "Automation", "enabled": True, "sceneIDs": [self.scene],
                                     "kind": "HMEventTrigger", "rulesStatus": "publicAPI", "events": [{"kind": "HMCalendarEvent", "fireDateComponents": {"hour": 18, "minute": 0}}],
                                     "endEvents": [], "predicate": None, "recurrences": None, "executeOnce": False}]}]}
        self.saved = self.store.capture(self.inventory)
        self.client = Mock()
        self.client.inventory.return_value = copy.deepcopy(self.inventory)

    def args(self, kind="accessory", object_id=None, **extra):
        return {"identifier": self.saved["id"], "home_id": self.home, "kind": kind,
                "object_id": object_id or self.accessory, **extra}

    def test_integrity_and_private_permissions(self):
        path = self.store.path(self.saved["id"])
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        wrapper = json.loads(path.read_text()); wrapper["record"]["label"] = "tampered"
        path.write_text(json.dumps(wrapper))
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.store.load(self.saved["id"])
        self.assertEqual(self.store.list()[0]["status"], "corrupt")

    def test_backup_failure_prevents_write(self):
        client = agent.Client("device")
        with patch.object(client, "inventory", return_value=self.inventory), patch.object(client, "transfer") as transfer, patch.object(backup.BackupStore, "write", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                client.submit({"operation": "rename_accessory", "homeID": self.home, "objectID": self.accessory, "name": "New"})
            transfer.assert_not_called()

    def test_write_ahead_snapshot_and_uncertain_transfer_receipt(self):
        client = agent.Client("device")
        def transfer(direction, source, destination):
            request = json.loads(pathlib.Path(source).read_text())
            record = self.store.load(request["id"])
            self.assertEqual(record["status"], "submission_indeterminate")
            self.assertEqual(record["inventory"], self.inventory)
            raise RuntimeError("interrupted")
        with patch.object(client, "inventory", return_value=self.inventory), patch.object(client, "transfer", side_effect=transfer) as transfer_mock:
            with self.assertRaises(RuntimeError):
                client.submit({"operation": "rename_accessory", "homeID": self.home, "objectID": self.accessory, "name": "New"})
            self.assertEqual(transfer_mock.call_count, 1)
        self.assertIn("submission_indeterminate", [r["status"] for r in self.store.list()])

    def test_uuid_missing_never_substitutes_matching_name(self):
        self.client.inventory.return_value["homes"][0]["accessories"][0]["id"] = str(uuid.uuid4()).upper()
        with self.assertRaisesRegex(ValueError, "UUID"):
            backup.plan(self.store, self.client, **self.args())
        self.client.submit.assert_not_called()

    def test_scene_unknown_or_empty_actions_block_without_partial_request(self):
        for value in ([], [{"kind": "hidden", "supported": False}]):
            data = copy.deepcopy(self.inventory)
            data["homes"][0]["scenes"][0]["actions"] = value
            saved = self.store.capture(data)
            preview = backup.plan(self.store, self.client, **self.args("scene", self.scene, identifier=saved["id"]))
            self.assertTrue(preview["blocked"]); self.assertEqual(preview["requests"], [])

    def test_rule_restores_guard_and_enabled_after_partial_failure(self):
        now = self.client.inventory.return_value["homes"][0]["automations"][0]
        now["events"][0]["fireDateComponents"]["hour"] = 20; now["enabled"] = False
        preview = backup.plan(self.store, self.client, **self.args("automation", self.automation))
        request = preview["requests"][0]
        self.assertEqual(request["events"], [{"kind": "calendar", "hour": 18, "minute": 0}])
        self.assertTrue(request["enabled"])
        self.assertNotIn("clearConditions", request)  # Original null predicate is already unchanged.

    def test_unsupported_rule_blocks_full_recovery_but_name_is_independent(self):
        data = copy.deepcopy(self.inventory)
        data["homes"][0]["automations"][0]["events"] = [{"kind": "HMCharacteristicThresholdRangeEvent"}]
        saved = self.store.capture(data)
        self.client.inventory.return_value = copy.deepcopy(data)
        self.client.inventory.return_value["homes"][0]["automations"][0]["name"] = "Changed"
        args = self.args("automation", self.automation, identifier=saved["id"])
        self.assertTrue(backup.plan(self.store, self.client, **args)["blocked"])
        preview = backup.plan(self.store, self.client, **args, fields=["name"])
        self.assertFalse(preview["blocked"])
        self.assertEqual(preview["requests"][0]["name"], "Automation")

    def test_stale_plan_or_missing_token_never_applies(self):
        args = self.args()
        token = backup.plan(self.store, self.client, **args)["planToken"]
        self.client.inventory.return_value["homes"][0]["accessories"][0]["name"] = "New"
        for extra in ({}, {"planToken": token}):
            with self.assertRaisesRegex(ValueError, "planToken"):
                backup.restore(self.store, self.client, dict(args, **extra))
        self.client.submit.assert_not_called()

    def test_restore_verifies_readback_and_backs_up_before_mutation(self):
        self.client.inventory.return_value["homes"][0]["accessories"][0]["name"] = "New"
        args = self.args(); args["planToken"] = backup.plan(self.store, self.client, **args)["planToken"]
        def submit(request):
            self.assertIn("restoring", [r["status"] for r in self.store.list()])
            self.client.inventory.return_value["homes"][0]["accessories"][0]["name"] = request["name"]
            return {"id": str(uuid.uuid4()).upper(), "state": "submitted"}
        self.client.submit.side_effect = submit
        self.client.result.return_value = {"state": "completed"}
        result = backup.restore(self.store, self.client, args)
        self.assertEqual(result["state"], "verified"); self.assertFalse(result["physicalBehaviorVerified"])
        self.assertEqual(self.client.submit.call_count, 1)

    def test_failed_recovery_stops_before_second_request(self):
        current = self.client.inventory.return_value["homes"][0]
        current["accessories"][0].update(name="New", roomID=str(uuid.uuid4()).upper())
        args = self.args(); args["planToken"] = backup.plan(self.store, self.client, **args)["planToken"]
        self.client.submit.return_value = {"id": str(uuid.uuid4()).upper(), "state": "submitted"}
        self.client.result.return_value = {"state": "failed"}
        self.assertEqual(backup.restore(self.store, self.client, args)["state"], "failed")
        self.assertEqual(self.client.submit.call_count, 1)

    def test_scalar_recovery_requires_fresh_saved_and_current_read(self):
        args = self.args("characteristic", self.characteristic)
        with self.assertRaisesRegex(ValueError, "fresh pre-change"):
            backup.plan(self.store, self.client, **args)
        record = self.store.load(self.saved["id"])
        record["beforeRead"] = {"results": [{"characteristicID": self.characteristic, "state": "read", "value": False}]}
        self.store.write(record)
        self.client.live_read.return_value = {"results": [{"characteristicID": self.characteristic, "state": "read", "value": True}]}
        preview = backup.plan(self.store, self.client, **args)
        self.assertFalse(preview["requests"][0]["value"])

    def test_characteristic_predicate_preserves_boolean_and_or(self):
        def comparison(key, value):
            return {"kind": "comparison", "modifier": "direct", "optionsRawValue": 0, "operator": "equal",
                    "left": {"keyPath": key}, "right": {"kind": "constant", "value": value}}
        leaf = {"kind": "compound", "operator": "and", "children": [comparison("characteristic", {"kind": "characteristic", "id": self.characteristic}), comparison("characteristicValue", False)]}
        result = backup.predicate({"kind": "compound", "operator": "or", "children": [leaf, leaf]})
        self.assertEqual(result["kind"], "any"); self.assertIs(result["children"][0]["value"], False)
        leaf["children"][1]["optionsRawValue"] = 1
        with self.assertRaises(ValueError): backup.predicate(leaf)

    def test_uncertain_recovery_never_replays_or_attempts_later_request(self):
        current = self.client.inventory.return_value["homes"][0]
        current["accessories"][0].update(name="New", roomID=str(uuid.uuid4()).upper())
        args = self.args(); args["planToken"] = backup.plan(self.store, self.client, **args)["planToken"]
        transaction = str(uuid.uuid4()).upper()
        self.client.submit.return_value = {"id": transaction, "state": "submitted"}
        self.client.result.return_value = {"state": "executing"}
        with patch.object(backup.time, "monotonic", side_effect=[0, 41]):
            result = backup.restore(self.store, self.client, args)
        self.assertEqual(result["state"], "indeterminate")
        self.assertEqual(result["transactions"][0]["id"], transaction)
        self.assertEqual(self.client.submit.call_count, 1)
        self.assertEqual(self.store.load(result["journalID"])["status"], "indeterminate")

    def test_mirror_failure_blocks_submission(self):
        self.store.mirror = pathlib.Path(self.temp.name) / "unavailable-volume" / "backups"
        client = agent.Client("device")
        with patch.object(client, "inventory", return_value=self.inventory), patch.object(client, "transfer") as transfer, patch.object(agent, "BackupStore", return_value=self.store):
            with self.assertRaisesRegex(RuntimeError, "mirror volume"):
                client.submit({"operation": "rename_accessory", "homeID": self.home, "objectID": self.accessory, "name": "New"})
            transfer.assert_not_called()

    def test_mirror_is_independently_checksum_verified(self):
        self.store.mirror = pathlib.Path(self.temp.name) / "mirror"
        record = self.store.load(self.saved["id"]); self.store.write(record)
        self.assertTrue(self.store.summary(record)["mirrorChecksumVerified"])
        path = self.store.mirror / (record["id"] + ".json")
        path.write_text("corrupt")
        self.assertFalse(self.store.summary(record)["mirrorChecksumVerified"])

    def test_invalid_fields_cannot_be_reported_as_verified_noop(self):
        for fields in ([], ["enabled"], ["typo"]):
            with self.assertRaises(ValueError): backup.plan(self.store, self.client, **self.args(fields=fields))


if __name__ == "__main__": unittest.main()
