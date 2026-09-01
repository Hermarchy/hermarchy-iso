#!/bin/bash

set -euo pipefail

readonly HERMARCHY_MIN_DISK_BYTES=8589934592

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
  [[ $value =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

validate_username() {
  local value=${1:-}
  (( ${#value} >= 1 && ${#value} <= 32 )) || return 1
  [[ $value =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
  case $value in
    root|nobody) return 1 ;;
  esac
}

username_conflicts_with_system_account() {
  local value=$1 file basename type name group sysusers_dir
  local -a sysusers_dirs
  declare -A seen_files=()
  shift

  if (( $# > 0 )); then
    sysusers_dirs=("$@")
  else
    sysusers_dirs=(/etc/sysusers.d /run/sysusers.d /usr/local/lib/sysusers.d /usr/lib/sysusers.d)
  fi

  getent passwd "$value" >/dev/null 2>&1 && return 0
  getent group "$value" >/dev/null 2>&1 && return 0
  for sysusers_dir in "${sysusers_dirs[@]}"; do
    for file in "$sysusers_dir"/*.conf; do
      [[ -e $file || -L $file ]] || continue
      basename=${file##*/}
      [[ -z ${seen_files[$basename]+present} ]] || continue
      seen_files[$basename]=1
      [[ -f $file ]] || continue
      while read -r type name group _; do
        [[ $type != \#* ]] || continue
        case $type in
          u*) [[ $name == "$value" ]] && return 0 ;;
          g) [[ $name == "$value" ]] && return 0 ;;
          m) [[ $name == "$value" || $group == "$value" ]] && return 0 ;;
        esac
      done <"$file"
    done
  done
  return 1
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

target_mount_conflict() {
  local target=$1 mounted
  while IFS= read -r mounted; do
    if [[ $mounted == "$target" || $mounted == "$target/"* ]]; then
      printf '%s\n' "$mounted"
      return 0
    fi
  done
  return 1
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

validate_uefi_environment() {
  local platform_size efivar_options secure_boot_var secure_boot

  [[ $(uname -m) == x86_64 ]] || { fail "Hermarchy currently supports x86_64 only"; return 1; }
  [[ -r /sys/firmware/efi/fw_platform_size ]] || { fail "UEFI firmware information is unavailable"; return 1; }
  platform_size=$(</sys/firmware/efi/fw_platform_size)
  [[ $platform_size == 64 ]] || { fail "Hermarchy requires 64-bit UEFI firmware"; return 1; }
  [[ -d /sys/firmware/efi/efivars ]] || { fail "UEFI variables are unavailable"; return 1; }
  [[ $(findmnt -nro FSTYPE /sys/firmware/efi/efivars 2>/dev/null || true) == efivarfs ]] ||
    { fail "UEFI variables are not mounted as efivarfs"; return 1; }
  efivar_options=$(findmnt -nro OPTIONS /sys/firmware/efi/efivars 2>/dev/null || true)
  [[ ,$efivar_options, != *,ro,* ]] || { fail "UEFI variables are mounted read-only"; return 1; }

  secure_boot_var=$(compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' | head -n 1 || true)
  if [[ -n $secure_boot_var ]]; then
    secure_boot=$(od -An -t u1 -j 4 -N 1 "$secure_boot_var" | tr -d '[:space:]') || {
      fail "Secure Boot state could not be read"
      return 1
    }
    case $secure_boot in
      0) ;;
      1) fail "Secure Boot is enabled but Hermarchy is not signed yet"; return 1 ;;
      *) fail "Secure Boot state could not be determined safely"; return 1 ;;
    esac
  fi
}

find_live_disk() {
  local source type parent
  source=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)
  [[ $source == /dev/* ]] || return 1

  source=$(readlink -f "$source")
  while [[ $source == /dev/* ]]; do
    type=$(lsblk -dnro TYPE "$source" 2>/dev/null || true)
    if [[ $type == disk ]]; then
      printf '%s\n' "$source"
      return 0
    fi
    [[ $type != rom ]] || return 0
    parent=$(lsblk -dnro PKNAME "$source" 2>/dev/null || true)
    [[ -n $parent ]] || return 1
    source="/dev/$parent"
  done
  return 1
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
  live_disk=$(find_live_disk) || { fail 'could not safely resolve the live installation medium'; return 1; }
  json=$(lsblk --tree --json --bytes --paths --output PATH,TYPE,SIZE,MODEL,RM,RO,MOUNTPOINTS)
  eligible_disks_from_json "$json" "$live_disk"
}

validate_install_disk() {
  local disk=$1 canonical kname type ro removable size live_disk mounts descendants swap ancestor
  [[ -b $disk ]] || { fail "$disk is not a block device"; return 1; }

  canonical=$(readlink -e "$disk") || { fail "could not canonicalize $disk"; return 1; }
  [[ $canonical == /dev/* ]] || { fail "$disk does not resolve beneath /dev"; return 1; }
  [[ $canonical == "$disk" ]] || { fail "installation disk must use its canonical path: $canonical"; return 1; }

  type=$(lsblk -dnro TYPE "$disk")
  [[ $type == disk ]] || { fail "$disk is not a whole disk"; return 1; }

  kname=$(lsblk -dnro KNAME "$disk")
  [[ -n $kname && ! -e /sys/class/block/$kname/partition ]] || { fail "$disk is a partition"; return 1; }

  ro=$(lsblk -dnro RO "$disk")
  [[ $ro == 0 ]] || { fail "$disk is read-only"; return 1; }

  removable=$(lsblk -dnro RM "$disk")
  [[ $removable == 0 ]] || { fail "$disk is removable"; return 1; }

  size=$(lsblk -bdnro SIZE "$disk")
  (( size >= HERMARCHY_MIN_DISK_BYTES )) || { fail "$disk is smaller than 8 GiB"; return 1; }

  live_disk=$(find_live_disk) || { fail 'could not safely resolve the live installation medium'; return 1; }
  [[ -z $live_disk || $disk != "$live_disk" ]] || { fail "$disk contains the live installation media"; return 1; }

  mounts=$(lsblk -nrpo MOUNTPOINTS "$disk" | tr -d '[:space:]')
  [[ -z $mounts ]] || { fail "$disk or one of its partitions is mounted"; return 1; }

  descendants=$(lsblk --tree --json --paths --output PATH,TYPE "$disk")
  jq -e '[.. | objects | .type? // empty] | all(. == "disk" or . == "part")' \
    <<<"$descendants" >/dev/null || { fail "$disk contains stacked block devices"; return 1; }

  while IFS= read -r swap; do
    [[ -n $swap ]] || continue
    while IFS= read -r ancestor; do
      [[ $(readlink -f "$ancestor") != "$disk" ]] || { fail "$disk backs active swap"; return 1; }
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

disk_identity_from_json() {
  local json=$1
  jq -cer '
    .blockdevices
    | select(length == 1)
    | .[0]
    | select(.type == "disk")
    | [.path, .["maj:min"], .size, (.model // ""), (.serial // ""), (.wwn // "")]
  ' <<<"$json"
}

disk_identity_has_stable_id() {
  local identity=$1
  jq -e '
    type == "array" and length == 6 and
    (((.[4] // "") | type == "string" and length > 0) or
     ((.[5] // "") | type == "string" and length > 0))
  ' <<<"$identity" >/dev/null
}

validate_disk_identity_for_environment() {
  local identity=$1
  if ! systemd-detect-virt --quiet && ! disk_identity_has_stable_id "$identity"; then
    fail "physical installation disks must expose a serial number or WWN"
    return 1
  fi
}

installation_disk_identity() {
  local disk=$1 json
  json=$(lsblk --nodeps --json --bytes --paths \
    --output PATH,TYPE,SIZE,MODEL,SERIAL,WWN,MAJ:MIN "$disk") || return 1
  disk_identity_from_json "$json"
}
