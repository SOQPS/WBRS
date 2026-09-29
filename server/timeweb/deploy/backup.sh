#!/usr/bin/env bash
# Encrypt a consistent PostgreSQL dump before writing it to disk or private S3.
set -Eeuo pipefail
umask 077

die() { printf 'Backup failed: %s\n' "$1" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing program: $1"; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
file_owner() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"; }
file_size() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"; }

[[ $# -eq 0 || ( $# -eq 1 && $1 == --execute ) ]] || die 'usage: backup.sh [--execute]'
execute=false
[[ $# -eq 1 ]] && execute=true
env_file=${CLRS_BACKUP_ENV_FILE:-/etc/clrs-staging/backup.env}
[[ -f $env_file && -r $env_file && ! -L $env_file ]] || die 'private backup.env is unavailable'
mode=$(file_mode "$env_file")
owner=$(file_owner "$env_file")
[[ $owner == 0 || $owner == "$EUID" ]] || die 'backup.env has an unexpected owner'
(( (8#$mode & 027) == 0 )) || die 'backup.env must not be group-writable or world-accessible'
# This is a trusted, administrator-owned shell environment file outside git.
set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

for name in PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE PGSSLMODE PGSSLROOTCERT \
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION S3_ENDPOINT \
  BACKUP_S3_BUCKET BACKUP_S3_PREFIX BACKUP_AGE_RECIPIENT_FILE BACKUP_DIR; do
  [[ -n ${!name:-} ]] || die "missing setting: $name"
done
[[ $PGSSLMODE == verify-full ]] || die 'PostgreSQL TLS verification must be verify-full'
[[ -r $PGSSLROOTCERT && -f $PGSSLROOTCERT ]] || die 'PostgreSQL CA is unavailable'
[[ -r $BACKUP_AGE_RECIPIENT_FILE && -f $BACKUP_AGE_RECIPIENT_FILE ]] || die 'age recipient is unavailable'
[[ $S3_ENDPOINT == https://* ]] || die 'S3 endpoint must use HTTPS'
[[ $BACKUP_S3_BUCKET =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] || die 'invalid backup bucket'
[[ $BACKUP_S3_PREFIX =~ ^[A-Za-z0-9/_-]+$ ]] || die 'invalid S3 prefix'
[[ $BACKUP_DIR == /* && $BACKUP_DIR != / ]] || die 'backup directory must be absolute'

if [[ $execute == false ]]; then
  printf 'Dry run: backup configuration valid. No database read or S3 write was made.\n'
  exit 0
fi

for executable in pg_dump age aws openssl sha256sum stat; do require "$executable"; done
[[ -d $BACKUP_DIR && -w $BACKUP_DIR && ! -L $BACKUP_DIR ]] || die 'private backup directory is unavailable'
dir_mode=$(file_mode "$BACKUP_DIR")
dir_owner=$(file_owner "$BACKUP_DIR")
[[ $dir_owner == "$EUID" ]] || die 'backup directory must be owned by the backup user'
(( (8#$dir_mode & 077) == 0 )) || die 'backup directory must have mode 0700'
versioning=$(aws --endpoint-url "$S3_ENDPOINT" s3api get-bucket-versioning \
  --bucket "$BACKUP_S3_BUCKET" --query Status --output text)
[[ $versioning == Enabled ]] || die 'backup bucket versioning is not enabled'
name="clrs-pg-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 8).dump.age"
partial="$BACKUP_DIR/.$name.partial"
final="$BACKUP_DIR/$name"
[[ ! -e $partial && ! -e $final ]] || die 'backup name collision'
trap 'rm -f -- "$partial"' EXIT

# No plaintext dump file or database password appears in command arguments.
pg_dump --format=custom --no-owner --no-acl | age -R "$BACKUP_AGE_RECIPIENT_FILE" -o "$partial"
[[ -s $partial ]] || die 'empty encrypted archive'
# An encrypted, complete archive survives a failed upload for an operator retry.
mv -- "$partial" "$final"
bytes=$(file_size "$final")
digest=$(sha256sum "$final")
digest=${digest%% *}
key="$BACKUP_S3_PREFIX/$(date -u +%Y/%m/%d)/$name"
aws --endpoint-url "$S3_ENDPOINT" s3 cp "$final" "s3://$BACKUP_S3_BUCKET/$key" \
  --metadata "sha256=$digest" --only-show-errors >/dev/null
remote_bytes=$(aws --endpoint-url "$S3_ENDPOINT" s3api head-object \
  --bucket "$BACKUP_S3_BUCKET" --key "$key" --query ContentLength --output text)
remote_digest=$(aws --endpoint-url "$S3_ENDPOINT" s3api head-object \
  --bucket "$BACKUP_S3_BUCKET" --key "$key" --query Metadata.sha256 --output text)
[[ $remote_bytes == "$bytes" && $remote_digest == "$digest" ]] || die 'S3 size/checksum metadata mismatch'
download_digest=$(aws --endpoint-url "$S3_ENDPOINT" s3 cp \
  "s3://$BACKUP_S3_BUCKET/$key" - --only-show-errors | sha256sum)
download_digest=${download_digest%% *}
[[ $download_digest == "$digest" ]] || die 'S3 object content checksum mismatch'
rm -- "$final"
printf 'Encrypted PostgreSQL backup uploaded and checked: %s (%s bytes).\n' "$key" "$bytes"
