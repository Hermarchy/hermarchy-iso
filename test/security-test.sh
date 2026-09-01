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

for forbidden in (
    'eval ', 'swapoff -a', 'swapoff --all', 'rm -rf /mnt', '${disk}1', '${disk}2',
    'hermarchy-release', 'hermarchy-fallback.conf', 'write_mkinitcpio_preset',
    'HERMARCHY_ROOT', 'HERMARCHY_EFI',
):
    if forbidden in all_installer:
        raise SystemExit(f'forbidden installer pattern: {forbidden}')
if 'pacman -Sy --noconfirm' not in ui:
    raise SystemExit('installer UI must verify the configured Arch repositories before confirmation')

required_engine = (
    'flock -n 9',
    'INSTALL_ATTEMPTED=1',
    'TARGET_MOUNTED=1',
    '--confirm-disk',
    '--disk-fd',
    '--confirm-identity',
    'confirmation disk does not exactly match',
    'installation disk identity changed before erasure',
    'validate_uefi_environment',
    'validate_install_disk "$disk"',
    'arch-chroot -S "$TARGET" bootctl',
    'bootctl --esp-path=/boot list',
    'systemctl --root="$TARGET" enable NetworkManager.service',
    'systemctl --root="$TARGET" is-enabled NetworkManager.service',
    'loader/entries/arch.conf',
    'findmnt --verify --tab-file',
    'install -m 0600 "$LOG_FILE"',
    'umount -R "$TARGET" || cleanup_status=1',
    '--output PATH,PARTN,PKNAME,PARTTYPE',
    'target_packages=(base linux linux-firmware mkinitcpio networkmanager sudo)',
    'target_packages+=("$microcode_package")',
    'systemd-detect-virt --quiet',
    'write_systemd_boot_entry',
    "'Arch Linux' /initramfs-linux.img",
)
for required in required_engine:
    if required not in engine:
        raise SystemExit(f'missing installer security invariant: {required}')
cleanup=engine[engine.index('cleanup() {'):engine.index('trap cleanup EXIT')]
if 'if (( TARGET_MOUNTED )); then' not in cleanup or 'mountpoint -q "$TARGET"' in cleanup:
    raise SystemExit('cleanup must unmount only a target mount created by this installer process')
if '--confirm-disk "$disk"' not in ui:
    raise SystemExit('installer UI must bind the engine confirmation to the exact selected disk')
if '--disk-fd "$disk_fd"' not in ui or 'exec {disk_fd}<>"$disk"' not in ui:
    raise SystemExit('installer UI must hold and pass an open handle for the selected disk')
if 'shopt -u varredir_close' not in ui or 'shopt -u varredir_close' not in engine:
    raise SystemExit('allocated disk and partition descriptors must survive child command execution')
if '--confirm-identity "$disk_identity"' not in ui:
    raise SystemExit('installer UI must bind the engine to the selected physical disk identity')
if '--insecure' in ui:
    raise SystemExit('password dialog must not disclose password length')
if engine.count('validate_install_disk "$disk"') < 2:
    raise SystemExit('installation disk must be revalidated after package preflight and immediately before erasure')
first_validation=engine.index('validate_install_disk "$disk"')
second_validation=engine.index('validate_install_disk "$disk"', first_validation + 1)
if not engine.index('pacman -Sp --noconfirm') < second_validation < engine.index('wipefs --all --force "$disk_handle"'):
    raise SystemExit('final disk validation must occur after package resolution and before erasure')
for preflight in (
    'pacman -Sy --noconfirm',
    'pacman -Sp --noconfirm',
    'target_mount_conflict "$TARGET"',
):
    if engine.index(preflight) > engine.index('wipefs --all --force "$disk_handle"'):
        raise SystemExit(f'destructive operation precedes required preflight: {preflight}')
for operation in ('wipefs --all --force', 'sgdisk --zap-all', 'partprobe'):
    line=next((line for line in engine.splitlines() if line.strip().startswith(operation)), '')
    if '$disk_handle' not in line:
        raise SystemExit(f'destructive operation is not bound to the inherited disk handle: {operation}')
if 'lsblk --tree --json --paths --output PATH,PARTN,PKNAME,PARTTYPE' not in engine:
    raise SystemExit('partition discovery must explicitly request nested lsblk JSON')

required_common = (
    'fw_platform_size',
    'SecureBoot-*',
    'Secure Boot state could not be determined safely',
    'swapon --show=NAME',
    'disk contains stacked block devices',
    'could not safely resolve the live installation medium',
    'partition_path_from_json',
    'microcode_package_for_vendor',
    'target_mount_conflict',
    'lsblk --tree --json',
)
for required in required_common:
    if required not in common:
        raise SystemExit(f'missing disk/firmware invariant: {required}')

for required in ('openssl rand -hex 16', 'remote_sha256', 'verify_remote_pair', 'manifest last'):
    if required not in publisher:
        raise SystemExit(f'missing R2 publication invariant: {required}')
PY
