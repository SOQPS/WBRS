"""Actual emulator permission checks, no production network or real users.
Run ONLY via firebase.strict.json; exit immediately unless demo project/loopback.
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

PROJECT = 'demo-clrs-security'
AUTH = 'http://127.0.0.1:9299/identitytoolkit.googleapis.com/v1'
BASE = f'projects/{PROJECT}/databases/(default)/documents'
DB = f'http://127.0.0.1:8180/v1/{BASE}'
STORAGE = f'http://127.0.0.1:9298/v0/b/{PROJECT}.appspot.com/o'
checks = []


def call(method, url, body=None, token=None, content_type='application/json'):
    assert urllib.parse.urlsplit(url).hostname == '127.0.0.1'
    headers = {'Content-Type': content_type}
    if content_type.startswith('multipart/related'):
        headers['X-Goog-Upload-Protocol'] = 'multipart'
    if token:
        headers['Authorization'] = f'Bearer {token}'
    data = body if isinstance(body, bytes) else json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            raw = response.read()
            try:
                value = json.loads(raw)
            except (ValueError, UnicodeDecodeError):
                value = {'bytes': len(raw)}
            return response.status, value
    except urllib.error.HTTPError as error:
        try:
            detail = json.loads(error.read())
        except ValueError:
            detail = {}
        return error.code, detail


def check(name, response, expected=200):
    code, detail = response
    assert code == expected, f'{name}: expected {expected}, received {code}: {detail}'
    checks.append(name)
    print(f'PASS {name}')
    return detail


def value(data):
    if data is None:
        return {'nullValue': None}
    if isinstance(data, bool):
        return {'booleanValue': data}
    if isinstance(data, int):
        return {'integerValue': str(data)}
    if isinstance(data, str):
        return {'stringValue': data}
    if isinstance(data, list):
        return {'arrayValue': {'values': [value(v) for v in data]}}
    return {'mapValue': {'fields': {k: value(v) for k, v in data.items()}}}


def write(path, data, stamps=(), patch=False):
    item = {'update': {'name': BASE + '/' + path, 'fields': {k: value(v) for k, v in data.items()}}}
    if stamps:
        item['updateTransforms'] = [{'fieldPath': field, 'setToServerValue': 'REQUEST_TIME'} for field in stamps]
    if patch:
        item['updateMask'] = {'fieldPaths': list(data)}
    return item


def delete(path):
    return {'delete': BASE + '/' + path}


def commit(token, *writes):
    return call('POST', DB + ':commit', {'writes': list(writes)}, token)


def get(path, token=None):
    return call('GET', DB + '/' + path, token=token)


def account(name, admin=False):
    body = {'email': name + '@example.test', 'password': 'local-fixture-password', 'returnSecureToken': True}
    status, user = call('POST', AUTH + '/accounts:signUp?key=demo', body)
    assert status == 200, user
    if admin:
        status, detail = call('POST', AUTH + '/accounts:update?key=demo', {
            'localId': user['localId'], 'customAttributes': json.dumps({'admin': True})}, 'owner')
        assert status == 200, detail
        status, user = call('POST', AUTH + '/accounts:signInWithPassword?key=demo', body)
        assert status == 200, user
    return user['localId'], user['idToken']


def run():
    a, ta = account('alice')
    b, tb = account('bob')
    c, tc = account('charlie')
    admin, tadmin = account('admin', admin=True)
    if '--storage-only' in sys.argv:
        run_storage(a, ta, tb, tadmin)
        print(json.dumps({'project': PROJECT, 'passed': len(checks), 'scope': 'storage', 'productionTested': False}))
        return
    # Admin SDK equivalent seeds bypass rules, separately from authenticated test roles.
    assert commit('owner', *[
        write(f'users/{uid}', {'uid': uid, 'fullName': label, 'email': label+'@private.test', 'balance': 27,
                              'status': 'active', 'role': 'user', 'gifts': {'gift-1': 1}})
        for uid, label in [(a, 'Alice'), (b, 'Bob'), (c, 'Charlie'), (admin, 'Admin')]
    ], write(f'public_profiles/{b}', {'uid': b, 'fullName': 'Bob'}),
       write(f'private_users/{b}', {'email': 'bob@private.test'}),
       write(f'TOKENS/{b}', {'token': 'fake-push-token'}))[0] == 200

    check('own legacy profile readable', get(f'users/{a}', ta))
    check('peer legacy email-containing profile denied', get(f'users/{b}', ta), 403)
    check('anonymous profile denied', get(f'users/{a}'), 403)
    check('ordinary user listing legacy profiles denied', get('users', ta), 403)
    check('administrator reads legacy profile', get(f'users/{b}', tadmin))
    public = check('safe projection readable by signed user', get(f'public_profiles/{b}', ta))
    assert 'email' not in public['fields']
    check('anonymous public projection denied', get(f'public_profiles/{b}'), 403)
    check('client cannot put private data in public projection', commit(tb, write(f'public_profiles/{b}', {'email':'leak'})), 403)
    check('private email denied to peer', get(f'private_users/{b}', ta), 403)
    check('private email denied to owner client', get(f'private_users/{b}', tb), 403)
    check('private email readable by administrator', get(f'private_users/{b}', tadmin))
    check('owner profile text update allowed', commit(ta, write(f'users/{a}', {'about':'Own profile'}, patch=True)))
    check('foreign profile update denied', commit(ta, write(f'users/{b}', {'about':'Overwrite'}, patch=True)), 403)
    check('self admin escalation denied', commit(ta, write(f'users/{a}', {'role':'admin'}, patch=True)), 403)
    check('self balance credit denied', commit(ta, write(f'users/{a}', {'balance':999}, patch=True)), 403)
    check('self gift minting denied', commit(ta, write(f'users/{a}', {'gifts':{'gift-1':100}}, patch=True)), 403)
    check('owner cannot delete and recreate registration bonus', commit(ta, delete(f'users/{a}')), 403)
    check('foreign push token read denied', get(f'TOKENS/{b}', ta), 403)
    check('foreign push token write denied', commit(ta, write(f'TOKENS/{b}', {'token':'hijack'})), 403)
    check('owner push token write allowed', commit(ta, write(f'TOKENS/{a}', {'token':'own-fake'})))
    check('profile image metadata owner write', commit(ta, write(f'users/{a}/images/one', {'url':'local-photo', 'thumbnailUrl':'local-thumb'})))
    check('profile image metadata foreign overwrite denied', commit(tb, write(f'users/{a}/images/one', {'url':'changed'})), 403)

    request = {'uid':a, 'fullName':'Alice', 'requestedRole':'author', 'status':'pending',
               'proposedText':'Sample article', 'proposedImageUrl':'', 'proposalId':'proposal-one'}
    check('author proposal allowed', commit(ta, write(f'author_requests/{a}', request, ['createdAt'])))
    check('author proposal private from peers', get(f'author_requests/{a}', tb), 403)
    check('author proposal visible to admin', get(f'author_requests/{a}', tadmin))
    check('self approve role request denied', commit(ta, write(f'author_requests/{a}', {'status':'approved'}, patch=True)), 403)
    check('self author grant denied', commit(ta, write(f'author_grants/{a}', {'uid':a,'status':'approved'})), 403)
    check('self moderator grant denied', commit(ta, write(f'moderator_grants/{a}', {'uid':a,'status':'approved'})), 403)
    post = {'authorUid':a,'authorName':'Alice','authorPhoto':'','authorGroup':'','text':'Hello',
            'imageUrl':'','status':'published','likeCount':0,'commentCount':0,'shareCount':0,'nativeLanguage':'en'}
    check('unapproved author cannot publish', commit(ta, write('posts/article', post, ['createdAt'])), 403)
    check('admin grants author', commit(tadmin, write(f'author_grants/{a}', {'uid':a,'status':'approved'})))
    check('approved author can publish', commit(ta, write('posts/article', post, ['createdAt'])))
    check('peer reads published post', get('posts/article', tb))
    check('author cannot forge identity', commit(ta, write('posts/spoof', dict(post, authorUid=b), ['createdAt'])), 403)
    check('reader cannot inflate post counters', commit(tb, write('posts/article', {'likeCount':500}, patch=True)), 403)
    check('author cannot inflate own counters', commit(ta, write('posts/article', {'likeCount':500}, patch=True)), 403)
    check('reader can create own like', commit(tb, write(f'posts/article/likes/{b}', {'uid':b}, ['createdAt'])))
    check('reader cannot forge foreign like', commit(tb, write(f'posts/article/likes/{c}', {'uid':c}, ['createdAt'])), 403)
    check('reader cannot delete foreign like', commit(tc, delete(f'posts/article/likes/{b}')), 403)
    comment = {'authorUid':b, 'authorName':'Bob','authorPhoto':'','authorGroup':'','text':'Comment',
               'imageUrl':'','parentId':None,'likeCount':0,'notificationRecipient':a}
    check('reader can create comment', commit(tb, write('posts/article/comments/one', comment, ['createdAt'])))
    report_path = f'moderation_reports/comment-article-one-{b}'
    report = {'reporterUid': b, 'entityType': 'comment',
              'entityId': 'article/one', 'status': 'new'}
    check('absent comment report cannot be pre-read', get(report_path, tb), 403)
    check('reader creates first comment report', commit(tb, write(report_path, report, ['createdAt'])))
    check('reader sees own existing report', get(report_path, tb))
    check('peer cannot read comment report', get(report_path, ta), 403)
    check('reader cannot update submitted report',
          commit(tb, write(report_path, {'status': 'reviewed'}, patch=True)), 403)
    check('administrator reviews comment report',
          commit(tadmin, write(report_path, {'status': 'reviewed'}, patch=True)))
    check('retry cannot reset reviewed report',
          commit(tb, write(report_path, report, ['createdAt'])), 403)
    post_report_path = f'moderation_reports/post-article-{b}'
    post_report = {'reporterUid': b, 'entityType': 'post',
                   'entityId': 'article', 'status': 'new'}
    check('absent post report cannot be pre-read', get(post_report_path, tb), 403)
    check('reader creates first post report',
          commit(tb, write(post_report_path, post_report, ['createdAt'])))
    check('peer cannot read post report', get(post_report_path, ta), 403)
    check('administrator reviews post report',
          commit(tadmin, write(post_report_path, {'status': 'reviewed'}, patch=True)))
    check('retry cannot reset reviewed post report',
          commit(tb, write(post_report_path, post_report, ['createdAt'])), 403)
    check('reader cannot forge comment author', commit(tc, write('posts/article/comments/spoof', comment, ['createdAt'])), 403)
    check('missing parent comment rejected', commit(tb, write('posts/article/comments/bad-parent', dict(comment,parentId='missing'), ['createdAt'])), 403)
    check('legacy counter transaction rejected atomically', commit(tb,
        write('posts/article/comments/legacy', comment, ['createdAt']),
        write('posts/article', {'commentCount':1}, patch=True)), 403)
    check('failed legacy transaction leaves no comment', get('posts/article/comments/legacy', ta), 404)
    check('owner wall share allowed', commit(tb, write(f'users/{b}/wall/article', {'sharedPostId':'article'}, ['createdAt'])))
    check('foreign wall share denied', commit(ta, write(f'users/{b}/wall/foreign', {'sharedPostId':'article'}, ['createdAt'])), 403)

    incoming = {'fromUid':a,'fromName':'Alice','fromPhoto':'','группа':'','status':'pending'}
    outgoing = {'toUid':b,'toName':'Bob','toPhoto':'','группа':'','status':'pending'}
    check('orphan friend request denied', commit(ta, write(f'users/{b}/friend_requests/{a}', incoming, ['createdAt'])), 403)
    check('paired friend request allowed', commit(ta,
        write(f'users/{b}/friend_requests/{a}', incoming, ['createdAt']),
        write(f'users/{a}/friend_requests_sent/{b}', outgoing, ['createdAt'])))
    check('request readable by recipient', get(f'users/{b}/friend_requests/{a}', tb))
    check('request unreadable by outsider', get(f'users/{b}/friend_requests/{a}', tc), 403)
    friend_a = {'uid':a,'fullName':'Alice','profilePic':'','profilePicThumb':'','группа':''}
    friend_b = dict(friend_a, uid=b, fullName='Bob')
    accept = [write(f'users/{b}/friends/{a}',friend_a,['createdAt']),
              write(f'users/{a}/friends/{b}',friend_b,['createdAt']),
              delete(f'users/{b}/friend_requests/{a}'),delete(f'users/{a}/friend_requests_sent/{b}')]
    check('sender cannot accept own outgoing invitation', commit(ta,*accept),403)
    check('recipient accepts mutual friendship atomically', commit(tb,*accept))
    check('outsider cannot create friendship without request',commit(tc,write(f'users/{c}/friends/{a}',friend_a,['createdAt'])),403)
    check('outsider cannot list friends',get(f'users/{a}/friends',tc),403)
    check('owner lists friends',get(f'users/{a}/friends',ta))
    check('one-sided friendship removal denied',commit(ta,delete(f'users/{a}/friends/{b}')),403)
    check('mutual friendship removal allowed',commit(ta,delete(f'users/{a}/friends/{b}'),delete(f'users/{b}/friends/{a}')))

    notice = {'type':'friend_request','entityId':b,'title':'Seed notice','body':'Fixture','read':False}
    assert commit('owner',write(f'users/{a}/notifications/one',notice,['createdAt']))[0] == 200
    check('notification recipient can read',get(f'users/{a}/notifications/one',ta))
    check('foreign notification read denied',get(f'users/{a}/notifications/one',tb),403)
    check('forged notification denied',commit(tb,write(f'users/{a}/notifications/forged',notice,['createdAt'])),403)
    check('self fabricated notification denied',commit(ta,write(f'users/{a}/notifications/forged',notice,['createdAt'])),403)
    check('notification read flag allowed',commit(ta,write(f'users/{a}/notifications/one',{'read':True},patch=True)))
    check('notification content rewrite denied',commit(ta,write(f'users/{a}/notifications/one',{'body':'Forged'},patch=True)),403)
    check('gift receipt minting denied',commit(ta,write(f'users/{b}/received_gifts/fake',{'senderUid':a})),403)

    chat={'user1':a,'user2':b,'chatId':'ab','unreadMessage':0}
    check('participant can create private room',commit(ta,write('chats/ab',chat)))
    check('outsider cannot create room as others',commit(tc,write('chats/spoof',chat)),403)
    check('recipient can read room',get('chats/ab',tb))
    check('outsider cannot read room',get('chats/ab',tc),403)
    check('participant cannot change room membership',commit(ta,write('chats/ab',{'user2':c},patch=True)),403)
    msg={'type':'text','sendByID':a,'sender':a,'message':'Private hello','isRead':False}
    check('participant sends own message',commit(ta,write('chats/ab/chats/one',msg)))
    check('outsider cannot read messages',get('chats/ab/chats/one',tc),403)
    check('participant cannot forge sender',commit(tb,write('chats/ab/chats/spoof',msg)),403)
    check('recipient acknowledges message',commit(tb,write('chats/ab/chats/one',{'isRead':True},patch=True)))
    check('recipient cannot rewrite message',commit(tb,write('chats/ab/chats/one',{'message':'Tamper'},patch=True)),403)
    check('sender cannot certify recipient read',commit(ta,write('chats/ab/chats/one',{'isRead':True},patch=True)),403)
    assert commit('owner',write('meets/public',{'admin':a,'users':[a,b],'type':'коллективная'}),
                  write('meets/private',{'admin':a,'users':[a,b],'type':'индивидуальная','invitedUid':b}))[0] == 200
    check('public meeting visible',get('meets/public',tc))
    check('private meeting hidden from outsiders',get('meets/private',tc),403)
    check('invited user can read personal meeting',get('meets/private',tb))
    check('meeting member can send',commit(ta,write('meets/public/messages/one',msg)))
    check('outsider cannot read meeting chat',get('meets/public/messages/one',tc),403)
    check('outsider cannot join by arbitrary member-list write',commit(tc,write('meets/public',{'users':[a,b,c]},patch=True)),403)
    check('unknown collection default deny',commit(ta,write('unknown/one',{'uid':a})),403)

    run_storage(a, ta, tb, tadmin)
    print(json.dumps({'project':PROJECT,'passed':len(checks),'productionTested':False},indent=2))


def run_storage(a, ta, tb, tadmin):
    def upload(path,token,body=b'local-image-fixture',mime='image/jpeg'):
        boundary = 'clrs-security-multipart'
        metadata = json.dumps({'name':path,'contentType':mime}).encode()
        multipart = (f'--{boundary}\r\nContent-Type: application/json\r\n\r\n'.encode() + metadata +
                     f'\r\n--{boundary}\r\nContent-Type: {mime}\r\n\r\n'.encode() + body +
                     f'\r\n--{boundary}--\r\n'.encode())
        return call('POST',STORAGE+'?uploadType=multipart&name='+urllib.parse.quote(path,safe=''),
                    multipart,token,'multipart/related; boundary='+boundary)
    def download(path,token=None):
        return call('GET',STORAGE+'/'+urllib.parse.quote(path,safe='')+'?alt=media',token=token)
    check('photo Storage upload by owner',upload(f'users/{a}/photos/one.jpg',ta))
    check('photo Storage upload by peer denied',upload(f'users/{a}/photos/other.jpg',tb),403)
    check('signed user reads public profile photo',download(f'users/{a}/photos/one.jpg',tb))
    check('anonymous direct Storage read denied',download(f'users/{a}/photos/one.jpg'),403)
    check('non-image upload denied',upload(f'users/{a}/photos/bad.txt',ta,mime='text/plain'),403)
    check('oversize upload denied',upload(f'users/{a}/photos/large.jpg',ta,body=b'x'*(10*1024*1024+1)),403)
    check('registration Storage path allowed',upload(f'profile_images/{a}/registration/one.jpg',ta))
    check('feed image Storage path allowed',upload(f'feed_comments/{a}/one.jpg',ta))
    check('unknown Storage prefix denied',upload(f'private/{a}/one.jpg',ta),403)
    check('author proposal image owner upload',upload(f'author_applications/{a}/proposal-one.jpg',ta))
    check('author proposal image hidden from peer',download(f'author_applications/{a}/proposal-one.jpg',tb),403)
    check('author proposal image readable by admin',download(f'author_applications/{a}/proposal-one.jpg',tadmin))


if __name__ == '__main__':
    run()
