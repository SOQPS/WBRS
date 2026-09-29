-- Read-only check AFTER applying 001_initial_mysql84.sql and BEFORE importing.
-- Run against the isolated clrs_staging database; it never changes data.
SELECT VERSION() AS mysql_version, @@innodb_page_size AS innodb_page_size;

SELECT
  (SELECT COUNT(*) FROM information_schema.tables
   WHERE table_schema = 'clrs_staging' AND table_type = 'BASE TABLE') AS tables_found,
  (SELECT COUNT(*) FROM information_schema.referential_constraints
   WHERE constraint_schema = 'clrs_staging') AS foreign_keys_found,
  (SELECT COUNT(*) FROM clrs_staging.schema_migrations WHERE version = 1) AS version_marker_found,
  (SELECT COUNT(*) FROM clrs_staging.event_counter WHERE singleton = 1 AND last_id = 0) AS event_counter_found;

SELECT
  (SELECT COUNT(*) FROM clrs_staging.accounts) AS accounts,
  (SELECT COUNT(*) FROM clrs_staging.legacy_auth_users) AS archived_auth_users,
  (SELECT COUNT(*) FROM clrs_staging.legacy_documents) AS archived_documents,
  (SELECT COUNT(*) FROM clrs_staging.legacy_storage_objects) AS archived_storage_objects;
