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
        self.assertEqual([t["name"] for t in agent.tool_definitions()], ["home_inventory", "home_change_execute", "home_change_result"])

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


if __name__ == "__main__":
    unittest.main()
