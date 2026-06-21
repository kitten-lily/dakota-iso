# Install Failure Reference

Root causes for "ISO boots but installed system does not boot / install fails."
Read this before touching squashfs builds, recipe.json, or fisherman integration.

---

## STATUS (as of 2026-06-21)

| Variant | Status | Note |
|---|---|---|
| dakota | ✅ WORKS | plain-e2e-test3.log verified |
| bluefin | ❌ ENOSPC at install — FIX IN configure-live.sh (unverified) | see below |
| bluefin-lts-hwe | ❌ NOT TESTED | same fix applies |

---

## Failure 1: bluefin/lts-hwe ENOSPC during install (ROOT CAUSE + FIX)

### What breaks

Installer completes squashfs boot fine. fisherman starts, begins install, then:
```
Error: open /var/lib/containers/storage/vfs/dir/<id>/sysroot/ostree/...: no space left on device
```

### Why

fisherman non-composefs path (when `composeFsBackend=false`) does:
1. `podman run ... -v /var/lib/containers:/var/lib/containers ... <image-ref> bootc install`
2. podman pulls `oci:/var/lib/containers/oci-store` → VFS driver creates a full copy of the
   ~9 GB squashed image as a writable container layer at `/var/lib/containers/storage/vfs/dir/`
3. That path is on the live system's overlayfs upper dir (tmpfs / RAM) → ENOSPC

### The fix (applied in configure-live.sh)

fisherman v0.2.0+ reads `additionalImageStores` from recipe.json.
When set, `appendImageStoreArgs()` in fisherman writes a containers/storage config:
```toml
[storage]
driver = "overlay"
[storage.options]
additionalimagestores = ["/var/lib/containers/oci-store"]
```
and passes it as `CONTAINERS_STORAGE_CONF` into the podman container.
bootc finds the image via additionalimagestores (read-only, no copy) — no ENOSPC.

**Fix location:** `live/src/configure-live.sh` recipe.json generation, non-composefs branch:
```python
recipe["additionalImageStores"] = ["/var/lib/containers/oci-store"]
```

**This fix has been applied but NOT yet tested end-to-end.**
Next agent: build a bluefin ISO and run `just plain-test-qemu bluefin`.

### What NOT to do

- Do NOT squash or not-squash OCI layers to fix this. Layers don't matter.
- Do NOT add extra QEMU disks, bind mounts, or scratch volumes to the test harness.
- Do NOT change fisherman upstream. The fix is in recipe.json configuration.
- Do NOT use `installer_channel=dev` for bluefin — dev fisherman ignores `bootloader: grub2`.

---

## Failure 2: installed system drops to emergency shell (FIXED in d974a1e)

**Symptom:** `dracut Warning: Refusing to install. ...` or `Cannot mount root` in serial log.

**Root cause:** COMPOSEFS_BACKEND detection in `scripts/build-live-squashfs.sh` always returned
false. Dakota (composefs=true) was embedded as OCI layout instead of VFS containers-storage.
fisherman found no image in containers-storage → pulled uninjected image from network →
image lacked `root-mount-spec = "LABEL=root"` → wrong `root=` in BLS entry → initramfs
could not mount root → emergency shell.

**Fix:** Replaced `sh -c 'python3 -c "..."'` with `python3 -c '...'` in build-live-squashfs.sh.
The outer `sh -c` split on inner double-quotes, breaking the python3 invocation.

**Verified fixed:** plain-e2e-test3.log (2026-06-21) `✅ Installed system boot verified`.

---

## Failure 3: live ISO drops to emergency shell / never reaches installer (FIXED in d974a1e)

**Symptom:** QEMU boots ISO, dracut error before installer appears.
`dracut Warning: /sysroot has no proper rootfs layout` or similar.

**Root cause:** CI debug ISO rebuild in `build-iso.yml` ran:
```bash
mksquashfs ... -wildcards -e sys -e dev
```
With `-wildcards`, `-e sys` removes the `sys/` directory node entirely.
`dmsquash-live-root.sh` requires `proc/`, `sys/`, `dev/` to exist as directories.

**Fix:** `mkdir -p sys/ dev/` before mksquashfs, change to `-e "sys/*" -e "dev/*"`.
Same fix is in `scripts/build-live-squashfs.sh` (applies to all builds).

---

## Failure 4: installed system has no bootloader / UEFI falls to PXE

**Symptom:** installed system QEMU shows UEFI PXE timeout, never boots.

**Root cause:** `installer_channel=dev` fisherman ignores `bootloader: grub2` in recipe.json
and auto-detects systemd-boot. Bluefin uses grub2; `systemd-bootx64.efi` is not present →
no EFI binary written → UEFI has nothing to boot.

**Fix:** Use `installer_channel=stable` for bluefin/lts-hwe variants. Never use dev channel
for grub2 variants until tuna-os/fisherman fixes recipe.json bootloader field handling.

---

## Variant configuration reference

| Variant | bootloader | composeFsBackend | image in recipe.json | additionalImageStores |
|---|---|---|---|---|
| dakota | systemd | true | `containers-storage:ghcr.io/projectbluefin/dakota-nvidia:stable` | (none) |
| bluefin | grub2 | false | `oci:/var/lib/containers/oci-store` | `["/var/lib/containers/oci-store"]` |
| bluefin-lts-hwe | grub2 | false | `oci:/var/lib/containers/oci-store` | `["/var/lib/containers/oci-store"]` |

All variants: filesystem=btrfs. XFS is a UI option only, never the default.

Config files controlling this (read by configure-live.sh at container build time):
- `live/src/<variant>/composefs` — "true" or "false"
- `live/src/<variant>/bootloader` — "grub" (normalized to "grub2") or "systemd"

---

## How to verify a working install

```bash
just debug=1 iso-sd-boot bluefin
just plain-test-qemu bluefin
# Must end with: ✅ Installed system boot verified
```

"ISO booted" is not proof. Only a completed install + installed-system boot proves it.

---

## How fisherman uses additionalImageStores (for future reference)

Source: `tuna-os/fisherman/fisherman/internal/install/bootc.go`

`appendImageStoreArgs()` is called when `NeedsContainerStorageMount(opts)` is true
(i.e., `!ComposeFsBackend`). If `opts.AdditionalImageStores` is non-empty, it:
1. Writes a storage.conf to `scratchDir/fisherman-conf/storage-*.conf`:
   ```toml
   [storage]
   driver = "overlay"
   [storage.options]
   additionalimagestores = ["<path>"]
   ```
2. Bind-mounts each store path read-only into the container at the same host path
3. Sets `CONTAINERS_STORAGE_CONF` to the container-side path of the storage.conf

Result: bootc inside the container sees the OCI store as an additionalimagestore via
overlay driver. No VFS copy, no ENOSPC.

fisherman reads `additionalImageStores` from recipe.json into `opts.AdditionalImageStores`.
This is the correct field to set. No code changes to fisherman are needed.
