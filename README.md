# Hermarchy ISO

Development tooling for the Hermarchy installation ISO. The current milestone is a functional console-based x86_64 Arch system that boots directly into a custom Hermarchy installer. It retains the broad hardware and recovery capabilities of ArchISO rather than becoming a VM-only appliance. A desktop environment is the next milestone. The installer does not invoke `archinstall`.

## Development policy

- Work only on `dev`.
- Build a dev ISO only when Dillon explicitly requests one.
- The GitHub workflow is `workflow_dispatch` only: pushes and schedules never build an ISO.
- RC and production builds, package channels, signing, and release promotion are out of scope.
- Cloudflare R2 retains one current dev ISO set. A successful publish replaces it; failed builds and staging uploads leave it unchanged.

## Current installer scope

- x86_64 UEFI-only live ISO; physical installation currently supports Intel and AMD CPUs
- UEFI-only installed target
- Online packages from official Arch repositories
- Whole-disk destructive repartition and format (not forensic secure erase)
- GPT with a 1 GiB FAT32 ESP and ext4 root
- systemd-boot
- One user with wheel/sudo access
- NetworkManager enabled on the target
- CPU-appropriate Intel or AMD microcode installed on the target and packed into both mkinitcpio images for early loading
- UTC and `en_US.UTF-8`

The live ISO carries `broadcom-wl-dkms` as a manual proprietary-driver fallback while keeping the in-kernel Broadcom drivers available by default. Milestone 1 target installations use the standard in-kernel drivers and `linux-firmware`; automatic installation and selection of proprietary `wl` on the target is not yet supported.

Not yet supported: encryption, dual boot, partition preservation, offline installation, Secure Boot, custom Hermarchy packages, RCs, or production releases.

See [`docs/milestone-1.md`](docs/milestone-1.md) for the console-foundation contract and acceptance gates.

## Repository layout

- `profile/` — vendored ArchISO releng profile and live filesystem overlay
- `profile/airootfs/usr/local/bin/hermarchy-installer` — dialog UI
- `profile/airootfs/usr/local/bin/hermarchy-install` — noninteractive install engine
- `profile/airootfs/usr/local/lib/hermarchy-installer/common.sh` — validation and disk helpers
- `bin/build-iso` — privileged Arch-container build wrapper
- `bin/test-iso` — QEMU/OVMF manual test harness
- `bin/publish-dev-iso` — staged rclone/R2 replacement and rollback helper
- `test/` — VM-free validation and transaction tests
- `.github/workflows/build-dev-iso.yml` — manual build-and-publish workflow

The base profile was imported from ArchISO commit `f900196af8f293ec7e4ef452b368b9db8012d79f`; see `profile/ARCHISO_UPSTREAM`. It has been modified for Hermarchy. This repository is distributed under GPL-3.0; see `LICENSE`.

## Run tests

```bash
./test/all
./bin/resolve-profile-packages
./bin/validate-profile-dkms
```

`./test/all` validates shell syntax, shellcheck, input validation, CPU microcode selection and boot-entry generation, disk filtering, NVMe-style partition discovery, profile invariants, resolver container policy, manual-only workflow triggers, and R2 replacement/rollback behavior. It does not touch block devices, access real R2, or create an ISO.

`./bin/resolve-profile-packages` uses the same digest-pinned Arch container and `profile/pacman.conf` as the build to resolve the complete live package list. It also rejects Broadcom DKMS revisions known not to build against the current Arch kernel. It requires network and Docker access, but it is unprivileged and does not invoke `mkarchiso`. Run it before requesting a dev ISO so removed, inconsistent, or known-incompatible Arch packages fail early.

`./bin/validate-profile-dkms` installs the resolved kernel, matching headers, and Broadcom DKMS source in another unprivileged ephemeral container. It hard-fails unless DKMS installs `wl.ko`, `depmod` succeeds, and `modinfo` can read the module for the exact kernel. This check is required because Arch package hooks can report a DKMS warning without making the surrounding ArchISO build fail.

## Build locally

Building creates a real dev ISO, so run this only after Dillon explicitly requests a dev build:

```bash
./bin/build-iso --clean
```

Requirements are Docker and either direct daemon access or passwordless `sudo docker`; privileged containers are used only for the actual ArchISO build. The wrapper runs `mkarchiso` inside a digest-pinned Arch Linux container and writes one commit-identified image under `release/`.

The build refuses any uncommitted files or changes so `/etc/hermarchy-build` always names a committed source revision.

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

GitHub requires a `workflow_dispatch` file on the default branch before it will register the workflow. `main` therefore contains only a guarded registration stub at the same path; dispatching with `--ref dev` loads and runs the complete workflow from `dev`. A dispatch against `main` fails deliberately.

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

Publishing uploads and byte-verifies a complete staging set before touching `dev/`. If a previous complete set exists it is copied into a byte-verified rollback area. Promotion replaces the ISO and checksum, then writes `build.json` last as the commit marker. A failed promotion attempts to restore and verify all prior objects. Transaction objects are removed on every handled exit.

R2 provides atomic replacement for one key, not a multi-object transaction across all three fixed keys. A runner crash during promotion can therefore expose a temporarily mixed set. Staging plus rollback is the strongest fixed-URL design without adding a Worker or changing to immutable per-build URLs. `build.json` is promoted last so clients that honor it have a commit marker. Any rollback failure is reported as an indeterminate external state and must be inspected before another build.

No ISO is retained as a GitHub Actions artifact, and no historical dev ISO is retained in R2. A Cloudflare Cache Rule explicitly bypasses cache for `dev-isos.hermarchy.com` so fixed-key overwrites are read directly from strongly consistent R2 storage.

Download URL after the first requested successful build:

```text
https://dev-isos.hermarchy.com/dev/hermarchy-dev-x86_64.iso
```

## Failure behavior

- Test or build failure: R2 is untouched.
- Staging upload/verification failure: current R2 objects are untouched.
- Promotion failure: the previous complete set is restored when present.
- No previous set plus failed promotion: partial current objects are removed.
- A build is reported successful only after final R2 byte verification and a complete public ISO download whose SHA-256 matches the public checksum and manifest.

Installer failures preserve `/var/log/hermarchy-install.log`, copy it into the target when possible, unmount installer-owned mounts, and return to the live environment. The engine refuses non-x86_64 or non-64-bit UEFI systems, Secure Boot, unavailable/read-only EFI variables, non-whole disks, read-only/removable/live-media disks, mounted or stacked disks, active-swap backing disks, disks smaller than 8 GiB, concurrent installer runs, invalid hostnames/users, and malformed credentials.
