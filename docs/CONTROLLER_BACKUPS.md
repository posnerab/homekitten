# Controller backup interoperability and configuration coverage

HomeKitten can read Controller for HomeKit's legacy `.backup` format locally on
macOS. The attachment is base64 wrapping AES-128-CBC/PKCS7 ciphertext; its payload
is UTF-8 YAML. The legacy format uses fixed compatibility constants, not the
user's account password. New or different formats are rejected. There is no
network service, account access, DRM modification or HomeKit write in the decoder.

```sh
python3 scripts/controller_backup.py /private/path/example.backup --output /private/path/new-export.yaml --archive
```

`--output` creates a new mode-0600 file and refuses to overwrite an existing file.
The parent directory must already exist. Decoded contents are never printed.
`--archive` retains the **exact original attachment** and the complete decoded YAML,
including unknown fields, inside a checksum-verified backup-store record. Existing
primary and mirror settings apply; mirror failure is reported. Archive records
have status `external_archive` and no HomeKitten Home inventory, so automatic
restore cannot accidentally replay them. No YAML parser or dependency is needed.
Legacy CBC is unauthenticated: padding/schema checks establish readability, and
archive checksums establish storage integrity, neither establishes authenticity.

These files may include manually entered HomeKit pairing codes, accessory serials,
locations, icons and app-specific ordering. Keep originals, decoded files and
archives private and outside Git. Controller IDs are scoped to Controller's
HomeKit client. They are not automatically mapped to HomeKitten IDs by name.

## Closed gaps in build 13 / client 1.7.0

- Native UI, app pre-write and agent inventory backups now share a complete public
  configuration serializer. New native backups embed a readable `configuration`
  tree and `configurationVersion: 3`, while old backups remain readable.
- The tree includes the default room, zone membership, complete services and
  characteristics, associated service type, linked/primary/interactive service
  metadata, numeric limits/choices/step, maximum string length, manufacturer
  descriptions, cached values, home scenes **and trigger-owned scenes**, unsupported
  action markers, complete public event/predicate/recurrence/timer information.
- Native backup details offer **Export Backup JSON**. Native restore resolves exact
  UUIDs and preflights references instead of substituting names, skipping missing
  scene actions or recreating incomplete timers. It refuses legacy/opaque scene
  replacement; automation restore explicitly covers name, enabled state and scene
  links only. Agent recovery remains the detailed rule-recovery path.
- `rename_service` changes the exact service UUID's name. `set_service_type` changes
  a switch/outlet's associated fan/lightbulb/outlet presentation; empty string clears
  it. Both support scoped `service` backup recovery.
- `delete_room`, `delete_group`, `delete_zone` accept only Home/target UUIDs. Objects
  must be empty; rooms must be ordinary rooms with no zone membership. Native
  automation references block deletion. Nothing cascades; absence is checked.
- Numeric threshold events can be written and recovered with lower/upper bounds.
  See [the agent contract](USB_AGENT.md#controller-comparison-extensions).
- Condition summaries recurse through every AND/OR/NOT branch. They pair a
  characteristic reference only with the value comparison in its exact factory
  subtree, never with a similarly typed accessory or another branch's value.
  Inventory retains the raw predicate and adds `conditionSummary`/`conditionIssues`.
  An isolated accessory reference is shown as **without a value comparison**.
  It is not guessed to mean on/off or silently dropped during edits/recovery.

## Remaining boundaries

The Controller archive retains its app-specific icons, sorting and manually
stored pairing codes. These are not publicly readable HomeKit configuration and
cannot be rediscovered through HomeKitten's HomeKit connection. An archive is not
an automatic Controller-to-HomeKitten migration or a paired-accessory recovery
image. Hidden Apple Home shortcut/audio actions, custom presence-user lists,
pairing keys and user permissions remain unavailable. No API implementation is
claimed for these private internals.

HomeKitten's existing declarative writer still cannot reconstruct every native
time/presence/threshold/custom expression, location event or timer recurrence.
Unsupported rules remain fully retained as public structured evidence and block
lossy automatic restore. Whole-home recreation or cross-client UUID mapping needs
an explicitly designed migration, not a display-name fallback. Arbitrary paired
accessory/Home/user deletion is outside this release; populated bridge retirement
retains its separate child/reference/opaque-action audit.

Configuration read-back does not verify physical execution. New deletion/service
and threshold capabilities are validated by unit/build checks and advertised by
`structuralWritesVersion: 1` / `thresholdWritesVersion: 1`; do not create/delete
live Home objects just to test availability. Refresh MCP clients after updating.

## Controller grouped-condition round trips (build 14 / client 1.7.1)

A valid HomeKit predicate can still fail another app's backup round trip. In the
observed Controller backup, repeatedly nested AND groups retained only shallow
characteristic conditions and omitted deeper time/presence/switch clauses. A clean
`conditionIssues` list describes semantic reference/comparison checks; it does not
establish Controller export compatibility.

`normalize_automation_conditions` accepts only `homeID` and exact automation
`objectID` alongside the operation. It flattens redundant native AND nesting,
retaining characteristic identity/value factory pairs as intact leaves. OR, NOT,
solar/time, presence, comparison flags and object constants remain untouched; no
raw predicate or reconstruction passes through the client. The app backs up first,
disables the target during the update, verifies the complete native predicate and
then restores its enabled state. No-op canonical rules are left untouched. Failed
writes/read-back can leave a trigger disabled; retrieve its transaction before any
retry. Original grouping is retained as evidence; generic rule recovery cannot
replay every native clause.

Inventory advertises `conditionNormalizationVersion: 1` and includes
`conditionGroupingStatus` (`nestedConjunctions`, `canonical`, `noPredicate`, or
`unsupportedNormalization`). `nestedConjunctions` is a compatibility cue, not a
claim that HomeKit logic is invalid or that every third-party app will fail.
Future MCP AND writes and native condition appends apply the same canonicalization
so redundant wrappers do not accumulate again. Confirm Controller's actual rule
view and a newly created backup separately from HomeKit configuration read-back.
