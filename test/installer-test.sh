#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=profile/airootfs/usr/local/lib/hermarchy-installer/common.sh
source "$ROOT/profile/airootfs/usr/local/lib/hermarchy-installer/common.sh"

pass() { printf 'ok - %s\n' "$1"; }
fail_test() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_success() { "$@" >/dev/null || fail_test "$1 should succeed"; }
assert_failure() { if "$@" >/dev/null 2>&1; then fail_test "$1 should fail"; fi; }
assert_equal() { [[ $1 == "$2" ]] || fail_test "$3: expected '$2', got '$1'"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

assert_success validate_hostname hermarchy
assert_success validate_hostname hermarchy-dev
assert_failure validate_hostname ArchLinux
assert_failure validate_hostname '-bad'
assert_failure validate_hostname 'bad-'
assert_failure validate_hostname 'bad.name'
pass 'hostname validation'

assert_success validate_username hermarchy
assert_success validate_username dev_user
assert_failure validate_username Root
assert_failure validate_username root
assert_failure validate_username 'bad.name'
pass 'username validation'

install -d "$TMP/sysusers"
cat >"$TMP/sysusers/arch.conf" <<'EOF'
u archreserved - "Reserved test user"
m memberreserved wheel
g groupreserved -
m anotheruser mgroupreserved
EOF
for reserved in archreserved memberreserved groupreserved mgroupreserved; do
  assert_success username_conflicts_with_system_account "$reserved" "$TMP/sysusers"
done
assert_failure username_conflicts_with_system_account definitely_not_an_arch_account_987 "$TMP/sysusers"

install -d "$TMP/sysusers-etc" "$TMP/sysusers-usr"
printf 'u maskedreserved - "Masked test user"\n' >"$TMP/sysusers-usr/package.conf"
ln -s /dev/null "$TMP/sysusers-etc/package.conf"
assert_failure username_conflicts_with_system_account maskedreserved "$TMP/sysusers-etc" "$TMP/sysusers-usr"
pass 'target system-account and group collision detection honors sysusers precedence'

cat >"$TMP/cpuinfo-intel" <<'EOF'
processor : 0
vendor_id : GenuineIntel
EOF
cat >"$TMP/cpuinfo-amd" <<'EOF'
processor : 0
vendor_id : AuthenticAMD
EOF
assert_equal "$(cpu_vendor_from_cpuinfo "$TMP/cpuinfo-intel")" GenuineIntel 'Intel CPU vendor detection'
assert_equal "$(cpu_vendor_from_cpuinfo "$TMP/cpuinfo-amd")" AuthenticAMD 'AMD CPU vendor detection'
assert_equal "$(cpu_vendor_from_cpuinfo "$TMP/missing")" '' 'missing CPU vendor data'
assert_equal "$(microcode_package_for_vendor GenuineIntel)" intel-ucode 'Intel microcode package'
assert_equal "$(microcode_package_for_vendor AuthenticAMD)" amd-ucode 'AMD microcode package'
assert_equal "$(microcode_package_for_vendor UnknownVendor)" '' 'unknown CPU microcode package'
pass 'CPU microcode selection'

(
  # Called indirectly by validate_uefi_environment.
  # shellcheck disable=SC2329
  uname() { printf 'aarch64\n'; }
  assert_failure validate_uefi_environment
)
assert_failure validate_install_disk /definitely-not-a-block-device
pass 'safety validators return failure in conditional contexts'

assert_equal "$(target_mount_conflict /mnt <<<'/mnt')" /mnt 'exact target mount conflict'
assert_equal "$(target_mount_conflict /mnt <<<'/mnt/data')" /mnt/data 'nested target mount conflict'
if target_mount_conflict /mnt <<<'/mnt-other' >/dev/null; then
  fail_test 'sibling mount must not conflict with installer target'
fi
pass 'installer target mount conflict detection'

(
  TEST_SOURCE=/dev/sda1
  findmnt() { printf '%s\n' "$TEST_SOURCE"; }
  readlink() { printf '%s\n' "${*: -1}"; }
  lsblk() {
    local args=$*
    case $args in
      *TYPE*/dev/sda1) printf 'part\n' ;;
      *PKNAME*/dev/sda1) printf 'sda\n' ;;
      *TYPE*/dev/sda) printf 'disk\n' ;;
      *TYPE*/dev/loop0) printf 'loop\n' ;;
      *TYPE*/dev/sr0) printf 'rom\n' ;;
    esac
  }
  assert_equal "$(find_live_disk)" /dev/sda 'live partition parent disk'
  TEST_SOURCE=/dev/loop0
  assert_failure find_live_disk
  TEST_SOURCE=/dev/sr0
  assert_equal "$(find_live_disk)" '' 'optical live medium has no writable parent disk'
)
pass 'live installation medium resolution fails closed'

write_systemd_boot_entry \
  "$TMP/arch.conf" 'Arch Linux' /initramfs-linux.img \
  01234567-89ab-cdef-0123-456789abcdef
expected_entry=$'title Arch Linux\nlinux /vmlinuz-linux\ninitrd /initramfs-linux.img\noptions root=UUID=01234567-89ab-cdef-0123-456789abcdef rw'
assert_equal "$(<"$TMP/arch.conf")" "$expected_entry" 'combined-microcode boot entry'
pass 'systemd-boot entry generation'

fixture='{
  "blockdevices": [
    {"path":"/dev/vda","type":"disk","size":42949672960,"model":"QEMU HARDDISK","rm":false,"ro":false,"mountpoints":[null],"children":[]},
    {"path":"/dev/sda","type":"disk","size":68719476736,"model":"Live USB","rm":true,"ro":false,"mountpoints":[null]},
    {"path":"/dev/sdb","type":"disk","size":68719476736,"model":"Mounted Disk","rm":false,"ro":false,"mountpoints":[null],"children":[{"path":"/dev/sdb1","type":"part","mountpoints":["/mnt/data"]}]},
    {"path":"/dev/vdb","type":"disk","size":4294967296,"model":"Too Small","rm":false,"ro":false,"mountpoints":[null]},
    {"path":"/dev/vdc","type":"disk","size":42949672960,"model":"Live Source","rm":false,"ro":false,"mountpoints":[null]},
    {"path":"/dev/vdd","type":"disk","size":42949672960,"model":"Stacked","rm":false,"ro":false,"mountpoints":[null],"children":[{"path":"/dev/dm-0","type":"crypt","mountpoints":[null]}]}
  ]
}'
rows=$(eligible_disks_from_json "$fixture" /dev/vdc)
assert_equal "$rows" $'/dev/vda\t40 GiB  QEMU HARDDISK' 'eligible disk selection'
pass 'disk eligibility excludes unsafe devices'

sanitized_fixture='{"blockdevices":[{"path":"/dev/vda","type":"disk","size":42949672960,"model":"A\tB\u0001C","rm":false,"ro":false,"mountpoints":[null],"children":[]}]}'
assert_equal "$(eligible_disks_from_json "$sanitized_fixture")" $'/dev/vda\t40 GiB  A?B?C' 'model sanitization'
pass 'disk display metadata is sanitized'

common_source=$(<"$ROOT/profile/airootfs/usr/local/lib/hermarchy-installer/common.sh")
removable_check="lsblk -dnro RM \"\$disk\""
[[ $common_source == *"$removable_check"* ]] || fail_test 'authoritative disk validation must reject removable disks'
[[ $common_source == *'lsblk --tree --json --bytes --paths'* ]] || fail_test 'disk enumeration must request nested lsblk JSON'
[[ $common_source == *'lsblk --tree --json --paths --output PATH,TYPE'* ]] || fail_test 'authoritative descendant validation must request nested lsblk JSON'
pass 'authoritative disk validation rejects removable media'

esp_guid=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
root_guid=4f68bce3-e8cd-4db1-96e7-fbcaf984b709
partitions='{"blockdevices":[{"path":"/dev/nvme0n1","partn":null,"pkname":null,"parttype":null,"children":[{"path":"/dev/nvme0n1p1","partn":1,"pkname":"/dev/nvme0n1","parttype":"c12a7328-f81f-11d2-ba4b-00a0c93ec93b"},{"path":"/dev/nvme0n1p2","partn":2,"pkname":"/dev/nvme0n1","parttype":"4f68bce3-e8cd-4db1-96e7-fbcaf984b709"}]}]}'
assert_equal "$(partition_path_from_json "$partitions" 1 /dev/nvme0n1 "$esp_guid")" /dev/nvme0n1p1 'ESP path'
assert_equal "$(partition_path_from_json "$partitions" 2 /dev/nvme0n1 "$root_guid")" /dev/nvme0n1p2 'root path'
assert_failure partition_path_from_json "$partitions" 1 wrong-parent "$esp_guid"
pass 'partition discovery does not concatenate disk names'

for record in \
  'sda:sda1' \
  'vda:vda1' \
  'mmcblk0:mmcblk0p1'; do
  parent=${record%%:*}
  child=${record#*:}
  fixture=$(printf '{"blockdevices":[{"path":"/dev/%s","partn":null,"pkname":null,"parttype":null,"children":[{"path":"/dev/%s","partn":1,"pkname":"/dev/%s","parttype":"%s"}]}]}' \
    "$parent" "$child" "$parent" "$esp_guid")
  assert_equal "$(partition_path_from_json "$fixture" 1 "/dev/$parent" "$esp_guid")" "/dev/$child" "$parent partition path"
done
pass 'SATA, virtio, and MMC partition paths resolve from metadata'

identity_json='{"blockdevices":[{"path":"/dev/vda","type":"disk","size":42949672960,"model":"QEMU Disk","serial":"disk-1","wwn":null,"maj:min":"252:0"}]}'
assert_equal \
  "$(disk_identity_from_json "$identity_json")" \
  '["/dev/vda","252:0",42949672960,"QEMU Disk","disk-1",""]' \
  'disk identity token'
assert_failure disk_identity_from_json '{"blockdevices":[]}'
pass 'disk identity snapshot uses path, device number, size, model, serial, and WWN'

assert_success disk_identity_has_stable_id '["/dev/sda","8:0",1000,"Disk","serial-1",""]'
assert_success disk_identity_has_stable_id '["/dev/sda","8:0",1000,"Disk","","wwn-1"]'
assert_failure disk_identity_has_stable_id '["/dev/sda","8:0",1000,"Disk","",""]'
pass 'physical disk identity requires a serial number or WWN'

(
  # Called indirectly by validate_disk_identity_for_environment.
  # shellcheck disable=SC2329
  systemd-detect-virt() { return 1; }
  assert_success validate_disk_identity_for_environment '["/dev/sda","8:0",1000,"Disk","serial-1",""]'
  assert_failure validate_disk_identity_for_environment '["/dev/sda","8:0",1000,"Disk","",""]'
)
(
  # Called indirectly by validate_disk_identity_for_environment.
  # shellcheck disable=SC2329
  systemd-detect-virt() { return 0; }
  assert_success validate_disk_identity_for_environment '["/dev/vda","252:0",1000,"Virtio","",""]'
)
pass 'virtual disks may rely on the inherited open handle when stable IDs are absent'
