"""Offline, review-only plan for a Firestore REST-format users snapshot.

No credentials, SDK or network. Does not execute writes or contact production.
The plan contains private data: keep it outside source control and access-limited.
Reads {"documents": [{"name": ..., "fields": ..., "updateTime": ...}]}.
"""
import argparse
import json
import os
import re
from pathlib import Path

PUBLIC_FIELDS = frozenset([
    'uid', 'fullName', 'profilePic', 'profilePicThumb', 'age', 'rost', 'about',
    'hobbi', 'deti', 'temperament', 'city', 'country', 'countryCode',
    'languageGroup', 'countrySegment', 'region', 'images', 'pol',
    'relationStatus', 'группа', 'group', 'language', 'online', 'lastOnlineTS',
])
NAME = re.compile(r'^(projects/[^/]+/databases/[^/]+/documents)/users/([^/]+)$')


def scalar(fields, key):
    raw = fields.get(key, {})
    return raw.get('stringValue', raw.get('booleanValue'))


def make_plan(documents):
    batches = []
    count_private = 0
    for doc in documents:
        match = NAME.fullmatch(doc.get('name', ''))
        if not match or not doc.get('updateTime'):
            raise ValueError('Every source must be a users/{uid} document with updateTime')
        base, uid = match.groups()
        fields = doc.get('fields', {})
        writes = []
        hidden = scalar(fields, 'status') in ['blocked', 'deleted'] or \
            scalar(fields, 'deleted') is True or \
            scalar(fields, 'isUnVisible') is True or scalar(fields, 'isUnvisible') is True
        if hidden:
            writes.append({'delete': f'{base}/public_profiles/{uid}'})
        else:
            public = {key: value for key, value in fields.items() if key in PUBLIC_FIELDS}
            public['uid'] = {'stringValue': uid}
            writes.append({'update': {'name': f'{base}/public_profiles/{uid}', 'fields': public}})
        if 'email' in fields:
            count_private += 1
            writes.append({'update': {'name': f'{base}/private_users/{uid}',
                                     'fields': {'email': fields['email']}},
                           'updateMask': {'fieldPaths': ['email']}})
            # The same atomic commit copies email and removes the legacy field.
            # A changed source invalidates ALL writes (including the projection).
            writes.append({'update': {'name': doc['name'], 'fields': {}},
                           'updateMask': {'fieldPaths': ['email']},
                           'currentDocument': {'updateTime': doc['updateTime']}})
        else:
            # A no-op write provides the same optimistic version guard.
            writes.append({'update': {'name': doc['name'], 'fields': {}},
                           'updateMask': {'fieldPaths': []},
                           'currentDocument': {'updateTime': doc['updateTime']}})
        batches.append({'sourceUid': uid, 'writes': writes})
    return {'reviewOnly': True, 'productionApproved': False,
            'sourceDocuments': len(documents), 'privateEmailDocuments': count_private,
            'atomicBatches': batches}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if args.input.resolve() == args.output.resolve():
        parser.error('Input export must remain unchanged')
    source = json.loads(args.input.read_text())
    plan = make_plan(source['documents'])
    # Refuse overwriting an existing artifact; owner-only permissions from open.
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as file:
        json.dump(plan, file, ensure_ascii=False, indent=2)
    print(json.dumps({'sourceDocuments': plan['sourceDocuments'],
                      'privateEmailDocuments': plan['privateEmailDocuments'],
                      'writesExecuted': 0, 'reviewOnly': True}))


if __name__ == '__main__':
    main()
