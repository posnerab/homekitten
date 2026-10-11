#!/usr/bin/env python3
"""HomeKitten paired-device and local Mac client. No dependencies, network service, or secrets.

CLI: (--device UDID | --local-bridge DIR) inventory | submit request.json | result UUID | mcp
Fresh reads: read request.json | read-result UUID
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
import time
import uuid

BUNDLE = "abie.ios.homekitten"
OPERATIONS = ["rename_accessory", "set_characteristic", "create_scene", "update_scene",
              "rename_scene", "run_scene", "create_timer", "create_event_automation", "update_automation", "create_room", "assign_accessory"]


RULE_FIELDS = {"events", "endEvents", "conditions", "clearConditions", "recurrenceWeekdays", "executeOnce"}
COMPARISONS = ["equal", "not_equal", "less_than", "greater_than", "at_most", "at_least"]


def validate_automation_rules(request):
    """Reject malformed rule writes before queueing; the app also validates Home objects/types."""
    if not any(key in request for key in RULE_FIELDS) and request["operation"] != "create_event_automation":
        return
    if request["operation"] not in ("create_event_automation", "update_automation"):
        raise ValueError("Event rules require an event automation operation")
    if request.get("clearConditions") and "conditions" in request:
        raise ValueError("conditions and clearConditions are mutually exclusive")
    if request["operation"] == "create_event_automation" and ("events" not in request or not request.get("sceneIDs") or not request.get("name")):
        raise ValueError("Event creation requires name, events, and sceneIDs")
    for field in ("clearConditions", "executeOnce"):
        if field in request and type(request[field]) is not bool:
            raise ValueError(field + " must be boolean")
    if "recurrenceWeekdays" in request:
        days = request["recurrenceWeekdays"]
        if not isinstance(days, list) or len(days) > 7 or any(type(d) is not int or not 1 <= d <= 7 for d in days) or len(set(days)) != len(days):
            raise ValueError("Use unique weekdays 1–7, or [] for every day")
    for field in ("events", "endEvents"):
        if field not in request:
            continue
        events = request[field]
        if not isinstance(events, list) or len(events) > 32 or (field == "events" and not events):
            raise ValueError("Provide 1–32 events (0–32 end events)")
        encoded = []
        for event in events:
            if not isinstance(event, dict):
                raise ValueError("Event must be an object")
            kind = event.get("kind")
            allowed = {"characteristic": {"kind", "characteristicID", "value"}, "calendar": {"kind", "hour", "minute"},
                       "significant_time": {"kind", "significantEvent", "offsetMinutes"}, "presence": {"kind", "presenceEvent", "presenceUser"},
                       "duration": {"kind", "durationSeconds"}}.get(kind)
            if allowed is None or not set(event) <= allowed:
                raise ValueError("Unsupported event kind/fields")
            if kind == "characteristic":
                event["characteristicID"] = str(uuid.UUID(event["characteristicID"])).upper()
                if type(event.get("value")) not in (bool, int, float, str):
                    raise ValueError("Characteristic event requires a scalar value")
            elif kind == "calendar":
                if type(event.get("hour")) is not int or not 0 <= event["hour"] <= 23 or type(event.get("minute")) is not int or not 0 <= event["minute"] <= 59:
                    raise ValueError("Calendar event requires valid hour/minute")
            elif kind == "significant_time":
                if event.get("significantEvent") not in ("sunrise", "sunset") or type(event.get("offsetMinutes", 0)) is not int or not -720 <= event.get("offsetMinutes", 0) <= 720:
                    raise ValueError("Invalid significant time event")
            elif kind == "presence":
                if event.get("presenceEvent") not in ("first_entry", "last_exit") or event.get("presenceUser", "home_users") not in ("home_users", "current_user"):
                    raise ValueError("Invalid presence event")
            elif field != "endEvents" or type(event.get("durationSeconds")) not in (int, float) or not 0 < event["durationSeconds"] <= 86400:
                raise ValueError("Duration must be an end event between 0 and 86400 seconds")
            encoded.append(json.dumps(event, sort_keys=True, allow_nan=False))
        if len(set(encoded)) != len(encoded):
            raise ValueError("Duplicate events")
    def condition(node, depth=0):
        if not isinstance(node, dict) or depth >= 8:
            raise ValueError("Invalid or overly deep condition tree")
        if node.get("kind") == "characteristic":
            if not set(node) <= {"kind", "characteristicID", "comparison", "value"} or node.get("comparison", "equal") not in COMPARISONS or type(node.get("value")) not in (bool, int, float, str):
                raise ValueError("Invalid characteristic condition")
            node["characteristicID"] = str(uuid.UUID(node["characteristicID"])).upper()
            if node.get("comparison", "equal") not in ("equal", "not_equal") and type(node["value"]) not in (int, float):
                raise ValueError("Ordering requires a numeric value")
        else:
            children = node.get("children")
            if node.get("kind") not in ("all", "any", "not") or not set(node) <= {"kind", "children"} or not isinstance(children, list) or not 1 <= len(children) <= 32 or (node["kind"] == "not" and len(children) != 1):
                raise ValueError("Use all/any with children, or not with exactly one child")
            for child in children:
                condition(child, depth + 1)
    if "conditions" in request:
        condition(request["conditions"])


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
        request = json.loads(json.dumps(arguments, allow_nan=False))
        for key in ("id", "sessionID"):
            request.pop(key, None)
        request["homeID"] = str(uuid.UUID(request["homeID"])).upper()
        for key in ("objectID", "roomID"):
            if request.get(key):
                request[key] = str(uuid.UUID(request[key])).upper()
        validate_automation_rules(request)
        request["id"] = str(uuid.uuid4()).upper()
        inventory = self.inventory()
        if not inventory.get("writesAllowed"):
            raise RuntimeError("Read-only session. Reconnect in HomeKitten with changes allowed.")
        if (request["operation"] == "create_event_automation" or any(key in request for key in RULE_FIELDS)) and inventory.get("automationWritesVersion", 0) < 1:
            raise RuntimeError("This app build does not support event automation writes; install the updated HomeKitten app.")
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

    def read_result(self, transaction):
        transaction = str(uuid.UUID(transaction)).upper()
        try:
            return self.read("read-responses/" + transaction + ".json")
        except RuntimeError:
            return {"id": transaction, "state": "queued", "message": "Retry home_read_result with this id; the app has not returned an outcome."}

    def live_read(self, arguments):
        home = str(uuid.UUID(arguments["homeID"])).upper()
        ids = arguments["characteristicIDs"]
        if not isinstance(ids, list) or not 1 <= len(ids) <= 10:
            raise ValueError("Provide 1–10 characteristic UUIDs")
        ids = [str(uuid.UUID(item)).upper() for item in ids]
        if len(set(ids)) != len(ids):
            raise ValueError("Duplicate characteristic UUIDs")
        inventory = self.inventory()
        if not inventory.get("liveReadsSupported"):
            raise RuntimeError("This app build does not support live reads; install the updated HomeKitten app.")
        request = {"id": str(uuid.uuid4()).upper(), "sessionID": inventory["sessionID"],
                   "homeID": home, "characteristicIDs": ids}
        with tempfile.TemporaryDirectory(prefix="homekitten-read-") as temp:
            incoming = pathlib.Path(temp) / (request["id"] + ".json")
            incoming.write_text(json.dumps(request))
            self.transfer("to", incoming, "Documents/AgentBridge/reads/" + incoming.name)
        deadline = time.monotonic() + 40
        while True:
            result = self.read_result(request["id"])
            if result.get("state") not in ("queued", "executing") or time.monotonic() >= deadline:
                return result
            time.sleep(0.5)


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
    scalar = {"type": ["boolean", "number", "string"]}
    event = {"oneOf": [
        {"type": "object", "additionalProperties": False, "required": ["kind", "characteristicID", "value"], "properties": {
            "kind": {"const": "characteristic"}, "characteristicID": {"type": "string", "format": "uuid"}, "value": scalar}},
        {"type": "object", "additionalProperties": False, "required": ["kind", "hour", "minute"], "properties": {
            "kind": {"const": "calendar"}, "hour": {"type": "integer", "minimum": 0, "maximum": 23}, "minute": {"type": "integer", "minimum": 0, "maximum": 59}}},
        {"type": "object", "additionalProperties": False, "required": ["kind", "significantEvent"], "properties": {
            "kind": {"const": "significant_time"}, "significantEvent": {"enum": ["sunrise", "sunset"]}, "offsetMinutes": {"type": "integer", "minimum": -720, "maximum": 720}}},
        {"type": "object", "additionalProperties": False, "required": ["kind", "presenceEvent"], "properties": {
            "kind": {"const": "presence"}, "presenceEvent": {"enum": ["first_entry", "last_exit"]}, "presenceUser": {"enum": ["home_users", "current_user"]}}},
        {"type": "object", "additionalProperties": False, "required": ["kind", "durationSeconds"], "properties": {
            "kind": {"const": "duration"}, "durationSeconds": {"type": "number", "exclusiveMinimum": 0, "maximum": 86400}}}
    ]}
    condition = {"oneOf": [
        {"type": "object", "additionalProperties": False, "required": ["kind", "characteristicID", "value"], "properties": {
            "kind": {"const": "characteristic"}, "characteristicID": {"type": "string", "format": "uuid"}, "comparison": {"enum": COMPARISONS}, "value": scalar}},
        {"type": "object", "additionalProperties": False, "required": ["kind", "children"], "properties": {
            "kind": {"enum": ["all", "any", "not"]}, "children": {"type": "array", "minItems": 1, "maxItems": 32, "items": {"$ref": "#/$defs/condition"}}}}
    ]}
    return [
        {"name": "home_inventory", "description": "Read current HomeKit configuration with UUIDs, automation events, predicate conditions, timing/recurrence rules, and attached actions. Unsupported public-API details are marked. Characteristic values are cached, not fresh sensor reads.",
         "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
        {"name": "home_change_execute", "description": "Execute one HomeKit change automatically in a app-authorized connection session. update_scene replaces ALL existing scene actions. create_timer and create_event_automation default to disabled. Event/condition arrays replace existing rules; conditions are declarative all/any/not/characteristic trees. Updates disable the automation while editing; failures may leave it disabled.",
         "inputSchema": {"type": "object", "required": ["operation", "homeID"],
                         "additionalProperties": False, "$defs": {"condition": condition}, "properties": {
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
                             "enabled": {"type": "boolean"},
                             "events": {"type": "array", "minItems": 1, "maxItems": 32, "items": event, "description": "Replace all start events; duration is supported only in endEvents."},
                             "endEvents": {"type": "array", "maxItems": 32, "items": event},
                             "conditions": {"$ref": "#/$defs/condition"},
                             "clearConditions": {"type": "boolean", "description": "true removes the predicate; omit to preserve it. Mutually exclusive with conditions."},
                             "recurrenceWeekdays": {"type": "array", "maxItems": 7, "uniqueItems": True, "items": {"type": "integer", "minimum": 1, "maximum": 7}, "description": "Foundation weekday: Sunday=1. [] means every day."},
                             "executeOnce": {"type": "boolean"}}}},
        {"name": "home_change_result", "description": "Read execution outcome by transaction UUID.",
         "inputSchema": {"type": "object", "required": ["id"], "properties": {"id": {"type": "string", "format": "uuid"}}, "additionalProperties": False}},
        {"name": "home_read_characteristics", "description": "Request fresh HomeKit reads for 1–10 characteristic UUIDs in one Home. Works in read-only sessions. Returns per-characteristic values and readAt timestamps, or explicit errors/timeouts without cached fallback. Homebridge plugin/device freshness can vary. A queued/executing response can be retrieved with home_read_result.",
         "annotations": {"readOnlyHint": True},
         "inputSchema": {"type": "object", "required": ["homeID", "characteristicIDs"], "additionalProperties": False,
                         "properties": {"homeID": {"type": "string", "format": "uuid"},
                                        "characteristicIDs": {"type": "array", "minItems": 1, "maxItems": 10, "uniqueItems": True,
                                                              "items": {"type": "string", "format": "uuid"}}}}},
        {"name": "home_read_result", "description": "Retrieve a queued or executing live-read request by id without submitting another request.",
         "annotations": {"readOnlyHint": True},
         "inputSchema": {"type": "object", "required": ["id"], "additionalProperties": False,
                         "properties": {"id": {"type": "string", "format": "uuid"}}}}
    ]


def dispatch(client, method, params):
    if method == "initialize":
        return {"protocolVersion": params.get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {}}, "serverInfo": {"name": "homekitten-usb", "version": "1.1.0"}}
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
            elif name == "home_read_characteristics":
                result = client.live_read(args)
            elif name == "home_read_result":
                result = client.read_result(args["id"])
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
    commands.add_parser("read").add_argument("request", type=pathlib.Path)
    commands.add_parser("read-result").add_argument("id")
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
        elif args.command == "read":
            result = client.live_read(json.loads(args.request.read_text()))
        elif args.command == "read-result":
            result = client.read_result(args.id)
        else:
            result = client.result(args.id)
        print(json.dumps(result, indent=2))
    except (ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
