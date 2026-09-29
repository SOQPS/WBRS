-- Reversal is intentionally limited to a disposable, EMPTY staging schema.
-- A populated migration must instead be rolled back by restoring the verified
-- pre-migration database backup to a separate database and switching traffic.
BEGIN;
SELECT pg_advisory_xact_lock(hashtext('clrs:001_initial'));
DO $$
DECLARE
  relation record;
  has_rows boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'clrs') THEN
    RAISE EXCEPTION 'CLRS schema does not exist';
  END IF;
  IF (SELECT count(*) FROM clrs.schema_migrations) <> 1
     OR NOT EXISTS (SELECT 1 FROM clrs.schema_migrations WHERE version = 1) THEN
    RAISE EXCEPTION 'Refusing to drop a schema with later migrations';
  END IF;
  FOR relation IN
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'clrs'
      AND tablename NOT IN ('schema_migrations', 'event_counter')
  LOOP
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM clrs.%I LIMIT 1)', relation.tablename)
      INTO has_rows;
    IF has_rows THEN
      RAISE EXCEPTION 'Refusing to drop populated CLRS table %', relation.tablename;
    END IF;
  END LOOP;
END $$;
DROP SCHEMA clrs CASCADE;
COMMIT;
