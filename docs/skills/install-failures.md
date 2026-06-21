# Install Failure Reference

Root causes of "ISO boots but installed system does not boot" failures, in order
of most-likely to least-likely.  Ordered by symptom for fast lookup.

---

## Symptom: installed system drops to emergency shell

### Root cause 1: COMPOSEFS_BACKEND detection bug (FIXED in d974a1e)

**What happened:**
`scripts/build-live-squashfs.sh` detected composefs by running:
```bash
sh -c 'python3 -c "import json; print(json.load(open("/etc/bootc-installer/recipe.json"))...)"'
```
The outer `sh -c '...'` split the string at the first inner `"`, so python3 received
broken arguments → returned non-zero → `COMPOSEFS_BACKEND` was set `false` for ALL
variants including dakota (which should be `true`).

**Effect:**
- Dakota went through the non-composefs OCI layout path: embedded as
  `/var/lib/containers/oci-store` instead of VFS containers-storage.
- `recipe.json` correctly said `image: "containers-storage:..."` (set by
  `configure-live.sh` based on the `composefs` file in the variant dir).
- Fisherman inspected containers-storage → NOT FOUND → pulled uninjected image
  from `ghcr.io` (network) or failed entirely.
- The network-pulled image lacked the injected `root-mount-spec = "LABEL=root"`
  in `/usr/lib/bootc/install/00-defaults.toml`.
- `bootc install` used default root-mount-spec → boot entry had wrong `root=` param
  → initramfs could not mount root → emergency shell.

**Fix:** Replace `sh -c 'python3 -c "..."'` with `python3 -c '...'` directly.
See `scripts/build-live-squashfs.sh` around the `COMPOSEFS_BACKEND` detection block.

**Verification:** `plain-e2e-test3.log` (Jun 21 2026) — `✅ Installed system boot verified`.

---

## Symptom: installed system cannot find bootloader (UEFI falls to PXE)

### Root cause: fisherman dev channel ignores `bootloader: grub2` in recipe.json

**Observed:**
```
"Detected bootloader"
"Installing bootloader via systemd-boot"
"Warning: could not ensure systemd-boot EFI binary: systemd-bootx64.efi not found under
 /mnt/fisherman-target/{ostree,sysroot/ostree}"
```
UEFI firmware then falls through to PXE boot entries → timeout.

**What happened:**
- `output/bluefin/bluefin-live.iso` recipe.json correctly says `"bootloader": "grub2"`.
- Fisherman dev channel ignored this field and auto-detected `systemd-boot`.
- Bluefin uses grub2: `systemd-bootx64.efi` not present → no EFI binary written.
- Fresh OVMF VARS (no NVRAM entries) → UEFI falls to PXE → timeout.

**Affected:** bluefin and bluefin-lts-hwe variants with `installer_channel=dev`.

**Workaround:** Use `installer_channel=stable` for grub2 variants.  
**Fix needed upstream:** tuna-os/fisherman or tuna-os/tuna-installer must respect
`"bootloader"` field in recipe.json regardless of auto-detection result.

**CI gap:** `build-iso-bluefin.yml` only verifies live ISO boots — it has no install
E2E.  `test-plain-install.yml` only tests the `dakota` variant.  A bluefin install
E2E does not exist.  Until one is added, bluefin install regressions will not be
caught automatically.

---

## Symptom: live ISO drops to emergency shell (never reaches installer)

### Root cause: debug ISO mksquashfs removes sys/ and dev/ directory nodes (FIXED in d974a1e)

**What happened:**
`build-iso.yml` debug ISO rebuild ran:
```bash
mksquashfs ... -wildcards -e proc -e sys -e dev ...
```
With `-wildcards` active, `-e sys` and `-e dev` remove the **directory nodes** themselves,
not just their contents.  `dmsquash-live-root.sh` then fails:
- If squashfs has `LiveOS/proc` but no `sys/` or `dev/` → `usable_root()` fallback fails.
- Error: `dracut Warning: /sysroot has no proper rootfs layout`.

`plain-boot-qemu-live` prefers `<target>-debug-live.iso` over the production ISO, so
CI was always booting the broken debug ISO.

**Fix:**
```bash
mkdir -p sys/ dev/
mksquashfs ... -wildcards -e "sys/*" -e "dev/*" ...
```
The `mkdir -p` ensures empty directory nodes exist; `"dir/*"` excludes only contents.

---

## Variant configuration correctness reference

| Variant | `bootloader` | `composeFsBackend` | `image` in recipe.json |
|---|---|---|---|
| dakota | systemd | true | `containers-storage:ghcr.io/projectbluefin/dakota-nvidia:stable` |
| bluefin | grub2 | false | `oci:/var/lib/containers/oci-store` |
| bluefin-lts-hwe | grub2 | false | `oci:/var/lib/containers/oci-store` |

All variants default to btrfs.  XFS is available as a UI option only — never the
default.  See stored memory: "filesystem defaults".

---

## How to diagnose a new install failure

1. **Get the serial log.** The install log and post-install serial log are the
   primary evidence.  Look for the BLS entry to see actual `root=` and `composefs=`
   params written by `bootc install`.

2. **Check fisherman's `--bootloader` and `--composefs-backend` flags.**  They must
   match the variant's recipe.json.  If they don't, the ISO has a wrong recipe.json
   OR fisherman is ignoring it.

3. **Check the `image:` field in recipe.json vs what's embedded:**
   - composefs (dakota): `containers-storage:...` → VFS at `/var/lib/containers/storage`
   - non-composefs: `oci:/var/lib/containers/oci-store`  
   Mismatch → fisherman pulls from network → uninjected image → wrong root-mount-spec.

4. **Check `root-mount-spec` injection.**  The squashfs build injects
   `root-mount-spec = "LABEL=root"` into `/usr/lib/bootc/install/00-defaults.toml`
   inside the embedded image.  If fisherman uses a network-pulled image, this
   injection is missing.

5. **Verify filesystem label.**  The btrfs root partition must have LABEL=root for
   `root=LABEL=root` in the BLS entry to work.  This is set by fisherman during
   partitioning based on the root-mount-spec; if the spec was wrong the label is wrong.

6. **Check `storage.conf` on the live ISO:**  Must have `driver = "vfs"` (all variants)
   so containers-storage reads from the VFS store embedded in the squashfs.  If `driver`
   is missing or set to `overlay`, containers-storage cannot read the embedded image.
