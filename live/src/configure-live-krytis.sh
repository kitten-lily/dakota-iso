#!/usr/bin/bash
# Live-environment setup for the Krytis ISO installer image.
#
# Runs inside the final Krytis container stage with:
#   --cap-add sys_admin --security-opt label=disable
#
# At this point the initramfs has already been replaced (by the Debian
# initramfs-builder stage) with a dmsquash-live capable one.  This script
# configures: live user, greetd autologin into niri, and passwordless sudo.
#
# Krytis uses greetd + noctalia-greeter (not GDM).  The live session bypasses
# the greeter entirely via greetd's initial_session, logging liveuser directly
# into niri-session.

set -exo pipefail

# ── VERSION_ID ────────────────────────────────────────────────────────────────
# Ensure VERSION_ID is present — bootc tooling requires it.
if grep -q '^VERSION_ID=' /usr/lib/os-release 2>/dev/null; then
    sed -i 's/^VERSION_ID=.*/VERSION_ID=latest/' /usr/lib/os-release
else
    echo 'VERSION_ID=latest' >> /usr/lib/os-release
fi

# ── Live user ─────────────────────────────────────────────────────────────────
useradd --create-home --uid 1000 --user-group \
    --comment "Live User" liveuser || true
passwd --delete liveuser

# Debug builds only: enable SSH for remote testing.
if [[ "${DEBUG:-0}" == "1" ]]; then
    echo "liveuser:live" | chpasswd
    passwd --unlock root
    echo "root:root" | chpasswd

    cat > /etc/systemd/system/show-ip.service <<'EOF'
[Unit]
Description=Show live session IP address on console
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '\
    IP=$(ip -4 addr show scope global | grep -oP "(?<=inet )[\d.]+" | head -1); \
    echo " ssh liveuser@${IP:-<no-ip>}  (password: live)"; \
    wall "Live session ready: ssh liveuser@${IP:-<no-ip>}"'

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable show-ip.service

    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /usr/lib/systemd/system/sshd.service \
        /etc/systemd/system/multi-user.target.wants/sshd.service
fi

# ── Passwordless sudo ─────────────────────────────────────────────────────────
echo 'liveuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/liveuser
chmod 0440 /etc/sudoers.d/liveuser

# ── greetd autologin ──────────────────────────────────────────────────────────
# Override /etc/greetd/config.toml (installed by greetd-config.bst) to add
# initial_session so greetd auto-logs liveuser into niri without invoking
# noctalia-greeter.
#
# WLR_RENDERER=pixman / WLR_NO_HARDWARE_CURSORS=1 are not needed for the
# niri session itself — those env vars are required by cage (the greeter
# compositor), not by niri.  niri handles its own renderer selection.
#
# niri-session is installed by desktop/niri.bst at /usr/bin/niri-session.
cat > /etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
command = "env WLR_RENDERER=pixman WLR_NO_HARDWARE_CURSORS=1 noctalia-greeter-session"
user = "greeter"

[initial_session]
command = "niri-session"
user = "liveuser"
EOF

# ── bootc installer config ────────────────────────────────────────────────────
# Set root mount label for bootc install to-disk from the live session.
mkdir -p /usr/lib/bootc/install
printf '[install]\nroot-mount-spec = "LABEL=root"\n' \
    > /usr/lib/bootc/install/00-defaults.toml
