#!/bin/bash

set -euo pipefail

HERMARCHY_MIN_DISK_BYTES=${HERMARCHY_MIN_DISK_BYTES:-8589934592}

log() {
  printf '[hermarchy] %s\n' "$*"
}

fail() {
  printf '[hermarchy] ERROR: %s\n' "$*" >&2
  return 1
}

validate_hostname() {
  local value=${1:-}
  (( ${#value} >= 1 && ${#value} <= 63 )) || return 1
  [[ $value =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]
}

validate_username() {
  local value=${1:-}
  (( ${#value} >= 1 && ${#value} <= 32 )) || return 1
  [[ $value =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
  case $value in
    root|nobody) return 1 ;;
  esac
}

cpu_vendor_from_cpuinfo() {
  local cpuinfo=${1:-/proc/cpuinfo} key value
  [[ -r $cpuinfo ]] || return 0

  while IFS=: read -r key value; do
    key=${key//[[:space:]]/}
    [[ $key == vendor_id ]] || continue
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s\n' "$value"
    return 0
  done <"$cpuinfo"
}

microcode_package_for_vendor() {
  case ${1:-} in
    GenuineIntel) printf '%s\n' intel-ucode ;;
    AuthenticAMD) printf '%s\n' amd-ucode ;;
  esac
}

microcode_blob_for_vendor() {
  case ${1:-} in
    GenuineIntel) printf '%s\n' kernel/x86/microcode/GenuineIntel.bin ;;
    AuthenticAMD) printf '%s\n' kernel/x86/microcode/AuthenticAMD.bin ;;
  esac
}

write_systemd_boot_entry() {
  local destination=$1 title=$2 initramfs=$3 root_uuid=$4
  {
    printf 'title %s\n' "$title"
    printf 'linux /vmlinuz-linux\n'
    printf 'initrd %s\n' "$initramfs"
    printf 'options root=UUID=%s rw\n' "$root_uuid"
  } >"$destination"
}

write_mkinitcpio_preset() {
  local destination=$1
  cat >"$destination" <<'EOF'
# Hermarchy target preset: retain an all-modules fallback image.
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default' 'fallback')
default_image="/boot/initramfs-linux.img"
fallback_image="/boot/initramfs-linux-fallback.img"
fallback_options="-S autodetect"
EOF
}

validate_uefi_environment() {
  local platform_size efivar_options secure_boot_var secure_boot

  [[ $(uname -m) == x86_64 ]] || fail "Hermarchy currently supports x86_64 only"
  [[ -r /sys/firmware/efi/fw_platform_size ]] || fail "UEFI firmware information is unavailable"
  platform_size=$(</sys/firmware/efi/fw_platform_size)
  [[ $platform_size == 64 ]] || fail "Hermarchy requires 64-bit UEFI firmware"
  [[ -d /sys/firmware/efi/efivars ]] || fail "UEFI variables are unavailable"
  [[ $(findmnt -nro FSTYPE /sys/firmware/efi/efivars 2>/dev/null || true) == efivarfs ]] ||
    fail "UEFI variables are not mounted as efivarfs"
  efivar_options=$(findmnt -nro OPTIONS /sys/firmware/efi/efivars 2>/dev/null || true)
  [[ ,$efivar_options, != *,ro,* ]] || fail "UEFI variables are mounted read-only"

  secure_boot_var=$(compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' | head -n 1 || true)
  if [[ -n $secure_boot_var ]]; then
    secure_boot=$(od -An -t u1 -j 4 -N 1 "$secure_boot_var" | tr -d '[:space:]')
    [[ $secure_boot != 1 ]] || fail "Secure Boot is enabled but Hermarchy is not signed yet"
  fi
}

find_live_disk() {
  local source type parent
  source=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)
  [[ $source == /dev/* ]] || return 0

  source=$(readlink -f "$source")
  while [[ $source == /dev/* ]]; do
    type=$(lsblk -dnro TYPE "$source" 2>/dev/null || true)
    if [[ $type == disk ]]; then
      printf '%s\n' "$source"
      return 0
    fi
    parent=$(lsblk -dnro PKNAME "$source" 2>/dev/null || true)
    [[ -n $parent ]] || return 0
    source="/dev/$parent"
  done
}

eligible_disks_from_json() {
  local json=$1 live_disk=${2:-}
  jq -r \
    --arg live "$live_disk" \
    --argjson minimum "$HERMARCHY_MIN_DISK_BYTES" '
      .blockdevices[]
      | select(.type == "disk")
      | select((.ro == false) or (.ro == 0))
      | select((.rm == false) or (.rm == 0))
      | select((.size // 0) >= $minimum)
      | select(.path != $live)
      | select(
          ([.. | objects | .mountpoints? // empty | .[]? | select(. != null and . != "")] | length) == 0
        )
      | select(([.. | objects | .type? // empty] | all(. == "disk" or . == "part")))
      | [
          .path,
          (((.size / 1073741824) * 10 | floor) / 10 | tostring) + " GiB" +
          (if ((.model // "") | length) > 0 then
             "  " + (.model | gsub("[[:cntrl:]]"; "?") | gsub("[[:space:]]+"; " ") | .[0:64])
           else "" end)
        ]
      | @tsv
    ' <<<"$json"
}

list_install_disks() {
  local json live_disk
  live_disk=$(find_live_disk)
  json=$(lsblk --tree --json --bytes --paths --output PATH,TYPE,SIZE,MODEL,RM,RO,MOUNTPOINTS)
  eligible_disks_from_json "$json" "$live_disk"
}

validate_install_disk() {
  local disk=$1 canonical kname type ro removable size live_disk mounts descendants swap ancestor
  [[ -b $disk ]] || fail "$disk is not a block device"

  canonical=$(readlink -e "$disk") || fail "could not canonicalize $disk"
  [[ $canonical == /dev/* ]] || fail "$disk does not resolve beneath /dev"
  [[ $canonical == "$disk" ]] || fail "installation disk must use its canonical path: $canonical"

  type=$(lsblk -dnro TYPE "$disk")
  [[ $type == disk ]] || fail "$disk is not a whole disk"

  kname=$(lsblk -dnro KNAME "$disk")
  [[ -n $kname && ! -e /sys/class/block/$kname/partition ]] || fail "$disk is a partition"

  ro=$(lsblk -dnro RO "$disk")
  [[ $ro == 0 ]] || fail "$disk is read-only"

  removable=$(lsblk -dnro RM "$disk")
  [[ $removable == 0 ]] || fail "$disk is removable"

  size=$(lsblk -bdnro SIZE "$disk")
  (( size >= HERMARCHY_MIN_DISK_BYTES )) || fail "$disk is smaller than 8 GiB"

  live_disk=$(find_live_disk)
  [[ -z $live_disk || $disk != "$live_disk" ]] || fail "$disk contains the live installation media"

  mounts=$(lsblk -nrpo MOUNTPOINTS "$disk" | tr -d '[:space:]')
  [[ -z $mounts ]] || fail "$disk or one of its partitions is mounted"

  descendants=$(lsblk --tree --json --paths --output PATH,TYPE "$disk")
  jq -e '[.. | objects | .type? // empty] | all(. == "disk" or . == "part")' \
    <<<"$descendants" >/dev/null || fail "$disk contains stacked block devices"

  while IFS= read -r swap; do
    [[ -n $swap ]] || continue
    while IFS= read -r ancestor; do
      [[ $(readlink -f "$ancestor") != "$disk" ]] || fail "$disk backs active swap"
    done < <(lsblk -snrpo PATH "$swap" 2>/dev/null || true)
  done < <(swapon --show=NAME --noheadings 2>/dev/null || true)
}

partition_path_from_json() {
  local json=$1 number=$2 parent=$3 parttype=$4
  jq -er \
    --argjson number "$number" \
    --arg parent "$parent" \
    --arg parttype "${parttype,,}" '
    [.. | objects |
      select((.partn? // 0) == $number) |
      select((.pkname? // "") == $parent) |
      select(((.parttype? // "") | ascii_downcase) == $parttype) |
      .path] as $matches
    | select(($matches | length) == 1)
    | $matches[0]
    | select(type == "string" and length > 0)
  ' <<<"$json"
}
