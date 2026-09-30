#!/usr/bin/env bash
# Copy backed-up media into a separate test bucket only.
set -Eeuo pipefail
set +x
umask 077

die() { printf 'Media restore stopped: %s\n' "$1" >&2; exit 1; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
file_owner() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"; }
target=''
execute=false
confirm=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-bucket|--confirm-target)
      [[ $# -ge 2 ]] || die "missing value for $1"
      case "$1" in
        --target-bucket) target=$2 ;;
        --confirm-target) confirm=$2 ;;
      esac
      shift 2 ;;
    --execute) execute=true; shift ;;
    *) die 'usage: restore-media.sh --target-bucket clrs-restore-NAME [--execute --confirm-target NAME]' ;;
  esac
done
[[ $target =~ ^clrs-restore-[a-z0-9-]+$ ]] || die 'target must be a clrs-restore-* bucket'
[[ $execute == false || $confirm == "$target" ]] || die 'execute requires matching --confirm-target'
env_file=${CLRS_MEDIA_RESTORE_ENV_FILE:-/etc/clrs-staging/media-restore.env}
[[ -f $env_file && -r $env_file && ! -L $env_file ]] || die 'private media-restore.env is unavailable'
mode=$(file_mode "$env_file")
owner=$(file_owner "$env_file")
[[ $owner == 0 || $owner == "$EUID" ]] || die 'media-restore.env has an unexpected owner'
(( (8#$mode & 077) == 0 )) || die 'media-restore.env must have mode 0600'
set -a
# shellcheck disable=SC1090
source "$env_file"
set +a
for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION S3_ENDPOINT \
  TIMEWEB_API_TOKEN MEDIA_S3_BUCKET BACKUP_S3_BUCKET RESTORE_S3_BUCKET_ID \
  BACKUP_MEDIA_PREFIX; do
  [[ -n ${!name:-} ]] || die "missing setting: $name"
done
[[ $S3_ENDPOINT == https://* ]] || die 'S3 endpoint must use HTTPS'
for bucket in "$MEDIA_S3_BUCKET" "$BACKUP_S3_BUCKET"; do
  [[ $bucket =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] || die 'invalid S3 bucket'
done
[[ $BACKUP_MEDIA_PREFIX =~ ^[A-Za-z0-9/_-]+$ ]] || die 'invalid backup prefix'
[[ $target != "$MEDIA_S3_BUCKET" && $target != "$BACKUP_S3_BUCKET" ]] || die 'cannot overwrite a live bucket'
[[ $RESTORE_S3_BUCKET_ID =~ ^[1-9][0-9]*$ ]] || die 'invalid restore bucket ID'
if [[ $execute == false ]]; then
  printf 'Dry run: media would be copied into test bucket %s. No S3 call was made.\n' "$target"
  exit 0
fi
command -v aws >/dev/null 2>&1 || die 'missing program: aws'
command -v node >/dev/null 2>&1 || die 'missing program: node'
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
node "$script_dir/check-private-media-bucket.mjs" "$target" "$RESTORE_S3_BUCKET_ID" \
  || die 'restore bucket privacy preflight failed'
existing=$(aws --endpoint-url "$S3_ENDPOINT" s3api list-objects-v2 \
  --bucket "$target" --max-keys 1 --query KeyCount --output text) \
  || die 'target bucket unavailable'
[[ $existing == 0 ]] || die 'target bucket is not empty'
aws --endpoint-url "$S3_ENDPOINT" s3 sync \
  "s3://$BACKUP_S3_BUCKET/$BACKUP_MEDIA_PREFIX/" "s3://$target/" \
  --only-show-errors >/dev/null
node "$script_dir/check-private-media-bucket.mjs" "$target" "$RESTORE_S3_BUCKET_ID" \
  || die 'restore bucket privacy recheck failed; inspect the copied objects'
printf 'Media restored into test bucket %s. Check sample file bytes and permissions.\n' "$target"
