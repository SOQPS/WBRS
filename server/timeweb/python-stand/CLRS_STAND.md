# CLRS Timeweb smoke mode (historical deployment)

This document describes only the earlier smoke mode. See CLRS_API_DRAFT.md for the current separate Python 3.12 API stand. This is an infrastructure smoke build for a separate App Platform stand of the existing stopped Flask service. The branch entry point is a standard-library WSGI app. It has no MySQL, Firebase, S3, authentication, payment, or user-data routes. `/healthz` only reports process reachability; `/readyz` deliberately returns HTTP 503 because the CLRS API and private data services are not connected.

The existing application starts `python app.py` on port 5005. Select this branch for a free backend stand. Set only `CLRS_STAGING_SMOKE_ENABLED=1` and confirm that no database, S3, or Firebase environment variables are inherited. Keep the old main application stopped. The stand URL is temporary and must not be put into an APK.

Before launch, review the branch and confirm no legacy routes, hard-coded credentials, or old templates are imported by the new entry point. On the stand URL verify HTTP 200 for `/healthz`, 503 for `/readyz`, and 404 for `/sql/execute`, `/query`, `/users`, and `/chats`. Rollback is to stop or delete only this stand; do not change the old application, MySQL, or public S3 bucket.

This smoke build is not a migrated CLRS backend. A real API requires an agreed contract, private media, TLS to a dedicated database user, access checks, data import, and end-to-end app tests.