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
  info) exit 0 ;;
  run)
    printf '%s\0' "$@" >"$FAKE_DOCKER_LOG"
    exit 0
    ;;
  *) exit 2 ;;
esac
FAKE
chmod 0755 "$TMP/bin/docker"

FAKE_DOCKER_LOG="$TMP/docker-args" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/validate-profile-dkms"

python3 - "$TMP/docker-args" "$ROOT/profile" <<'PY'
import re
import sys

raw=open(sys.argv[1], 'rb').read()
args=[value.decode() for value in raw.split(b'\0') if value]
profile=sys.argv[2]

if not args or args[0] != 'run':
    raise SystemExit(f'unexpected docker command: {args!r}')
for required in (
    '--rm', '--security-opt=no-new-privileges',
    '-v', f'{profile}:/profile:ro', 'bash', '-euo', 'pipefail', '-c',
):
    if required not in args:
        raise SystemExit(f'missing DKMS validator container argument: {required}')
if not any(re.fullmatch(r'archlinux@sha256:[0-9a-f]{64}', value) for value in args):
    raise SystemExit('DKMS validator did not use the digest-pinned Arch image')
joined='\n'.join(args)
for required in (
    'linux linux-headers mkinitcpio',
    'dkms install --force',
    'depmod -a',
    'modinfo -k',
    'wl.ko',
):
    if required not in joined:
        raise SystemExit(f'missing DKMS validation operation: {required}')
if '--privileged' in args:
    raise SystemExit('DKMS validation must not use a privileged container')
if 'mkarchiso' in joined:
    raise SystemExit('DKMS validation must not build an ISO')
PY

printf 'ok - DKMS validator container policy\n'
