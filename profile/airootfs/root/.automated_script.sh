#!/bin/bash

set -euo pipefail

[[ $(tty) == /dev/tty1 ]] || exit 0

exec /usr/local/bin/hermarchy-installer
