#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ENGINE="$ROOT/profile/airootfs/usr/local/bin/hermarchy-install"
COMMON="$ROOT/profile/airootfs/usr/local/lib/hermarchy-installer/common.sh"
UI="$ROOT/profile/airootfs/usr/local/bin/hermarchy-installer"
PUBLISHER="$ROOT/bin/publish-dev-iso"

python3 - "$ENGINE" "$COMMON" "$UI" "$PUBLISHER" <<'PY'
import sys
engine, common, ui, publisher = (open(path).read() for path in sys.argv[1:])
all_installer = '\n'.join((engine, common, ui))

for forbidden in ('eval ', 'swapoff -a', 'swapoff --all', 'rm -rf /mnt', '${disk}1', '${disk}2'):
    if forbidden in all_installer:
        raise SystemExit(f'forbidden installer pattern: {forbidden}')

required_engine = (
    'flock -n 9',
    'validate_uefi_environment',
    'validate_install_disk "$disk"',
    'arch-chroot -S "$TARGET" bootctl',
    'systemctl --root="$TARGET" enable NetworkManager.service',
    'hermarchy-fallback.conf',
    'findmnt --verify --tab-file',
    'install -m 0600 "$LOG_FILE"',
    '--output PATH,PARTN,PKNAME,PARTTYPE',
    'target_packages+=("$microcode_package")',
    'systemd-detect-virt --quiet',
    'mkinitcpio -P',
    'lsinitcpio --early',
    'write_systemd_boot_entry',
)
for required in required_engine:
    if required not in engine:
        raise SystemExit(f'missing installer security invariant: {required}')

required_common = (
    'fw_platform_size',
    'SecureBoot-*',
    'swapon --show=NAME',
    'disk contains stacked block devices',
    'partition_path_from_json',
    'microcode_package_for_vendor',
    'microcode_blob_for_vendor',
)
for required in required_common:
    if required not in common:
        raise SystemExit(f'missing disk/firmware invariant: {required}')

for required in ('openssl rand -hex 16', 'remote_sha256', 'verify_remote_pair', 'manifest last'):
    if required not in publisher:
        raise SystemExit(f'missing R2 publication invariant: {required}')
PY
