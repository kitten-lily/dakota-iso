#!/usr/bin/bash
# payload-prep.sh — inject bootc install defaults into the payload image and
# emit it as an oci-archive for embedding into the live squashfs store.
#
# Extracted from iso-sd-boot.sh so the identical logic runs either:
#   • directly on the host (host buildah), or
#   • inside the iso-tools container (ISO_TOOLS_IMAGE set) for hosts that
#     lack buildah — invoked via a single `podman run` so the buildah working
#     container persists across the from→copy→commit sequence (ephemeral
#     `podman run` per command would lose it).
#
# All inputs arrive via environment:
#   PAYLOAD_IMAGE      — image ref to prepare (must exist in local storage)
#   PAYLOAD_OCI        — output oci-archive path
#   OUTPUT_DIR         — scratch dir for the generated config files
#   COMPOSEFS_BACKEND  — "true" (squash + diffid relabel) or anything else
set -euo pipefail

: "${PAYLOAD_IMAGE:?PAYLOAD_IMAGE must be set}"
: "${PAYLOAD_OCI:?PAYLOAD_OCI must be set}"
: "${OUTPUT_DIR:?OUTPUT_DIR must be set}"
COMPOSEFS_BACKEND="${COMPOSEFS_BACKEND:-true}"

printf '[install]\nroot-mount-spec = "LABEL=root"\n' > "${OUTPUT_DIR}/.bootc-root-mount.toml"

INJECT_CTR=$(buildah from --pull-never "${PAYLOAD_IMAGE}")
buildah copy "${INJECT_CTR}" "${OUTPUT_DIR}/.bootc-root-mount.toml" /tmp/.bootc-root-mount.toml
buildah run "${INJECT_CTR}" -- sh -c 'mkdir -p /usr/lib/bootc/install && cp /tmp/.bootc-root-mount.toml /usr/lib/bootc/install/00-defaults.toml && rm /tmp/.bootc-root-mount.toml'

if [[ "${COMPOSEFS_BACKEND}" == "true" ]]; then
    printf '[storage]\ndriver = "vfs"\nrunroot = "/run/containers/storage"\ngraphroot = "/var/lib/containers/storage"\n' > "${OUTPUT_DIR}/.vfs-storage.conf"
    buildah run "${INJECT_CTR}" -- mkdir -p /etc/containers
    buildah copy "${INJECT_CTR}" "${OUTPUT_DIR}/.vfs-storage.conf" /etc/containers/storage.conf
    echo "=== Squashing ${PAYLOAD_IMAGE} to single layer (avoids VFS explosion) ==="
    buildah commit --squash "${INJECT_CTR}" "oci-archive:${PAYLOAD_OCI}:${PAYLOAD_IMAGE}"
    buildah rm "${INJECT_CTR}"
    ANNOT_CTR=$(buildah from --pull-never "oci-archive:${PAYLOAD_OCI}:${PAYLOAD_IMAGE}")
    SQUASHED_DIFFID=$(skopeo inspect --config "oci-archive:${PAYLOAD_OCI}:${PAYLOAD_IMAGE}" 2>/dev/null | \
        python3 -c 'import json,sys; c=json.load(sys.stdin); print(c["rootfs"]["diff_ids"][0])' 2>/dev/null || true)
    if [[ -n "${SQUASHED_DIFFID}" ]]; then
        echo "Updating ostree.final-diffid to ${SQUASHED_DIFFID} (composefs mode)"
        buildah config --label "ostree.final-diffid=${SQUASHED_DIFFID}" "${ANNOT_CTR}"
        buildah config --annotation "ostree.final-diffid=${SQUASHED_DIFFID}" "${ANNOT_CTR}"
    fi
    buildah commit --squash "${ANNOT_CTR}" "oci-archive:${PAYLOAD_OCI}:${PAYLOAD_IMAGE}"
    buildah rm "${ANNOT_CTR}"
else
    # Non-composefs (bootcDirect): no squash to preserve ostree commits.
    echo "=== Committing ${PAYLOAD_IMAGE} WITHOUT squash to preserve ostree commits ==="
    buildah commit "${INJECT_CTR}" "oci-archive:${PAYLOAD_OCI}:${PAYLOAD_IMAGE}"
    buildah rm "${INJECT_CTR}"
fi
