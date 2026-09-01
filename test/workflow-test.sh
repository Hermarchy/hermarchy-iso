#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$ROOT/.github/workflows/build-dev-iso.yml"

python3 - "$WORKFLOW" <<'PY'
import sys
text=open(sys.argv[1]).read()
if 'workflow_dispatch:' not in text:
    raise SystemExit('workflow_dispatch trigger missing')
for forbidden in ('schedule:', 'pull_request:', 'push:'):
    if forbidden in text:
        raise SystemExit(f'automatic trigger forbidden: {forbidden}')
for required in (
    'environment: dev-iso',
    'cancel-in-progress: false',
    'R2_ACCESS_KEY_ID',
    './bin/resolve-profile-packages',
    './bin/publish-dev-iso',
    'Verify public download set',
    'validate-ref:',
    'needs: validate-ref',
    '[[ "$GITHUB_REF" == "refs/heads/dev" ]]',
    'ref: ${{ github.sha }}',
    'hermarchy-dev-public.iso',
    '$ISO_URL.sha256',
    '$base_url/build.json',
):
    if required not in text:
        raise SystemExit(f'missing workflow invariant: {required}')
if "if: github.ref == 'refs/heads/dev'" in text:
    raise SystemExit('a job-level ref condition would report a wrong-ref dispatch as skipped success')
PY
