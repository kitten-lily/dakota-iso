#!/usr/bin/bash
# scripts/iso-sd-boot.sh — Build a systemd-boot UEFI live ISO for a given target variant.
#
# Called by the iso-sd-boot justfile recipe. Receives configuration via environment:
#
#   TARGET            — variant directory name (e.g. dakota, stable, lts)
#   OUTPUT_DIR        — directory for the final ISO and intermediate artifacts
#   WORKDIR           — working directory for CS staging and squashfs root
#   DEBUG             — 0 (default) or 1 to enable SSH in the live env
#   INSTALLER_CHANNEL — stable (default) or dev
#   COMPRESSION       — fast (default) or release
#
# All variables have defaults so the script can be run standalone for testing.
# Usage: TARGET=dakota OUTPUT_DIR=output bash scripts/iso-sd-boot.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

TARGET="${TARGET:?TARGET must be set}"
OUTPUT_DIR="${OUTPUT_DIR:-output}"
WORKDIR="${WORKDIR:-${OUTPUT_DIR}}"
DEBUG="${DEBUG:-0}"
INSTALLER_CHANNEL="${INSTALLER_CHANNEL:-stable}"
COMPRESSION="${COMPRESSION:-fast}"

PAYLOAD_IMAGE=$(cat "${TARGET}/payload_ref" | tr -d '[:space:]')

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR=$(realpath "${OUTPUT_DIR}")
WORKDIR=$(realpath "${WORKDIR}")

echo "=== Disk space before container build ==="
df -h "${OUTPUT_DIR}"

if ! findmnt -n -o FSTYPE -T "${WORKDIR}" 2>/dev/null | grep -qE '^(xfs|btrfs)$'; then
    echo "Hint: ${WORKDIR} is not an XFS/BTRFS mount.  For faster VFS import, run:" >&2
    echo "  sudo just mount-xfs" >&2
    echo "  sudo just workdir=/mnt iso-sd-boot ${TARGET}" >&2
fi

AVAILABLE_KB=$(df --output=avail -B1024 "${OUTPUT_DIR}" | tail -1 | tr -d ' ')
REQUIRED_KB=$((20 * 1024 * 1024))
if [ "${AVAILABLE_KB}" -lt "${REQUIRED_KB}" ]; then
    echo "WARNING: Only $(( AVAILABLE_KB / 1024 / 1024 ))GB free on $(df --output=target "${OUTPUT_DIR}" | tail -1) — ISO output needs ~5GB, full build needs more" >&2
fi
podman images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" 2>/dev/null || true

just debug="${DEBUG}" installer_channel="${INSTALLER_CHANNEL}" container "${TARGET}"

echo "=== Disk space after container build ==="
df -h "${OUTPUT_DIR}"
podman images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" 2>/dev/null || true

podman rmi debian:sid 2>/dev/null || true
podman image prune -f 2>/dev/null || true
echo "=== Disk space after intermediate cleanup ==="
df -h "${OUTPUT_DIR}"

# podman unshare enters the user namespace for rootless builds.
# When running as root (CI with sudo) run directly.
if [[ $(id -u) -eq 0 ]]; then
    _ns() { bash -c "$1"; }
else
    _ns() { podman unshare bash -c "$1"; }
fi

SQUASHFS="${OUTPUT_DIR}/${TARGET}-rootfs.sfs"
BOOT_TAR="${OUTPUT_DIR}/${TARGET}-boot-files.tar"
CS_STAGING="${WORKDIR}/${TARGET}-cs-staging"
SQUASHFS_ROOT="${WORKDIR}/${TARGET}-sfs-root"
PAYLOAD_OCI="${OUTPUT_DIR}/${TARGET}-payload.oci.tar"

trap "rm -f '${SQUASHFS}' '${BOOT_TAR}' '${PAYLOAD_OCI}' 2>/dev/null || true" EXIT

echo "=== Disk space before squashfs assembly ==="
df -h "${OUTPUT_DIR}"
[[ "${WORKDIR}" != "${OUTPUT_DIR}" ]] && df -h "${WORKDIR}"
echo "Building squashfs and boot tar from localhost/${TARGET}-installer..."

LIVE_TARGET=$(cat "${TARGET}/live_target" 2>/dev/null | tr -d '[:space:]' || echo "${TARGET}")
BOOTLOADER_VARIANT=$(echo "${LIVE_TARGET}" | sed 's/-nvidia-open$//;s/-nvidia$//')
COMPOSEFS_BACKEND=$(cat "live/src/${BOOTLOADER_VARIANT}/composefs" 2>/dev/null | tr -d '[:space:]' || echo "true")
echo "=== Building offline OCI store (composefs=${COMPOSEFS_BACKEND}) for ${PAYLOAD_IMAGE} ==="

# Payload prep needs buildah + skopeo + python3. On hosts without buildah
# (e.g. immutable Krytis) set ISO_TOOLS_IMAGE to run the step inside the
# iso-tools container (see live/iso-tools/Containerfile); the whole
# from→copy→commit sequence runs in one `podman run` so the buildah working
# container survives across commands. Otherwise it runs on the host.
#
# Export the payload to an oci-archive on the host first, so payload-prep reads
# from a file under OUTPUT_DIR rather than the host containers-storage. This
# avoids bind-mounting /var/lib/containers/storage into the tools container —
# that path is wrong for rootless podman (storage lives under $HOME) and even
# when mounted the nested userns can't take the storage lock. The oci-archive
# transport works identically rootless and rootful.
PAYLOAD_INPUT="${OUTPUT_DIR}/${TARGET}-payload-input.oci.tar"
trap "rm -f '${SQUASHFS}' '${BOOT_TAR}' '${PAYLOAD_OCI}' '${PAYLOAD_INPUT}' 2>/dev/null || true" EXIT
echo "=== Exporting ${PAYLOAD_IMAGE} to oci-archive for payload prep ==="
podman save --format oci-archive -o "${PAYLOAD_INPUT}" "${PAYLOAD_IMAGE}"
podman rmi "${PAYLOAD_IMAGE}" || true

export PAYLOAD_IMAGE PAYLOAD_INPUT PAYLOAD_OCI OUTPUT_DIR COMPOSEFS_BACKEND
if [[ -n "${ISO_TOOLS_IMAGE:-}" ]]; then
    echo "Running payload prep in iso-tools container: ${ISO_TOOLS_IMAGE}"
    # STORAGE_DRIVER=vfs: buildah's internal storage lives on the container's
    # overlayfs rootfs. Its default overlay driver cannot stack on overlayfs
    # without fuse-overlayfs ("'overlay' is not supported over overlayfs"); vfs
    # has no such constraint. Scoped to the container path — the host path uses
    # whatever the host buildah is configured for (overlay on rootful CI).
    podman run --rm --privileged --net=host \
        -v "${OUTPUT_DIR}:${OUTPUT_DIR}" \
        -v "${REPO_ROOT}/live/iso-tools/payload-prep.sh:/payload-prep.sh:ro" \
        -e PAYLOAD_IMAGE -e PAYLOAD_INPUT -e PAYLOAD_OCI -e OUTPUT_DIR -e COMPOSEFS_BACKEND \
        -e STORAGE_DRIVER=vfs \
        "${ISO_TOOLS_IMAGE}" bash /payload-prep.sh
else
    _ns "bash '${REPO_ROOT}/live/iso-tools/payload-prep.sh'"
fi

rm -f "${PAYLOAD_INPUT}"

# ── Squashfs assembly (runs in user namespace for rootless UID mapping) ───────
#
# All variables needed inside _ns are passed via the outer scope — no string
# interpolation of shell vars into the bash -c argument. Instead we export them
# and the inner bash inherits them directly.
export OUTPUT_DIR WORKDIR TARGET PAYLOAD_IMAGE COMPOSEFS_BACKEND COMPRESSION
export CS_STAGING SQUASHFS_ROOT SQUASHFS BOOT_TAR PAYLOAD_OCI

_ns_build_squashfs() {
    set -euo pipefail

    echo "=== Disk space inside _ns block ==="
    df -h "${OUTPUT_DIR}"
    [[ "${WORKDIR}" != "${OUTPUT_DIR}" ]] && df -h "${WORKDIR}"

    OVERLAY_UPPER=$(mktemp -d "${SQUASHFS_ROOT}_upper_XXXXXX")
    OVERLAY_WORK=$(mktemp -d "${SQUASHFS_ROOT}_work_XXXXXX")

    ns_cleanup() {
        umount "${SQUASHFS_ROOT}/var/lib/containers/storage" 2>/dev/null || true
        umount "${SQUASHFS_ROOT}/usr/lib/containers/storage" 2>/dev/null || true
        umount "${SQUASHFS_ROOT}" 2>/dev/null || true
        podman image unmount "localhost/${TARGET}-installer" 2>/dev/null || true
        rm -rf "${OVERLAY_UPPER}" "${OVERLAY_WORK}" 2>/dev/null || true
        rm -rf "${CS_STAGING}" "${SQUASHFS_ROOT}" 2>/dev/null || true
    }
    trap ns_cleanup EXIT

    MOUNT=$(podman image mount "localhost/${TARGET}-installer")
    PATH=/usr/sbin:/usr/bin:/home/linuxbrew/.linuxbrew/bin:$PATH

    echo "=== Disk space before OCI store embed ==="
    df -h "${OUTPUT_DIR}"
    [[ "${WORKDIR}" != "${OUTPUT_DIR}" ]] && df -h "${WORKDIR}"

    if [[ "${COMPOSEFS_BACKEND}" == "true" ]]; then
        # Overlay, not vfs: /vfs-storage is a plain bind-mounted dir on the host
        # WORKDIR filesystem (recommend xfs/ext4/btrfs — see the findmnt hint
        # above), not the container's own overlayfs rootfs, and this container
        # already runs --privileged. Neither of the constraints that force vfs
        # in payload-prep.sh (rootless build, overlay-on-overlayfs) applies
        # here — see docs/skills/mise.md in krytis for the full writeup.
        SQUASHFS_STORAGE="${CS_STAGING}/var/lib/containers/storage"
        STORAGE_CONF=$(mktemp "${OUTPUT_DIR}/live-storage-XXXXXX.conf")
        mkdir -p "${SQUASHFS_STORAGE}"
        printf '[storage]\ndriver = "overlay"\nrunroot = "/tmp/cs-runroot"\ngraphroot = "/vfs-storage"\n' > "${STORAGE_CONF}"
        echo 'Importing OCI image into squashfs overlay containers-storage...'
        podman run --rm \
            --privileged \
            -v "${PAYLOAD_OCI}:/payload.oci.tar:ro" \
            -v "${SQUASHFS_STORAGE}:/vfs-storage" \
            -v "${STORAGE_CONF}:/tmp/st.conf:ro" \
            "localhost/${TARGET}-installer" \
            sh -c "mkdir -p /tmp/cs-runroot /var/tmp && CONTAINERS_STORAGE_CONF=/tmp/st.conf skopeo copy oci-archive:/payload.oci.tar:${PAYLOAD_IMAGE} containers-storage:${PAYLOAD_IMAGE}"
        rm -f "${PAYLOAD_OCI}" "${STORAGE_CONF}"
    else
        # Non-composefs: embed into overlay containers-storage.
        SQUASHFS_STORAGE="${CS_STAGING}/usr/lib/containers/storage"
        STORAGE_CONF=$(mktemp "${OUTPUT_DIR}/live-storage-XXXXXX.conf")
        mkdir -p "${SQUASHFS_STORAGE}"
        printf '[storage]\ndriver = "overlay"\nrunroot = "/tmp/cs-runroot"\ngraphroot = "/vfs-storage"\n' > "${STORAGE_CONF}"
        echo 'Importing OCI image into squashfs overlay containers-storage...'
        podman run --rm \
            --privileged \
            -v "${PAYLOAD_OCI}:/payload.oci.tar:ro" \
            -v "${SQUASHFS_STORAGE}:/vfs-storage" \
            -v "${STORAGE_CONF}:/tmp/st.conf:ro" \
            "localhost/${TARGET}-installer" \
            sh -c "mkdir -p /tmp/cs-runroot /var/tmp && CONTAINERS_STORAGE_CONF=/tmp/st.conf skopeo copy oci-archive:/payload.oci.tar:${PAYLOAD_IMAGE} containers-storage:${PAYLOAD_IMAGE}"
        rm -f "${PAYLOAD_OCI}" "${STORAGE_CONF}"
    fi

    echo "=== Disk space after OCI store embed ==="
    df -h "${OUTPUT_DIR}"
    [[ "${WORKDIR}" != "${OUTPUT_DIR}" ]] && df -h "${WORKDIR}"
    du -sh "${CS_STAGING}" 2>/dev/null || true

    echo 'Building unified squashfs source tree using bind mounts...'
    mkdir -p "${SQUASHFS_ROOT}"

    FS_TYPE=$(findmnt -n -o FSTYPE -T "${SQUASHFS_ROOT}" 2>/dev/null || echo "unknown")
    if [[ "${FS_TYPE}" == "xfs" || "${FS_TYPE}" == "ext4" ]]; then
        echo "Filesystem is ${FS_TYPE}, trying overlay"
        if ! mount -t overlay overlay \
                -o lowerdir="${MOUNT}",upperdir="${OVERLAY_UPPER}",workdir="${OVERLAY_WORK}" \
                "${SQUASHFS_ROOT}"; then
            echo "Overlay mount failed on ${FS_TYPE}; falling back to cp -a"
            cp -a "${MOUNT}/." "${SQUASHFS_ROOT}/"
        fi
    else
        echo "Filesystem is ${FS_TYPE}, doing it the boring way"
        cp -a "${MOUNT}/." "${SQUASHFS_ROOT}/"
    fi

    if [[ "${COMPOSEFS_BACKEND}" == "true" ]]; then
        mkdir -p "${SQUASHFS_ROOT}/var/lib/containers/storage"
        echo "Copying overlay store into squashfs root..."
        # Overlay containers-storage contains character-device whiteout files that
        # cp -a cannot create without privileges.  Use rsync to skip them — they
        # are write-layer artifacts not needed in the read-only additional store
        # (payload-prep.sh already squashes to a single layer, so there is
        # nothing for a whiteout to mark deleted in the first place).
        rsync -a --no-specials --no-devices "${CS_STAGING}/var/lib/containers/storage/" "${SQUASHFS_ROOT}/var/lib/containers/storage/"
    else
        mkdir -p "${SQUASHFS_ROOT}/usr/lib/containers/storage"
        echo "Copying overlay store into squashfs root..."
        # Overlay containers-storage contains character-device whiteout files that
        # cp -a cannot create without privileges.  Use rsync to skip them — they
        # are write-layer artifacts not needed in the read-only additional store.
        rsync -a --no-specials --no-devices "${CS_STAGING}/usr/lib/containers/storage/" "${SQUASHFS_ROOT}/usr/lib/containers/storage/"
    fi

    echo "=== Disk space after creation of squashfs root ==="
    df -h "${OUTPUT_DIR}"
    [[ "${WORKDIR}" != "${OUTPUT_DIR}" ]] && df -h "${WORKDIR}"
    du -sh "${SQUASHFS_ROOT}" 2>/dev/null || true

    mkdir -p "${SQUASHFS_ROOT}/proc" "${SQUASHFS_ROOT}/sys" "${SQUASHFS_ROOT}/dev"
    SFS_LEVEL=3; SFS_BLOCK=131072
    [[ "${COMPRESSION}" == "release" ]] && { SFS_LEVEL=15; SFS_BLOCK=1048576; }
    mksquashfs "${SQUASHFS_ROOT}" "${SQUASHFS}" \
        -noappend -comp zstd -Xcompression-level "${SFS_LEVEL}" -b "${SFS_BLOCK}" \
        -processors 4 \
        -wildcards -e "proc/*" -e "sys/*" -e "dev/*" -e run -e tmp

    tar -C "${MOUNT}" \
        -cf "${BOOT_TAR}" \
        ./usr/lib/modules \
        ./usr/lib/systemd/boot/efi
}
export -f _ns_build_squashfs

if [[ $(id -u) -eq 0 ]]; then
    bash -c '_ns_build_squashfs'
else
    podman unshare bash -c '_ns_build_squashfs'
fi

echo "=== Disk space after squashfs, before ISO assembly ==="
df -h "${OUTPUT_DIR}"
du -sh "${SQUASHFS}" "${BOOT_TAR}" 2>/dev/null || true

LIVE_TITLE=$(cat "${TARGET}/live_title" 2>/dev/null || echo 'Dakota Live')
LIVE_LABEL=$(cat "${TARGET}/live_label" 2>/dev/null | tr -d '[:space:]' || echo 'DAKOTA_LIVE')

# xorriso/implantisomd5 have no freedesktop-sdk component. When ISO_TOOLS_IMAGE
# is set (immutable host), route just those two binaries through the container;
# mtools/dosfstools/truncate/tar still run on the host. OUTPUT_DIR is mounted at
# the same path so the WORK tmpdir (TMPDIR=OUTPUT_DIR) and OUTPUT_ISO resolve.
XORRISO="xorriso"
IMPLANTISOMD5="implantisomd5"
if [[ -n "${ISO_TOOLS_IMAGE:-}" ]]; then
    XORRISO="podman run --rm -v ${OUTPUT_DIR}:${OUTPUT_DIR} -w ${OUTPUT_DIR} ${ISO_TOOLS_IMAGE} xorriso"
    IMPLANTISOMD5="podman run --rm -v ${OUTPUT_DIR}:${OUTPUT_DIR} -w ${OUTPUT_DIR} ${ISO_TOOLS_IMAGE} implantisomd5"
fi

TMPDIR="${OUTPUT_DIR}" \
XORRISO="${XORRISO}" \
IMPLANTISOMD5="${IMPLANTISOMD5}" \
PATH="/usr/sbin:/usr/bin:/home/linuxbrew/.linuxbrew/bin:${PATH}" \
    bash "live/src/build-iso.sh" \
        --title "${LIVE_TITLE}" \
        --label "${LIVE_LABEL}" \
        "${BOOT_TAR}" "${SQUASHFS}" "${OUTPUT_DIR}/${TARGET}-live.iso"

echo "ISO ready: ${OUTPUT_DIR}/${TARGET}-live.iso"
