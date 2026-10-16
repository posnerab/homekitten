import copy
import pathlib
import sys
import tempfile
import unittest
import uuid
from unittest.mock import Mock, patch
sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / 'scripts'))
import homekit_agent as agent
import homekit_backup as backup


class BackupParityTests(unittest.TestCase):
    def setUp(self):
        self.home, self.service, self.characteristic = [str(uuid.uuid4()).upper() for _ in range(3)]

    def test_threshold_bounds_and_capability_are_validated_before_transfer(self):
        request = {'operation': 'update_automation', 'homeID': self.home, 'objectID': self.service,
                   'events': [{'kind': 'threshold', 'characteristicID': self.characteristic, 'minValue': 30, 'maxValue': 60}]}
        agent.validate_automation_rules(copy.deepcopy(request))
        for bounds in ({}, {'minValue': True}, {'minValue': 50, 'maxValue': 10}, {'minValue': float('inf')}):
            bad = copy.deepcopy(request);bad['events'][0] = dict(kind='threshold', characteristicID=self.characteristic, **bounds)
            with self.assertRaises(ValueError): agent.validate_automation_rules(bad)
        client = agent.Client('fixture')
        with patch.object(client, 'inventory', return_value={'active':True, 'writesAllowed':True, 'automationWritesVersion':1}), patch.object(client, 'transfer') as transfer:
            with self.assertRaisesRegex(RuntimeError, 'thresholdWritesVersion'): client.submit(request)
            transfer.assert_not_called()
        self.assertEqual(backup.event({'kind':'HMCharacteristicThresholdRangeEvent','characteristicID':self.characteristic,'thresholdRange':{'min':None,'max':55}}),
                         {'kind':'threshold','characteristicID':self.characteristic,'maxValue':55})

    def test_structural_operations_reject_unrelated_fields_and_unsupported_types(self):
        for op in ('delete_room', 'delete_group', 'delete_zone', 'normalize_automation_conditions'):
            base = {'operation':op, 'homeID':self.home, 'objectID':self.service}
            agent.validate_extension(base)
            for key,value in (('name','bad'),('roomIDs',[]),('conditions',{})):
                with self.assertRaises(ValueError): agent.validate_extension(dict(base, **{key:value}))
        with self.assertRaises(ValueError): agent.validate_extension({'operation':'set_service_type','homeID':self.home,'objectID':self.service,'associatedServiceType':'bad'})

    def test_service_recovery_is_exact_and_legacy_missing_type_blocks_whole_selection(self):
        service = {'id':self.service,'name':'Saved','associatedServiceType':''}
        inventory = {'homes':[{'id':self.home,'accessories':[{'services':[service]}]}]}
        current = copy.deepcopy(inventory);current['homes'][0]['accessories'][0]['services'][0]['name'] = 'Changed'
        with tempfile.TemporaryDirectory() as temp:
            store = backup.BackupStore(temp);saved = store.capture(inventory)
            client = Mock();client.inventory.return_value = current
            plan = backup.plan(store, client, saved['id'], self.home, 'service', self.service)
            self.assertEqual(plan['requests'], [{'operation':'rename_service','homeID':self.home,'objectID':self.service,'name':'Saved'}])
            service.pop('associatedServiceType');saved = store.capture(inventory)
            plan = backup.plan(store, client, saved['id'], self.home, 'service', self.service)
            self.assertTrue(plan['blocked']);self.assertEqual(plan['requests'], [])
