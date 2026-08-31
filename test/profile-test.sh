#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE="$ROOT/profile"

[[ -f $PROFILE/profiledef.sh ]]
[[ -f $PROFILE/packages.x86_64 ]]
[[ -x $PROFILE/airootfs/root/.automated_script.sh ]]
[[ -x $PROFILE/airootfs/usr/local/bin/hermarchy-installer ]]
[[ -x $PROFILE/airootfs/usr/local/bin/hermarchy-install ]]

if python3 - "$PROFILE/packages.x86_64" <<'PY'
import sys
pkgs={line.strip() for line in open(sys.argv[1]) if line.strip() and not line.startswith('#')}
required={'arch-install-scripts','dialog','jq'}
missing=required-pkgs
if missing:
    raise SystemExit(f'missing live packages: {sorted(missing)}')
if 'archinstall' in pkgs:
    raise SystemExit('archinstall must not be present')
PY
then :; else exit 1; fi

python3 - "$PROFILE/profiledef.sh" <<'PY'
import sys
text=open(sys.argv[1]).read()
for expected in ('iso_name="hermarchy-dev"', '/usr/local/bin/hermarchy-installer', '/usr/local/bin/hermarchy-install'):
    if expected not in text:
        raise SystemExit(f'missing profile declaration: {expected}')
PY
