#!/usr/bin/env bash
# Copy current media objects into a separate versioned private backup bucket.
set -Eeuo pipefail
umask 077

die() { printf 'Media backup stopped: %s\n' "$1" >&2; exit 1; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
file_owner() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"; }
[[ $# -eq 0 || ( $# -eq 1 && $1 == --execute ) ]] || die 'usage: backup-media.sh [--execute]'
execute=false
[[ $# -eq 1 ]] && execute=true
env_file=${CLRS_MEDIA_BACKUP_ENV_FILE:-/etc/clrs-staging/media-backup.env}
[[ -f $env_file && -r $env_file && ! -L $env_file ]] || die 'private media-backup.env is unavailable'
mode=$(file_mode "$env_file")
owner=$(file_owner "$env_file")
[[ $owner == 0 || $owner == "$EUID" ]] || die 'media-backup.env has an unexpected owner'
(( (8#$mode & 027) == 0 )) || die 'media-backup.env must not be group-writable or world-accessible'
set -a
# shellcheck disable=SC1090
source "$env_file"
set +a
for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION S3_ENDPOINT \
  MEDIA_S3_BUCKET BACKUP_S3_BUCKET BACKUP_MEDIA_PREFIX; do
  [[ -n ${!name:-} ]] || die "missing setting: $name"
done
[[ $S3_ENDPOINT == https://* ]] || die 'S3 endpoint must use HTTPS'
for bucket in "$MEDIA_S3_BUCKET" "$BACKUP_S3_BUCKET"; do
  [[ $bucket =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] || die 'invalid S3 bucket'
done
[[ $MEDIA_S3_BUCKET != "$BACKUP_S3_BUCKET" ]] || die 'media and backup buckets must differ'
[[ $BACKUP_MEDIA_PREFIX =~ ^[A-Za-z0-9/_-]+$ ]] || die 'invalid backup prefix'

if [[ $execute == false ]]; then
  printf 'Dry run: media backup configuration valid. No S3 listing or copy was made.\n'
  exit 0
fi
command -v aws >/dev/null 2>&1 || die 'missing program: aws'
for bucket in "$MEDIA_S3_BUCKET" "$BACKUP_S3_BUCKET"; do
  versioning=$(aws --endpoint-url "$S3_ENDPOINT" s3api get-bucket-versioning \
    --bucket "$bucket" --query Status --output text)
  [[ $versioning == Enabled ]] || die "versioning is not enabled for $bucket"
done
# Deliberately omit --delete. Older copies survive a deletion in the source bucket.
aws --endpoint-url "$S3_ENDPOINT" s3 sync \
  "s3://$MEDIA_S3_BUCKET/" "s3://$BACKUP_S3_BUCKET/$BACKUP_MEDIA_PREFIX/" \
  --only-show-errors >/dev/null
printf 'Current media objects copied to private backup prefix %s. Restore spot checks are still required.\n' \
  "$BACKUP_MEDIA_PREFIX"
