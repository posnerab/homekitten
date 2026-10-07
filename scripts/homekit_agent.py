#!/usr/bin/env python3
"""HomeKitten paired-device and local Mac client. No dependencies, network service, or secrets.

CLI: (--device UDID | --local-bridge DIR) inventory | submit request.json | result UUID | mcp
MCP uses newline-delimited JSON-RPC on stdin/stdout. Device diagnostics never
appear on protocol stdout. The app grants write access for its remembered connection.
"""
import argparse
import datetime
import json
import os
import shutil
import pathlib
import subprocess
import sys
import tempfile
import uuid

BUNDLE = "abie.ios.homekitten"
OPERATIONS = ["rename_accessory", "set_characteristic", "create_scene", "update_scene",
              "rename_scene", "run_scene", "create_timer", "update_automation", "create_room", "assign_accessory"]


class Client:
    def __init__(self, device):
        self.device = device

    def transfer(self, direction, source, destination):
        command = ["xcrun", "devicectl", "device", "copy", direction, "--quiet",
                   "--device", self.device, "--domain-type", "appDataContainer",
                   "--domain-identifier", BUNDLE, "--source", str(source),
                   "--destination", str(destination)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise RuntimeError("Device file transfer failed. Keep the paired phone unlocked and HomeKitten's Agent Access screen open.")

    def read(self, relative):
        with tempfile.TemporaryDirectory(prefix="homekitten-agent-") as temp:
            output = pathlib.Path(temp) / "response.json"
            self.transfer("from", "Documents/AgentBridge/" + relative, output)
            return json.loads(output.read_text())

    def inventory(self):
        result = self.read("inventory.json")
        captured = datetime.datetime.fromisoformat(result["capturedAt"].replace("Z", "+00:00"))
        age = (datetime.datetime.now(datetime.timezone.utc) - captured).total_seconds()
        if not result.get("active") or age > 15 or age < -5:
            raise RuntimeError("Bridge is disconnected or inventory is stale. Connect on HomeKitten's Agent Access screen.")
        return result

    def submit(self, arguments):
        if arguments.get("operation") not in OPERATIONS:
            raise ValueError("Unsupported operation")
        request = dict(arguments)
        for key in ("id", "sessionID"):
            request.pop(key, None)
        request["homeID"] = str(uuid.UUID(request["homeID"])).upper()
        for key in ("objectID", "roomID"):
            if request.get(key):
                request[key] = str(uuid.UUID(request[key])).upper()
        request["id"] = str(uuid.uuid4()).upper()
        inventory = self.inventory()
        if not inventory.get("writesAllowed"):
            raise RuntimeError("Read-only session. Reconnect in HomeKitten with changes allowed.")
        request["sessionID"] = inventory["sessionID"]
        encoded = json.dumps(request, allow_nan=False).encode()
        if len(encoded) > 65536:
            raise ValueError("Request too large")
        with tempfile.TemporaryDirectory(prefix="homekitten-agent-") as temp:
            incoming = pathlib.Path(temp) / (request["id"] + ".json")
            incoming.write_bytes(encoded)
            self.transfer("to", incoming, "Documents/AgentBridge/incoming/" + incoming.name)
        return {"id": request["id"], "state": "submitted",
                "message": "Queued for automatic execution in the authorized session; use home_change_result to retrieve the outcome."}

    def result(self, transaction):
        transaction = str(uuid.UUID(transaction)).upper()
        try:
            return self.read("responses/" + transaction + ".json")
        except RuntimeError:
            raise RuntimeError("Request is queued or device is unavailable; retry result retrieval")


class LocalClient(Client):
    """Use the running signed Mac app's private bridge directory."""
    def __init__(self, directory):
        self.directory = pathlib.Path(directory).expanduser().resolve()

    def transfer(self, direction, source, destination):
        relative = str(source if direction == "from" else destination)
        prefix = "Documents/AgentBridge/"
        if not relative.startswith(prefix):
            raise ValueError("Invalid bridge path")
        target = (self.directory / relative[len(prefix):]).resolve()
        if not target.is_relative_to(self.directory):
            raise ValueError("Path escapes the bridge directory")
        try:
            if direction == "from":
                shutil.copyfile(target, destination)
            elif direction == "to":
                # Publish complete requests atomically so the app never sees partial JSON.
                with tempfile.NamedTemporaryFile(dir=target.parent, prefix=".request-", delete=False) as output:
                    temporary = pathlib.Path(output.name)
                    try:
                        output.write(pathlib.Path(source).read_bytes())
                        output.flush()
                        os.replace(temporary, target)
                    finally:
                        temporary.unlink(missing_ok=True)
            else:
                raise ValueError("Invalid transfer direction")
        except OSError as error:
            raise RuntimeError("Local bridge file access failed. Keep the signed Mac app running with Agent Access connected.") from error


def tool_definitions():
    return [
        {"name": "home_inventory", "description": "Read current HomeKit configuration with UUIDs, automation events, predicate conditions, timing/recurrence rules, and attached actions. Unsupported public-API details are marked. Characteristic values are cached, not fresh sensor reads.",
         "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
        {"name": "home_change_execute", "description": "Execute one HomeKit change automatically in a app-authorized connection session. update_scene replaces ALL existing scene actions. create_timer creates a disabled timer unless enabled=true.",
         "inputSchema": {"type": "object", "required": ["operation", "homeID"],
                         "additionalProperties": False, "properties": {
                             "operation": {"type": "string", "enum": OPERATIONS},
                             "homeID": {"type": "string", "format": "uuid"},
                             "objectID": {"type": "string", "format": "uuid"},
                             "roomID": {"type": "string", "format": "uuid", "description": "Destination room UUID for assign_accessory; must belong to the selected Home."},
                             "name": {"type": "string"},
                             "value": {"type": ["boolean", "number", "string"]},
                             "actions": {"type": "array", "items": {"type": "object", "required": ["characteristicID", "value"], "properties": {
                                 "characteristicID": {"type": "string", "format": "uuid"},
                                 "value": {"type": ["boolean", "number", "string"]}}}},
                             "sceneIDs": {"type": "array", "items": {"type": "string", "format": "uuid"}},
                             "fireDate": {"type": "string", "description": "Future ISO 8601 UTC date, e.g. 2026-10-07T12:00:00Z"},
                             "recurrenceMinutes": {"type": "integer", "minimum": 1, "maximum": 525600},
                             "enabled": {"type": "boolean"}}}},
        {"name": "home_change_result", "description": "Read execution outcome by transaction UUID.",
         "inputSchema": {"type": "object", "required": ["id"], "properties": {"id": {"type": "string", "format": "uuid"}}, "additionalProperties": False}}
    ]


def dispatch(client, method, params):
    if method == "initialize":
        return {"protocolVersion": params.get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {}}, "serverInfo": {"name": "homekitten-usb", "version": "1.0.0"}}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": tool_definitions()}
    if method == "tools/call":
        args = params.get("arguments", {})
        try:
            name = params["name"]
            if name == "home_inventory":
                result = client.inventory()
            elif name in ("home_change_execute", "home_change_propose"):
                result = client.submit(args)
            elif name == "home_change_result":
                result = client.result(args["id"])
            else:
                raise ValueError("Unknown tool")
            return {"content": [{"type": "text", "text": json.dumps(result)}]}
        except (ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
            return {"content": [{"type": "text", "text": str(error)}], "isError": True}
    raise ValueError("Unknown method")


def serve(client, input_stream=sys.stdin, output_stream=sys.stdout):
    for line in input_stream:
        message = None
        try:
            message = json.loads(line)
            if "id" not in message:
                continue
            result = dispatch(client, message["method"], message.get("params", {}))
            response = {"jsonrpc": "2.0", "id": message["id"], "result": result}
        except (ValueError, KeyError, TypeError) as error:
            response = {"jsonrpc": "2.0", "id": message.get("id") if isinstance(message, dict) else None,
                        "error": {"code": -32600, "message": str(error)}}
        print(json.dumps(response), file=output_stream, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    transport = parser.add_mutually_exclusive_group(required=True)
    transport.add_argument("--device", help="Paired iPhone or iPad UDID")
    transport.add_argument("--local-bridge", type=pathlib.Path, help="Running Mac app AgentBridge directory")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("inventory")
    commands.add_parser("mcp")
    commands.add_parser("submit").add_argument("request", type=pathlib.Path)
    commands.add_parser("result").add_argument("id")
    args = parser.parse_args()
    client = LocalClient(args.local_bridge) if args.local_bridge else Client(args.device)
    if args.command == "mcp":
        serve(client)
        return
    try:
        if args.command == "inventory":
            result = client.inventory()
        elif args.command == "submit":
            result = client.submit(json.loads(args.request.read_text()))
        else:
            result = client.result(args.id)
        print(json.dumps(result, indent=2))
    except (ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
