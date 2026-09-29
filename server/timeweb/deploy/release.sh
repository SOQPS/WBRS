#!/usr/bin/env bash
# Deploy or revert only the new isolated staging API image, never Firebase data.
set -Eeuo pipefail
umask 077

die() { printf 'Release stopped: %s\n' "$1" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing program: $1"; }
valid_image() { [[ $1 =~ ^[A-Za-z0-9._:/-]+@sha256:[a-f0-9]{64}$ ]]; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
file_owner() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"; }

[[ $# -ge 1 ]] || die 'usage: release.sh plan|deploy IMAGE | rollback [--execute --confirm-image IMAGE]'
action=$1
shift
case "$action" in
  plan|deploy)
    [[ $# -ge 1 ]] || die 'missing immutable API image'
    image=$1
    shift ;;
  rollback)
    image=''
    ;;
  *) die 'usage: release.sh plan|deploy IMAGE | rollback [--execute --confirm-image IMAGE]' ;;
esac
execute=false
confirm=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) execute=true; shift ;;
    --confirm-image)
      [[ $# -ge 2 ]] || die 'missing confirmation image'
      confirm=$2; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ $action != plan || $execute == false ]] || die 'plan never deploys'

state_dir=${CLRS_STATE_DIR:-/var/lib/clrs-staging}
compose_env=${CLRS_COMPOSE_ENV_FILE:-/etc/clrs-staging/compose.env}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
compose_file="$script_dir/compose.yaml"
[[ -f $compose_env && -r $compose_env && ! -L $compose_env ]] || die 'private compose.env is unavailable'
mode=$(file_mode "$compose_env")
owner=$(file_owner "$compose_env")
[[ $owner == 0 || $owner == "$EUID" ]] || die 'compose.env has an unexpected owner'
(( (8#$mode & 077) == 0 )) || die 'compose.env must have mode 0600'
set -a
# shellcheck disable=SC1090
source "$compose_env"
set +a
[[ -n ${CLRS_DOMAIN:-} && $CLRS_DOMAIN =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ \
   && $CLRS_DOMAIN == *.* && $CLRS_DOMAIN != *..* ]] || die 'invalid staging domain'
[[ -n ${CLRS_API_ENV_FILE:-} && $CLRS_API_ENV_FILE == /* ]] || die 'API env path must be absolute'
[[ -n ${CLRS_DATABASE_CA_HOST_FILE:-} && $CLRS_DATABASE_CA_HOST_FILE == /* ]] \
  || die 'PostgreSQL CA path must be absolute'

if [[ $action == rollback ]]; then
  [[ -f $state_dir/previous-image ]] || die 'no previous verified image recorded'
  image=$(<"$state_dir/previous-image")
fi
valid_image "$image" || die 'API image must be pinned by sha256 digest'
if [[ $execute == false ]]; then
  printf 'Dry run: %s image %s at https://%s/readyz. No cloud change was made.\n' \
    "$action" "$image" "$CLRS_DOMAIN"
  exit 0
fi
[[ $confirm == "$image" ]] || die 'execute requires matching --confirm-image'
[[ $EUID -eq 0 ]] || die 'deployment requires an administrator on the staging VPS'
[[ -f $CLRS_API_ENV_FILE && -r $CLRS_API_ENV_FILE && ! -L $CLRS_API_ENV_FILE ]] \
  || die 'private API env file is unavailable'
[[ -f $CLRS_DATABASE_CA_HOST_FILE && -r $CLRS_DATABASE_CA_HOST_FILE && ! -L $CLRS_DATABASE_CA_HOST_FILE ]] \
  || die 'PostgreSQL CA file is unavailable'
ca_mode=$(file_mode "$CLRS_DATABASE_CA_HOST_FILE")
(( (8#$ca_mode & 004) != 0 )) || die 'PostgreSQL CA file must be readable by the non-root API process'
api_mode=$(file_mode "$CLRS_API_ENV_FILE")
api_owner=$(file_owner "$CLRS_API_ENV_FILE")
[[ $api_owner == 0 ]] || die 'API env file must be owned by root'
(( (8#$api_mode & 077) == 0 )) || die 'API env file must have mode 0600'
for executable in docker curl flock; do require "$executable"; done
[[ $state_dir == /* && $state_dir != / ]] || die 'state directory must be absolute'
mkdir -p -- "$state_dir"
chmod 0700 "$state_dir"
exec 9>"$state_dir/.release.lock"
flock -x 9

compose() {
  CLRS_API_IMAGE=$1 docker compose --project-name clrs-staging \
    --env-file "$compose_env" -f "$compose_file" "${@:2}"
}
compose "$image" config --quiet || die 'Compose configuration is invalid'
container=$(compose "$image" ps --quiet api)
running=''
if [[ -n $container ]]; then
  running=$(docker inspect --format '{{.Config.Image}}' "$container")
fi
if [[ -f $state_dir/current-image ]]; then
  recorded=$(<"$state_dir/current-image")
  [[ $running == "$recorded" ]] || die 'running image differs from recorded image; inspect manually'
elif [[ -n $running ]]; then
  die 'unmanaged API container exists; inspect manually'
fi
[[ $running != "$image" ]] || die 'requested image is already running'

healthy() {
  local attempt
  for attempt in {1..12}; do
    if curl --fail --silent --show-error --output /dev/null --connect-timeout 3 \
      --max-time 5 --proto '=https' --tlsv1.2 "https://$CLRS_DOMAIN/readyz" 2>/dev/null; then
      return 0
    fi
    sleep 5
  done
  return 1
}

recover() {
  local reason=$1
  if [[ -n $running ]] && valid_image "$running"; then
    if compose "$running" up -d >/dev/null 2>&1 && healthy; then
      die "$reason; previous image restored and verified"
    fi
    die "$reason; automatic rollback could not be verified"
  fi
  compose "$image" stop api edge >/dev/null 2>&1 || true
  die "$reason; no prior verified image exists"
}

if [[ $action != rollback ]] || ! docker image inspect "$image" >/dev/null 2>&1; then
  compose "$image" pull api || die 'unable to fetch reviewed API image'
fi
compose "$image" up -d || recover 'new image failed to start'
if ! healthy; then
  recover 'new image failed HTTPS health'
fi

if [[ -n $running ]]; then
  printf '%s\n' "$running" >"$state_dir/.previous-image.$$"
  mv -- "$state_dir/.previous-image.$$" "$state_dir/previous-image"
else
  rm -f -- "$state_dir/previous-image"
fi
printf '%s\n' "$image" >"$state_dir/.current-image.$$"
mv -- "$state_dir/.current-image.$$" "$state_dir/current-image"
printf 'Staging API is healthy over HTTPS at %s; image %s.\n' "$CLRS_DOMAIN" "$image"
