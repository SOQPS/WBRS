# Read-only inventory before migration

The bounded CLRSX2 staging importer and read-back verifier are described in [IMPORT_PREPARATION.md](IMPORT_PREPARATION.md). They are local preparation only; no real Timeweb import or APK switch has been performed.

Current status (2026-09-30): migration is **not complete**. The existing Flask app remains paused after an unauthenticated SQL editor was confirmed. An empty `clrs_staging` database was created on the existing Timeweb MySQL cluster without ordering new paid resources. Firebase Owner access and read-only Auth/Firestore/Storage queries now work; no real user data has been exported or imported, no CLRS API is deployed, and no APK has been switched. See [account inventory](ACCOUNT_INVENTORY.md), [migration plan](PLAN.md), [API contract](CONTRACT.md), [encrypted export preparation](EXPORT_PREPARATION.md), [database schema](db/README.md), [deployment/backup templates](deploy/README.md), and [infrastructure smoke API](api/README.md).

`PLAN.md` describes the migration gates. These scripts **do not export user content**, write to Firebase, import data into Timeweb, or switch an APK. They produce a protected manifest of counts, HMAC fingerprints of Auth UIDs/emails, Firestore document paths and content, Storage object keys/checksums, and selected ID/storage links. A matching HMAC key allows a later Timeweb inventory to be compared without listing names, emails, message text or download tokens.

Requirements: Node.js 22, package dependencies installed in this directory, an explicit Firebase project ID and Storage bucket, and Application Default Credentials for a dedicated read-only principal. No service-account JSON key is required in the repository. Grant only `roles/firebaseauth.viewer`, `roles/datastore.viewer`, and `roles/storage.objectViewer` on the relevant bucket. Auth listing uses the read-only Identity Toolkit `projects.accounts:batchGet` REST method with an ADC bearer token; it does not call the Firebase Admin user-management SDK, which requires a service account. If ADC supplies a quota project, the adapter forwards it in `x-goog-user-project`; Google may additionally require `serviceusage.services.use` for that quota project. Password hashes are intentionally excluded: their absence under a viewer role cannot establish whether an account has a password. Production reads can incur cost; choose read limits after checking project size. A granted IAM role alone does not prove that the local ADC token has the required OAuth scope; a live read must confirm this.

Create a random 32-byte HMAC key in a **private directory outside git** with mode `0600`, or have a secrets manager deliver it as a restricted file. Reuse the same key for source and target inventories; losing it makes fingerprints incomparable. The example below uses placeholders, not actual project IDs or secrets:

Before any broad inventory, one bounded Auth permission check is available: `node check-firebase-auth-access.mjs --project PROJECT_ID`. It requests at most one account and prints no user data. A 403 still needs local IAM, OAuth scope and quota-project diagnosis; this tool does not request new privileges.

```sh
node inventory-firebase.mjs \
  --project PROJECT_ID \
  --bucket STORAGE_BUCKET \
  --key-file /secure/location/inventory-hmac-key \
  --out /secure/location/firebase-manifest.json \
  --max-auth-users 10000 \
  --max-auth-list-pages 20 \
  --max-documents 100000 \
  --max-objects 100000 \
  --confirm-read-cost
```

The key file must not be group/world-readable. The manifest is created once at mode `0600` and never silently overwritten. It contains pseudonymous IDs and must still be treated as sensitive. CLI errors deliberately omit SDK responses and values. Do not upload it to a chat or commit it. The script reads all root collections, **recurses into subcollections even below missing parent documents**, counts documents by collection path pattern, paginates Auth and Storage, and stops with an error if the explicit limits are reached. The Auth limits bound both users and page requests, including empty pages. `--max-documents` bounds individual document fetches, including missing parent documents; the manifest's document count includes existing documents only. Firestore `listDocuments()` first loads all references for one collection: this option is **not a hard cap on listing memory, API requests or charges**. Estimate the collection sizes before a production run. Snapshot consistency is not guaranteed while Firebase writes continue. Auth users without profile documents can be legitimate accounts paused during registration; unresolved links require review before classification as defects.

When a matching Timeweb manifest exists, compare both local files:

```sh
node compare-manifests.mjs /secure/location/firebase-manifest.json /secure/location/timeweb-manifest.json
```

Exit status 0 means both schema-v2 manifests are structurally complete, share the same HMAC key, and every recorded count, HMAC fingerprint, content digest and selected link matches; status 2 means differences; status 1 means unreadable/invalid input. The command prints **only difference categories and counts**. A media URL rewrite or deliberate schema transformation changes the corresponding document digest; a migration must supply a reviewed mapping and explain differences rather than suppressing them. Matching manifests are necessary but not sufficient: verify file bytes, Auth login/password compatibility, access rules, subscriptions and the user scenarios in `PLAN.md` separately.

Run the small synthetic suite without credentials:

```sh
npm test
npm run check
```

The inventory was written to run with standard ADC/service-principal credentials. It was not run against real Firebase or Timeweb in this preparation step.
