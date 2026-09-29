#!/usr/bin/env bash
# Restore a verified archive only into a pre-created, empty clrs_staging database.
set -Eeuo pipefail
set +x
umask 077

die() { printf 'MySQL restore stopped: %s\n' "$1" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing program: $1"; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
file_owner() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"; }
sha256() { openssl dgst -sha256 -r "$1" | cut -d ' ' -f 1; }

archive=''
target=''
confirm=''
execute=false
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
    *) die 'usage: restore-mysql84.sh --archive FILE --target-db clrs_staging [--execute --confirm-target clrs_staging]' ;;
  esac
done
[[ $target == clrs_staging ]] || die 'target must be exactly clrs_staging'
[[ $execute == false || $confirm == clrs_staging ]] || die 'execute requires --confirm-target clrs_staging'
[[ $archive == /* && -f $archive && -r $archive && ! -L $archive ]] || die 'encrypted archive is unavailable'
[[ -f $archive.sha256 && -r $archive.sha256 && ! -L $archive.sha256 ]] || die 'archive checksum is unavailable'
for file in "$archive" "$archive.sha256"; do
  mode=$(file_mode "$file")
  owner=$(file_owner "$file")
  [[ $owner == 0 || $owner == "$EUID" ]] || die 'archive has an unexpected owner'
  (( (8#$mode & 022) == 0 )) || die 'archive must not be writable by others'
done

env_file=${CLRS_MYSQL_RESTORE_ENV_FILE:-/etc/clrs-staging/mysql-restore.env}
[[ -f $env_file && -r $env_file && ! -L $env_file ]] || die 'private mysql-restore.env is unavailable'
mode=$(file_mode "$env_file")
owner=$(file_owner "$env_file")
[[ $owner == 0 || $owner == "$EUID" ]] || die 'mysql-restore.env has an unexpected owner'
(( (8#$mode & 077) == 0 )) || die 'mysql-restore.env must have mode 0600'
# shellcheck disable=SC1090
source "$env_file"
export -n MYSQL_PASSWORD 2>/dev/null || true
unset MYSQL_PWD
export MYSQL_TEST_LOGIN_FILE=/dev/null

for name in MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_DATABASE \
  MYSQL_CA_FILE RESTORE_AGE_IDENTITY_FILE; do
  [[ -n ${!name:-} ]] || die "missing setting: $name"
done
[[ $MYSQL_DATABASE == clrs_staging ]] || die 'database must be clrs_staging'
[[ $MYSQL_HOST =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ && ! $MYSQL_HOST =~ ^[0-9.]+$ ]] \
  || die 'database host must be a DNS name'
[[ $MYSQL_PORT =~ ^[0-9]{1,5}$ ]] || die 'invalid database port'
(( 10#$MYSQL_PORT >= 1 && 10#$MYSQL_PORT <= 65535 )) || die 'invalid database port'
[[ $MYSQL_PASSWORD != *$'\n'* && $MYSQL_PASSWORD != *$'\r'* ]] || die 'invalid password format'
[[ $MYSQL_CA_FILE == /* && -f $MYSQL_CA_FILE && -r $MYSQL_CA_FILE && ! -L $MYSQL_CA_FILE ]] \
  || die 'MySQL CA is unavailable'
[[ $RESTORE_AGE_IDENTITY_FILE == /* && -f $RESTORE_AGE_IDENTITY_FILE && -r $RESTORE_AGE_IDENTITY_FILE && ! -L $RESTORE_AGE_IDENTITY_FILE ]] \
  || die 'age identity is unavailable'
mode=$(file_mode "$RESTORE_AGE_IDENTITY_FILE")
owner=$(file_owner "$RESTORE_AGE_IDENTITY_FILE")
[[ $owner == 0 || $owner == "$EUID" ]] || die 'age identity has an unexpected owner'
(( (8#$mode & 077) == 0 )) || die 'age identity must have mode 0600'

for executable in age mysql openssl stat; do require "$executable"; done
expected=$(cat "$archive.sha256")
[[ $expected =~ ^[a-f0-9]{64}$ ]] || die 'invalid archive checksum format'
[[ $(sha256 "$archive") == "$expected" ]] || die 'encrypted archive checksum mismatch'

client_defaults() {
  local escaped=${MYSQL_PASSWORD//\\/\\\\}
  escaped=${escaped//\"/\\\"}
  printf '[client]\npassword="%s"\n' "$escaped"
}
client_flags=(--no-login-paths --protocol=TCP --host="$MYSQL_HOST" --port="$MYSQL_PORT"
  --user="$MYSQL_USER" --ssl-mode=VERIFY_IDENTITY --ssl-ca="$MYSQL_CA_FILE"
  --default-character-set=utf8mb4 --connect-timeout=5 --database="$target")

verify_sql_stream() {
  local header bytes
  IFS= read -r header || return 1
  [[ $header == '-- CLRS_MYSQL84_STAGING_BACKUP_V1 clrs_staging' ]] || return 1
  bytes=$(wc -c)
  [[ $bytes -gt 64 ]]
}
# Read every decrypted byte to verify age integrity and the staging format.
age -d -i "$RESTORE_AGE_IDENTITY_FILE" "$archive" | verify_sql_stream \
  || die 'archive cannot be decrypted or is not a complete clrs_staging dump'

count=$(mysql --defaults-file=/dev/fd/3 "${client_flags[@]}" \
  --batch --skip-column-names --execute="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='clrs_staging'" \
  3< <(client_defaults) 2>/dev/null) || die 'target database is unavailable'
[[ $count == 0 ]] || die 'clrs_staging must be empty before restore'

if [[ $execute == false ]]; then
  printf 'Dry run: encrypted archive verified and empty clrs_staging reachable. No restore was made.\n'
  exit 0
fi

age -d -i "$RESTORE_AGE_IDENTITY_FILE" "$archive" | \
  mysql --defaults-file=/dev/fd/3 "${client_flags[@]}" 3< <(client_defaults) >/dev/null 2>&1 \
  || die 'restore failed; inspect and recreate the empty staging database before retrying'
printf 'Encrypted archive restored into clrs_staging. Verify schema and counts separately.\n'
