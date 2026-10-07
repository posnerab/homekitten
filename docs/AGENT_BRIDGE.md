# HomeKitten agent bridge

This is the original Mac Catalyst architecture proposal. The implemented
iPhone bridge uses the paired-device file service instead of a network server;
see [USB agent usage](USB_AGENT.md) for its actual protocol and supported scope.

## Goal

Let a locally paired coding agent inspect and manage the Apple Home database
through HomeKitten, without turning the signed HomeKit application into an
unauthenticated LAN or shell API. The bridge complements HomeKitten's existing
interactive management UI; it does not replace the Apple Home permission
model.

## Constraints

- HomeKitten is the only component that talks to `HMHomeManager`. It remains a
  signed Mac Catalyst app with the HomeKit entitlement.
- The system permission prompt is owned by macOS. A bridge cannot grant,
  bypass, or retain access after the user revokes it.
- HomeKit identifiers are stable inputs. Display names are only search aids;
  writes must resolve to a unique HomeKit UUID and return the resolved object
  in their preview.
- Accessory setup, invitations, homes, and destructive removal stay out of
  version one. They require separate product and safety review.

## Design

```
Codex MCP client
       │ local request
       ▼
paired localhost MCP server ───── audit log (redacted)
       │ authenticated RPC
       ▼
HomeKitten (foreground, signed, HomeKit-authorized)
       │ HomeKit framework
       ▼
Apple Home database and accessories
```

The MCP server is local-only and has no LAN listener. HomeKitten generates a
pairing secret on demand, stores it in the user Keychain, and presents a QR or
one-time pairing flow. The secret is never checked into the repository,
printed, supplied as a command-line argument, or written to an MCP registry.

Every request carries a unique transaction ID. HomeKitten records the requested
operation, resolved HomeKit UUIDs, outcome, and timestamp in a local redacted
audit log. It never records characteristic values that could disclose occupancy
or sensor history unless the user explicitly exports a backup.

## Tools and approval policy

| Tool family | Initial scope | Approval |
| --- | --- | --- |
| `home_list`, `home_get`, `accessory_list`, `scene_list`, `automation_list` | Read current configuration and readable characteristic values | Paired session; no per-call sheet |
| `characteristic_set` | Write one writable characteristic | Preview plus a HomeKitten approval sheet |
| `scene_create`, `scene_update`, `scene_run` | Manage or invoke action sets | Preview plus approval |
| `automation_create`, `automation_update`, `automation_enable` | Manage timer and characteristic-event triggers | Preview plus approval |
| `room_update`, `group_update` | Rename or organize existing HomeKit objects | Preview plus approval |
| `scene_delete`, `automation_delete`, `room_delete`, `group_delete` | Destructive removal | Typed-name confirmation in HomeKitten |

The agent first calls a `*_preview` operation for each write. The preview
contains the exact object UUIDs, prior values where readable, proposed values,
and any invalid/ambiguous name matches. A confirm token is short-lived,
single-use, and is only issued after the user accepts the HomeKitten sheet.
Writes never execute solely because a text request names an accessory.

## Required implementation phases

1. Add a local bridge controller to HomeKitten that owns pairing state,
   transaction previews, confirmation sheets, and redacted audit records.
2. Add a loopback-only authenticated transport and a tiny local MCP server.
   Deny requests while HomeKitten is locked, unavailable, or not authorized.
3. Implement read-only tools and verify their returned UUID hierarchy against a
   signed HomeKitten session.
4. Implement one reversible write (`characteristic_set`) with a visible
   confirmation and read-back verification.
5. Add scene and automation builders using HomeKit's action-set and trigger
   APIs, retaining the existing backup-before-reassignment workflow.
6. Add destructive operations only after backup/export, typed-name
   confirmation, and a successful restore rehearsal in a test home.

## At-home setup checklist

1. In Xcode, select the user's Apple Developer team for the HomeKitten target
   and keep the existing HomeKit capability enabled.
2. Register a unique App ID and let Xcode create the Mac Catalyst development
   provisioning profile. Do not use ad-hoc signing.
3. Run HomeKitten from Xcode and accept the macOS Home access prompt. Confirm
   that the app shows the expected homes before any bridge work.
4. Install the chosen local MCP-development utility only after choosing the
   transport implementation. The bridge does not need any cloud endpoint.
5. Pair one local Codex session, test reads, and test a reversible light or
   outlet write. Verify it in Apple Home before enabling scene or automation
   changes.

## Validation gates

- Unit-test request decoding, UUID resolution, approval expiry, confirmation
  replay rejection, and audit redaction without HomeKit access.
- Build unsigned in CI for source validation; a signed local build is required
  for actual HomeKit use.
- Verify each successful write by reading the characteristic again and by
  confirming the change in Apple Home.
- Never treat a completed API callback as visual or physical-device
  confirmation.
