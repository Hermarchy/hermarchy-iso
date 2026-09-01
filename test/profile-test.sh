#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE="$ROOT/profile"

[[ -f $PROFILE/profiledef.sh ]]
[[ -f $PROFILE/packages.x86_64 ]]
[[ -x $PROFILE/airootfs/root/.automated_script.sh ]]
[[ -x $PROFILE/airootfs/usr/local/bin/hermarchy-installer ]]
[[ -x $PROFILE/airootfs/usr/local/bin/hermarchy-install ]]
[[ -x $ROOT/bin/resolve-profile-packages ]]
[[ -x $ROOT/bin/validate-profile-dkms ]]
[[ -f $PROFILE/airootfs/etc/modprobe.d/broadcom-wl-dkms.conf ]]
[[ ! -e $PROFILE/airootfs/etc/modprobe.d/broadcom-wl.conf ]]

if python3 - "$PROFILE/packages.x86_64" <<'PY'
import sys
package_lines=[line.strip() for line in open(sys.argv[1]) if line.strip() and not line.startswith('#')]
if package_lines != sorted(set(package_lines)):
    raise SystemExit('live package list must be sorted and contain no duplicates')
pkgs=set(package_lines)
required={
    'amd-ucode', 'arch-install-scripts', 'broadcom-wl-dkms', 'curl', 'dialog',
    'dosfstools', 'e2fsprogs', 'efibootmgr', 'gptfdisk', 'intel-ucode', 'jq',
    'linux-headers',
}
missing=required-pkgs
if missing:
    raise SystemExit(f'missing live packages: {sorted(missing)}')
if 'archinstall' in pkgs:
    raise SystemExit('archinstall must not be present')
if 'broadcom-wl' in pkgs:
    raise SystemExit('obsolete broadcom-wl package must not be present')
PY
then :; else exit 1; fi

python3 - "$PROFILE/profiledef.sh" <<'PY'
import sys
text=open(sys.argv[1]).read()
for expected in ('iso_name="hermarchy-dev"', '/usr/local/bin/hermarchy-installer', '/usr/local/bin/hermarchy-install'):
    if expected not in text:
        raise SystemExit(f'missing profile declaration: {expected}')
if "bootmodes=('uefi.systemd-boot')" not in text:
    raise SystemExit('profile must build only the UEFI systemd-boot mode')
if 'bios.syslinux' in text or 'uefi.grub' in text:
    raise SystemExit('unsupported boot modes are enabled')
PY

python3 - \
  "$ROOT/bin/lib/archiso-container.sh" \
  "$ROOT/bin/build-iso" \
  "$ROOT/bin/resolve-profile-packages" \
  "$ROOT/bin/validate-profile-dkms" <<'PY'
import re, sys
texts={path: open(path).read() for path in sys.argv[1:]}
pin_text=texts[sys.argv[1]]
if not re.search(r"archlinux@sha256:[0-9a-f]{64}", pin_text):
    raise SystemExit('Arch build container must be pinned by digest')
if sum(text.count('archlinux@sha256:') for text in texts.values()) != 1:
    raise SystemExit('Arch build container digest must have exactly one production source')
for consumer in sys.argv[2:]:
    if 'source "$ROOT/bin/lib/archiso-container.sh"' not in texts[consumer]:
        raise SystemExit(f'container consumer does not source shared configuration: {consumer}')
if any('archlinux:latest' in text for text in texts.values()):
    raise SystemExit('mutable Arch build image tag is forbidden')
PY
