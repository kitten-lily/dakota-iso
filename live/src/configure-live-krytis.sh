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

# src/ is copied to /tmp/src/ by the Containerfile; this script lives there too.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ── Passwordless polkit for the live user ─────────────────────────────────────
# The bootc-installer flatpak needs polkit authorization to run `bootc install`.
# GNOME provides a polkit GUI agent via gnome-shell; niri ships none, so polkit
# falls back to the text agent (pkttyagent), which fails in the Wayland session
# with no controlling terminal:
#   Error creating textual authentication agent: Error opening current
#   controlling terminal for the process ('/dev/tty'): No such device or address
# Grant liveuser every polkit action without authentication so no agent is
# needed. Live-session only — installed systems never include this rule.
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/49-live-nopasswd.rules <<'EOF'
// Live ISO: liveuser may perform any polkit action without authentication.
polkit.addRule(function(action, subject) {
    if (subject.user === "liveuser") {
        return polkit.Result.YES;
    }
});
EOF

# ── Disable systemd-firstboot in the live session ─────────────────────────────
# The Krytis image enables systemd-firstboot.service (see
# elements/config/systemd-firstboot.bst). On the live ISO the overlay root has
# no /etc/machine-id, so ConditionFirstBoot fires and the service prompts
# interactively for locale/timezone/hostname/root password — unwanted noise in
# a live session that already has an autologin liveuser. Mask the service so the
# live boot goes straight to greetd; installed systems (post bootc install) keep
# firstboot from the baked-in preset.
ln -sf /dev/null /etc/systemd/system/systemd-firstboot.service

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

# ── bootc install defaults ────────────────────────────────────────────────────
# Set root mount label for bootc install to-disk from the live session.
mkdir -p /usr/lib/bootc/install
printf '[install]\nroot-mount-spec = "LABEL=root"\n' \
    > /usr/lib/bootc/install/00-defaults.toml

# ── Offline containers-storage for the embedded payload ───────────────────────
# iso-sd-boot.sh embeds the payload OCI image into the squashfs as a *VFS*
# containers-storage graphroot at /var/lib/containers/storage (composefs=true
# path). Podman's default driver is "overlay", so without this config it looks
# in an empty overlay/ tree and reports the image as missing — the installer
# then fails until you `podman pull` over the network, defeating the offline ISO.
#
# Two things are needed:
#   driver = "vfs"        — match the embedded store's on-disk layout.
#   additionalimagestores — fisherman runs rootless as liveuser, whose graphroot
#                           is ~/.local/share/containers/storage (rootless always
#                           overrides the system graphroot). Listing the embedded
#                           store as a read-only additional store makes the image
#                           resolvable rootless. For a rootful (pkexec) path the
#                           default graphroot already is /var/lib/containers/storage,
#                           so this covers both.
mkdir -p /etc/containers
cat > /etc/containers/storage.conf << 'STORAGEEOF'
[storage]
driver = "vfs"

[storage.options]
additionalimagestores = ["/var/lib/containers/storage"]
STORAGEEOF

# ── tuna-installer (bootc-installer flatpak) configuration ────────────────────
# Krytis embeds the bootc-installer flatpak (org.bootcinstaller.Installer). It
# reads /etc/bootc-installer/{recipe,images}.json for branding + the offline
# image source, and shells out to fisherman via pkexec to run the install.
INSTALLER_APP_ID="org.bootcinstaller.Installer"
[[ "${INSTALLER_CHANNEL:-stable}" == "dev" ]] && INSTALLER_APP_ID="org.bootcinstaller.Installer.Devel"

# Krytis is a single composefs image (no nvidia split). The payload baked into
# the squashfs VFS store is ghcr.io/starlit-os/krytis:latest; install offline
# from that containers-storage ref.
KRYTIS_IMGREF="ghcr.io/starlit-os/krytis:latest"

mkdir -p /etc/bootc-installer /usr/share/bootc-installer/images
# Reuse the shared tour image so recipe.json's tour slides resolve.
[[ -f "$SCRIPT_DIR/images/dakotaraptor.png" ]] && \
    install -Dm644 "$SCRIPT_DIR/images/dakotaraptor.png" \
        /usr/share/bootc-installer/images/dakotaraptor.png

# images.json: single Krytis entry.
cat > /etc/bootc-installer/images.json << IMGEOF
{
  "default_image": "${KRYTIS_IMGREF}",
  "fallback_flatpaks": [],
  "images": [
    {
      "name": "StarlitOS Krytis",
      "imgref": "${KRYTIS_IMGREF}",
      "desc": "StarlitOS Krytis",
      "bootloader": "systemd",
      "filesystem": "btrfs",
      "composefs": true,
      "needs_user_creation": true,
      "flatpak_var_path": "state/os/default/var",
      "filesystems": ["btrfs", "xfs"]
    }
  ]
}
IMGEOF

# recipe.json: start from the shared template, override branding + image refs.
# composefs=true → install from containers-storage (podman-based offline install).
python3 - << PYEOF
import json
with open("$SCRIPT_DIR/etc/bootc-installer/recipe.json") as f:
    recipe = json.load(f)
recipe["distro_name"] = "StarlitOS Krytis"
recipe["welcome_title"] = "Welcome to StarlitOS Krytis"
recipe["imgref"] = "${KRYTIS_IMGREF}"
recipe["targetImgref"] = "${KRYTIS_IMGREF}"
recipe["image"] = "containers-storage:${KRYTIS_IMGREF}"
recipe["local_imgref"] = "containers-storage:${KRYTIS_IMGREF}"
recipe["bootloader"] = "systemd"
recipe["composeFsBackend"] = True
recipe["filesystem"] = "btrfs"
with open("/etc/bootc-installer/recipe.json", "w") as f:
    json.dump(recipe, f, indent=2)
    f.write("\n")
PYEOF

# Flag read by the installer to activate live-ISO mode inside the Flatpak sandbox.
touch /etc/bootc-installer/live-iso-mode

# fisherman backend: the installer calls /usr/local/bin/fisherman via pkexec.
# The Flatpak does not export it to the host, so symlink it from the app dir.
INSTALLER_APP_DIR=$(find /var/lib/flatpak/app/${INSTALLER_APP_ID} -name fisherman -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null || true)
if [ -n "$INSTALLER_APP_DIR" ]; then
    # /usr/local is a symlink to ../../var/usrlocal on freedesktop-sdk images, so
    # `mkdir -p /usr/local/bin` errors on the symlinked path. Resolve to the
    # canonical dir first; /usr/local/bin/fisherman still reaches it at runtime.
    USR_LOCAL_BIN="$(readlink -f /usr/local)/bin"
    mkdir -p "${USR_LOCAL_BIN}"
    ln -sf "${INSTALLER_APP_DIR}/fisherman" "${USR_LOCAL_BIN}/fisherman"
fi

# Installer polkit policy: allow_active=yes so an active session installs without
# a prompt. (The broad liveuser rule above already covers it; this is the
# upstream-expected policy file, also covering the exec.path annotation.)
mkdir -p /usr/share/polkit-1/actions
cat > /usr/share/polkit-1/actions/org.bootcinstaller.Installer.policy << 'POLICYEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
  "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
  "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <action id="org.tunaos.Installer.install">
    <description>Install an operating system to disk</description>
    <message>Authentication is required to install an operating system</message>
    <icon_name>drive-harddisk</icon_name>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>no</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/bin/fisherman</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>
</policyconfig>
POLICYEOF

# Launchable desktop entry (niri does not run XDG autostart, so the user starts
# it from the launcher; pass the recipe via the Flatpak sandbox host path).
mkdir -p /usr/share/applications
cat > /usr/share/applications/krytis-installer.desktop << DTEOF
[Desktop Entry]
Name=Install StarlitOS Krytis
Comment=Install StarlitOS Krytis to your computer
Exec=flatpak run --env=BOOTC_CUSTOM_RECIPE=/run/host/etc/bootc-installer/recipe.json ${INSTALLER_APP_ID}
Icon=drive-harddisk
Terminal=false
Type=Application
Categories=System;
DTEOF

# ── Install-time scratch space ────────────────────────────────────────────────
# The VFS offline install copies the multi-GB squashed image and skopeo writes
# large blobs to /var/tmp. The live overlay puts /var on a small RAM overlay, so
# expand /var/tmp and /run to a large share of RAM or the install hits ENOSPC.
cat > /usr/lib/systemd/system/var-tmp.mount << 'UNITEOF'
[Unit]
Description=Large tmpfs for /var/tmp in the live environment

[Mount]
What=tmpfs
Where=/var/tmp
Type=tmpfs
Options=size=80%,nr_inodes=1m

[Install]
WantedBy=local-fs.target
UNITEOF
systemctl enable var-tmp.mount || true

cat > /usr/lib/systemd/system/live-run-expand.service << 'UNITEOF'
[Unit]
Description=Expand /run tmpfs for large VFS offline installs
DefaultDependencies=no
After=systemd-remount-fs.service
Before=basic.target

[Service]
Type=oneshot
ExecStart=/bin/mount -o remount,size=70% /run
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
UNITEOF
systemctl enable live-run-expand.service || true

# fisherman bind-mounts /var/fisherman-tmp to /var/tmp; pre-create it.
mkdir -p /var/fisherman-tmp

# Never suspend mid-install.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target || true
