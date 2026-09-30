# Read-only inventory before migration

The bounded CLRSX2 staging importer and read-back verifier are described in [IMPORT_PREPARATION.md](IMPORT_PREPARATION.md). They are local preparation only; no real Timeweb import or APK switch has been performed.

The encrypted exporter also supports `--scope metadata` for Auth metadata and typed Firestore documents without listing or downloading Storage objects. It marks this CLRSX2 archive as a partial source (`completeSource: false`); the staging importer rejects it before any writes. See [encrypted export preparation](EXPORT_PREPARATION.md) for the bounded command and limits.

Current status (2026-09-30): migration is **not complete**. The legacy Flask remains stopped after an unauthenticated SQL editor was confirmed. The existing Timeweb MySQL cluster now contains a separate `clrs_staging` schema with **42 tables and 66 foreign keys**, verified empty after one guarded DDL application. No new paid resource was ordered and `default_db` was not changed. Firebase Owner access and Auth/Firestore/Storage reads work. The earlier protected source inventory records 8,202 Auth users, 70,412 Firestore documents, and 6,472 Storage objects totalling 6,917,630,044 bytes. A separate authenticated **partial metadata archive** excludes file bytes and password secrets and is rejected by the importer. A new full encrypted archive is running with bounded Firestore concurrency (Auth 8,208 and Firestore 70,486 completed; Storage bytes still streaming); do not import its unfinished file. These live reads are not an atomic snapshot while Firebase writes continue. No real data has been imported into Timeweb and no APK has been switched. See [account inventory](ACCOUNT_INVENTORY.md), [migration plan](PLAN.md), [encrypted export preparation](EXPORT_PREPARATION.md), [database schema](db/MYSQL84_STAGING.md), [guarded schema application](APPLY_MYSQL84.md), and [deployment/backup templates](deploy/README.md).

The manifest reports 2,177 Auth accounts without a root `users` profile, 72 root profiles without an Auth account, 5,453 unresolved user references, and 389 referenced Storage keys absent from its object listing. These are **comparison results for this read**, not confirmed data-loss defects; registration state, legacy records, link formats and concurrent writes still need review. Keep the manifest and archive private; neither belongs in Git or an APK.

The existing paid App Platform has a separate **free stand** (ID 5167), using a branch without the legacy SQL editor or database credentials. A read-only Python API draft is [published in GitLab](https://gitlab.com/4eKHyTblyi/python_server/-/tree/codex/clrs-api-readonly-draft) at `fbd4ecafdb968ab31f529fa855a730f5870a7245`. Its downloaded archive matches all 11 reviewed local files byte for byte; 25 synthetic Python tests passed. Missing/invalid bearer tokens return 401, legacy SQL routes return 404, and readiness remains 503 `migration_incomplete`. The SELECT-only technical DB URL was supplied through stand settings, outside Git and APK. The older stand 5167 retained Python 3.14 and rejected the provider certificate. A second free stand 5179 was built after selecting Python 3.12; its HTTPS `/readyz` returns 503 `migration_incomplete` with **`database_connected:true`** at `https://4ekhytblyi-python-server-stand-f41f.twc1.net`. The published code requires `CERT_REQUIRED` and hostname verification; certificate checks were not disabled. Imported profiles and a live authenticated API request are still required.

The existing 10 GB S3 bucket is now **private**, with automatic paid capacity expansion disabled. Its one legacy object was backed up locally and its byte hash was preserved. The restricted migration S3 user can write only quarantine/probe prefixes and delete only disposable privacy probes; the 30-day Timeweb token has S3 read access only. Live control-plane private type, owner-only ACL, exact empty policy and anonymous denial of a real random probe were verified; the probe was removed. No user media has been imported yet.

Both DB users were verified against the real cluster: `clrs_api_ro` has SELECT only on `clrs_staging.*`; temporary `clrs_migrate` has exactly CREATE, REFERENCES, SELECT, INSERT and UPDATE on that database. `USE default_db` was denied. Import/schema helpers set strict SQL mode only on their own connection and keep global server settings unchanged.

A separate encrypted Auth credential export was authenticated and read back: **8,208 password accounts**, all with available hash/salt, version 0 and project SCRYPT configuration. Keys and sensitive hash configuration remain in private local files outside Git. This preserves the inputs needed for legacy-password compatibility, but **no standalone Timeweb login is verified**. See [Auth migration gate](AUTH_MIGRATION_GATE.md). Newly preserved legacy admin claims also require final synchronization; an earlier Auth page read must not be treated as the final rights snapshot.

`PLAN.md` describes the migration gates. The inventory and manifest comparison scripts **do not export user content**, write to Firebase, import data into Timeweb, or switch an APK. They produce a protected manifest of counts, HMAC fingerprints of Auth UIDs/emails, Firestore document paths and content, Storage object keys/checksums, and selected ID/storage links. A matching HMAC key allows a later Timeweb inventory to be compared without listing names, emails, message text or download tokens.

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

The encrypted metadata exporter and the earlier Firebase inventory ran against the real project. Their authenticated archive ending and manifest structure were checked locally. They provide a baseline, but no matching Timeweb data manifest exists yet. The full archive and separate credential export serve different purposes and must not be confused. Schema DDL has run on the empty staging database; no real user/content import or end-to-end Timeweb APK acceptance is verified.
