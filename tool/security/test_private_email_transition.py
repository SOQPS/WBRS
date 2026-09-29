import copy
import unittest

from private_email_transition import prepare_email_transition, prepare_email_rollback


PROJECT = 'demo-clrs-email'
BASE = f'projects/{PROJECT}/databases/(default)/documents'
SOURCE = {'name': f'{BASE}/users/alice', 'updateTime': '2026-09-28T19:00:00.123456789Z',
          'fields': {'uid': {'stringValue': 'alice'},
                     'email': {'stringValue': 'private@example.test'},
                     'balance': {'integerValue': '27'},
                     'gifts': {'mapValue': {'fields': {'one': {'integerValue': '1'}}}}}}
PRIVATE = {'name': f'{BASE}/private_users/alice', 'updateTime': '2026-09-28T18:00:00Z',
           'fields': {'otherPrivateField': {'stringValue': 'preserve'}}}
RECEIPT = {'commitTime': '2026-09-28T20:00:00.999Z',
           'writeResults': [{'updateTime': '2026-09-28T20:00:00.999Z'},
                            {'updateTime': '2026-09-28T20:00:00.999Z'}]}


class PrivateEmailTransitionTest(unittest.TestCase):
    def plan(self, source=SOURCE, private=None):
        return prepare_email_transition(source, private, expected_project=PROJECT)

    def test_two_email_fields_only_in_one_atomic_commit(self):
        plan = self.plan(private=PRIVATE)
        self.assertEqual(len(plan['writes']), 2)
        self.assertEqual(plan['writes'][0]['updateMask']['fieldPaths'], ['email'])
        self.assertEqual(plan['writes'][1]['updateMask']['fieldPaths'], ['email'])
        self.assertNotIn('balance', repr(plan))
        self.assertNotIn('gifts', repr(plan))
        self.assertNotIn('otherPrivateField', repr(plan))
        self.assertTrue(plan['reviewOnly'])

    def test_creation_and_both_existing_versions_guarded(self):
        plan = self.plan()
        self.assertEqual(plan['writes'][0]['currentDocument'], {'exists': False})
        plan = self.plan(private=PRIVATE)
        self.assertEqual(plan['writes'][0]['currentDocument']['updateTime'], PRIVATE['updateTime'])
        self.assertEqual(plan['writes'][1]['currentDocument']['updateTime'], SOURCE['updateTime'])

    def test_conflicting_private_copy_never_overwritten(self):
        private = copy.deepcopy(PRIVATE)
        private['fields']['email'] = {'stringValue': 'different@example.test'}
        with self.assertRaisesRegex(ValueError, '^private_email_conflict$'):
            self.plan(private=private)

    def test_identical_private_copy_is_preserved_by_rollback(self):
        private = copy.deepcopy(PRIVATE)
        private['fields']['email'] = SOURCE['fields']['email']
        rollback = prepare_email_rollback(self.plan(private=private), RECEIPT)
        self.assertEqual(rollback['writes'][1]['update']['fields'], {'email': SOURCE['fields']['email']})

    def test_no_email_is_a_noop_not_a_destination_delete(self):
        source = copy.deepcopy(SOURCE)
        source['fields'].pop('email')
        self.assertEqual(self.plan(source=source, private=PRIVATE)['writes'], [])

    def test_rollback_new_private_document_is_version_guarded(self):
        rollback = prepare_email_rollback(self.plan(), RECEIPT)
        self.assertEqual(rollback['writes'][0]['update']['fields'], {'email': SOURCE['fields']['email']})
        self.assertEqual(rollback['writes'][1]['delete'], f'{BASE}/private_users/alice')
        for write in rollback['writes']:
            self.assertEqual(write['currentDocument']['updateTime'], RECEIPT['commitTime'])

    def test_rollback_existing_private_document_removes_only_copied_field(self):
        rollback = prepare_email_rollback(self.plan(private=PRIVATE), RECEIPT)
        self.assertEqual(rollback['writes'][1]['update']['fields'], {})
        self.assertEqual(rollback['writes'][1]['updateMask'], {'fieldPaths': ['email']})
        self.assertNotIn('delete', rollback['writes'][1])

    def test_scope_uid_and_versions_fail_closed_without_private_error_details(self):
        cases = [('name', f'{BASE}/chats/alice'), ('name', f'projects/other/databases/(default)/documents/users/alice'),
                 ('updateTime', ''), ('updateTime', '2026-99-28T18:00:00Z')]
        for key, value in cases:
            source = copy.deepcopy(SOURCE); source[key] = value
            with self.assertRaises(ValueError): self.plan(source=source)
        source = copy.deepcopy(SOURCE); source['fields']['uid'] = {'stringValue': 'bob'}
        with self.assertRaisesRegex(ValueError, '^source_owner_mismatch$'): self.plan(source=source)
        private = copy.deepcopy(PRIVATE); private['name'] = f'{BASE}/private_users/bob'
        with self.assertRaisesRegex(ValueError, '^unexpected_destination_scope$'): self.plan(private=private)

    def test_receipt_required_and_inputs_unchanged(self):
        before = copy.deepcopy((SOURCE, PRIVATE, RECEIPT))
        plan = self.plan(private=PRIVATE)
        for receipt in [{}, {'writeResults': []}, {'writeResults': RECEIPT['writeResults'], 'commitTime': 'bad'}]:
            with self.assertRaises(ValueError): prepare_email_rollback(plan, receipt)
        prepare_email_rollback(plan, RECEIPT)
        self.assertEqual((SOURCE, PRIVATE, RECEIPT), before)


if __name__ == '__main__':
    unittest.main()
