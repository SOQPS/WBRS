# Firebase admin claims for CLRS

The mobile admin screen reads the real Firestore `users` collection. Its route
is displayed only when the current Firebase ID token contains `admin: true`;
opening the route forces a token refresh. A profile field, email address or
hardcoded client UID is not an admin role.

`admin-claims.mjs` reads exactly four email addresses from a JSON array in a
private file outside the repository. It is read-only by default. For a grant or
revoke, it checks each matching Firebase Auth account and its `users/{uid}`
profile, preserves all unrelated custom claims, and reports aggregate counts.
An `--apply` operation requires `--confirm-project PROJECT_ID` and writes a
mode-0600 backup outside the repository **before** changing any claim. The
backup must be in a private (mode-0700) directory. Keep that file until access
has been checked; it is required for rollback.

```sh
node server/timeweb/admin-claims.mjs --project PROJECT_ID --action grant \
  --emails-file /absolute/private/admin-emails.json \
  --backup /absolute/private/admin-claims-before-grant.json

# After reviewing the dry-run output, append:
# --apply --confirm-project PROJECT_ID
# If a specifically approved account has an unverified email, the operator
# must also explicitly append --allow-unverified. This does not change its
# emailVerified state.

node server/timeweb/admin-claims.mjs --project PROJECT_ID --action restore \
  --backup /absolute/private/admin-claims-before-grant.json
# After reviewing the restore dry-run, append:
# --apply --confirm-project PROJECT_ID
```

The IAM principal running this needs `firebaseauth.users.get` and, only for
apply, `firebaseauth.users.update`; the exact profile checks need
`datastore.entities.get`. If an ADC quota project is set, it may also need
`serviceusage.services.use` there. Do not use an AWS/Timeweb password or put
Firebase credentials in this repository.

This client guard is **not** server authorization. Firestore rules must also
enforce the intended admin privileges before the admin controls can be called
secure. The current production rules and app query patterns require a separate
compatibility review; do not deploy the strict rules fixture wholesale.
