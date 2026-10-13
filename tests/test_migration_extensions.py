import copy
import json
import pathlib
import sys
import tempfile
import unittest
import uuid
from unittest.mock import Mock, patch

sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / 'scripts'))
import homekit_agent as agent
import homekit_backup as backup
import homekit_migration as migration


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.ids = [str(uuid.uuid4()).upper() for _ in range(12)]
        h,old,new,os,ns,oc,nc,scene,action,group,room,zone=self.ids
        def characteristic(id):
            return {'id':id,'type':'00000025-0000-1000-8000-0026BB765291','format':'bool','min':None,'max':None,
                    'properties':[migration.READABLE,migration.WRITABLE,migration.NOTIFY]}
        def accessory(id,s,c):
            return {'id':id,'name':'identical name','roomID':room,'services':[{'id':s,'type':'00000043-0000-1000-8000-0026BB765291',
                     'characteristics':[characteristic(c),{'id':str(uuid.uuid4()).upper(),'type':migration.SERIAL,'cachedValue':'aa:bb:cc:dd:ee:ff'}]}]}
        self.home={'id':h,'accessories':[accessory(old,os,oc),accessory(new,ns,nc)],'rooms':[{'id':room,'name':'Room'}],
                   'scenes':[{'id':scene,'name':'Owned','type':'HMActionSetTypeTriggerOwned','actions':[{'id':action,'kind':'characteristicWrite','characteristicID':oc,'value':1}]}],
                   'groups':[{'id':group,'name':'Group','serviceIDs':[os]}],'zones':[{'id':zone,'name':'Zone','roomIDs':[room]}],'automations':[]}
        self.inventory={'active':True,'writesAllowed':True,'sessionID':'session','homes':[self.home],
                        'incrementalSceneWritesVersion':1,'membershipWritesVersion':1,'booleanNormalizationVersion':1}
        self.pairs=[{'sourceID':old,'targetID':new}]
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        env=patch.dict(agent.os.environ,{'HOMEKITTEN_BACKUP_DIR':self.temp.name});env.start();self.addCleanup(env.stop)

    def plan(self):return migration.migration_plan(self.inventory,self.home['id'],self.pairs)

    def test_stage_maps_hardware_adds_owned_actions_and_groups_without_removal(self):
        p=self.plan();self.assertEqual(len(p['hardwareMatches']),1)
        patch_scene=next(r for r in p['requests'] if r['operation']=='patch_scene')
        self.assertIs(patch_scene['actions'][0]['value'],True)
        self.assertEqual(next(r for r in p['requests'] if r['operation']=='update_group')['addServiceIDs'],[self.ids[4]])
        self.assertFalse(p['retirementAllowed']);self.assertFalse(p['physicalParityVerified'])
        self.assertTrue(all(not any('remove' in k.lower() for k in r) for r in p['requests']))

    def test_names_do_not_match_hardware_and_ambiguous_types_do_not_guess(self):
        self.home['accessories'][1]['services'][0]['characteristics'][1]['cachedValue']='112233445566'
        p=self.plan();self.assertFalse(p['hardwareMatches']);self.assertTrue(p['blockers']);self.assertEqual(p['requests'],[])
        self.home['accessories'][1]['services'][0]['characteristics'][1]['cachedValue']='aabbccddeeff'
        self.home['accessories'][1]['services'].append(copy.deepcopy(self.home['accessories'][1]['services'][0]))
        p=self.plan();self.assertTrue(any('ambiguous' in b['reason'] for b in p['blockers']))

    def test_staging_is_idempotent_and_target_conflicts_block(self):
        scene=self.home['scenes'][0];scene['actions'].append({'id':str(uuid.uuid4()),'kind':'characteristicWrite','characteristicID':self.ids[6],'value':True})
        self.home['groups'][0]['serviceIDs'].append(self.ids[4])
        self.assertEqual(self.plan()['requests'],[])
        scene['actions'][-1]['value']=False
        self.assertTrue(any('conflicts' in b['reason'] for b in self.plan()['blockers']))

    def test_temperature_range_mismatch_never_clamps_scene_value(self):
        for accessory in self.home['accessories']:
            c=accessory['services'][0]['characteristics'][0];c.update(format='uint32',min=140,max=500)
        self.home['accessories'][1]['services'][0]['characteristics'][0].update(min=154,max=455)
        self.home['scenes'][0]['actions'][0]['value']=500
        p=self.plan();self.assertTrue(any('maximum' in b['reason'] for b in p['blockers']))
        self.assertFalse(any(r['operation']=='patch_scene' for r in p['requests']))
        self.assertEqual(self.home['scenes'][0]['actions'][0]['value'],500)

    def test_hidden_actions_remain_and_retirement_is_blocked(self):
        self.home['scenes'][0]['actions'].append({'id':str(uuid.uuid4()),'kind':'Shortcut','supported':False})
        p=self.plan();self.assertTrue(any('Hidden' in b['reason'] for b in p['blockers']))
        self.assertEqual(next(r for r in p['requests'] if r['operation']=='patch_scene')['actions'][0]['characteristicID'],self.ids[6])

    def test_bool_normalization_does_not_weaken_numeric_types(self):
        for value,result in [(0,False),(1,True),(False,False),(True,True)]:self.assertIs(migration.normalize(value,{'format':'bool'}),result)
        for value in (2,-1,0.5,'1'):
            with self.assertRaises(ValueError):migration.normalize(value,{'format':'bool'})
        for value in (True,False):
            with self.assertRaises(ValueError):migration.normalize(value,{'format':'uint8','min':0,'max':100})
        self.assertEqual(migration.normalize(1,{'format':'uint8','min':0,'max':100}),1)
        for value in (1.5,101,float('nan')):
            with self.assertRaises(ValueError):migration.normalize(value,{'format':'uint8','min':0,'max':100})

    def test_bad_patch_lists_overlap_and_wrong_capability_never_transfer(self):
        client=agent.Client('device')
        base={'operation':'patch_scene','homeID':self.ids[0],'objectID':self.ids[7]}
        bad=[dict(base,removeActionIDs=[self.ids[8]],actionUpdates=[{'actionID':self.ids[8],'value':False}]),
             dict(base,actions=[{'characteristicID':self.ids[6],'value':True}]*2),dict(base,serviceIDs=[self.ids[4]])]
        with patch.object(client,'inventory',return_value=self.inventory),patch.object(client,'transfer') as transfer:
            for request in bad:
                with self.assertRaises(ValueError):client.submit(request)
            transfer.assert_not_called()
        old=dict(self.inventory,incrementalSceneWritesVersion=0)
        with patch.object(client,'inventory',return_value=old),patch.object(client,'transfer') as transfer:
            with self.assertRaises(RuntimeError):client.submit(dict(base,actions=[{'characteristicID':self.ids[6],'value':True}]))
            transfer.assert_not_called()

    def test_client_bool_patch_is_backed_up_before_publication(self):
        client=agent.Client('device');sent=[]
        def transfer(direction,source,destination):
            request=json.loads(pathlib.Path(source).read_text());record=backup.BackupStore().load(request['id'])
            self.assertEqual(record['status'],'submission_indeterminate');self.assertEqual(record['inventory'],self.inventory)
            sent.append(request)
        with patch.object(client,'inventory',return_value=self.inventory),patch.object(client,'transfer',side_effect=transfer):
            result=client.submit({'operation':'patch_scene','homeID':self.ids[0],'objectID':self.ids[7],
                                  'actions':[{'characteristicID':self.ids[6],'value':0}]})
        self.assertIs(sent[0]['actions'][0]['value'],False)
        self.assertEqual(result['recovery']['scope']['kind'],'scene_patch')
        self.assertEqual(result['recovery']['scope']['characteristic_ids'],[self.ids[6]])

    def test_lowercase_characteristic_ids_are_normalized_before_backup(self):
        client=agent.Client('device');sent=[]
        with patch.object(client,'inventory',return_value=self.inventory),patch.object(client,'transfer',side_effect=lambda _,source,destination:sent.append(json.loads(pathlib.Path(source).read_text()))):
            client.submit({'operation':'patch_scene','homeID':self.ids[0].lower(),'objectID':self.ids[7].lower(),
                           'actions':[{'characteristicID':self.ids[6].lower(),'value':1}]})
        self.assertEqual(sent[0]['actions'][0]['characteristicID'],self.ids[6])
        self.assertIs(sent[0]['actions'][0]['value'],True)

    def test_owned_scalar_recovery_preserves_hidden_and_unrelated_new_actions(self):
        store=backup.BackupStore();saved=store.capture(copy.deepcopy(self.inventory))
        current=copy.deepcopy(self.inventory);scene=current['homes'][0]['scenes'][0]
        hidden={'id':str(uuid.uuid4()),'kind':'Shortcut','supported':False};scene['actions'].append(hidden)
        scene['actions'].append({'id':str(uuid.uuid4()),'kind':'characteristicWrite','characteristicID':self.ids[6],'value':True})
        client=Mock();client.inventory.return_value=current
        p=backup.plan(store,client,saved['id'],self.ids[0],'scene_patch',self.ids[7],fields=['actions'],characteristic_ids=[self.ids[6]])
        self.assertEqual(p['requests'][0]['removeActionIDs'],[scene['actions'][-1]['id']])
        self.assertNotIn(hidden['id'],p['requests'][0]['removeActionIDs'])
        self.assertEqual(len(p['requests'][0]),4)

    def test_membership_recovery_preserves_uuid_and_validates_all_saved_members(self):
        store=backup.BackupStore();saved=store.capture(copy.deepcopy(self.inventory));current=copy.deepcopy(self.inventory)
        current['homes'][0]['groups'][0]['serviceIDs'].append(self.ids[4]);client=Mock();client.inventory.return_value=current
        p=backup.plan(store,client,saved['id'],self.ids[0],'group',self.ids[9],fields=['serviceIDs'])
        self.assertEqual(p['requests'][0],{'operation':'update_group','homeID':self.ids[0],'objectID':self.ids[9],'serviceIDs':[self.ids[3]]})
        current['homes'][0]['accessories'][0]['services']=[]
        self.assertTrue(backup.plan(store,client,saved['id'],self.ids[0],'group',self.ids[9])['blocked'])

if __name__=='__main__':unittest.main()
