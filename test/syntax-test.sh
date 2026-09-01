#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
files=(
  "$ROOT/bin/build-iso"
  "$ROOT/bin/lib/archiso-container.sh"
  "$ROOT/bin/publish-dev-iso"
  "$ROOT/bin/resolve-profile-packages"
  "$ROOT/bin/test-iso"
  "$ROOT/profile/airootfs/root/.automated_script.sh"
  "$ROOT/profile/airootfs/usr/local/bin/hermarchy-install"
  "$ROOT/profile/airootfs/usr/local/bin/hermarchy-installer"
  "$ROOT/profile/airootfs/usr/local/lib/hermarchy-installer/common.sh"
  "$ROOT/test/all"
  "$ROOT/test/installer-test.sh"
  "$ROOT/test/profile-test.sh"
  "$ROOT/test/publish-test.sh"
  "$ROOT/test/resolver-test.sh"
  "$ROOT/test/security-test.sh"
  "$ROOT/test/shellcheck-test.sh"
  "$ROOT/test/syntax-test.sh"
  "$ROOT/test/workflow-test.sh"
)

for file in "${files[@]}"; do
  bash -n "$file"
done
