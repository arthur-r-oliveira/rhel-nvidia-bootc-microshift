#!/usr/bin/bash
# Embed MicroShift release images + optional NVDP_IMAGE into dir: transport for air-gapped boots.
# Fails the build on any unresolved pull (avoids silent partial payloads when /bin/sh ignores skopeo errors).
set -euo pipefail

AUTHFILE="${AUTHFILE:-/run/secrets/pull-secret.json}"
RELEASE_JSON="/usr/share/microshift/release/release-$(uname -m).json"

if [[ ! -f "${AUTHFILE}" ]]; then
    echo "embed-microshift-images: missing auth file ${AUTHFILE}" >&2
    exit 1
fi
if [[ ! -f "${RELEASE_JSON}" ]]; then
    echo "embed-microshift-images: missing ${RELEASE_JSON}" >&2
    exit 1
fi

embed_one() {
    local img="$1"
    local sha
    sha="$(echo "${img}" | sha256sum | awk '{print $1}')"
    if skopeo copy --all --preserve-digests \
        --authfile "${AUTHFILE}" \
        "docker://${img}" "dir:${IMAGE_STORAGE_DIR}/${sha}"; then
        echo "${img},${sha}" >> "${IMAGE_LIST_FILE}"
        return 0
    fi
    # Customer pull secrets often lack quay.io; the same payload frequently mirrors under registry.redhat.io.
    if [[ "${img}" == quay.io/openshift-release-dev/* ]]; then
        local alt="registry.redhat.io/${img#quay.io/}"
        echo "embed-microshift-images: retrying ${img} as ${alt}" >&2
        if skopeo copy --all --preserve-digests \
            --authfile "${AUTHFILE}" \
            "docker://${alt}" "dir:${IMAGE_STORAGE_DIR}/${sha}"; then
            echo "${img},${sha}" >> "${IMAGE_LIST_FILE}"
            return 0
        fi
    fi
    echo "embed-microshift-images: failed to copy ${img}" >&2
    return 1
}

while IFS= read -r img; do
    [[ -z "${img}" ]] && continue
    embed_one "${img}" || exit 1
done < <(jq -r '.images[]' "${RELEASE_JSON}")

if [[ -n "${NVDP_IMAGE:-}" ]]; then
    sha_nvdp="$(echo "${NVDP_IMAGE}" | sha256sum | awk '{print $1}')"
    skopeo copy --all --preserve-digests \
        --authfile "${AUTHFILE}" \
        "docker://${NVDP_IMAGE}" "dir:${IMAGE_STORAGE_DIR}/${sha_nvdp}"
    echo "${NVDP_IMAGE},${sha_nvdp}" >> "${IMAGE_LIST_FILE}"
fi
