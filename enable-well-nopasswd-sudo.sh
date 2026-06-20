#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' 'well ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/well-nopasswd >/dev/null
sudo chmod 440 /etc/sudoers.d/well-nopasswd
sudo visudo -cf /etc/sudoers.d/well-nopasswd

printf '\nValidation:\n'
printf '  sudo -k\n'
printf '  sudo -n true\n'
