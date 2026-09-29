"""Offline atomic email transition and version-guarded rollback.

No SDK, credentials, network or production writes. Inputs and returned plans
contain private email: callers must keep them encrypted outside the checkout.
Unlike the older projection review, this job touches only two email fields.
"""
import copy
import datetime
import re


_NAME = re.compile(
    r'^(projects/([^/]+)/databases/([^/]+)/documents)/users/([^/]+)$')
_TIME = re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$')


def _timestamp(value):
    if not isinstance(value, str) or not _TIME.fullmatch(value):
        raise ValueError('missing_or_invalid_version')
    # Python 3.9 accepts microseconds only; Firestore versions carry nanoseconds.
    # Truncate solely for calendar validation, never for the returned guard.
    validation_value = value
    if '.' in value:
        seconds, fraction = value[:-1].split('.', 1)
        validation_value = seconds + '.' + fraction[:6].ljust(6, '0') + 'Z'
    try:
        datetime.datetime.fromisoformat(validation_value.replace('Z', '+00:00'))
    except ValueError:
        raise ValueError('missing_or_invalid_version') from None
    return value


def _email(value):
    if not isinstance(value, dict) or set(value) != {'stringValue'} or \
            not isinstance(value['stringValue'], str):
        raise ValueError('invalid_email_field')
    return copy.deepcopy(value)


def prepare_email_transition(source, private_before, *, expected_project):
    """Prepare one atomic commit after capturing BOTH documents at one read time.

    The source's email is authoritative only when the closed copy is absent or
    identical. A different private email requires manual review, never overwrite.
    Source and destination versions are checked in the same Firestore commit.
    """
    match = _NAME.fullmatch(source.get('name', ''))
    if not match or match.group(2) != expected_project:
        raise ValueError('unexpected_source_scope')
    base, _, _, uid = match.groups()
    version = _timestamp(source.get('updateTime'))
    fields = source.get('fields', {})
    if not isinstance(fields, dict):
        raise ValueError('invalid_source_fields')
    if 'uid' in fields and fields['uid'] != {'stringValue': uid}:
        raise ValueError('source_owner_mismatch')
    if 'email' not in fields:
        return {'reviewOnly': True, 'action': 'no_legacy_email', 'writes': []}
    email = _email(fields['email'])
    target = f'{base}/private_users/{uid}'
    original_private_email = None
    if private_before is None:
        private_guard = {'exists': False}
    else:
        if private_before.get('name') != target or \
                not isinstance(private_before.get('fields', {}), dict):
            raise ValueError('unexpected_destination_scope')
        private_guard = {'updateTime': _timestamp(private_before.get('updateTime'))}
        private_fields = private_before.get('fields', {})
        if 'email' in private_fields:
            original_private_email = _email(private_fields['email'])
            if original_private_email != email:
                raise ValueError('private_email_conflict')
    return {
        'reviewOnly': True,
        'action': 'move_email',
        'scope': {'source': source['name'], 'destination': target},
        'backup': {
            'sourceEmail': email,
            'privateExisted': private_before is not None,
            'privateEmail': original_private_email,
        },
        'writes': [
            {'update': {'name': target, 'fields': {'email': email}},
             'updateMask': {'fieldPaths': ['email']},
             'currentDocument': private_guard},
            {'update': {'name': source['name'], 'fields': {}},
             'updateMask': {'fieldPaths': ['email']},
             'currentDocument': {'updateTime': version}},
        ],
    }


def prepare_email_rollback(plan, commit_receipt):
    """Restore only affected fields, guarded by the SUCCESSFUL commit's versions.

    An account/profile/private-document change after migration makes the entire
    rollback fail rather than erase newer data. Never reuse a guessed timestamp.
    Store the direct successful REST commit response with the encrypted job.
    """
    if plan.get('action') != 'move_email' or len(plan.get('writes', [])) != 2:
        raise ValueError('not_an_email_transition')
    results = commit_receipt.get('writeResults', [])
    if len(results) != 2:
        raise ValueError('missing_successful_commit_receipt')
    _timestamp(commit_receipt.get('commitTime'))
    private_version = _timestamp(results[0].get('updateTime'))
    source_version = _timestamp(results[1].get('updateTime'))
    scope = plan['scope']
    backup = plan['backup']
    source_write = {
        'update': {'name': scope['source'],
                   'fields': {'email': _email(backup['sourceEmail'])}},
        'updateMask': {'fieldPaths': ['email']},
        'currentDocument': {'updateTime': source_version},
    }
    if not backup['privateExisted']:
        private_write = {'delete': scope['destination'],
                         'currentDocument': {'updateTime': private_version}}
    else:
        previous = backup['privateEmail']
        private_write = {
            'update': {'name': scope['destination'],
                       'fields': {} if previous is None else {'email': _email(previous)}},
            'updateMask': {'fieldPaths': ['email']},
            'currentDocument': {'updateTime': private_version},
        }
    return {'reviewOnly': True, 'action': 'restore_email',
            'writes': [source_write, private_write]}
