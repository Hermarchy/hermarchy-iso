# Milestone 1: console Arch foundation

Milestone 1 delivers an unchanged Arch Linux console system through a custom installer, not a new distribution layer or VM-only demonstration image. The live profile remains the pinned ArchISO releng profile except for adding the Hermarchy installer, `dialog`, `jq`, executable declarations, and tty1 launch integration. The upstream `archinstall` command remains available but is not part of the Hermarchy flow. The installed target receives only normal Arch packages and ordinary installation configuration.

## Supported installation contract

- x86_64 with writable 64-bit UEFI variables and Secure Boot disabled
- online installation from current official Arch `core` and `extra` repositories
- whole-disk destructive GPT layout
- 1 GiB FAT32 ESP mounted at `/boot`
- ext4 root filesystem
- systemd-boot
- `base`, `linux`, `linux-firmware`, mkinitcpio, NetworkManager, and sudo
- Intel or AMD microcode on physical systems when available; unknown vendors continue without an unavailable microcode package, and virtual machines leave microcode to the host
- one wheel user, locked root account, UTC, and `en_US.UTF-8`

The installed system must support normal full Arch upgrades and installation of additional official packages with Pacman.
It retains Arch's package-provided identity and repository configuration: the installer does not add a Hermarchy release file, custom package, repository, mkinitcpio preset, kernel, or system service.

## Acceptance gates

1. `./test/all` passes without touching real disks, R2, or ISO output.
2. `./bin/resolve-profile-packages` resolves every live package from `profile/pacman.conf` in the digest-pinned Arch container.
3. A profile parity test proves every non-installer live file matches the pinned ArchISO releng profile and that the package delta contains only direct installer dependencies.
4. A manually requested GitHub workflow builds and publishes one checksum-verified dev ISO.
5. The exact public ISO boots with QEMU/OVMF and automatically launches the installer on tty1 while preserving the normal Arch live shell and `script=` automation path.
6. A disposable virtio disk completes installation and boots without the ISO attached.
7. The target passes checks for GPT/ESP/ext4 layout, fstab, Arch's package-provided identity and default initramfs, absence of Hermarchy packages/repositories/release metadata, systemd-boot, user login, sudo, NetworkManager, DNS, `pacman -Syu`, and installation of an additional official package.
8. Representative physical UEFI systems verify disk discovery, wired and wireless networking, Arch-managed microcode loading where applicable, and reboot.

## Explicitly later

A desktop environment, Hermarchy package repository, AUR and Flatpak integration, encryption, dual boot, partition preservation, Secure Boot, offline installation, RCs, and Stable promotion follow after the console foundation repeatedly installs and upgrades successfully.

Dev ISO creation remains manual-only and requires Dillon's explicit build request.
