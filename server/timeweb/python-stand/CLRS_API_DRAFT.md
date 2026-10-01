# CLRS API draft on the existing Timeweb stand

**Status, 2026-10-01:** the reviewed code at GitLab commit `fbd4ecafdb968ab31f529fa855a730f5870a7245` runs on free stand **5179**, “CLRS TLS Python3.12”, at `https://4ekhytblyi-python-server-stand-f41f.twc1.net`. The stand uses Python 3.12, four stand-only env variables and the dedicated read-only DB account. Live `/readyz` returns HTTP 503 with `state:migration_incomplete` and `database_connected:true`; certificate and hostname verification remain enabled. The legacy main Flask stays stopped. The existing staging database now has 42 empty tables and 66 foreign keys; no real authenticated profile request or full-data import has succeeded. This directory preserves the reviewed deployment sources together with the mobile/migration repository; do not deploy unrelated repository files.

The deployed revision exposes `GET /v1/me/profile` with a Firebase ID token in the Authorization Bearer header. The server verifies its Google signature, issuer, audience, expiry and current Firebase account status, including disabled state and `validSince`, on every request. The UID returned by that check is the only key passed to a fixed, parameterized MySQL SELECT. The endpoint returns a short allowlist of the **same user's** profile fields. There is no route to fetch another user's profile, execute SQL, upload media, or administer accounts. `/readyz` intentionally remains HTTP 503 while the migration is incomplete.

The next reviewed sources additionally include **default-off** native login/refresh/logout routes and native bearer verification. See [NATIVE_AUTH.md](NATIVE_AUTH.md) for secrets, exact table grants, session/replay semantics and outstanding live gates. Do not enable native flags before full import, encrypted-credential readback and restricted runtime role checks. The HTTP runtime bounds workers and absolute socket duration, suppresses private tracebacks and keeps unrelated health requests independent of a slow request. Offline checks passed; live native login is still unverified.

## Configuration for the isolated review deployment

Set exactly one of `CLRS_STAGING_SMOKE_ENABLED=1` or `CLRS_API_DRAFT_ENABLED=1`. The draft requires `FIREBASE_PROJECT_ID`, `FIREBASE_WEB_API_KEY` and `CLRS_DB_URL`. It uses the bundled public `timeweb-ca.pem` by default; `CLRS_DB_CA_FILE` can override it with an absolute CA path. Keep the DB URL and other secrets in Timeweb's protected environment configuration, never in Git or a ZIP. The DB URL must name the separate `clrs_staging` database with `sslmode=verify-full`; certificate validation and hostname checking remain required. Provide a dedicated DB user with **SELECT only** on `clrs_staging.accounts` and `clrs_staging.profiles`. Neither the old Flask DB user nor its `default_db` is accepted by the intended deployment plan. `/readyz` always stays HTTP 503 while migration is incomplete and reports only whether a fixed `SELECT 1` TLS connection succeeded.

The current Timeweb MySQL cluster has TLS enabled by its owner. The bundled public CA comes from `https://st.timeweb.com/cloud-static/ca.crt`; its SHA-256 certificate fingerprint is `17179BADB992FEB038426FF31BA66AB7FA711F092CA22705BD7251F3011A124D`. Python 3.14 strict X.509 validation rejected the provider certificate for a missing Authority Key Identifier; Python 3.12 on the new stand passes the verified-TLS connection probe. No certificate validation was disabled. The migration role has exactly CREATE, REFERENCES, SELECT, INSERT, UPDATE only on `clrs_staging`; the read-only role has SELECT there. Both are denied access to `default_db`. The empty schema was applied once; do not run its DDL again.

Run local checks with dependencies from `requirements.txt`:

```sh
python -m unittest discover -v

```

Tests use synthetic JWT keys and fake SQL connections. They do not prove live Firebase token lookup, MySQL TLS, legacy account-state parity, or app behavior.

## Review and rollback before any later deployment

1. Record the existing stand ID, deployed commit, environment variable names, health response and current stopped state of legacy main. Keep secrets out of that record. Retain the known-good smoke branch and its ZIP.
2. Review the draft diff and test results. Use a separate stand/deployment version with no connection to real data until the DB TLS, restricted user and an empty-schema rehearsal are verified. Do not switch the app or legacy main.
3. If a later test fails, remove the draft-only environment variables and redeploy the recorded smoke commit to the stand. Confirm `/healthz` returns `smoke_only` and `/readyz` returns 503. Check that legacy main is still stopped. No data rollback should be required while this draft remains read-only and disconnected.

The full migration still needs a complete verified data export/import, reconciled references, restricted media API, standalone login/session lifecycle and controlled end-to-end tests before the APK can change servers. The existing S3 bucket is now private: its old single object is backed up, an authenticated privacy probe passed and anonymous access returns 403. Auto-upgrade is disabled and the existing 10 GB tariff is unchanged. Technical S3 and control-plane read credentials stay outside this repository. No new paid resource was ordered.
