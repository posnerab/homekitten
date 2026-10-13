# Staged accessory migration

Use the signed app advertising `membershipWritesVersion: 1`,
`incrementalSceneWritesVersion: 1`, `nativeReferenceWritesVersion: 1`,
`booleanNormalizationVersion: 1`, `migrationPlanVersion: 1`, and
`backupConfigurationVersion: 2`, together with Python MCP client 1.6.0.
Existing UUIDs, pairings, session checks, consumed transactions and mirrored
write-ahead backups remain in place. Reconnect existing MCP clients for the new
schema. Only the Mac development install is part of this release; iOS source is
signed-build checked, without installing on another device.

## Placement operations

All operations use `home_change_execute` (or CLI `submit`) with exact `homeID`.
Names are only values for explicit create/rename operations, never lookup keys.
The app validates the entire request before its first write and reads back
membership/name after completion. Addition occurs before removal in replacement
operations. Membership changes preserve the group/zone UUID and unrelated members
when using incremental fields. General accessory, room, group, zone and Home
deletion remains unavailable. Guarded populated-bridge retirement is described
below.

| operation | Fields beyond homeID and operation |
| --- | --- |
| `create_group` | `name`, optional `serviceIDs` |
| `update_group` | `objectID`, optional `name`, and either `serviceIDs` replacement or `addServiceIDs`/`removeServiceIDs` |
| `create_zone` | `name`, optional `roomIDs` |
| `update_zone` | `objectID`, optional `name`, and either `roomIDs` replacement or `addRoomIDs`/`removeRoomIDs` |
| `rename_room` | `objectID`, `name` |

Replacement and incremental fields cannot be mixed. UUID lists must be unique
(maximum 512); addition/removal lists cannot overlap. Removal requires current
membership. Explicit empty replacement removes all members; this is not implied
by omitted fields. Rooms must belong to the same Home. Accessory room assignment
continues through `assign_accessory`; zones contain rooms, not accessories.

## Incremental scene actions

`patch_scene` resolves the union of `home.actionSets` and all trigger-owned action
sets by UUID, including built-in and owned sets. Inventory now exports the exact
`id` of every public action. Use any combination of:

- `actions`: add `{characteristicID, value}` scalar actions. An already identical
  single action is an idempotent no-op. A different/duplicate existing target is
  rejected; use its exact action UUID to update it.
- `actionUpdates`: `{actionID, value}` entries, updating only that scalar action's
  target value while retaining its action UUID.
- `removeActionIDs`: exact scalar action UUIDs to remove.

All additions/updates validate writable characteristics and their advertised
format/range/step/choices before any mutation. Numeric 0/1 is normalized only for
boolean characteristics; other numeric values, strings and numeric types retain
strict validation. Duplicate or overlapping patch targets are rejected. Combined
patches are bounded to 512 entries. Unsupported/hidden actions cannot be removed
or updated and remain untouched. Other action UUIDs are verified still present.
Patching does not run the scene or change any device state.

Whole-scene `update_scene` remains for fully exposed user-defined scenes only;
built-in and owned action sets require incremental patches. Owned action sets
cannot be executed, renamed or attached to another trigger through these tools.
Apple's public action API adds/removes separate action objects; updating an
existing scalar action uses its target-value API. See [Apple's action-set API](https://developer.apple.com/documentation/homekit/hmactionset/addaction(_:completionhandler:)).

## Native automation reference mapping

`remap_automation_references` accepts `objectID` for one event automation and
`referenceMappings` of `{sourceID, targetID}` characteristic UUIDs (1–64). Pairs
must be unique and unchained. Source/target characteristic types, formats,
units/steps, readable/notification support and complete advertised range/choice
coverage must agree. Narrower target ranges are rejected.

The operation replaces characteristic and threshold-range event references in
both start and end events. Calendar, solar, duration, location and custom-user
presence events remain the original native objects. Predicate surgery replaces
only matching HomeKit object constants inside native comparisons/compound trees;
comparison flags, AND/OR/NOT structure and every unrelated time/presence/custom
clause are retained. Source-bearing opaque expressions/custom selectors reject
the request rather than being approximated. No raw predicate text is accepted or
evaluated. Unexposed Apple Home shortcut internals remain uninspectable.

The app computes the complete rewrite before disabling the trigger. It restores
the prior enabled flag after reference read-back. Failure may leave the trigger
disabled, so retrieve its transaction and inspect state; never replay blindly.
A request with no mapped references does not toggle the trigger. This operation
changes trigger semantics and is a later, separately scoped migration step,
not part of adding scene/group counterparts. Unknown hidden references still
prevent claiming complete retirement coverage.

Full native rule recovery is **not** newly promised. The public snapshot retains
all exposed evidence, but exact native rules with unsupported clauses are not
reconstructed by the backup converter. Assess recovery before choosing a native
reference write; saved evidence and preserved clauses do not make every rule
change automatically reversible.

## Plan and validate before migration

`home_migration_plan` is read-only and accepts `homeID` and `pairs` of exact
accessory `{sourceID, targetID}` UUIDs. CLI equivalent:

```sh
python3 scripts/homekit_agent.py --local-bridge ~/Documents/AgentBridge migration-plan /private/path/pairs.json
```

It checks MAC/serial identity and ambiguity within bridges, then unique service
and characteristic types. It never guesses ordinal siblings or display names.
It audits capabilities, target values/ranges, conflicting/duplicate scene actions,
service-group membership, room/zone placement, and exported events/endEvents/
predicates. Hidden or zero-action sets and unsupported rule details remain
explicit blockers. It returns compatible **add-first** room/group/scene requests,
UUID maps, references, conservative native mapping candidates, blockers, and a
fingerprint of its observed configuration. A plan is not an execution or physical
proof; re-plan from fresh inventory before applying individual requests. Partial
compatible staging is possible while blockers remain, but must not be mistaken
for parity or retirement readiness.

1. Create a labelled, mirrored baseline and retain the backup ID.
2. Resolve hardware identity and compatibility from fresh inventory; inspect all
   blockers and choose the intended scope.
3. Add matching placements/group members/scene actions, retaining source references.
   Poll every returned transaction and independently compare fresh configuration.
4. Prove requested physical command parity only under explicit device-test scope;
   configuration/API agreement alone cannot establish delivery.
5. Resolve native rule and hidden references without dropping conditions. Obtain
   fresh backups and scoped recovery assessments before any later rule edits.
6. Remove source references/retire a bridge only in an explicitly authorized later
   step after all placement, rule, reachability, hidden-reference and physical gates
   pass. This release performs none of those removals or unpairing operations.

`retirementAllowed` and `physicalParityVerified` remain false in the planner;
these gates cannot be certified by a configuration-only tool.

## Bridge retirement through MCP

Build 8 advertises `bridgeRemovalVersion: 1`. MCP `home_change_execute` supports
`remove_bridge` with exact `homeID`, bridge `objectID`, the complete current
`bridgedAccessoryIDs`, and `auditedOpaqueSceneIDs`. No other change fields are
accepted. Refresh a cached MCP connection, or initialize a fresh stdio session
with the current client to discover this contract.

The child list must match the populated bridge exactly. The opaque scene list
must match all current zero-public-action and unsupported-action sets; it records
the operator's preceding audit, rather than claiming to inspect private audio or
shortcut internals. Keep that audit and command/reachability evidence with the
retirement receipt. The app refuses remaining scalar scene, service-group,
native start/end-event or predicate references to the bridge or its children.
Predicate inspection follows native function operands and collections without
evaluating or rewriting them; unknown expressions/events fail closed.

Removal saves a fresh Home/rule backup and repeats preflight, calls the public
HomeKit bridge-removal API, then checks absence of the bridge/children and
preservation of unrelated accessory, scene/action, group/member and automation
UUIDs. Independently read Home configuration and service health afterward.
Pairing removal has no automatic inverse: configuration snapshots do not
re-pair a bridge or recreate its original HomeKit UUIDs. Existing authorized
sessions and task scope govern execution; no approval sheet is introduced.

If Apple denies direct edits of a scalar trigger-owned set, create a verified
user-defined counterpart scene and change only the original trigger's attached
scene association through `update_automation`. This avoids reconstructing its
native events/predicate and preserves the trigger UUID and enabled state.
Independently compare every original rule field after the change. Do not use
this approach to reconstruct hidden actions or replay an uncertain failed edit.

## Recovery additions

`home_restore_preview`/`home_restore_apply` now accept:

- `kind: group`, fields `name`/`serviceIDs`;
- `kind: zone`, fields `name`/`roomIDs`;
- `kind: room`, field `name`;
- `kind: scene_patch`, field `actions`, optional unique `characteristic_ids` scope.

Membership recovery requires every saved member still present in the Home by
UUID, then restores membership/name with independent read-back. No recreation of
missing groups/zones/rooms is inferred. Scalar scene recovery computes additions,
exact-ID target updates and removals for the selected characteristic scope while
preserving hidden and unrelated actions. It works for built-in and owned sets;
restoring a removed scalar action creates a new action UUID, preserving the
scene UUID and semantic target. Older inventory backups lacking action IDs can
still supply saved scalar values, but current inventory must expose IDs before
updates/removals. An automatic patch receipt records its touched characteristic
scope, preventing rollback from deleting unrelated later additions. Use
`recovery.scope`, preview, a current planToken and require `configurationVerified`.
Creation and unsupported native-rule recovery retain their existing limitations.
