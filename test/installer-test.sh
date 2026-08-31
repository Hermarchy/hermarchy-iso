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

assert_success validate_hostname hermarchy
assert_success validate_hostname hermarchy-dev
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
pass 'authoritative disk validation rejects removable media'

esp_guid=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
root_guid=4f68bce3-e8cd-4db1-96e7-fbcaf984b709
partitions='{"blockdevices":[{"path":"/dev/nvme0n1","partn":null,"pkname":null,"parttype":null,"children":[{"path":"/dev/nvme0n1p1","partn":1,"pkname":"nvme0n1","parttype":"c12a7328-f81f-11d2-ba4b-00a0c93ec93b"},{"path":"/dev/nvme0n1p2","partn":2,"pkname":"nvme0n1","parttype":"4f68bce3-e8cd-4db1-96e7-fbcaf984b709"}]}]}'
assert_equal "$(partition_path_from_json "$partitions" 1 nvme0n1 "$esp_guid")" /dev/nvme0n1p1 'ESP path'
assert_equal "$(partition_path_from_json "$partitions" 2 nvme0n1 "$root_guid")" /dev/nvme0n1p2 'root path'
assert_failure partition_path_from_json "$partitions" 1 wrong-parent "$esp_guid"
pass 'partition discovery does not concatenate disk names'

for record in \
  'sda:sda1' \
  'vda:vda1' \
  'mmcblk0:mmcblk0p1'; do
  parent=${record%%:*}
  child=${record#*:}
  fixture=$(printf '{"blockdevices":[{"path":"/dev/%s","partn":null,"pkname":null,"parttype":null,"children":[{"path":"/dev/%s","partn":1,"pkname":"%s","parttype":"%s"}]}]}' \
    "$parent" "$child" "$parent" "$esp_guid")
  assert_equal "$(partition_path_from_json "$fixture" 1 "$parent" "$esp_guid")" "/dev/$child" "$parent partition path"
done
pass 'SATA, virtio, and MMC partition paths resolve from metadata'
