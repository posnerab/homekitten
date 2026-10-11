import datetime
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
import uuid
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("homekit_agent", pathlib.Path(__file__).parents[1] / "scripts/homekit_agent.py")
agent = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(agent)


class AgentTests(unittest.TestCase):
    def test_inventory_rejects_stale_or_disconnected(self):
        client = agent.Client("device")
        for record in [
            {"active": False, "capturedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()},
            {"active": True, "capturedAt": "2000-01-01T00:00:00Z"},
        ]:
            with patch.object(client, "read", return_value=record), self.assertRaises(RuntimeError):
                client.inventory()

    def test_submission_uses_live_session_and_new_uuid(self):
        client = agent.Client("device")
        captured = []
        def transfer(direction, source, destination):
            captured.append((direction, json.loads(pathlib.Path(source).read_text()), destination))
        with patch.object(client, "inventory", return_value={"sessionID": "live-session", "writesAllowed": True}), patch.object(client, "transfer", side_effect=transfer):
            result = client.submit({"operation": "rename_accessory", "homeID": str(uuid.uuid4()), "objectID": str(uuid.uuid4()), "name": "Test", "sessionID": "forged", "id": "forged"})
        request = captured[0][1]
        self.assertEqual(request["sessionID"], "live-session")
        self.assertEqual(request["id"], result["id"])
        uuid.UUID(request["id"])
        self.assertTrue(captured[0][2].endswith(request["id"] + ".json"))
        self.assertEqual(result["state"], "submitted")

    def test_mcp_inventory_preserves_automation_rules(self):
        record = {"automationRulesVersion": 1, "homes": [{"automations": [{
            "events": [{"kind": "HMSignificantTimeEvent", "offset": {"minute": -18}}],
            "predicate": {"kind": "compound", "operator": "and", "children": []},
            "actionSets": [{"id": "trigger-owned", "actions": [{"kind": "HMShortcutAction", "supported": False}]}],
            "recurrences": [{"weekday": 7}], "endEvents": []}]}]}
        source = io.StringIO(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "home_inventory", "arguments": {}}}) + "\n")
        output = io.StringIO()
        client = agent.Client("device")
        with patch.object(client, "inventory", return_value=record):
            agent.serve(client, source, output)
        response = json.loads(output.getvalue())
        self.assertEqual(json.loads(response["result"]["content"][0]["text"]), record)

    def test_no_approve_operation_exposed(self):
        client = agent.Client("device")
        with self.assertRaises(ValueError):
            client.submit({"operation": "approve"})
        self.assertEqual([t["name"] for t in agent.tool_definitions()], ["home_inventory", "home_change_execute", "home_change_result", "home_read_characteristics", "home_read_result"])

    def test_read_only_session_cannot_send_changes(self):
        client = agent.Client("device")
        with patch.object(client, "inventory", return_value={"sessionID": "read-only", "writesAllowed": False}), patch.object(client, "transfer") as transfer:
            with self.assertRaises(RuntimeError):
                client.submit({"operation": "rename_accessory", "homeID": str(uuid.uuid4()), "name": "Test"})
            transfer.assert_not_called()

    def test_mcp_notifications_do_not_get_responses(self):
        source = io.StringIO('\n'.join([
            json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}),
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}),
            '{malformed',
            json.dumps({"jsonrpc": "2.0", "id": 2, "method": "ping"}),
        ]) + '\n')
        output = io.StringIO()
        agent.serve(agent.Client("device"), source, output)
        responses = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(responses), 3)
        self.assertEqual(responses[0]["id"], 1)
        self.assertIn("error", responses[1])
        self.assertEqual(responses[2]["result"], {})

    def test_local_transport_keeps_session_and_publishes_complete_request(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            (root / "incoming").mkdir()
            (root / "responses").mkdir()
            record = {"active": True, "writesAllowed": True, "sessionID": "local-session",
                      "capturedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}
            (root / "inventory.json").write_text(json.dumps(record))
            client = agent.LocalClient(root)
            with patch.object(agent.subprocess, "run", side_effect=AssertionError("device transfer forbidden")):
                result = client.submit({"operation": "rename_accessory", "homeID": str(uuid.uuid4()), "name": "Test"})
                request = json.loads((root / "incoming" / (result["id"] + ".json")).read_text())
                self.assertEqual(request["sessionID"], "local-session")
                self.assertEqual(list(root.glob("incoming/.request-*")), [])
                response = {"state": "succeeded"}
                (root / "responses" / (result["id"] + ".json")).write_text(json.dumps(response))
                self.assertEqual(client.result(result["id"]), response)
            (root / "inventory.json").write_text(json.dumps(dict(record, writesAllowed=False)))
            with self.assertRaises(RuntimeError):
                client.submit({"operation": "rename_accessory", "homeID": str(uuid.uuid4()), "name": "Test"})

    def test_local_transport_rejects_paths_outside_bridge(self):
        with tempfile.TemporaryDirectory() as temp:
            client = agent.LocalClient(temp)
            for path in ["Documents/AgentBridge/../outside.json", "wrong-prefix/inventory.json"]:
                with self.assertRaises(ValueError):
                    client.transfer("from", path, pathlib.Path(temp) / "output.json")

    def test_room_operations_validate_uuid_and_use_authorized_session(self):
        client = agent.Client("device")
        home, accessory, room = [str(uuid.uuid4()) for _ in range(3)]
        submitted = []
        with patch.object(client, "inventory", return_value={"sessionID": "live", "writesAllowed": True}), patch.object(
                client, "transfer", side_effect=lambda _, source, dest: submitted.append(json.loads(pathlib.Path(source).read_text()))):
            client.submit({"operation": "create_room", "homeID": home, "name": "Wiz"})
            client.submit({"operation": "assign_accessory", "homeID": home, "objectID": accessory, "roomID": room})
            with self.assertRaises(ValueError):
                client.submit({"operation": "assign_accessory", "homeID": home, "objectID": accessory, "roomID": "bad-room"})
        self.assertEqual(len(submitted), 2)
        self.assertEqual(submitted[1]["roomID"], room.upper())
        self.assertEqual(submitted[1]["sessionID"], "live")
        schema = agent.tool_definitions()[1]["inputSchema"]
        self.assertIn("create_room", schema["properties"]["operation"]["enum"])
        self.assertIn("assign_accessory", schema["properties"]["operation"]["enum"])
        self.assertEqual(schema["properties"]["roomID"]["format"], "uuid")

    def event_request(self):
        ids = [str(uuid.uuid4()) for _ in range(4)]
        return {"operation": "create_event_automation", "homeID": ids[0], "name": "Sonos exit", "enabled": True,
                "events": [{"kind": "characteristic", "characteristicID": ids[1], "value": False},
                           {"kind": "characteristic", "characteristicID": ids[2], "value": False}],
                "conditions": {"kind": "all", "children": [
                    {"kind": "characteristic", "characteristicID": ids[1], "value": False},
                    {"kind": "characteristic", "characteristicID": ids[2], "value": False}]}, "sceneIDs": [ids[3]]}

    def test_mcp_event_write_keeps_two_off_events_and_both_off_condition(self):
        request = self.event_request()
        original = json.dumps(request)
        sent = []
        client = agent.Client("device")
        with patch.object(client, "inventory", return_value={"sessionID": "actual", "writesAllowed": True, "automationWritesVersion": 1}), patch.object(
                client, "transfer", side_effect=lambda _, path, dest: sent.append(json.loads(pathlib.Path(path).read_text()))):
            result = agent.dispatch(client, "tools/call", {"name": "home_change_execute", "arguments": request})
        self.assertEqual(json.loads(result["content"][0]["text"])["state"], "submitted")
        self.assertEqual(sent[0]["conditions"]["kind"], "all")
        self.assertEqual([e["value"] for e in sent[0]["events"]], [False, False])
        self.assertEqual([c["value"] for c in sent[0]["conditions"]["children"]], [False, False])
        self.assertEqual(sent[0]["sceneIDs"], request["sceneIDs"])
        self.assertEqual(json.dumps(request), original)

    def test_event_rules_cannot_be_silently_ignored_by_old_app(self):
        client = agent.Client("device")
        with patch.object(client, "inventory", return_value={"sessionID": "old", "writesAllowed": True}), patch.object(client, "transfer") as transfer:
            for request in [self.event_request(), {"operation": "update_automation", "homeID": str(uuid.uuid4()), "conditions": self.event_request()["conditions"]}]:
                with self.assertRaisesRegex(RuntimeError, "does not support event automation"):
                    client.submit(request)
            transfer.assert_not_called()

    def test_event_rules_reject_unsafe_or_malformed_inputs_before_queueing(self):
        import copy
        good = self.event_request()
        variants = []
        for key, value in [("events", []), ("events", good["events"] * 2), ("events", [{"kind": "duration", "durationSeconds": 30}]),
                           ("recurrenceWeekdays", [1, 1]), ("recurrenceWeekdays", [True]), ("conditions", {"kind": "raw", "format": "TRUEPREDICATE"}),
                           ("conditions", {"kind": "not", "children": good["conditions"]["children"]}), ("clearConditions", True)]:
            bad = copy.deepcopy(good); bad[key] = value; variants.append(bad)
        bad = copy.deepcopy(good); bad["events"][0]["characteristicID"] = "bad-id"; variants.append(bad)
        bad = copy.deepcopy(good); bad["conditions"]["children"][0]["comparison"] = "greater_than"; variants.append(bad)
        bad = copy.deepcopy(good); bad["events"][0]["unused"] = True; variants.append(bad)
        client = agent.Client("device")
        with patch.object(client, "transfer") as transfer:
            for request in variants:
                with self.subTest(request=request), self.assertRaises(ValueError):
                    client.submit(request)
            transfer.assert_not_called()

    def test_event_time_presence_end_duration_and_clearing_are_supported(self):
        request = {"operation": "update_automation", "homeID": str(uuid.uuid4()), "events": [
            {"kind": "calendar", "hour": 18, "minute": 0}, {"kind": "significant_time", "significantEvent": "sunset", "offsetMinutes": -18},
            {"kind": "presence", "presenceEvent": "first_entry", "presenceUser": "home_users"}],
            "endEvents": [{"kind": "duration", "durationSeconds": 60}], "clearConditions": True, "recurrenceWeekdays": [], "executeOnce": False}
        agent.validate_automation_rules(request)
        schema = agent.tool_definitions()[1]["inputSchema"]
        self.assertIn("create_event_automation", schema["properties"]["operation"]["enum"])
        self.assertEqual(schema["properties"]["conditions"]["$ref"], "#/$defs/condition")
        self.assertIn("endEvents", schema["properties"])

    def test_live_read_works_read_only_and_uses_separate_queue(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            (root / "reads").mkdir()
            record = {"active": True, "writesAllowed": False, "liveReadsSupported": True,
                      "sessionID": "actual-session", "capturedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}
            (root / "inventory.json").write_text(json.dumps(record))
            client = agent.LocalClient(root)
            home, characteristic = [str(uuid.uuid4()) for _ in range(2)]
            completed = {"state": "completed", "results": [{"state": "read", "value": False, "readAt": "2026-10-11T02:00:00Z"}]}
            with patch.object(client, "read_result", side_effect=[{"state": "executing"}, completed]), patch.object(agent.time, "sleep"):
                result = client.live_read({"homeID": home, "characteristicIDs": [characteristic], "id": "forged", "sessionID": "forged"})
            self.assertEqual(result, completed)
            files = list((root / "reads").glob("*.json"))
            self.assertEqual(len(files), 1)
            request = json.loads(files[0].read_text())
            self.assertEqual(request["sessionID"], "actual-session")
            self.assertEqual(request["homeID"], home.upper())
            self.assertEqual(request["characteristicIDs"], [characteristic.upper()])
            self.assertNotIn("operation", request)
            uuid.UUID(request["id"])

    def test_live_read_validation_and_older_app_do_not_submit(self):
        client = agent.Client("device")
        home, characteristic = [str(uuid.uuid4()) for _ in range(2)]
        with patch.object(client, "inventory", return_value={"liveReadsSupported": False}), patch.object(client, "transfer") as transfer:
            for ids in ([], [characteristic] * 2, [str(uuid.uuid4()) for _ in range(11)], ["bad-uuid"]):
                with self.assertRaises(ValueError):
                    client.live_read({"homeID": home, "characteristicIDs": ids})
            with self.assertRaises(RuntimeError):
                client.live_read({"homeID": home, "characteristicIDs": [characteristic]})
            transfer.assert_not_called()

    def test_live_read_wait_timeout_keeps_request_retrievable(self):
        client = agent.Client("device")
        pending = {"id": str(uuid.uuid4()), "state": "executing"}
        with patch.object(client, "inventory", return_value={"sessionID": "actual-session", "liveReadsSupported": True}), patch.object(client, "transfer"), patch.object(client, "read_result", return_value=pending), patch.object(agent.time, "monotonic", side_effect=[0, 41]):
            result = client.live_read({"homeID": str(uuid.uuid4()), "characteristicIDs": [str(uuid.uuid4())]})
        self.assertEqual(result, pending)

    def test_mcp_live_read_preserves_partial_failure_without_cached_fallback(self):
        client = agent.Client("device")
        result = {"state": "completed", "results": [{"state": "read", "value": True, "readAt": "now"},
                                                     {"state": "failed", "error": "HomeKit read timed out after 3 seconds"}]}
        with patch.object(client, "live_read", return_value=result):
            response = agent.dispatch(client, "tools/call", {"name": "home_read_characteristics", "arguments": {}})
        self.assertEqual(json.loads(response["content"][0]["text"]), result)
        self.assertNotIn("value", result["results"][1])
        with patch.object(client, "read_result", return_value=result) as read_result:
            response = agent.dispatch(client, "tools/call", {"name": "home_read_result", "arguments": {"id": "saved-request"}})
            read_result.assert_called_once_with("saved-request")
            self.assertEqual(json.loads(response["content"][0]["text"]), result)


if __name__ == "__main__":
    unittest.main()
