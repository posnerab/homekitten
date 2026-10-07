import datetime
import importlib.util
import io
import json
import pathlib
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


if __name__ == "__main__":
    unittest.main()
