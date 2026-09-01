# Milestone 1: console Arch foundation

Milestone 1 delivers a real x86_64 Arch-based console system, not a VM-only demonstration image. The live ISO retains ArchISO's broad hardware, network, storage, recovery, and package-management capabilities while the custom installer deliberately supports one safe installation layout.

## Supported installation contract

- x86_64 with writable 64-bit UEFI variables and Secure Boot disabled
- online installation from current official Arch `core` and `extra` repositories
- whole-disk destructive GPT layout
- 1 GiB FAT32 ESP mounted at `/boot`
- ext4 root filesystem
- systemd-boot
- `base`, `linux`, `linux-firmware`, mkinitcpio, NetworkManager, and sudo
- Intel or AMD microcode on physical systems; virtual machines leave microcode to the host
- one wheel user, locked root account, UTC, and `en_US.UTF-8`

The installed system must support normal full Arch upgrades and installation of additional official packages with Pacman.

## Acceptance gates

1. `./test/all` passes without touching real disks, R2, or ISO output.
2. `./bin/resolve-profile-packages` resolves every live package from `profile/pacman.conf` in the digest-pinned Arch container.
3. A manually requested GitHub workflow builds and publishes one checksum-verified dev ISO.
4. The exact public ISO boots with QEMU/OVMF and automatically launches the installer on tty1.
5. A disposable virtio disk completes installation and boots without the ISO attached.
6. The target passes checks for GPT/ESP/ext4 layout, fstab, normal and fallback initramfs, systemd-boot, user login, sudo, NetworkManager, DNS, `pacman -Syu`, and installation of an additional official package.
7. Representative physical Intel and AMD UEFI systems verify disk discovery, networking, early microcode loading, and reboot.

## Explicitly later

A desktop environment, Hermarchy package repository, AUR and Flatpak integration, encryption, dual boot, partition preservation, Secure Boot, offline installation, RCs, and Stable promotion follow after the console foundation repeatedly installs and upgrades successfully.

Dev ISO creation remains manual-only and requires Dillon's explicit build request.
