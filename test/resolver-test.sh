#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat >"$TMP/bin/docker" <<'FAKE'
#!/bin/bash
set -euo pipefail
case ${1:-} in
  info) exit "${FAKE_DOCKER_INFO_STATUS:-0}" ;;
  run)
    printf '%s\0' "$@" >"$FAKE_DOCKER_LOG"
    exit 0
    ;;
  *) exit 2 ;;
esac
FAKE
chmod 0755 "$TMP/bin/docker"
cat >"$TMP/bin/sudo" <<'FAKE'
#!/bin/bash
set -euo pipefail
[[ ${1:-} == -n && ${2:-} == docker ]] || exit 2
shift 2
case ${1:-} in
  info) exit 0 ;;
  run)
    printf '%s\0' -n docker "$@" >"$FAKE_SUDO_LOG"
    exit 0
    ;;
  *) exit 2 ;;
esac
FAKE
chmod 0755 "$TMP/bin/sudo"

FAKE_DOCKER_LOG="$TMP/docker-args" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/resolve-profile-packages"

python3 - "$TMP/docker-args" "$ROOT/profile" <<'PY'
import re
import sys

raw=open(sys.argv[1], 'rb').read()
args=[value.decode() for value in raw.split(b'\0') if value]
profile=sys.argv[2]

if not args or args[0] != 'run':
    raise SystemExit(f'unexpected docker command: {args!r}')
for required in ('--rm', '--security-opt=no-new-privileges', '-v', f'{profile}:/profile:ro', 'bash', '-euo', 'pipefail', '-c'):
    if required not in args:
        raise SystemExit(f'missing resolver container argument: {required}')
if not any(re.fullmatch(r'archlinux@sha256:[0-9a-f]{64}', value) for value in args):
    raise SystemExit('resolver did not use the digest-pinned Arch image')
joined='\n'.join(args)
if '--privileged' in args:
    raise SystemExit('package resolution must not use a privileged container')
if 'mkarchiso' in joined:
    raise SystemExit('package resolution must not build an ISO')
if 'pacman --config /profile/pacman.conf -Sp' not in joined:
    raise SystemExit('resolver must use the profile pacman configuration')
if 'minimum_broadcom_version=6.30.223.271-49' not in joined:
    raise SystemExit('resolver must reject the known-incompatible Broadcom DKMS revision')
PY

FAKE_DOCKER_INFO_STATUS=1 FAKE_SUDO_LOG="$TMP/sudo-args" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/resolve-profile-packages"

python3 - "$TMP/sudo-args" <<'PY'
import sys

raw=open(sys.argv[1], 'rb').read()
args=[value.decode() for value in raw.split(b'\0') if value]
if args[:3] != ['-n', 'docker', 'run']:
    raise SystemExit(f'resolver did not use noninteractive sudo fallback: {args!r}')
PY

printf 'ok - package resolver container policy\n'
