# Hermarchy ISO

Development tooling for the Hermarchy installation ISO. The current milestone is a basic x86_64 ArchISO that boots directly into a custom Hermarchy installer. It does not invoke `archinstall`.

## Development policy

- Work only on `dev`.
- Build a dev ISO only when Dillon explicitly requests one.
- The GitHub workflow is `workflow_dispatch` only: pushes and schedules never build an ISO.
- RC and production builds, package channels, signing, and release promotion are out of scope.
- Cloudflare R2 retains one current dev ISO set. A successful publish replaces it; failed builds and staging uploads leave it unchanged.

## Current installer scope

- x86_64 live ISO
- UEFI-only installed target
- Online packages from official Arch repositories
- Whole-disk destructive install
- GPT with a 1 GiB FAT32 ESP and ext4 root
- systemd-boot
- One user with wheel/sudo access
- NetworkManager enabled on the target
- UTC and `en_US.UTF-8`

Not yet supported: encryption, dual boot, partition preservation, offline installation, Secure Boot, custom Hermarchy packages, RCs, or production releases.

## Repository layout

- `profile/` — vendored ArchISO releng profile and live filesystem overlay
- `profile/airootfs/usr/local/bin/hermarchy-installer` — dialog UI
- `profile/airootfs/usr/local/bin/hermarchy-install` — noninteractive install engine
- `profile/airootfs/usr/local/lib/hermarchy-installer/common.sh` — validation and disk helpers
- `bin/build-iso` — privileged Arch-container build wrapper
- `bin/test-iso` — QEMU/OVMF manual test harness
- `bin/publish-dev-iso` — transactional rclone/R2 replacement helper
- `test/` — VM-free validation and transaction tests
- `.github/workflows/build-dev-iso.yml` — manual build-and-publish workflow

The base profile was imported from ArchISO commit `f900196af8f293ec7e4ef452b368b9db8012d79f`; see `profile/ARCHISO_UPSTREAM`. It has been modified for Hermarchy. This repository is distributed under GPL-3.0; see `LICENSE`.

## Run tests

```bash
./test/all
```

Tests validate shell syntax, shellcheck, input validation, disk filtering, NVMe-style partition discovery, profile invariants, manual-only workflow triggers, and R2 replacement/rollback behavior. They do not touch block devices or create an ISO.

## Build locally

Building creates a real dev ISO, so run this only after Dillon explicitly requests a dev build:

```bash
./bin/build-iso --clean
```

Requirements are Docker and permission to use privileged containers. The wrapper runs `mkarchiso` inside `archlinux:latest` and writes one commit-identified image under `release/`.

The build refuses tracked or staged changes so `/etc/hermarchy-build` always names a committed source revision.

## Test in QEMU

```bash
./bin/test-iso release/hermarchy-dev-<commit>-x86_64.iso
```

The harness creates or reuses `/tmp/hermarchy-dev.qcow2`, uses OVMF, prefers KVM when available, and falls back to TCG. The installer intentionally refuses legacy-BIOS target installation.

## Manual GitHub build

The workflow can only deploy from the `dev` branch and must be dispatched manually:

```bash
gh workflow run build-dev-iso.yml \
  --repo Hermarchy/hermarchy-iso \
  --ref dev \
  -f reason='requested dev test build'
```

The GitHub environment is `dev-iso`, restricted to the `dev` branch.

Environment variables:

- `R2_BUCKET=hermarchy-isos-dev`
- `DEV_ISO_PUBLIC_BASE_URL=https://dev-isos.hermarchy.com`

Environment secrets:

- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`
- `R2_ENDPOINT`

The R2 credential must have Object Read & Write permission scoped only to `hermarchy-isos-dev`.

## R2 current-object contract

The public current set is:

```text
dev/hermarchy-dev-x86_64.iso
dev/hermarchy-dev-x86_64.iso.sha256
dev/build.json
```

Publishing uploads and size-verifies a complete staging set before touching `dev/`. If a previous complete set exists it is copied into a transaction rollback area. Promotion replaces the ISO and checksum, then writes `build.json` last as the commit marker. A failed promotion attempts to restore all prior objects. Transaction objects are always removed.

No ISO is retained as a GitHub Actions artifact, and no historical dev ISO is retained in R2.

Download URL after the first requested successful build:

```text
https://dev-isos.hermarchy.com/dev/hermarchy-dev-x86_64.iso
```

## Failure behavior

- Test or build failure: R2 is untouched.
- Staging upload/verification failure: current R2 objects are untouched.
- Promotion failure: the previous complete set is restored when present.
- No previous set plus failed promotion: partial current objects are removed.
- A build is reported successful only after final R2 size verification and a public HTTP size check.

Installer failures preserve `/var/log/hermarchy-install.log` and return to the live environment. The engine refuses non-UEFI systems, non-whole disks, read-only/removable/live-media disks, mounted disks, disks smaller than 8 GiB, invalid hostnames/users, and malformed credentials.
