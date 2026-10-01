-- Reviewed template only. DO NOT run as part of deploy or migration.
-- First create the two password-protected accounts manually in Timeweb with
-- no pre-existing database/global privileges. Passwords never enter this file.
-- The host component '%' must match the account actually created by Timeweb;
-- use a verified narrower server host if the platform supports it.
-- An authorized DB administrator must apply the exact table grants after the
-- owner confirms the concrete action. No default_db or clrs_staging.* grant.

ALTER USER 'clrs_native_auth'@'%' REQUIRE SSL;
GRANT SELECT ON clrs_staging.accounts TO 'clrs_native_auth'@'%';
GRANT SELECT ON clrs_staging.auth_credentials TO 'clrs_native_auth'@'%';
GRANT SELECT, INSERT, UPDATE ON clrs_staging.device_sessions
  TO 'clrs_native_auth'@'%';

ALTER USER 'clrs_legacy_read'@'%' REQUIRE SSL;
GRANT SELECT ON clrs_staging.accounts TO 'clrs_legacy_read'@'%';
GRANT SELECT ON clrs_staging.legacy_source TO 'clrs_legacy_read'@'%';
GRANT SELECT ON clrs_staging.legacy_documents TO 'clrs_legacy_read'@'%';

-- Privilege inspection only; no password/authentication fields are returned.
SHOW GRANTS FOR 'clrs_native_auth'@'%';
SHOW GRANTS FOR 'clrs_legacy_read'@'%';
-- Verify each account's REQUIRE SSL separately in the private administration
-- console. SHOW CREATE USER can disclose authentication hashes: never copy its
-- complete result into Git, public logs, screenshots or chat.
