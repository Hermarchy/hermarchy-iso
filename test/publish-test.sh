#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/r2"

cat >"$TMP/bin/rclone" <<'FAKE'
#!/bin/bash
set -euo pipefail
map_path() {
  local value=$1
  if [[ $value == r2:* ]]; then
    printf '%s/%s\n' "$FAKE_R2_ROOT" "${value#r2:}"
  else
    printf '%s\n' "$value"
  fi
}
maybe_fail() {
  local destination=$1
  if [[ -n ${FAKE_RCLONE_FAIL_ONCE:-} && $destination == *"$FAKE_RCLONE_FAIL_ONCE"* && ! -f $FAKE_R2_ROOT/.failed-once ]]; then
    touch "$FAKE_R2_ROOT/.failed-once"
    exit 70
  fi
}
command=$1
shift
case $command in
  copyto)
    source=$(map_path "$1")
    destination=$(map_path "$2")
    maybe_fail "$2"
    mkdir -p "$(dirname "$destination")"
    cp "$source" "$destination"
    ;;
  size)
    path=$(map_path "$1")
    if [[ -f $path ]]; then
      printf '{"count":1,"bytes":%s}\n' "$(stat -c %s "$path")"
    else
      printf '{"count":0,"bytes":0}\n'
    fi
    ;;
  cat)
    path=$(map_path "$1")
    /usr/bin/cat "$path"
    ;;
  purge)
    path=$(map_path "$1")
    rm -rf "$path"
    ;;
  deletefile)
    path=$(map_path "$1")
    rm -f "$path"
    ;;
  *)
    echo "unsupported fake rclone command: $command" >&2
    exit 2
    ;;
esac
FAKE
chmod 0755 "$TMP/bin/rclone"

export PATH="$TMP/bin:$PATH"
export FAKE_R2_ROOT="$TMP/r2"
export R2_ACCESS_KEY_ID=test
export R2_SECRET_ACCESS_KEY=test
export R2_ENDPOINT=https://example.invalid
export R2_BUCKET=bucket
export GITHUB_RUN_ATTEMPT=1

make_set() {
  local prefix=$1 payload=$2 sha size
  printf '%s\n' "$payload" >"$TMP/$prefix.iso"
  sha=$(sha256sum "$TMP/$prefix.iso" | cut -d' ' -f1)
  size=$(stat -c %s "$TMP/$prefix.iso")
  printf '%s  hermarchy-dev-x86_64.iso\n' "$sha" >"$TMP/$prefix.sha256"
  printf '{"channel":"dev","architecture":"x86_64","sha256":"%s","size":%s,"payload":"%s"}\n' \
    "$sha" "$size" "$payload" >"$TMP/$prefix.json"
}

publish() {
  local prefix=$1
  "$ROOT/bin/publish-dev-iso" "$TMP/$prefix.iso" "$TMP/$prefix.sha256" "$TMP/$prefix.json"
}

current="$TMP/r2/bucket/dev"
make_set old old
GITHUB_RUN_ID=1 publish old
cmp "$TMP/old.iso" "$current/hermarchy-dev-x86_64.iso"
cmp "$TMP/old.sha256" "$current/hermarchy-dev-x86_64.iso.sha256"
cmp "$TMP/old.json" "$current/build.json"
printf 'ok - first publish creates the current set\n'

make_set new new
GITHUB_RUN_ID=2 publish new
cmp "$TMP/new.iso" "$current/hermarchy-dev-x86_64.iso"
cmp "$TMP/new.sha256" "$current/hermarchy-dev-x86_64.iso.sha256"
cmp "$TMP/new.json" "$current/build.json"
printf 'ok - successful publish replaces all current objects\n'

make_set broken broken
export FAKE_RCLONE_FAIL_ONCE='/staging/hermarchy-dev-x86_64.iso.sha256'
if GITHUB_RUN_ID=3 publish broken; then
  echo 'staging failure unexpectedly succeeded' >&2
  exit 1
fi
unset FAKE_RCLONE_FAIL_ONCE
cmp "$TMP/new.iso" "$current/hermarchy-dev-x86_64.iso"
cmp "$TMP/new.sha256" "$current/hermarchy-dev-x86_64.iso.sha256"
cmp "$TMP/new.json" "$current/build.json"
printf 'ok - staging failure leaves current set unchanged\n'

rm -f "$TMP/r2/.failed-once"
export FAKE_RCLONE_FAIL_ONCE='/dev/hermarchy-dev-x86_64.iso.sha256'
if GITHUB_RUN_ID=4 publish broken; then
  echo 'promotion failure unexpectedly succeeded' >&2
  exit 1
fi
unset FAKE_RCLONE_FAIL_ONCE
cmp "$TMP/new.iso" "$current/hermarchy-dev-x86_64.iso"
cmp "$TMP/new.sha256" "$current/hermarchy-dev-x86_64.iso.sha256"
cmp "$TMP/new.json" "$current/build.json"
printf 'ok - promotion failure restores the previous current set\n'

if [[ -d $TMP/r2/bucket/_transactions ]]; then
  entries=$(python3 - "$TMP/r2/bucket/_transactions" <<'PY'
from pathlib import Path
import sys
print(sum(1 for _ in Path(sys.argv[1]).rglob('*')))
PY
)
  [[ $entries == 0 ]]
fi
printf 'ok - transaction objects are cleaned up\n'
