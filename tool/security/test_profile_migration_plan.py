import copy
import unittest
from plan_private_profile_migration import make_plan


class ProfileMigrationPlanTest(unittest.TestCase):
    def setUp(self):
        self.doc = {'name':'projects/demo-clrs-security/databases/(default)/documents/users/alice',
                    'updateTime':'2026-09-28T00:00:00Z',
                    'fields':{'uid':{'stringValue':'alice'}, 'fullName':{'stringValue':'Alice'},
                              'email':{'stringValue':'private@example.test'},
                              'balance':{'integerValue':'27'},'role':{'stringValue':'admin'},
                              'token':{'stringValue':'private-token'},'gifts':{'mapValue':{}}}}

    def test_safe_projection_does_not_contain_private_fields(self):
        batch = make_plan([self.doc])['atomicBatches'][0]
        public = batch['writes'][0]['update']['fields']
        self.assertEqual(set(public), {'uid','fullName'})

    def test_private_copy_and_delete_are_atomic_and_version_guarded(self):
        writes = make_plan([self.doc])['atomicBatches'][0]['writes']
        self.assertTrue(writes[1]['update']['name'].endswith('/private_users/alice'))
        self.assertEqual(writes[1]['updateMask']['fieldPaths'], ['email'])
        self.assertEqual(writes[2]['update']['fields'], {})
        self.assertEqual(writes[2]['updateMask']['fieldPaths'], ['email'])
        self.assertEqual(writes[2]['currentDocument']['updateTime'], self.doc['updateTime'])

    def test_original_export_is_unchanged(self):
        before = copy.deepcopy(self.doc)
        plan = make_plan([self.doc])
        self.assertEqual(self.doc,before)
        self.assertTrue(plan['reviewOnly'])
        self.assertFalse(plan['productionApproved'])

    def test_hidden_profile_is_not_projected_publicly(self):
        for key, value in [('status', {'stringValue':'deleted'}), ('isUnvisible',{'booleanValue':True})]:
            source = copy.deepcopy(self.doc)
            source['fields'][key] = value
            writes = make_plan([source])['atomicBatches'][0]['writes']
            self.assertIn('delete', writes[0])

    def test_missing_email_does_not_erase_private_document(self):
        del self.doc['fields']['email']
        plan = make_plan([self.doc])
        self.assertEqual(plan['privateEmailDocuments'],0)
        writes = plan['atomicBatches'][0]['writes']
        self.assertEqual(len(writes),2)
        self.assertEqual(writes[1]['updateMask'], {'fieldPaths':[]})

    def test_invalid_source_or_missing_version_rejected(self):
        for key,value in [('name','projects/demo/databases/(default)/documents/chats/one'),('updateTime','')]:
            source = copy.deepcopy(self.doc)
            source[key] = value
            with self.assertRaises(ValueError):
                make_plan([source])


if __name__ == '__main__':
    unittest.main()
