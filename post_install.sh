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

