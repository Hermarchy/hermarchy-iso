#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
shellcheck \
  "$ROOT/bin/build-iso" \
  "$ROOT/bin/lib/archiso-container.sh" \
  "$ROOT/bin/publish-dev-iso" \
  "$ROOT/bin/resolve-profile-packages" \
  "$ROOT/bin/test-iso" \
  "$ROOT/bin/validate-profile-dkms" \
  "$ROOT/profile/airootfs/root/.automated_script.sh" \
  "$ROOT/profile/airootfs/usr/local/bin/hermarchy-install" \
  "$ROOT/profile/airootfs/usr/local/bin/hermarchy-installer" \
  "$ROOT/profile/airootfs/usr/local/lib/hermarchy-installer/common.sh" \
  "$ROOT/test/"*.sh
