# Current security fixture

Expanded strict local rules and compatibility blockers: [STRICT_RULES_REVIEW.md](STRICT_RULES_REVIEW.md).
Use `firebase.strict.json` for the 2026-09-28 checks. Both fixtures are local only.

# Social role rules fixture

`social_roles.rules` covers only the new author/moderator request and grant
collections and a publication-create gate. It is an isolated test fixture,
**not a replacement for production Firestore rules**. The deployed rule set must
be reviewed before these matches can be merged; existing likes, comments,
notifications and other collections are intentionally absent here.

With Firebase CLI and Java installed, from the repository root:

```sh
firebase emulators:exec --project demo-clrs-roles --only auth,firestore \
  --config tool/security/firebase.json \
  'python3 tool/security/test_social_roles.py'
```

This checks that an ordinary user can request the author role but cannot write
an author/moderator grant or publish before approval. It does not prove that the
production Firebase project enforces these rules.

## Read-only profile review snapshot

`capture_profile_review.mjs` reads only root `users` documents from the explicitly
confirmed project, at one server read time. It writes an authenticated AES-GCM
snapshot and a review-only private-email migration plan outside the Git checkout.
Plaintext profiles, tokens and the encryption key never go to stdout or source
archives; the key is a separate mode-0600 file. The tool uses existing local
application-default Google credentials and never deploys rules or writes data.

```sh
node tool/security/capture_profile_review.mjs \
  --confirm-project chatapp-4e347 \
  --out-dir /private/path/outside-the-checkout
```

The destination must not already contain a snapshot/key. The summary contains
counts, archive hashes and the result of an authenticated round-trip comparison.
This is a backup of root profiles only: Auth accounts, chat subcollections and
Storage files are not exported. Creating a review plan does not approve or apply
a production migration. Keep the encrypted files and key outside deliverables.

## Email-only atomic transition and rollback

`private_email_transition.py` is an offline preparation module, not an executor.
It touches only `users/{uid}.email` and `private_users/{uid}.email`; it does not
rewrite the profile, balance, inventory, Auth account or public projection.
Capture both source and destination at a consistent read time, encrypt their
affected fields outside Git, and keep the successful commit receipt with the
encrypted job. Apply and rollback use optimistic guards for both documents.
A different existing private email requires review instead of replacement.
A changed profile/private document makes the whole commit or rollback fail.

Local checks: nine unit scenarios and seven exact commit/rollback scenarios on
the fixed localhost Firestore Emulator. Production apply/rollback was not run.

`social.required.indexes.json` contains only the new feed and regional fanout
requirements. It is a fragment: merge it with the currently deployed indexes,
preserving existing indexes and field overrides. Never deploy this fragment as
a replacement of the complete production index configuration.
