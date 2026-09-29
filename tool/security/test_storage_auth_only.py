"""Targeted localhost checks for the auth-only Storage containment rule."""
import json
import urllib.request
import test_storage_transition as fixture

fixture.PROJECT = 'demo-clrs-storage-auth-only'
fixture.AUTH_HOST = '127.0.0.1:18299'
fixture.STORAGE_HOST = '127.0.0.1:18298'
fixture.AUTH = f'http://{fixture.AUTH_HOST}/identitytoolkit.googleapis.com/v1'
fixture.STORAGE = f'http://{fixture.STORAGE_HOST}/v0/b/{fixture.PROJECT}.appspot.com/o'


def run():
    fixture.require_local_emulators()
    alice, ta = fixture.account('alice')
    bob, tb = fixture.account('bob')
    c = fixture.check
    upload = fixture.upload
    get = fixture.get
    delete = fixture.delete

    root = 'legacy-root-photo.jpg'
    profile = f'users/{alice}/photos/photo.jpg'
    current_paths = [
        f'users/{alice}/photos/thumbs/photo.jpg',
        f'profile_images/{alice}/registration/draft/photo.jpg',
        f'feed_posts/{alice}/post.jpg',
        f'feed_comments/{alice}/comment.jpg',
        f'author_applications/{alice}/request.jpg',
    ]

    c('anonymous root create denied', upload(root), 403)
    c('signed-in root create retained', upload(root, ta), 200)
    c('anonymous root read retained', get(root), 200)
    c('anonymous root metadata read retained', get(root, metadata=True), 200)
    c('anonymous root overwrite denied', upload(root), 403)
    c('signed-in root overwrite retained', upload(root, ta), 200)
    c('anonymous root delete denied', delete(root), 403)
    c('signed-in root delete retained', delete(root, ta), 204)

    # An anonymous *Firebase Auth account* still has request.auth != null.
    request = urllib.request.Request(
        fixture.AUTH + '/accounts:signUp?key=demo',
        data=json.dumps({'returnSecureToken': True}).encode(),
        headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=25) as response:
        anonymous_auth = json.load(response)['idToken']
    c('Firebase anonymous Auth account may write',
      upload('firebase-anonymous-account.jpg', anonymous_auth), 200)

    c('anonymous new profile upload denied', upload(profile), 403)
    c('signed-in profile upload retained', upload(profile, ta), 200)
    c('anonymous profile read retained', get(profile), 200)
    c('anonymous profile delete denied', delete(profile), 403)
    for path in current_paths:
        c(f'signed-in upload retained: {path.split("/")[0]}', upload(path, ta), 200)
        c(f'anonymous read retained: {path.split("/")[0]}', get(path), 200)

    c('anonymous listing retained', fixture.call('GET', fixture.STORAGE), 200)
    c('signed-in unknown prefix write retained', upload(f'other/{alice}/x.jpg', ta), 200)

    # These passes reveal the remaining critical vulnerability, not a safe
    # owner policy: any account can replace/delete another account's photos.
    c('foreign account can overwrite profile', upload(profile, tb), 200)
    c('foreign account can delete profile', delete(profile, tb), 204)

    print(json.dumps({'scope': 'storage-auth-only', 'passed': len(fixture.checks),
                      'productionTested': False}))


if __name__ == '__main__':
    run()
