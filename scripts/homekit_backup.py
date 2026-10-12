"""Private, durable HomeKit inventory backups and conservative UUID-only recovery.

No pairing secrets or Apple Home shortcut/audio internals are exposed by HomeKit.
Recovery targets existing objects; it never runs scenes or guesses by display name.
"""
import datetime
import hashlib
import json
import os
import pathlib
import tempfile
import time
import uuid


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


class BackupStore:
    settings_path = pathlib.Path.home() / "Library/Application Support/HomeKitten/backup-settings.json"

    def __init__(self, directory=None):
        self.mirror = None
        if directory is None and not os.environ.get("HOMEKITTEN_BACKUP_DIR") and self.settings_path.exists():
            try:
                settings = json.loads(self.settings_path.read_text())
                self.mirror = pathlib.Path(settings["mirrorDirectory"]).expanduser()
                volume = settings.get("mirrorVolume")
                if volume and not os.path.ismount(volume):
                    raise RuntimeError("Configured backup mirror volume is not mounted; refusing to skip it")
            except (OSError, ValueError, KeyError) as error:
                raise RuntimeError("Backup mirror configuration is unreadable; refusing to skip it") from error
        self.directory = pathlib.Path(directory or os.environ.get("HOMEKITTEN_BACKUP_DIR") or
                                      pathlib.Path.home() / "Library/Application Support/HomeKitten/AgentBackups").expanduser()

    def path(self, identifier):
        return self.directory / (str(uuid.UUID(identifier)).upper() + ".json")

    def write(self, record):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        payload = encoded(record)
        wrapper = {"sha256": hashlib.sha256(payload).hexdigest(), "record": record}
        with tempfile.NamedTemporaryFile(dir=self.directory, prefix=".backup-", delete=False) as output:
            temporary = pathlib.Path(output.name)
            try:
                output.write(encoded(wrapper)); output.flush(); os.fsync(output.fileno())
                os.replace(temporary, self.path(record["id"]))
            finally:
                temporary.unlink(missing_ok=True)
        directory_fd = os.open(self.directory, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        # Verify the persisted file, not just the serialization in memory.
        verified = self.load(record["id"])
        if self.mirror is not None:
            if not self.mirror.parent.is_dir():
                raise RuntimeError("Backup mirror volume is unavailable; write was not submitted")
            BackupStore(self.mirror).write(record)
        return verified

    def load(self, identifier):
        try:
            wrapper = json.loads(self.path(identifier).read_bytes())
            record = wrapper["record"]
            if hashlib.sha256(encoded(record)).hexdigest() != wrapper["sha256"]:
                raise ValueError("Backup checksum mismatch")
            if record["version"] != 1 or record["id"] != str(uuid.UUID(identifier)).upper():
                raise ValueError("Invalid backup version or identity")
            return record
        except (OSError, KeyError, json.JSONDecodeError) as error:
            raise RuntimeError("Backup is missing or unreadable; no recovery performed") from error

    def capture(self, inventory, label="manual", request=None, identifier=None):
        record = {"version": 1, "id": identifier or str(uuid.uuid4()).upper(),
                  "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  "label": label, "inventory": inventory, "request": request,
                  "status": "prepared", "limitations": [
                      "Public HomeKit configuration only; no pairing keys, users, shortcut or audio internals.",
                      "Accessory values are cached unless a separate fresh read is recorded.",
                      "Recovery requires the same Home and client UUIDs; no whole-Home recreation."]}
        self.write(record)
        return self.summary(record)

    def summary(self, record):
        mirror_verified = None
        if self.mirror:
            try:
                mirror_verified = BackupStore(self.mirror).load(record["id"]) == record
            except (RuntimeError, ValueError):
                mirror_verified = False
        return {key: record[key] for key in ("id", "createdAt", "label", "status")} | {
            "path": str(self.path(record["id"])), "checksumVerified": True,
            "mirrorPath": str(self.mirror / (record["id"] + ".json")) if self.mirror else None,
            "mirrorChecksumVerified": mirror_verified,
            "homes": [{"id": h["id"], "counts": {k: len(h.get(k, [])) for k in
                       ("accessories", "rooms", "scenes", "automations", "groups", "zones")}}
                      for h in record["inventory"].get("homes", [])], "limitations": record["limitations"]}

    def list(self):
        result = []
        for path in sorted(self.directory.glob("*.json")):
            try:
                result.append(self.summary(self.load(path.stem)))
            except (ValueError, RuntimeError):
                result.append({"id": path.stem, "status": "corrupt", "path": str(path)})
        return sorted(result, key=lambda r: r.get("createdAt", ""), reverse=True)


def find(items, identifier):
    matches = [item for item in items if item["id"].upper() == identifier.upper()]
    if len(matches) != 1:
        raise ValueError("Exact UUID missing or ambiguous; never substitute a name")
    return matches[0]


def scalar(value):
    if type(value) not in (bool, int, float, str):
        raise ValueError("Unsupported non-scalar value")
    encoded(value)
    return value


def actions(scene):
    if scene.get("type") != "HMActionSetTypeUserDefined" or not scene.get("actions"):
        raise ValueError("HomeKit-owned or zero-action scene: hidden shortcut/audio actions cannot be recovered")
    result = []
    for action in scene["actions"]:
        if action.get("kind") != "characteristicWrite" or action.get("supported") is False:
            raise ValueError("Unsupported scene action; refusing partial replacement")
        result.append({"characteristicID": action["characteristicID"], "value": scalar(action["value"])})
    return sorted(result, key=lambda a: (a["characteristicID"], encoded(a["value"])))


def event(item):
    kind = item["kind"]
    if item.get("supported") is False:
        raise ValueError("Unsupported event")
    if kind == "HMCharacteristicEvent":
        return {"kind": "characteristic", "characteristicID": item["characteristicID"], "value": scalar(item["triggerValue"])}
    if kind == "HMCalendarEvent":
        parts = item["fireDateComponents"]
        if set(parts) - {"hour", "minute"} or "hour" not in parts or "minute" not in parts:
            raise ValueError("Calendar date/time-zone components cannot be represented exactly")
        return {"kind": "calendar", **parts}
    if kind == "HMSignificantTimeEvent":
        parts = item.get("offset") or {}
        if set(parts) - {"hour", "minute"}:
            raise ValueError("Solar offset cannot be represented exactly")
        return {"kind": "significant_time", "significantEvent": item["significantEvent"],
                "offsetMinutes": parts.get("hour", 0) * 60 + parts.get("minute", 0)}
    if kind == "HMDurationEvent":
        return {"kind": "duration", "durationSeconds": item["durationSeconds"]}
    if kind == "HMPresenceEvent":
        scope = {"homeUsers": "home_users", "currentUser": "current_user"}.get(item["presenceUserType"])
        trigger = {"firstEntryOrAtHome": "first_entry", "lastExitOrNotAtHome": "last_exit"}.get(item["presenceEventType"])
        if scope and trigger:
            return {"kind": "presence", "presenceEvent": trigger, "presenceUser": scope}
    raise ValueError("Event type cannot be restored exactly: " + kind)


def predicate(node):
    if not isinstance(node, dict) or node.get("supported") is False:
        raise ValueError("Unsupported predicate")
    # HomeKit's characteristic predicate is an AND of characteristic identity and value comparison.
    if node.get("kind") == "compound":
        children = node["children"]
        if node["operator"] == "and" and len(children) == 2:
            identity = next((c for c in children if c.get("left", {}).get("keyPath") == "characteristic"), None)
            comparison = next((c for c in children if c.get("left", {}).get("keyPath") == "characteristicValue"), None)
            if identity and comparison:
                for c in (identity, comparison):
                    if c.get("kind") != "comparison" or c.get("modifier") != "direct" or c.get("optionsRawValue") != 0 or c.get("right", {}).get("kind") != "constant":
                        raise ValueError("Unsupported characteristic predicate comparison")
                ref = identity["right"]["value"]
                if identity["operator"] != "equal" or not isinstance(ref, dict) or ref.get("kind") != "characteristic":
                    raise ValueError("Unsupported characteristic identity")
                return {"kind": "characteristic", "characteristicID": ref["id"],
                        "comparison": {"equal": "equal", "notEqual": "not_equal", "lessThan": "less_than", "greaterThan": "greater_than",
                                       "lessThanOrEqual": "at_most", "greaterThanOrEqual": "at_least"}.get(comparison["operator"], "unsupported"), "value": scalar(comparison["right"]["value"])}
        operator = {"and": "all", "or": "any", "not": "not"}.get(node["operator"])
        if operator:
            return {"kind": operator, "children": [predicate(c) for c in children]}
    raise ValueError("Predicate cannot be restored exactly; native presence/time/custom clauses require manual recovery")


def rules(automation):
    if automation["kind"] != "HMEventTrigger" or automation.get("rulesStatus") != "publicAPI":
        raise ValueError("Only representable event automation rules can be restored")
    result = {"events": [event(e) for e in automation["events"]],
              "endEvents": [event(e) for e in automation["endEvents"]], "executeOnce": automation["executeOnce"]}
    recurrences = automation.get("recurrences")
    if recurrences is not None and any(set(r) != {"weekday"} for r in recurrences):
        raise ValueError("Recurrence components cannot be represented exactly")
    result["recurrenceWeekdays"] = [r["weekday"] for r in recurrences or []]
    if automation.get("predicate") is None:
        result["clearConditions"] = True
    else:
        result["conditions"] = predicate(automation["predicate"])
    return result


def restore_request(saved, current, home, kind, fields=None):
    """Return only changed fields. Validate ALL selected saved fields before writing any."""
    request = {"homeID": home["id"], "objectID": saved["id"]}
    if kind == "accessory":
        request["operation"] = "rename_accessory"
        if fields is None or "name" in fields:
            if saved["name"] != current["name"]: request["name"] = saved["name"]
        results = [request] if "name" in request else []
        if fields is None or "roomID" in fields:
            if saved.get("roomID") != current.get("roomID"):
                find(home["rooms"], saved["roomID"])
                results.append({"operation": "assign_accessory", "homeID": home["id"], "objectID": saved["id"], "roomID": saved["roomID"]})
        return results
    if kind == "scene":
        request["operation"] = "update_scene" if fields is None or "actions" in fields else "rename_scene"
        if fields is None or "actions" in fields:
            old, now = actions(saved), actions(current)
            available = {c["id"] for a in home["accessories"] for service in a.get("services", []) for c in service.get("characteristics", [])}
            for action in old:
                if action["characteristicID"] not in available:
                    raise ValueError("Scene characteristic UUID missing; refusing partial recovery")
            if old != now: request["actions"] = old
        if (fields is None or "name" in fields) and saved["name"] != current["name"]:
            request["name"] = saved["name"]
        if request["operation"] == "update_scene" and "name" in request and "actions" not in request:
            request["operation"] = "rename_scene"
    elif kind == "automation":
        request["operation"] = "update_automation"
        for field in ("name", "enabled", "sceneIDs"):
            if fields is None or field in fields:
                if field == "sceneIDs":
                    if not saved[field]:
                        raise ValueError("Empty attached-scene list cannot be restored through the current bridge")
                    for identifier in saved[field]: find(home["scenes"], identifier)
                if saved[field] != current[field]: request[field] = saved[field]
        selected_rules = fields is None or bool(set(fields) & {"events", "endEvents", "conditions", "additionalConditions", "clearConditions", "recurrenceWeekdays", "executeOnce"})
        if selected_rules:
            old, now = rules(saved), rules(current)
            for field, value in old.items():
                selected = fields is None or field in fields or (field in ("conditions", "clearConditions") and set(fields) & {"conditions", "clearConditions", "additionalConditions"})
                if selected and value != now.get(field): request[field] = value
            # Restore the previous enabled flag after a partially failed rule update.
            if len(request) > 3 or saved["enabled"] != current["enabled"]:
                request["enabled"] = saved["enabled"]
    else:
        raise ValueError("Supported recovery kinds: accessory, scene, automation")
    return [request] if len(request) > 3 else []



def recovery_scope(request, identifier):
    operation = request["operation"]
    choices = {"rename_accessory": ("accessory", ["name"]), "assign_accessory": ("accessory", ["roomID"]),
               "set_characteristic": ("characteristic", ["value"]), "rename_scene": ("scene", ["name"]),
               "update_scene": ("scene", [key for key in ("name", "actions") if key in request]),
               "update_automation": ("automation", [key for key in ("name", "enabled", "sceneIDs", "events", "endEvents", "conditions", "additionalConditions", "clearConditions", "recurrenceWeekdays", "executeOnce") if key in request])}
    if operation not in choices:
        return {"state": "manual", "reason": "Creation, deletion and scene execution have no automatic inverse; inspect the saved configuration before recovery."}
    kind, fields = choices[operation]
    if not request.get("objectID"):
        return {"state": "blocked", "reason": "A target UUID is required for recovery"}
    return {"identifier": identifier, "home_id": request["homeID"], "kind": kind, "object_id": request["objectID"], "fields": fields}


def plan(store, client, identifier, home_id, kind, object_id, fields=None):
    allowed = {"accessory": {"name", "roomID"}, "scene": {"name", "actions"},
               "automation": {"name", "enabled", "sceneIDs", "events", "endEvents", "conditions", "additionalConditions", "clearConditions", "recurrenceWeekdays", "executeOnce"},
               "characteristic": {"value"}}
    if kind not in allowed or (fields is not None and (not isinstance(fields, list) or not fields or not set(fields) <= allowed[kind])):
        raise ValueError("Invalid recovery kind or fields")
    record = store.load(identifier)
    saved_home = find(record["inventory"]["homes"], home_id)
    current = client.inventory()
    home = find(current["homes"], home_id)
    if kind == "characteristic":
        before = record.get("beforeRead", {})
        readings = [r for r in before.get("results", []) if r.get("characteristicID", r.get("id", "")).upper() == object_id.upper() and r.get("state") == "read"]
        if len(readings) != 1:
            raise ValueError("No fresh pre-change value saved for this characteristic; cached values cannot establish recovery")
        live = client.live_read({"homeID": home_id, "characteristicIDs": [object_id]})
        readings_now = [r for r in live.get("results", []) if r.get("characteristicID", r.get("id", "")).upper() == object_id.upper() and r.get("state") == "read"]
        if len(readings_now) != 1: raise ValueError("Current characteristic read unavailable; no recovery performed")
        value, current_value = scalar(readings[0]["value"]), scalar(readings_now[0]["value"])
        requests = [] if value == current_value else [{"operation": "set_characteristic", "homeID": home_id, "objectID": object_id, "value": value}]
        basis = {"backupID": identifier, "homeID": home_id, "objectID": object_id, "fields": fields, "kind": kind, "value": current_value, "requests": requests}
        return {"backupID": identifier, "homeID": home_id, "kind": kind, "objectID": object_id, "fields": fields,
                "requests": requests, "blocked": [], "planToken": hashlib.sha256(encoded(basis)).hexdigest(), "state": "preview", "limitations": record["limitations"]}
    collection = {"accessory": "accessories", "scene": "scenes", "automation": "automations"}[kind]
    saved = find(saved_home[collection], object_id)
    present = find(home[collection], object_id)
    try:
        requests = restore_request(saved, present, home, kind, fields)
        from homekit_agent import validate_automation_rules
        for request in requests: validate_automation_rules(request)
        blocked = []
    except (ValueError, KeyError, TypeError) as error:
        requests, blocked = [], [str(error)]
    # Fingerprint includes current configuration; changes between preview and apply invalidate it.
    basis = {"backupID": identifier, "homeID": home_id, "kind": kind, "objectID": object_id,
             "fields": fields, "current": present, "requests": requests, "blocked": blocked}
    return {"backupID": identifier, "homeID": home_id, "kind": kind, "objectID": object_id,
            "fields": fields, "requests": requests, "blocked": blocked,
            "planToken": hashlib.sha256(encoded(basis)).hexdigest(), "state": "blocked" if blocked else "preview",
            "limitations": record["limitations"]}


def restore(store, client, arguments):
    args = dict(arguments)
    token = args.pop("planToken", None)
    preview = plan(store, client, **args)
    if preview["blocked"]: raise ValueError("Recovery blocked: " + "; ".join(preview["blocked"]))
    if not token or token != preview["planToken"]:
        raise ValueError("Preview first; planToken must match current configuration")
    # A durable journal survives lost responses; an incomplete recovery is never replayed automatically.
    journal_id = str(uuid.uuid4()).upper()
    journal = {"version": 1, "id": journal_id, "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "label": "restore-journal", "status": "restoring", "inventory": client.inventory(),
               "request": preview, "limitations": preview["limitations"], "transactions": []}
    store.write(journal)
    for request in preview["requests"]:
        try:
            submitted = client.submit(request)
        except (OSError, ValueError, RuntimeError) as error:
            journal["status"] = "interrupted"
            journal["error"] = str(error)
            store.write(journal)
            return {"state": "interrupted", "journalID": journal_id, "transactions": journal["transactions"],
                    "message": str(error) + " Inspect write-ahead receipts and Home before resuming."}
        journal["transactions"].append(submitted); store.write(journal)
        deadline = time.monotonic() + 40
        while True:
            try:
                outcome = client.result(submitted["id"])
            except RuntimeError:
                outcome = {"id": submitted["id"], "state": "queued"}
            if outcome.get("state") not in ("queued", "submitted", "executing"): break
            if time.monotonic() >= deadline:
                journal["status"] = "indeterminate"; store.write(journal)
                return {"state": "indeterminate", "journalID": journal_id, "transactions": journal["transactions"],
                        "message": "Retrieve the existing transaction; inspect Home before another recovery."}
            time.sleep(0.5)
        journal["transactions"][-1]["outcome"] = outcome; store.write(journal)
        if outcome.get("state") != "completed":
            journal["status"] = "failed"; store.write(journal)
            return {"state": "failed", "journalID": journal_id, "transactions": journal["transactions"]}
    # Wait for the app's next inventory publication, then independently compare the selected settings.
    deadline = time.monotonic() + 15
    while True:
        verification = plan(store, client, **args)
        if not verification["requests"] and not verification["blocked"]: break
        if time.monotonic() >= deadline: break
        time.sleep(0.5)
    journal["status"] = "verified" if not verification["requests"] and not verification["blocked"] else "verification_failed"
    journal["verification"] = verification; store.write(journal)
    return {"state": journal["status"], "journalID": journal_id, "transactions": journal["transactions"],
            "configurationVerified": journal["status"] == "verified", "physicalBehaviorVerified": False}
