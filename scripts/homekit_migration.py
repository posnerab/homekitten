"""Read-only, staged migration planning. No physical commands or retirement operations."""
import hashlib
import json
import math
import re
import uuid

WRITABLE = 'HMCharacteristicPropertyWritable'
READABLE = 'HMCharacteristicPropertyReadable'
NOTIFY = 'HMCharacteristicPropertySupportsEventNotification'
SERIAL = '00000030-0000-1000-8000-0026BB765291'
INFORMATION = '0000003E-0000-1000-8000-0026BB765291'


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def uid(value):
    return str(uuid.UUID(value)).upper()


def one(items, identifier):
    values = [i for i in items if i['id'] == identifier]
    if len(values) != 1: raise ValueError('Exact UUID missing or ambiguous')
    return values[0]


def characteristics(home):
    return {c['id']: c for a in home['accessories'] for s in a['services'] for c in s['characteristics']}


def normalize(value, characteristic):
    fmt = characteristic.get('format')
    if fmt == 'bool':
        if type(value) is bool: return value
        if type(value) in (int, float) and value in (0, 1): return bool(value)
        raise ValueError('Bool targets require bool or numeric 0/1')
    if fmt == 'string':
        if type(value) is not str: raise ValueError('String target required')
        return value
    if type(value) not in (int, float) or not math.isfinite(value): raise ValueError('Finite numeric target required')
    if fmt not in ('int', 'float', 'uint8', 'uint16', 'uint32', 'uint64'): raise ValueError('Unsupported target format')
    if fmt != 'float' and value != int(value): raise ValueError('Integer target required')
    if characteristic.get('min') is not None and value < characteristic['min']: raise ValueError('Target below advertised minimum')
    if characteristic.get('max') is not None and value > characteristic['max']: raise ValueError('Target above advertised maximum')
    if characteristic.get('step'):
        steps = (value - (characteristic.get('min') or 0)) / characteristic['step']
        if abs(steps - round(steps)) >= 0.00001: raise ValueError('Target violates step size')
    if characteristic.get('validValues') and value not in characteristic['validValues']: raise ValueError('Target outside advertised choices')
    return value


def hardware(accessory):
    values = {re.sub(r'[^a-f0-9]', '', str(c.get('cachedValue', '')).lower())
              for s in accessory['services'] for c in s['characteristics'] if c['type'] == SERIAL}
    values = {v for v in values if len(v) == 12}
    if len(values) != 1: raise ValueError('Unique hardware MAC/serial unavailable; no name inference')
    return values.pop()


def migration_plan(inventory, homeID, pairs):
    home = one(inventory['homes'], uid(homeID))
    if not isinstance(pairs, list) or not 1 <= len(pairs) <= 128: raise ValueError('Provide 1–128 exact accessory pairs')
    sources, targets, service_map, char_map = set(), set(), {}, {}
    hardware_ids = set()
    blockers, matches, requests, references = [], [], [], []
    all_chars = characteristics(home)
    for pair in pairs:
        source_id, target_id = uid(pair['sourceID']), uid(pair['targetID'])
        if source_id == target_id or source_id in sources or target_id in targets or source_id in targets or target_id in sources:
            raise ValueError('Duplicate, overlapping or chained accessory pairs')
        sources.add(source_id); targets.add(target_id)
        source, target = one(home['accessories'], source_id), one(home['accessories'], target_id)
        try:
            mac = hardware(source)
            if mac != hardware(target): raise ValueError('Hardware MAC/serial mismatch')
            if mac in hardware_ids: raise ValueError('Repeated hardware identity across pairs; resolve ambiguity')
            hardware_ids.add(mac)
            for selected in (source, target):
                duplicates = []
                for accessory in home['accessories']:
                    if accessory.get('bridgeID') != selected.get('bridgeID') or accessory['id'] == selected['id']: continue
                    try:
                        if hardware(accessory) == mac: duplicates.append(accessory['id'])
                    except ValueError: pass
                if duplicates and selected.get('bridgeID'): raise ValueError('Hardware identity ambiguous within its source bridge')
            matches.append({'sourceID': source_id, 'targetID': target_id, 'hardwareIdentity': mac})
        except ValueError as error:
            blockers.append({'sourceID': source_id, 'targetID': target_id, 'reason': str(error)}); continue
        if not source.get('reachable', True) or not target.get('reachable', True):
            blockers.append({'sourceID': source_id, 'targetID': target_id, 'reason': 'Accessory reachability is not confirmed on both clients'})
        for old in source['services']:
            if old['type'] == INFORMATION: continue
            old_siblings = [s for s in source['services'] if s['type'] == old['type']]
            candidates = [s for s in target['services'] if s['type'] == old['type']]
            if len(old_siblings) != 1 or len(candidates) != 1:
                blockers.append({'serviceID': old['id'], 'reason': 'Service type missing or ambiguous; no ordinal guessing'}); continue
            new = candidates[0]; service_map[old['id']] = new['id']
            for old_char in old['characteristics']:
                choices = [c for c in new['characteristics'] if c['type'] == old_char['type']]
                original = [c for c in old['characteristics'] if c['type'] == old_char['type']]
                if len(choices) != 1 or len(original) != 1:
                    blockers.append({'characteristicID': old_char['id'], 'reason': 'Characteristic type missing or ambiguous'}); continue
                if choices[0].get('format') != old_char.get('format'):
                    blockers.append({'characteristicID': old_char['id'], 'reason': 'Characteristic format mismatch'}); continue
                char_map[old_char['id']] = choices[0]['id']
        if source.get('roomID') != target.get('roomID'):
            one(home['rooms'], source['roomID'])
            requests.append({'operation': 'assign_accessory', 'homeID': home['id'], 'objectID': target_id, 'roomID': source['roomID']})
    for group in home.get('groups', []):
        additions = sorted({service_map[s] for s in group['serviceIDs'] if s in service_map} - set(group['serviceIDs']))
        if additions: requests.append({'operation': 'update_group', 'homeID': home['id'], 'objectID': group['id'], 'addServiceIDs': additions})
        if any(s in service_map for s in group['serviceIDs']): references.append({'kind': 'group', 'id': group['id'], 'name': group['name']})
    for scene in home['scenes']:
        additions = []
        if not scene.get('actions'):
            blockers.append({'sceneID': scene['id'], 'reason': 'Zero public actions: hidden shortcut/audio references cannot be audited'})
        for action in scene['actions']:
            if action.get('kind') != 'characteristicWrite' or action.get('supported') is False:
                blockers.append({'sceneID': scene['id'], 'actionID': action.get('id'), 'reason': 'Hidden/unsupported action retained; retirement coverage unknown'}); continue
            source_char = action['characteristicID']
            if source_char not in char_map: continue
            target_char = char_map[source_char]
            references.append({'kind': 'sceneAction', 'sceneID': scene['id'], 'actionID': action.get('id'), 'sourceID': source_char, 'targetID': target_char})
            try:
                if WRITABLE not in all_chars[target_char]['properties']: raise ValueError('Target characteristic not writable')
                value = normalize(action['value'], all_chars[target_char])
                existing = [a for a in scene['actions'] if a.get('characteristicID') == target_char]
                if len(existing) > 1: raise ValueError('Duplicate target scene actions')
                if existing:
                    if normalize(existing[0]['value'], all_chars[target_char]) != value: raise ValueError('Target action conflicts with source target')
                else: additions.append({'characteristicID': target_char, 'value': value})
            except (ValueError, KeyError) as error:
                blockers.append({'sceneID': scene['id'], 'sourceCharacteristicID': source_char, 'targetCharacteristicID': target_char, 'reason': str(error)})
        if additions: requests.append({'operation': 'patch_scene', 'homeID': home['id'], 'objectID': scene['id'], 'actions': additions})
    # Audit all native event/end-event/predicate references; staging never changes trigger semantics.
    def walk(value, automation, path):
        if isinstance(value, dict):
            if value.get('supported') is False:
                blockers.append({'automationID': automation['id'], 'path': path, 'reason': 'Unsupported native rule detail retained; hidden reference coverage unknown'})
            reference = value.get('characteristicID') or (value.get('id') if value.get('kind') == 'characteristic' else None)
            if reference in char_map:
                target = all_chars[char_map[reference]]
                references.append({'kind': 'automationReference', 'automationID': automation['id'], 'path': path, 'sourceID': reference, 'targetID': target['id']})
                if not {READABLE, NOTIFY} <= set(target.get('properties', [])): blockers.append({'automationID': automation['id'], 'reason': 'Mapped trigger reference lacks read/notify support'})
                if 'triggerValue' in value:
                    try: normalize(value['triggerValue'], target)
                    except ValueError as error: blockers.append({'automationID': automation['id'], 'reason': str(error)})
            for key, child in value.items():
                if key not in ('format', 'actionSets'): walk(child, automation, path + '/' + key)
        elif isinstance(value, list):
            for index, child in enumerate(value): walk(child, automation, path + '/' + str(index))
    for automation in home['automations']:
        for field in ('events', 'endEvents', 'predicate'): walk(automation.get(field), automation, field)
    # Record conservative full-range compatibility for native reference rewrites.
    native_mapping = []
    for source, target in char_map.items():
        old, new = all_chars[source], all_chars[target]
        if not {READABLE, NOTIFY} <= set(new.get('properties', [])): continue
        narrow = (old.get('min') is not None and (new.get('min') is None or new['min'] > old['min'])) or (old.get('max') is not None and (new.get('max') is None or new['max'] < old['max']))
        if narrow:
            blockers.append({'sourceCharacteristicID': source, 'targetCharacteristicID': target, 'reason': 'Target does not prove full source range for native rule remapping'})
        elif old.get('unit', '') != new.get('unit', '') or old.get('step') != new.get('step'):
            blockers.append({'sourceCharacteristicID': source, 'targetCharacteristicID': target, 'reason': 'Native reference units/step mismatch'})
        elif old.get('validValues') and not set(old['validValues']) <= set(new.get('validValues', [])):
            blockers.append({'sourceCharacteristicID': source, 'targetCharacteristicID': target, 'reason': 'Native reference choices are not covered'})
        else: native_mapping.append({'sourceID': source, 'targetID': target})
    result = {'version': 1, 'homeID': home['id'], 'stage': 'add-counterparts', 'hardwareMatches': matches,
              'serviceMapping': service_map, 'characteristicMapping': char_map, 'nativeReferenceMapping': native_mapping,
              'requests': requests, 'references': references, 'blockers': blockers,
              'roomZones': {r['id']: [z['id'] for z in home.get('zones', []) if r['id'] in z['roomIDs']] for r in home['rooms']},
              'retirementAllowed': False, 'physicalParityVerified': False,
              'retirementGates': ['All selected placements and actions independently verified', 'Native rule references and hidden references resolved without dropping clauses',
                                  'Physical command parity explicitly proven', 'Offline hardware reconciled', 'Fresh backup retained before removal'],
              'note': 'Read-only plan. Counterparts are added first. No source removal, unpairing, scene execution or implicit rule rewrite.'}
    result['planToken'] = hashlib.sha256(canonical({'home': home, 'pairs': pairs, 'result': result}).encode()).hexdigest()
    return result
