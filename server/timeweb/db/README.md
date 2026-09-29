# CLRS staging database

For the existing, empty Timeweb MySQL 8.4 `clrs_staging` database, use the separate [MySQL staging guide](MYSQL84_STAGING.md). The PostgreSQL instructions below do not apply to that database.

`001_initial.sql` is the initial PostgreSQL schema for a **new, isolated** CLRS database. It has not been applied to Timeweb. It does not read or change the existing Timeweb MySQL `default_db` or production Firebase.

Apply with a migration-owner role, in a newly provisioned PostgreSQL database, after taking a baseline backup:

```sh
psql -X -v ON_ERROR_STOP=1 -f 001_initial.sql
psql -X -v ON_ERROR_STOP=1 -f smoke.sql
```

The first file is transactional and intentionally fails if the `clrs` schema already exists. `smoke.sql` rolls back its synthetic rows. Do not run `001_down.sql` on a populated database: it refuses to drop user data. The operational rollback is to stop writes, reconcile any new Timeweb writes, restore the verified pre-cutover backup to an isolated database, then switch the test client/server endpoint back; production Firebase remains intact until acceptance.

Import in two phases. First, record **all** Auth users, Firestore documents and Storage objects in `legacy_auth_users`, `legacy_documents` and `legacy_storage_objects` using original Firebase UID, document ID/path, type-tagged field values, hashes, bytes and object paths. These tables intentionally have no parent foreign key so a missing parent is reported instead of silently discarding a subcollection. Promote Scrypt material to the private `auth_credentials` table only after a tested export, or use the verified Firebase-token bridge; never place secrets in reports. Treat all `legacy_*` tables and private auth/session/token tables as restricted to migration/auth services. Do not grant an API or reporting role blanket `SELECT` on the whole schema.

`legacy_source` binds this isolated target to exactly one Firebase project/database/bucket. `legacy_storage_objects.source_metadata` preserves the original generation, MIME and private Firebase metadata for review. The first-stage importer and independent read-back verifier are documented in [IMPORT_PREPARATION.md](../IMPORT_PREPARATION.md). They have only been exercised with synthetic data; do not treat this schema as an applied Timeweb migration.

Second, promote validated records into the relational tables within transactions, keeping original UID, chat ID, meeting ID, message ID and gift asset ID. Existing Firestore fields not mapped to columns remain in `legacy_raw` / `encoded_payload` until every API reader is checked. Compute chat member ordering with `uid_low < uid_high`, preserve message ordering with per-room `sequence`, and preserve the original timestamp type/value in encoded legacy payload. Stage or report any duplicate email, chat pair, orphaned user/reference, unknown status or inconsistent gift/balance; do not silently rename IDs or weaken constraints to make imports pass. `creation_request_id`, `idempotency_receipts` and unique source IDs prevent retries from replaying mutations. The server must atomically update wallet and ledger, membership and archive, chat and unread cursor, and entity and outbox; table constraints alone do not enforce those multi-row rules. The event publisher increments `event_counter.last_id` with `UPDATE ... RETURNING` in the **same transaction** as inserting `user_events`, so SSE cursor IDs follow commit order.

Before any test APK switch, compare source and target counts by Firebase collection path, Auth UIDs/providers/disabled state, Storage object count/size/checksum, missing references and gift balances. Check server authorization for every owner/admin route; database constraints are a second line of defense, not API access control. The API and client integration are not yet implemented.
