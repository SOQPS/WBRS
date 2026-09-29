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
`shop.dart`, `oplata.dart`, `robokassa_webview.dart`, `web_page.dart`, the
Robokassa Android library, and the existing payment QR asset are unchanged.
The GitHub donation banner and its external QR action were retained while the
five-section CLRS navigation was integrated. The drawer's QR target and
`ShopPage` destination match `origin/dev`; the registration balance literal and
`globalBalance` declaration are unchanged. Gift art, paid shop modules,
payment tests, and payment localization transformation scripts were excluded.

There is one unresolved behavior risk: the old `ShopPage` still calls
`NotificationsService.sendPushMessage`, while CLRS 1.0.25 uses a server hint
instead of embedding a Firebase service account in the APK. With the server
notification flag off, a gift notification may not be delivered. A successful
build cannot verify that flow. The payment transaction code is unchanged.

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

## Verification and limits

Flutter 3.32.5 `pub get` resolved the merged dependencies. `flutter analyze
--no-pub` finished with zero errors, one existing `unused_element` warning,
and informational lints (exit 1 because of lint findings). Android
`flutter build apk --release --flavor production --no-pub` succeeded and
produced the APK preserved outside the repository at
`artifacts/clrs_github_integration_2026-09-30/CLRS-1.0.25-39-github-integration-test.apk`, SHA-256
`bf9ad83ff9e8235454b5cfe0503a437055df9520184c3f544513c9f485ccd988`.
The APK certificate is **Android Debug**: this is an installable test build,
not a store-signed production release. The first targeted run had one failing
test because its test tap hit the timeout snackbar covering the like button;
the feed implementation was byte-identical to the reviewed source. The test
now waits for the snackbar to clear, matching its neighboring test. The final
targeted run passed **28/28** tests across feed QA, sharing/permissions,
retained reactions, and notification navigation. A staged-diff secret scan
found two non-secret fixtures: an emulator-only demo Firebase option and a
URL-with-userinfo case in a test. It found no newly staged live credentials.
The scan lists path, line, and rule only; no values are recorded.

This integration commit itself did not deploy Firebase rules, migrate Timeweb
data, or change live backend services. A temporary auth-only Storage rule was
published separately, and an empty Timeweb `clrs_staging` database was created;
the Timeweb state is recorded in `server/timeweb/README.md`, while the
published Storage rule source and rollback tooling are in `tool/security/`.
Payment and gift flows need device/account checks before release; this review
proves source preservation and a local Android build only.
