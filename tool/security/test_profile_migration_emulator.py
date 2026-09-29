"""Execute migration plan only against hardcoded demo loopback emulator."""
from plan_private_profile_migration import make_plan
from test_strict_rules import commit, get, write


def snapshot(path):
    status, doc = get(path, 'owner')
    assert status == 200
    return doc


path = 'users/migration-fixture'
source = {'uid':'migration-fixture','fullName':'Local Fixture','email':'private@example.test',
          'balance':27,'role':'user','gifts':{'one':1}}
assert commit('owner',write(path,source))[0] == 200
plan = make_plan([snapshot(path)])
status, detail = commit('owner',*plan['atomicBatches'][0]['writes'])
assert status == 200, detail
migrated = snapshot(path)['fields']
assert 'email' not in migrated
assert migrated['balance']['integerValue'] == '27'
assert migrated['gifts']['mapValue']['fields']['one']['integerValue'] == '1'
assert snapshot('private_users/migration-fixture')['fields']['email']['stringValue'] == source['email']
assert set(snapshot('public_profiles/migration-fixture')['fields']) == {'uid','fullName'}
print('PASS atomic email move preserves balance/gifts and safe public projection')

# A repeat with no legacy email must not erase the legacy document or private copy.
plan = make_plan([snapshot(path)])
status, detail = commit('owner',*plan['atomicBatches'][0]['writes'])
assert status == 200, detail
assert snapshot(path)['fields'] == migrated
assert snapshot('private_users/migration-fixture')['fields']['email']['stringValue'] == source['email']
print('PASS no-email repeat preserves all existing data')

# Changing the source after export must fail the whole batch, not partly migrate.
assert commit('owner',write(path,{'email':'stale@example.test'},patch=True))[0] == 200
stale_plan = make_plan([snapshot(path)])
assert commit('owner',write(path,{'email':'current@example.test','fullName':'New'},patch=True))[0] == 200
before_public = snapshot('public_profiles/migration-fixture')['fields']
status, detail = commit('owner',*stale_plan['atomicBatches'][0]['writes'])
assert status == 400 and detail.get('error',{}).get('status') == 'FAILED_PRECONDITION', detail
assert snapshot(path)['fields']['email']['stringValue'] == 'current@example.test'
assert snapshot('private_users/migration-fixture')['fields']['email']['stringValue'] == source['email']
assert snapshot('public_profiles/migration-fixture')['fields'] == before_public
print('PASS stale snapshot rejects entire batch without overwriting current email')
