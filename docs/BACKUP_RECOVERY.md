# HomeKit backups and recovery

The Python agent now saves a durable inventory snapshot **before every submitted
HomeKit write**, in addition to the signed app's own immediate pre-write backup.
The client requires an atomic, checksum-verified file and a write-ahead receipt
before transfer. If storage fails, the change is not submitted. A returned
`backupID` is also the transaction UUID. Retrieve that transaction after an
interruption; do not replay the request.

These backups protect configuration changes. They are not an Apple Home disaster
recovery image: HomeKit does not expose pairing keys, user access, Apple Home
shortcut internals, audio actions or every native rule. Devices must remain
paired, and recovery must use the same HomeKit client and exact UUIDs. No matching
by display name, bulk physical-state reset, scene execution, deletion or automatic
recreation of missing objects occurs during recovery.

## Storage and independent copies

The Mac agent stores private JSON under
`~/Library/Application Support/HomeKitten/AgentBackups/`, outside the source repo
and outside the app bundle. Files use mode 0600; newly created directories use
0700. Each file contains its payload checksum. No automatic expiration or cleanup
removes these snapshots. `HOMEKITTEN_BACKUP_DIR` selects another primary location
and bypasses the default mirror settings, useful for isolated tests.

On Abie-mini, private `~/Library/Application Support/HomeKitten/backup-settings.json`
configures `mirrorDirectory` as `/Volumes/Mac-Extend/HomeKitten-Backups` and
`mirrorVolume` as `/Volumes/Mac-Extend`.
Both copies are written and verified before submission. Keep the external volume
mounted; mirror failure blocks submission rather than quietly dropping redundancy.
This setting, all snapshots, requests and recovery journals remain local. To
recover after losing the internal copy, set `HOMEKITTEN_BACKUP_DIR` to the mirror
and use the same CLI. Do not publish either directory or the settings file.

The app separately retains its own pre-write snapshots under
`Documents/AgentBridge/backups/`. Native UI backups live in the app's Application
Support directory. The new agent does not convert or delete those older formats.
Use the agent recovery path for agent backups. The existing native restore UI has
limited automation information and is not a full event-rule recovery path.

## Agent tools

Refresh/reconnect existing MCP clients after this Python update. The signed app
needs no reinstall for these client-side tools:

- `home_backup_create`: fresh inventory capture, durable save and checksum verification.
- `home_backup_list`: IDs, timestamps, counts, paths and integrity status.
- `home_restore_preview`: differences for one exact object UUID and selected fields.
- `home_restore_apply`: apply the preview using its `planToken`, stopping on failure
  or an uncertain transaction, then independently compare the selected settings.

Every `home_change_execute` result now includes `backupID`, `backupPath` and a
`recovery` assessment. Supported edits include the exact recovery arguments in
`recovery.scope`. A blocked/manual assessment means this backup is evidence, not
an automatic inverse. Assess recovery **before** undertaking a change using fresh
inventory and the converter limits below; a backup does not make a deletion or
unsupported rule reversible. The assessment returned after submission is a
receipt, not an additional authorization gate.

For a planned batch, also create one labelled baseline before its first write.
Keep each transaction's backup ID and check the outcome. Backups contain the
configuration at inventory capture (at most 15 seconds old); the app's existing
snapshot additionally runs immediately before the HomeKit call. HomeKit does not
provide atomic whole-Home capture or restoration.

## CLI and recovery procedure

The same commands work through `--device <paired-device-UDID>`; local examples:

```sh
python3 scripts/homekit_agent.py --local-bridge ~/Documents/AgentBridge backup --label before-room-edit
python3 scripts/homekit_agent.py --local-bridge ~/Documents/AgentBridge backups
python3 scripts/homekit_agent.py --local-bridge ~/Documents/AgentBridge restore-preview /private/path/recovery.json
python3 scripts/homekit_agent.py --local-bridge ~/Documents/AgentBridge restore /private/path/recovery-with-token.json
```

The preview request (use actual UUIDs from the backup and current inventory):

```json
{
  "identifier": "<backup UUID>",
  "home_id": "<Home UUID>",
  "kind": "accessory",
  "object_id": "<accessory UUID>",
  "fields": ["name", "roomID"]
}
```

1. Check backup integrity and the original change's outcome/current state.
2. Preview one object and only the fields changed by the original operation.
   Copy `recovery.scope` from its receipt when available. Omit `fields` only when
   intentionally restoring all supported settings of that object.
3. Resolve any `blocked` reasons. Never drop unsupported clauses to force a restore.
4. Copy the preview's `planToken` into the request and apply. Changed configuration
   invalidates the token, requiring a fresh preview. This is a state check, not a
   per-change approval dialog.
5. Confirm `state: verified` and `configurationVerified: true`. Every recovery
   writes its own journal; each actual mutation also gets a new automatic backup.
   Failure stops later requests. `indeterminate` includes the existing transaction
   ID: retrieve its outcome and inspect state before resuming, rather than replaying.

HomeKit operations remain non-atomic. No-operation recovery also verifies the
selected state but does not establish that a changed live object was restored.
`physicalBehaviorVerified` stays false: configuration read-back is not physical
confirmation, even if a device write was accepted.

## Coverage

| Kind | Fields | Limits |
| --- | --- | --- |
| `accessory` | `name`, `roomID` | Paired accessory and destination room must still exist by UUID. |
| `scene` | `name`, `actions` | Action replacement requires nonempty user-defined scalar actions and every characteristic still present. Hidden/zero-action/owned scenes are blocked. Name-only recovery preserves actions. |
| `automation` | `name`, `enabled`, `sceneIDs`, `events`, `endEvents`, `conditions`, `recurrenceWeekdays`, `executeOnce` | Whole-rule recovery requires exactly representable event/predicate/recurrence data. Name/enabled recovery can work independently of unsupported rule details. Saved scene references must still exist; the current bridge cannot restore an empty reference list. |
| `characteristic` | `value` | Requires a saved **fresh** pre-change read and a successful fresh current read. Cached inventory values are never used as rollback values. Write-only or failed reads have no automatic recovery. |

Representable rules include scalar characteristic events; calendar hour/minute;
sunrise/sunset with whole-minute offsets; supported first-entry/last-exit presence;
end durations; weekday recurrence; and characteristic comparison predicates with
AND/OR/NOT. Threshold ranges, custom/every-entry presence, native time/presence
predicate expressions, unsupported date components and timer schedule recreation
are blocked. Unsupported details remain in the snapshot for manual inspection.
`additionalConditions` recovery restores the original complete predicate only
when that predicate can be represented exactly.

Creation, deletion and running a scene have no automatic inverse. Room/group/zone
configuration is preserved as evidence but is outside the current agent restore
operations. Re-pairing or moving between client devices changes UUID identity and
requires explicit manual mapping rather than automatic replay.

## Verified baseline, October 12, 2026

A fresh Mac inventory contained 261 accessories, 18 rooms, 74 scenes and 51
automations. Both baseline copies passed checksum verification. A live accessory
recovery preview/apply returned `verified` with no changes or HomeKit transactions.
The full recovery audit accepted 52 scenes and 23 event rules; 22 scene action
sets and 28 rules were blocked by the limits above. These counts are a dated
snapshot, not a guarantee about subsequent configuration. Tests additionally
simulate changed-state recovery, storage failure, stale previews, missing UUIDs,
unsupported rules, uncertain transfer and stop-on-failure behavior. No live device
or rule was deliberately changed to test rollback.

## Migration recovery extension

The signed migration app/client adds group/zone membership, room-name recovery,
and scalar incremental recovery of built-in/owned scene actions without replacing
hidden or unrelated actions. See [migration recovery](STAGED_MIGRATION.md#recovery-additions)
for `group`, `zone`, `room`, `scene_patch` kinds and characteristic scope. The
original coverage table above describes the replace-all recovery path; new
incremental recovery does not reconstruct hidden internals. Native automation
reference mapping preserves clauses in place, but does not promise automatic
recovery of every unsupported rule. Creation/deletion and pairing limits remain.
