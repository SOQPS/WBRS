# CLRS 1.0.25+39 → WBRS `dev`: local integration review

Base: `origin/dev` at `df49f48fd3e75e2b315b3f9e443a30b3a1fb01a7`.
Integration branch: `codex/clrs-1.0.25-integration`.
Reviewed source: `CLRS-1.0.25-39-sources.zip`, SHA-256
`cd8b7b1034668ea4bd9558bed857ae11a7115d1791b4992523bd7d874f2e3c93`.
The archive source files matched the local CLRS checkout before integration;
later Timeweb documentation and Storage containment source were taken from the
current checkout separately.

## Scope and traceability

`CLRS_1_0_25_manifest.tsv` lists every archive path and every GitHub-only
tracked path with the comparison, decision, and actual resolution.
`CLRS_1_0_25_copied_paths.txt` lists 400 paths copied explicitly from the
archive; `CLRS_1_0_25_post_archive_paths.tsv` records 15 later source paths.
The two visibility helpers
were added after review of their code: they change only the active flag of an
already paid period, never the balance or paid deadline. Current Timeweb docs,
four MySQL 8.4 source/verification files, and four Storage containment
source/test files were copied separately after a filename/content scan.
The current Timeweb migration plan and new authentication gate explain how to
retain existing Firebase logins during a later data/API migration.

The client includes the feed, profile wall, comments, reactions, friends,
navigation, localization, and their source tests. Translation server source and
tests are included. Timeweb source is included for review; its API is still a
separate backend migration and the MySQL schema has not been executed in
Timeweb. Firebase rules under `tool/security/` are source artifacts and this
branch does not deploy them.

## Payment boundary

`payment_preservation.json` records a byte comparison against `origin/dev`.
`shop.dart` now changes the gift catalog UI and opens the recipient sheet before
loading only the current user's chats. The catalog purchase prices, balance
checks and writes, and Robokassa handlers retain their prior behavior.
`oplata.dart`, `robokassa_webview.dart`, `web_page.dart`, the Robokassa Android
library, and the existing payment QR asset remain unchanged.
The GitHub donation banner and its external QR action were retained while the
five-section CLRS navigation was integrated. The drawer's QR target and
`ShopPage` destination match `origin/dev`; the registration balance literal and
`globalBalance` declaration are unchanged. The approved six photographic gift
assets are absent from the checked GitHub branches. Legacy gift PNGs still
contain lettering baked into their pixels; the separate title/description
layout cannot remove that lettering. No replacement art was generated and no
catalog prices were changed pending the approved source assets and price
decision.

There is one unresolved behavior risk: `ShopPage` still calls
`NotificationsService.sendPushMessage`, while CLRS 1.0.25 uses a server hint
instead of embedding a Firebase service account in the APK. With the server
notification flag off, a gift notification may not be delivered. A successful
build cannot verify that flow. The payment transaction handlers are unchanged.

## Credential boundary

The GitHub base tracked `assets/credentials.json` and `assets/key_api`; this
branch deletes both and removes the asset declaration. `.gitignore` now blocks
them, local `.env` files, `node_modules`, and generated native build output.
The 500 previously tracked `android/app/.cxx/` files are deleted from this
branch as generated build output.
The files still exist in the GitHub repository's earlier history. The existing
GitHub payment WebView also contains production-like signing literals; this
branch does not change that file or add new payment values. Their operational
validity was not tested.

`CLRS_1_0_25_full_preflight_scan.tsv` records scanner findings by path, line,
and rule only. The production-looking Firebase `Constants.apiKey` value is
byte-identical in the GitHub base and archive, was not copied, and has no
call-site in client source. Other selected-source findings are demo or test
fixtures; no values are included in the report. The private Timeweb production
audit JSON, service credentials, local auth data, logs, APKs, and dependency
caches were excluded from the integration source paths.

## Timeweb migration blockers

The existing MySQL cluster has secure connections disabled. Enabling them in
Timeweb changes connection details and may disconnect older clients, so the
change was cancelled pending a coordinated transition. The prepared MySQL CLI
and `/readyz` require verified TLS and cannot connect to this cluster as it
stands. The separate `clrs_staging` database is empty and has no dedicated
CLRS user or grants; the MySQL schema has not been applied, and no live data
has been migrated.

The existing 10 GB S3 bucket is public. The old Flask upload route uses
`public-read` and returns direct object URLs; a commented source line names
this exact bucket, but the effective deployed configuration remains unverified. Making it private
may therefore break old clients or links. Private CLRS photos must not be
imported into the public bucket. No full CLRS API is deployed: the included
server exposes infrastructure health/readiness endpoints, not the application
flows needed to replace Firebase.

## Verification and limits

Flutter 3.32.5 `clean` and `pub get` completed. Full `flutter analyze
--no-pub` reported zero errors, one pre-existing `unused_element` warning in
`lib/core/utils/inputs.dart`, and informational lints, so its exit status was
1. The full `flutter test --no-pub` run initially had 648 passes and 13
failures: outdated meeting-guide and notification-style expectations, a
missing localization key, and one unrelated author-request test that passed
on isolated rerun. After the related changes, the targeted 49-test recheck
and the gift localization-usage test passed. The full suite was not repeated.
The Android release-flavor build completed; the APK is delivered outside this
source archive as `CLRS-1.0.25-39-github-integration-test.apk` (SHA-256
`26c40063dfdc6420fd9443ec3a37939b508fe2f3fbc6d68693e30567d261a5d2`). Its
certificate is **Android Debug**, so this is an installable test build, not a
store-signed production release. The isolated Android emulator displayed the
new login screen without overflow and confirmed that registration cannot
proceed until the consent box is checked. A logged-in gift catalog and live account
flows were not available for device verification.

This integration commit itself did not deploy Firebase rules, migrate Timeweb
data, or change live backend services. A temporary auth-only Storage rule was
published separately, and an empty Timeweb `clrs_staging` database was created;
the Timeweb state is recorded in `server/timeweb/README.md`, while the
published Storage rule source and rollback tooling are in `tool/security/`.
An encrypted, private Firebase metadata export contains 8,202 Auth users and
70,412 Firestore documents, but no Storage/photo files or transferable
password hashes. It is not a complete migration source, and no import was run.
Payment and gift flows need device/account checks before release; this review
proves source preservation and a local Android build only.
