#!/usr/bin/env bash
# Restore only into a pre-created, empty test database named clrs_restore_*.
set -Eeuo pipefail
umask 077

die() { printf 'Restore stopped: %s\n' "$1" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing program: $1"; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
file_owner() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"; }

archive=''
target=''
execute=false
confirm=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive|--target-db|--confirm-target)
      [[ $# -ge 2 ]] || die "missing value for $1"
      case "$1" in
        --archive) archive=$2 ;;
        --target-db) target=$2 ;;
        --confirm-target) confirm=$2 ;;
      esac
      shift 2 ;;
    --execute) execute=true; shift ;;
    *) die 'usage: restore.sh --archive FILE --target-db clrs_restore_NAME [--execute --confirm-target NAME]' ;;
  esac
done
[[ -f $archive && -r $archive && ! -L $archive ]] || die 'encrypted archive is unavailable'
[[ $target =~ ^clrs_restore_[a-z0-9_]+$ ]] || die 'target must be a clrs_restore_* database'
[[ $execute == false || $confirm == "$target" ]] || die 'execute requires matching --confirm-target'
env_file=${CLRS_RESTORE_ENV_FILE:-/etc/clrs-staging/restore.env}
[[ -f $env_file && -r $env_file && ! -L $env_file ]] || die 'private restore.env is unavailable'
mode=$(file_mode "$env_file")
owner=$(file_owner "$env_file")
[[ $owner == 0 || $owner == "$EUID" ]] || die 'restore.env has an unexpected owner'
(( (8#$mode & 077) == 0 )) || die 'restore.env must have mode 0600'
set -a
# shellcheck disable=SC1090
source "$env_file"
set +a
for name in RESTORE_PGHOST RESTORE_PGPORT RESTORE_PGUSER RESTORE_PGPASSWORD \
  RESTORE_PGSSLMODE RESTORE_PGSSLROOTCERT RESTORE_AGE_IDENTITY_FILE; do
  [[ -n ${!name:-} ]] || die "missing setting: $name"
done
[[ $RESTORE_PGSSLMODE == verify-full ]] || die 'PostgreSQL TLS verification must be verify-full'
[[ -r $RESTORE_PGSSLROOTCERT && -f $RESTORE_PGSSLROOTCERT ]] || die 'PostgreSQL CA is unavailable'
[[ -r $RESTORE_AGE_IDENTITY_FILE && -f $RESTORE_AGE_IDENTITY_FILE && ! -L $RESTORE_AGE_IDENTITY_FILE ]] \
  || die 'age identity is unavailable'
identity_mode=$(file_mode "$RESTORE_AGE_IDENTITY_FILE")
identity_owner=$(file_owner "$RESTORE_AGE_IDENTITY_FILE")
[[ $identity_owner == 0 || $identity_owner == "$EUID" ]] || die 'age identity has an unexpected owner'
(( (8#$identity_mode & 077) == 0 )) || die 'age identity must have mode 0600'
for executable in age pg_restore psql; do require "$executable"; done

export PGHOST=$RESTORE_PGHOST PGPORT=$RESTORE_PGPORT PGUSER=$RESTORE_PGUSER
export PGPASSWORD=$RESTORE_PGPASSWORD PGSSLMODE=$RESTORE_PGSSLMODE
export PGSSLROOTCERT=$RESTORE_PGSSLROOTCERT

# Parse the encrypted archive without storing decrypted data on disk.
if ! age -d -i "$RESTORE_AGE_IDENTITY_FILE" "$archive" | pg_restore --list >/dev/null 2>&1; then
  die 'archive cannot be decrypted or parsed as a PostgreSQL custom dump'
fi
count=$(psql -X -A -t -v ON_ERROR_STOP=1 --dbname "$target" \
  --command "SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND c.relkind IN ('r','p','v','m','S','f')" 2>/dev/null) \
  || die 'target database unavailable'
[[ $count == 0 ]] || die 'target database is not empty'

if [[ $execute == false ]]; then
  printf 'Dry run: archive parses and empty test target %s is reachable. No restore was made.\n' "$target"
  exit 0
fi

if ! age -d -i "$RESTORE_AGE_IDENTITY_FILE" "$archive" | \
  pg_restore --exit-on-error --single-transaction --no-owner --no-acl \
    --dbname "$target" >/dev/null 2>&1; then
  die 'restore failed; inspect the test database before retrying'
fi
printf 'Encrypted archive restored into test database %s. Verify record counts and application links separately.\n' "$target"
