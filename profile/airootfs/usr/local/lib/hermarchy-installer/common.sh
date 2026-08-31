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
      | [
          .path,
          (((.size / 1073741824) * 10 | floor) / 10 | tostring) + " GiB" +
          (if ((.model // "") | length) > 0 then "  " + (.model | gsub("[[:space:]]+"; " ")) else "" end)
        ]
      | @tsv
    ' <<<"$json"
}

list_install_disks() {
  local json live_disk
  live_disk=$(find_live_disk)
  json=$(lsblk --json --bytes --paths --output PATH,TYPE,SIZE,MODEL,RM,RO,MOUNTPOINTS)
  eligible_disks_from_json "$json" "$live_disk"
}

validate_install_disk() {
  local disk=$1 type ro removable size live_disk mounts
  [[ -b $disk ]] || fail "$disk is not a block device"

  type=$(lsblk -dnro TYPE "$disk")
  [[ $type == disk ]] || fail "$disk is not a whole disk"

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
}

partition_path_from_json() {
  local json=$1 number=$2
  jq -er --argjson number "$number" '
    [.. | objects | select((.partn? // 0) == $number) | .path][0]
    | select(type == "string" and length > 0)
  ' <<<"$json"
}

partition_path() {
  local disk=$1 number=$2 json
  json=$(lsblk --json --paths --output PATH,PARTN "$disk")
  partition_path_from_json "$json" "$number"
}
