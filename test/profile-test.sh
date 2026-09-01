#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE="$ROOT/profile"
MANIFEST="$ROOT/test/fixtures/archiso-releng-f900196.json"

[[ -f $PROFILE/profiledef.sh ]]
[[ -f $PROFILE/packages.x86_64 ]]
[[ -x $PROFILE/airootfs/root/.automated_script.sh ]]
[[ -x $PROFILE/airootfs/usr/local/bin/Installation_guide ]]
[[ -x $PROFILE/airootfs/usr/local/bin/hermarchy-installer ]]
[[ -x $PROFILE/airootfs/usr/local/bin/hermarchy-install ]]
[[ -x $ROOT/bin/resolve-profile-packages ]]
[[ ! -e $ROOT/bin/validate-profile-dkms ]]

python3 - "$PROFILE" "$MANIFEST" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

profile=Path(sys.argv[1])
baseline=json.loads(Path(sys.argv[2]).read_text())
commit='f900196af8f293ec7e4ef452b368b9db8012d79f'
if (
    baseline['repository'] != 'https://gitlab.archlinux.org/archlinux/archiso.git'
    or baseline['commit'] != commit
    or baseline['profile'] != 'configs/releng'
):
    raise SystemExit('profile fixture does not identify the pinned releng baseline')
expected=baseline['entries']

def describe(path):
    metadata=path.lstat()
    # Git records only the executable bit for regular files, while checkout
    # umasks vary. Compare canonical Git modes; profiledef content below guards
    # ArchISO's final arbitrary ownership/mode declarations byte-for-byte.
    if stat.S_ISLNK(metadata.st_mode):
        return {'type':'symlink', 'mode':'0777', 'target':os.readlink(path)}
    if stat.S_ISDIR(metadata.st_mode):
        return {'type':'directory', 'mode':'0755'}
    if stat.S_ISREG(metadata.st_mode):
        mode='0755' if metadata.st_mode & stat.S_IXUSR else '0644'
        return {'type':'file', 'mode':mode, 'sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
    return {'type':'special', 'mode':f'{stat.S_IMODE(metadata.st_mode):04o}'}

record=(profile/'ARCHISO_UPSTREAM').read_text()
if f'Commit: {commit}' not in record or 'Profile: configs/releng' not in record:
    raise SystemExit('profile upstream record does not match the pinned releng baseline')

current={
    path.relative_to(profile).as_posix(): path
    for path in profile.rglob('*')
}
installer_additions={
    'ARCHISO_UPSTREAM',
    'airootfs/usr/local/lib',
    'airootfs/usr/local/lib/hermarchy-installer',
    'airootfs/usr/local/bin/hermarchy-install',
    'airootfs/usr/local/bin/hermarchy-installer',
    'airootfs/usr/local/lib/hermarchy-installer/common.sh',
}
extra=set(current)-set(expected)
missing=set(expected)-set(current)
if extra != installer_additions:
    raise SystemExit(f'unexpected non-upstream profile files: {sorted(extra ^ installer_additions)}')
if missing:
    raise SystemExit(f'upstream releng files were removed: {sorted(missing)}')
addition_metadata={
    'ARCHISO_UPSTREAM':{'type':'file', 'mode':'0644'},
    'airootfs/usr/local/lib':{'type':'directory', 'mode':'0755'},
    'airootfs/usr/local/lib/hermarchy-installer':{'type':'directory', 'mode':'0755'},
    'airootfs/usr/local/bin/hermarchy-install':{'type':'file', 'mode':'0755'},
    'airootfs/usr/local/bin/hermarchy-installer':{'type':'file', 'mode':'0755'},
    'airootfs/usr/local/lib/hermarchy-installer/common.sh':{'type':'file', 'mode':'0644'},
}
for relative, expected_metadata in addition_metadata.items():
    actual=describe(current[relative])
    if {key:actual[key] for key in ('type','mode')} != expected_metadata:
        raise SystemExit(f'unexpected installer addition type or mode: {relative}')

allowed_changes={
    'airootfs/root/.automated_script.sh',
    'packages.x86_64',
    'profiledef.sh',
}
for relative, digest in expected.items():
    if relative in allowed_changes:
        continue
    actual=describe(current[relative])
    if actual != digest:
        raise SystemExit(f'non-installer ArchISO profile drift: {relative}')
for relative in allowed_changes:
    actual=describe(current[relative])
    if actual['type'] != 'file' or expected[relative]['type'] != 'file' or actual['mode'] != expected[relative]['mode']:
        raise SystemExit(f'installer integration changed the upstream file type or mode: {relative}')

# The live package list may only add direct dependencies of the Hermarchy
# installer. All pinned releng packages, including archinstall, remain present.
package_path=current['packages.x86_64']
package_lines=[
    line.strip() for line in package_path.read_text().splitlines()
    if line.strip() and not line.lstrip().startswith('#')
]
if package_lines != sorted(set(package_lines)):
    raise SystemExit('live package list must be sorted and contain no duplicates')
packages=set(package_lines)
installer_packages={'dialog', 'jq'}
if 'archinstall' not in packages:
    raise SystemExit('the upstream archinstall package must remain available')
if not installer_packages <= packages:
    raise SystemExit(f'missing installer dependencies: {sorted(installer_packages-packages)}')
reconstructed=sorted(packages-installer_packages)
reconstructed_bytes=('\n'.join(reconstructed)+'\n').encode()
if hashlib.sha256(reconstructed_bytes).hexdigest() != expected['packages.x86_64']['sha256']:
    raise SystemExit('live packages differ from releng beyond installer dependencies')

# profiledef must retain Arch's identity and boot modes. Its only differences are
# executable mode declarations for the two custom installer entry points.
profiledef=current['profiledef.sh'].read_text()
for declaration in (
    '  ["/usr/local/bin/hermarchy-install"]="0:0:755"\n',
    '  ["/usr/local/bin/hermarchy-installer"]="0:0:755"\n',
):
    if profiledef.count(declaration) != 1:
        raise SystemExit(f'missing or duplicate installer profile declaration: {declaration.strip()}')
    profiledef=profiledef.replace(declaration, '')
if hashlib.sha256(profiledef.encode()).hexdigest() != expected['profiledef.sh']['sha256']:
    raise SystemExit('profiledef differs from releng beyond installer executable declarations')

# Preserve ArchISO's script= automation. The only startup delta is launching the
# custom installer on tty1 when no upstream automated script was requested.
automated=current['airootfs/root/.automated_script.sh'].read_text()
marker='if [[ $(tty) == "/dev/tty1" ]]; then\n'
if automated.count(marker) != 1:
    raise SystemExit('unexpected ArchISO tty1 startup structure')
prefix=automated.split(marker, 1)[0]
custom_tail='''if [[ $(tty) == "/dev/tty1" ]]; then
    if [[ -n $(script_cmdline) ]]; then
        automated_script
    else
        systemctl is-system-running --wait >/dev/null 2>&1 || true
        /usr/local/bin/hermarchy-installer ||
            printf 'Hermarchy installer exited. The normal Arch live shell remains available.\\n' >&2
    fi
fi
'''
if automated != prefix + custom_tail:
    raise SystemExit('tty1 startup differs from the reviewed installer launch integration')
reconstructed_automation=prefix + marker + '    automated_script\nfi\n'
if hashlib.sha256(reconstructed_automation.encode()).hexdigest() != expected['airootfs/root/.automated_script.sh']['sha256']:
    raise SystemExit('ArchISO startup automation differs beyond installer launch integration')
if '/usr/local/bin/hermarchy-installer' not in automated or 'script_cmdline' not in automated:
    raise SystemExit('installer launch or upstream script= support is missing')
PY

python3 - \
  "$ROOT/bin/lib/archiso-container.sh" \
  "$ROOT/bin/build-iso" \
  "$ROOT/bin/resolve-profile-packages" <<'PY'
import re
import sys

texts={path: open(path).read() for path in sys.argv[1:]}
pin_text=texts[sys.argv[1]]
if not re.search(r'archlinux@sha256:[0-9a-f]{64}', pin_text):
    raise SystemExit('Arch build container must be pinned by digest')
if sum(text.count('archlinux@sha256:') for text in texts.values()) != 1:
    raise SystemExit('Arch build container digest must have exactly one production source')
for consumer in sys.argv[2:]:
    if 'source "$ROOT/bin/lib/archiso-container.sh"' not in texts[consumer]:
        raise SystemExit(f'container consumer does not source shared configuration: {consumer}')
if any('archlinux:latest' in text for text in texts.values()):
    raise SystemExit('mutable Arch build image tag is forbidden')
if 'airootfs/etc/hermarchy-' in texts[sys.argv[2]]:
    raise SystemExit('build tooling must not inject Hermarchy identity into the live filesystem')
PY
