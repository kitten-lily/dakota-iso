---
name: krytis-live-config
description: "Live-only overrides for krytis's niri/noctalia desktop session (hotkey overlay, first-run popups). Use when editing live/src/configure-live-krytis.sh to suppress a desktop-session UI element for liveuser without changing the installed system's config."
metadata:
  type: reference
---

# krytis live session config overrides

`live/src/configure-live-krytis.sh` layers live-only tweaks on top of the
baked-in krytis image (niri + greetd + noctalia-greeter). The pattern for
suppressing a first-run/onboarding UI element: write to `liveuser`'s home
(`/home/liveuser/...`), never touch the shipped system config — installed
systems must keep default behavior.

### niri hotkey-overlay popup (2026-07-02)

**What:** krytis ships `/etc/niri/config.kdl` (from `files/niri/config.kdl`
in the krytis repo) with `hotkey-overlay { // skip-at-startup }` commented
out, so the "Important Hotkeys" cheat-sheet shows on first niri login —
desired on installed systems, noise on the live ISO installer.

**Why:** niri's config lookup order is `$XDG_CONFIG_HOME/niri/config.kdl` →
`/etc/niri/config.kdl` (fallback). Editing `/etc/niri/config.kdl` in the live
script would also require reverting it for the installed system — messier
than just shadowing it for `liveuser`.

**Fix:** copy the shipped `/etc/niri/config.kdl` into `liveuser`'s XDG config
and uncomment `skip-at-startup` via `sed`, so the live override composes with
the shipped config instead of hand-rolling a separate minimal one that could
drift from it:

```bash
mkdir -p /home/liveuser/.config/niri
sed 's/^    \/\/ skip-at-startup$/    skip-at-startup/' \
    /etc/niri/config.kdl > /home/liveuser/.config/niri/config.kdl
chown -R liveuser:liveuser /home/liveuser/.config
```

### noctalia welcome/onboarding popup (2026-07-02)

**What:** noctalia-shell shows a first-run welcome popup unless
`~/.local/state/noctalia/.setup-complete` already exists for the user.

**Why:** confirmed via upstream noctalia state-file convention (not
guessable from the krytis repo alone — see
[krytis#236](https://github.com/starlit-os/krytis/issues/236#issuecomment-4862419237)).

**Fix:** pre-seed the marker for `liveuser`, mirroring how
`gnome-initial-setup-done` is pre-seeded for GNOME-based live images
elsewhere in this repo (`dakota/src/configure-live.sh`,
`live/src/configure-live.sh`):

```bash
mkdir -p /home/liveuser/.local/state/noctalia
touch /home/liveuser/.local/state/noctalia/.setup-complete
chown -R liveuser:liveuser /home/liveuser/.local
```
