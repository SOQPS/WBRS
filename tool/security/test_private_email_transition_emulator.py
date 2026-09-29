"""Exact-scope integration test, fixed localhost/demo project, synthetic data only."""
import json
import urllib.error
import urllib.request

from private_email_transition import prepare_email_transition, prepare_email_rollback


PROJECT = 'demo-clrs-local'
BASE = f'projects/{PROJECT}/databases/(default)/documents'
API = 'http://127.0.0.1:8080/v1/'
PREFIX = 'qa-email-transition-20260928-'
created = []


def call(path, payload=None):
    request = urllib.request.Request(API + path,
        data=None if payload is None else json.dumps(payload).encode(),
        headers={'Authorization': 'Bearer owner', 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())


def read(name):
    status, body = call(name)
    assert status in (200, 404), status
    return body if status == 200 else None


def commit(writes):
    return call(BASE + ':commit', {'writes': writes})


def fixture(suffix, private=False):
    uid = PREFIX + suffix
    source = BASE + '/users/' + uid
    target = BASE + '/private_users/' + uid
    assert read(source) is None and read(target) is None, 'Fixture already exists'
    fields = {'uid': {'stringValue': uid}, 'email': {'stringValue': 'fictional@example.test'},
              'balance': {'integerValue': '27'}, 'gifts': {'mapValue': {'fields': {'one': {'integerValue': '1'}}}}}
    writes = [{'update': {'name': source, 'fields': fields}, 'currentDocument': {'exists': False}}]
    if private:
        writes.append({'update': {'name': target, 'fields': {'otherPrivateField': {'stringValue': 'preserve'}}},
                       'currentDocument': {'exists': False}})
    assert commit(writes)[0] == 200
    created.extend([source, target])
    return source, target, fields


checks = []
try:
    for private in (False, True):
        source, target, fields = fixture('existing' if private else 'new', private=private)
        private_before = read(target)
        plan = prepare_email_transition(read(source), private_before, expected_project=PROJECT)
        status, receipt = commit(plan['writes']); assert status == 200, status
        assert read(source)['fields'] == {k:v for k,v in fields.items() if k != 'email'}
        assert read(target)['fields']['email'] == fields['email']
        if private: assert read(target)['fields']['otherPrivateField'] == private_before['fields']['otherPrivateField']
        checks.append('atomic_move_' + str(private))
        rollback = prepare_email_rollback(plan, receipt)
        assert commit(rollback['writes'])[0] == 200
        assert read(source)['fields'] == fields
        assert read(target) is None if not private else read(target)['fields'] == private_before['fields']
        checks.append('rollback_' + str(private))

    source, target, fields = fixture('stale-source')
    plan = prepare_email_transition(read(source), None, expected_project=PROJECT)
    assert commit([{'update': {'name': source, 'fields': {'balance': {'integerValue': '99'}}},
                    'updateMask': {'fieldPaths': ['balance']}}])[0] == 200
    assert commit(plan['writes'])[0] != 200
    assert read(source)['fields']['email'] == fields['email']
    assert read(source)['fields']['balance'] == {'integerValue': '99'}
    assert read(target) is None
    checks.append('stale_source_atomic_reject')

    source, target, fields = fixture('stale-private', private=True)
    plan = prepare_email_transition(read(source), read(target), expected_project=PROJECT)
    assert commit([{'update': {'name': target, 'fields': {'otherPrivateField': {'stringValue': 'new'}}},
                    'updateMask': {'fieldPaths': ['otherPrivateField']}}])[0] == 200
    assert commit(plan['writes'])[0] != 200
    assert read(source)['fields'] == fields
    assert read(target)['fields'] == {'otherPrivateField': {'stringValue': 'new'}}
    checks.append('stale_private_atomic_reject')

    source, target, fields = fixture('stale-rollback')
    plan = prepare_email_transition(read(source), None, expected_project=PROJECT)
    status, receipt = commit(plan['writes']); assert status == 200
    rollback = prepare_email_rollback(plan, receipt)
    assert commit([{'update': {'name': source, 'fields': {'balance': {'integerValue': '99'}}},
                    'updateMask': {'fieldPaths': ['balance']}}])[0] == 200
    assert commit(rollback['writes'])[0] != 200
    assert read(source)['fields']['balance'] == {'integerValue': '99'}
    assert 'email' not in read(source)['fields']
    assert read(target)['fields']['email'] == fields['email']
    checks.append('changed_profile_rollback_atomic_reject')
finally:
    if created:
        assert all('/' + PREFIX in name for name in created)
        assert commit([{'delete': name} for name in created])[0] == 200
print(json.dumps({'environment': 'localhost Firestore Emulator', 'project': PROJECT,
                  'checks': checks, 'passed': len(checks), 'productionWrites': 0}))
