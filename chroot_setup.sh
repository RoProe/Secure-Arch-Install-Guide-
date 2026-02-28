#!/usr/bin/env bash
# chroot_setup.sh 
# runs via arch-chroot in new system and gets variables passed by arch_setup.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "\${CYAN}[INFO]\${NC} \$*"; }
success() { echo -e "\${GREEN}[OK]\${NC}   \$*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── sanity check — ensure required vars were passed ───────────────────────────
: "${USERNAME:?}" "${HOSTNAME:?}" "${TIMEZONE:?}" "${LOCALE:?}" "${KEYMAP:?}"
: "${LUKS_UUID:?}" "${GPU_CHOICE:?}" "${ALL_PKGS:?}"

# ── passwords ─────────────────────────────────────────────────────────────────
echo "Set ROOT password:"
passwd

# ── timezone & clock ──────────────────────────────────────────────────────────
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# ── locale ────────────────────────────────────────────────────────────────────
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# ── vconsole ──────────────────────────────────────────────────────────────────
printf "KEYMAP=${KEYMAP}\n" > /etc/vconsole.conf

# ── hostname ──────────────────────────────────────────────────────────────────
echo "${HOSTNAME}" > /etc/hostname

# ── user ──────────────────────────────────────────────────────────────────────
useradd -m -G wheel "${USERNAME}"
echo "Set password for ${USERNAME}:"
passwd "${USERNAME}"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# ── autologin (optional) ──────────────────────────────────────────────────────
if [[ "${ENABLE_AUTOLOGIN}" == "true" ]] ; then
  info "Configuring autologin..."
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -a ${USERNAME} --noclear %I \$TERM
EOF
fi

# ── services ──────────────────────────────────────────────────────────────────
systemctl enable NetworkManager
systemctl enable fstrim.timer
systemctl enable bluetooth             2>/dev/null || true
systemctl enable ufw                   2>/dev/null || true
systemctl enable power-profiles-daemon 2>/dev/null || true
systemctl enable syncthing@${USERNAME}.service 2>/dev/null || true

# ── hibernate config (suspend-to-disk via swapfile) ───────────────────────────
if [[ "${ENABLE_SWAP}" == "true" ]] ; then
  info "Configuring hibernate..."

  # Override systemd sleep defaults to always hibernate, never suspend-to-RAM.
  # This means closing the lid or running 'systemctl hibernate' writes RAM to
  # the encrypted swapfile and powers off. On next boot LUKS is unlocked first,
  # then the kernel reads the hibernate image from the swapfile.
  mkdir -p /etc/systemd/sleep.conf.d
  cat > /etc/systemd/sleep.conf.d/hibernate.conf << 'EOF'
[Sleep]
AllowSuspend=no
AllowHibernation=yes
AllowHybridSleep=no
AllowSuspendThenHibernate=no
HibernateMode=shutdown
EOF
  # Allow wheel users to hibernate without sudo password via polkit
  mkdir -p /etc/polkit-1/rules.d
  cat > /etc/polkit-1/rules.d/10-hibernate.rules << 'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.login1.hibernate" ||
         action.id == "org.freedesktop.login1.hibernate-multiple-sessions") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
EOF
  success "Hibernate configured. Use: systemctl hibernate"
fi

# ── snapper ───────────────────────────────────────────────────────────────────
snapper -c root create-config /
# Snapper auto-creates /.snapshots as a new subvolume, but we already have
# @snapshots mounted there. Delete it and restore the correct mount point.
btrfs subvolume delete /.snapshots 2>/dev/null || true
mkdir -p /.snapshots
chmod 750 /.snapshots
chown :wheel /.snapshots

# ── install user packages ─────────────────────────────────────────────────────
info "Installing selected packages..."
pacman -S --noconfirm --needed ${ALL_PKGS}

# ── dracut hook scripts ───────────────────────────────────────────────────────
mkdir -p /usr/local/bin /etc/pacman.d/hooks

cat > /usr/local/bin/dracut-install.sh << 'EOF'
#!/usr/bin/env bash
mkdir -p /boot/efi/EFI/Linux
kver="$(ls -1 /usr/lib/modules | sort -V | tail -n1)"
dracut --force --uefi --kver "$kver" /boot/efi/EFI/Linux/bootx64.efi
EOF

cat > /usr/local/bin/dracut-remove.sh << 'EOF'
#!/usr/bin/env bash
rm -f /boot/efi/EFI/Linux/bootx64.efi
EOF

chmod +x /usr/local/bin/dracut-install.sh /usr/local/bin/dracut-remove.sh

# ── pacman hooks for dracut ───────────────────────────────────────────────────
cat > /etc/pacman.d/hooks/90-dracut-install.hook << 'EOF'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/pkgbase

[Action]
Description = Updating linux EFI image
When = PostTransaction
Exec = /usr/local/bin/dracut-install.sh
Depends = dracut
NeedsTargets
EOF

cat > /etc/pacman.d/hooks/60-dracut-remove.hook << 'EOF'
[Trigger]
Type = Path
Operation = Remove
Target = usr/lib/modules/*/pkgbase

[Action]
Description = Removing linux EFI image
When = PreTransaction
Exec = /usr/local/bin/dracut-remove.sh
NeedsTargets
EOF

# ── dracut config ─────────────────────────────────────────────────────────────
mkdir -p /etc/dracut.conf.d

cat > /etc/dracut.conf.d/cmdline.conf << EOF
kernel_cmdline="rd.luks.uuid=luks-${LUKS_UUID} root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=rw,noatime,compress=zstd,subvol=@${RESUME_ARGS}"
EOF

cat > /etc/dracut.conf.d/flags.conf << 'EOF'
compress="zstd"
hostonly="no"
add_dracutmodules+=" snapshot-menu "
EOF

# ── Nvidia dracut config ──────────────────────────────────────────────────────
if [[ "$GPU_CHOICE" == nvidia* ]] ; then
  cat > /etc/dracut.conf.d/nvidia.conf << 'EOF'
add_drivers+=" nvidia nvidia_modeset nvidia_uvm nvidia_drm "
EOF

# Wayland requires DRM modesetting; fbdev needed for early KMS
  sed -i 's/"$/ nvidia_drm.modeset=1 nvidia_drm.fbdev=1"/' /etc/dracut.conf.d/cmdline.conf

  cat > /etc/pacman.d/hooks/nvidia-dracut.hook << 'EOF'
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Operation = Remove
Target = nvidia-dkms

[Action]
Description = Rebuilding UKI for nvidia driver update...
When = PostTransaction
Exec = /usr/local/bin/dracut-install.sh
EOF
fi

# ── post-LUKS snapshot menu — dracut module ───────────────────────────────────
#
# Two-hook design:
#   1. snapshot-menu.sh  — initqueue/settled: shows menu after LUKS unlock,
#                          writes rootflags-override if a snapshot was chosen.
#   2. apply-rootflags.sh — pre-mount: reads rootflags-override and exports
#                           $rootflags so dracut's mount step uses the snapshot.
#
info "Installing snapshot menu dracut module..."
REPO_RAW="https://raw.githubusercontent.com/RoProe/secure-arch-btrfs-snapper/refs/heads/main"
mkdir -p /usr/lib/dracut/modules.d/99snapshot-menu

for f in module-setup.sh snapshot-menu.sh apply-rootflags.sh; do
  curl -fsSL "${REPO_RAW}/dracut/99snapshot-menu/${f}" \
    -o /usr/lib/dracut/modules.d/99snapshot-menu/${f}
  chmod +x /usr/lib/dracut/modules.d/99snapshot-menu/${f}
done
success "Snapshot menu module installed."

# ── generate UKI (triggers dracut hook) ───────────────────────────────────────
# This reinstalls the linux package which fires 90-dracut-install.hook,
# which calls dracut-install.sh, which runs dracut --uefi to produce bootx64.efi
pacman -S --noconfirm linux

# Initial sign — must happen after UKI exists, before reboot
$(if $ENABLE_SECUREBOOT; then cat << 'SBSIGNEOF'
sbctl sign -s /boot/efi/EFI/Linux/bootx64.efi
SBSIGNEOF
fi)

# ── systemd-boot ──────────────────────────────────────────────────────────────
# systemd-boot is a minimal EFI boot manager — it just launches the UKI.
# timeout 0 = instant boot, no menu. Hold Space at power-on to access manually.
# The snapshot selection happens inside the UKI's initramfs after LUKS unlock.
info "Installing systemd-boot..."
bootctl --esp-path=/boot/efi install

mkdir -p /boot/efi/loader/entries

cat > /boot/efi/loader/loader.conf << 'EOF'
default arch.conf
timeout 0
console-mode auto
editor no
EOF

cat > /boot/efi/loader/entries/arch.conf << 'EOF'
title   Arch Linux
efi     /EFI/Linux/bootx64.efi
EOF

success "systemd-boot installed."

# ── post-install script for after first boot ──────────────────────────────────
cat > /home/${USERNAME}/post-install.sh << 'POSTEOF'
#!/usr/bin/env bash
# Run this after first boot as your regular user (not root).
# Installs yay, AUR packages, sets zsh as default shell.
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "\${CYAN}[INFO]\${NC} \$*"; }
success() { echo -e "\${GREEN}[OK]\${NC}   \$*"; }

info "Installing yay..."
cd /tmp
git clone https://aur.archlinux.org/yay.git
cd yay && makepkg -si --noconfirm
cd ~

AUR_LIST="$HOME/aur-packages.txt"
if [[ -f "\$AUR_LIST" && -s "\$AUR_LIST" ]]; then
    mapfile -t AUR_PKGS < "\$AUR_LIST"
    info "Installing AUR packages: \${AUR_PKGS[*]}"
    yay -S --noconfirm "\${AUR_PKGS[@]}"
fi

info "Setting zsh as default shell..."
chsh -s /bin/zsh

success "Post-install complete!"
echo ""
echo "Next steps:"
echo "  1. Restore dotfiles:   cd ~/dotfiles && stow *"
echo "  2. Restore NM VPN configs from Borg backup:"
echo "       sudo cp /path/*.nmconnection /etc/NetworkManager/system-connections/"
echo "       sudo chmod 600 /etc/NetworkManager/system-connections/*"
echo "       sudo systemctl restart NetworkManager"
POSTEOF
chown ${USERNAME}:${USERNAME} /home/${USERNAME}/post-install.sh
chmod +x /home/${USERNAME}/post-install.sh
success "post-install.sh written to /home/${USERNAME}/"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Chroot setup complete!                                  ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Exit chroot and run:                                    ║"
echo "║    umount -R /mnt                                        ║"
echo "║    cryptsetup close ${LUKS_NAME}                        ║"
echo "║    reboot                                                ║"
$(if $ENABLE_SECUREBOOT; then
  echo "echo '╠══════════════════════════════════════════════════════════╣'"
  echo "echo '║  After first boot — SecureBoot:                          ║'"
  echo "echo '║    1. Enable Setup Mode in BIOS                          ║'"
  echo "echo '║    2. sbctl enroll-keys ${MICROSOFT_CA:+--microsoft}     ║'"
  echo "echo '║    3. Reboot, enable UEFI Secure Boot, set BIOS password ║'"
fi)
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Then log in as ${USERNAME} and run:                    ║"
echo "║    bash ~/post-install.sh                                ║"
echo "╚══════════════════════════════════════════════════════════╝"

