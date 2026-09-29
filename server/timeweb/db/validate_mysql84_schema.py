#!/usr/bin/env python3
"""Local-only parity/safety check for the CLRS MySQL staging DDL.

This deliberately does not connect to MySQL, Timeweb, Firebase, or S3. It is
not a substitute for executing the DDL on an isolated MySQL 8.4 instance.
"""

from __future__ import annotations

import re
from pathlib import Path


DB_DIR = Path(__file__).resolve().parent
PG_SQL = DB_DIR / "001_initial.sql"
MYSQL_SQL = DB_DIR / "001_initial_mysql84.sql"


def without_comments(sql: str) -> str:
    return re.sub(r"(?m)^\s*--[^\n]*$", "", sql)


def tables(sql: str, schema: str, mysql: bool) -> dict[str, str]:
    ending = r"^\) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;" if mysql else r"^\);"
    pattern = re.compile(
        rf"^CREATE TABLE {schema}\.(\w+) \(\n(.*?){ending}",
        re.MULTILINE | re.DOTALL,
    )
    result = {match.group(1): match.group(2) for match in pattern.finditer(sql)}
    assert result, f"No {schema} tables found"
    return result


def columns(body: str) -> set[str]:
    reserved = {"PRIMARY", "UNIQUE", "KEY", "CONSTRAINT", "CHECK", "FOREIGN"}
    return {
        name
        for name in re.findall(r"(?m)^  ([a-z][a-z0-9_]*)\s+", body)
        if name.upper() not in reserved
    }


def foreign_keys(body: str, schema: str) -> set[tuple[tuple[str, ...], str, tuple[str, ...]]]:
    found = set()
    for child, parent, target in re.findall(
        rf"FOREIGN KEY \(([^)]+)\) REFERENCES {schema}\.(\w+)\(([^)]+)\)",
        body,
    ):
        found.add((tuple(x.strip() for x in child.split(",")), parent,
                   tuple(x.strip() for x in target.split(","))))
    for name, parent, target in re.findall(
        rf"(?m)^  (\w+) [^\n]*? REFERENCES {schema}\.(\w+)\(([^)]+)\)",
        body,
    ):
        if name not in {"CONSTRAINT", "FOREIGN"}:
            found.add(((name,), parent, tuple(x.strip() for x in target.split(","))))
    return found


def main() -> None:
    pg = without_comments(PG_SQL.read_text())
    my = without_comments(MYSQL_SQL.read_text())
    pg_tables = tables(pg, "clrs", mysql=False)
    my_tables = tables(my, "clrs_staging", mysql=True)
    assert set(pg_tables) == set(my_tables), (
        f"Table parity: missing={sorted(set(pg_tables) - set(my_tables))}, "
        f"extra={sorted(set(my_tables) - set(pg_tables))}"
    )

    fk_count = 0
    for name in sorted(pg_tables):
        missing_columns = columns(pg_tables[name]) - columns(my_tables[name])
        assert not missing_columns, f"{name}: missing columns {sorted(missing_columns)}"
        pg_fks = foreign_keys(pg_tables[name], "clrs")
        my_fks = foreign_keys(my_tables[name], "clrs_staging")
        assert pg_fks == my_fks, (
            f"{name}: missing FKs {sorted(pg_fks - my_fks)}; "
            f"extra FKs {sorted(my_fks - pg_fks)}"
        )
        fk_count += len(my_fks)

    assert re.search(r"(?m)^SET time_zone = '\+00:00';$", my)
    created_tables = re.findall(r"(?m)^CREATE TABLE (\w+)\.(\w+) \(", my)
    assert len(created_tables) == len(my_tables)
    assert all(schema == "clrs_staging" for schema, _ in created_tables)
    assert not re.search(r"(?im)^\s*(?:CREATE\s+DATABASE|DROP|TRUNCATE|GRANT|REVOKE|ALTER|USE|DELETE|UPDATE)\b", my)
    assert not re.search(r"(?i)\bdefault_db\b", my)
    assert not re.search(r"(?i)\b(?:postgres|firebase|s3)\s*[:.]", my)
    inserts = re.findall(r"(?m)^INSERT INTO (\w+\.\w+)", my)
    assert inserts == ["clrs_staging.event_counter", "clrs_staging.schema_migrations"], inserts
    assert my.rstrip().endswith("INSERT INTO clrs_staging.schema_migrations (version) VALUES (1);")
    assert "UNIQUE KEY profile_one_primary_photo_uq (uid, primary_slot)" in my
    assert "UNIQUE KEY legacy_documents_path_uq (firebase_path_sha256)" in my
    assert "UNIQUE KEY legacy_storage_source_uq (source_bucket, source_path_sha256)" in my
    assert "UNIQUE KEY legacy_auth_users_uid_uq (uid_sha256)" in my

    print(f"OK: {len(my_tables)} tables, {fk_count} FK relationships; complete PG column parity; local SQL only")


if __name__ == "__main__":
    main()
