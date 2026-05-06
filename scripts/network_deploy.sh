#!/usr/bin/env bash
# Deploy from a prepared artifact manifest on a restricted or air-gapped target.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${REPO_ROOT}/scripts"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib/network_common.sh"

MANIFEST_PATH=""
SHARED_PATH=""
FROM_STAGE=""
DRY_RUN=0
GROUP_ARG=""
MODULE_SYSTEM_ARG=""
INSTALL_JOBS=""
MAKE_JOBS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest) MANIFEST_PATH="$2"; shift 2 ;;
        --shared-path) SHARED_PATH="$2"; shift 2 ;;
        --from-stage) FROM_STAGE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --group) GROUP_ARG="$2"; shift 2 ;;
        --module-system) MODULE_SYSTEM_ARG="$2"; shift 2 ;;
        --jobs) INSTALL_JOBS="$2"; shift 2 ;;
        --make-jobs) MAKE_JOBS="$2"; shift 2 ;;
        *) echo "network_deploy.sh: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${MANIFEST_PATH}" || -z "${SHARED_PATH}" ]]; then
    echo "Usage: network_deploy.sh --manifest <file> --shared-path <path> [--from-stage N] [--dry-run]" >&2
    exit 1
fi
if [[ ! -f "${MANIFEST_PATH}" ]]; then
    echo "ERROR: manifest not found: ${MANIFEST_PATH}" >&2
    exit 1
fi

MANIFEST_DIR="$(cd "$(dirname "${MANIFEST_PATH}")" && pwd)"

mapfile -t MANIFEST_FIELDS < <(python3 - "${MANIFEST_PATH}" <<'PY'
import json
import sys

with open(sys.argv[1]) as fh:
    data = json.load(fh)

artifact_keys = ["lockfile", "source_mirror", "bootstrap_bundle", "spack_seed", "buildcache"]
for key in [
    "network_mode",
    "variant",
    "release",
    "package_set",
    "target",
    "gcc_version",
    "spack_version",
]:
    print(data.get(key, ""))
for key in artifact_keys:
    art = data.get("artifacts", {}).get(key, {})
    print(art.get("path", ""))
    print(art.get("sha256", ""))
PY
)

NETWORK_MODE="${MANIFEST_FIELDS[0]}"
VARIANT="${MANIFEST_FIELDS[1]}"
RELEASE="${MANIFEST_FIELDS[2]}"
PACKAGE_SET="${MANIFEST_FIELDS[3]}"
TARGET="${MANIFEST_FIELDS[4]}"
GCC_VERSION="${MANIFEST_FIELDS[5]}"
SPACK_VERSION="${MANIFEST_FIELDS[6]}"
LOCKFILE_REL="${MANIFEST_FIELDS[7]}"
LOCKFILE_SHA="${MANIFEST_FIELDS[8]}"
SOURCE_MIRROR_REL="${MANIFEST_FIELDS[9]}"
SOURCE_MIRROR_SHA="${MANIFEST_FIELDS[10]}"
BOOTSTRAP_REL="${MANIFEST_FIELDS[11]}"
BOOTSTRAP_SHA="${MANIFEST_FIELDS[12]}"
SPACK_SEED_REL="${MANIFEST_FIELDS[13]}"
SPACK_SEED_SHA="${MANIFEST_FIELDS[14]}"
BUILDCACHE_REL="${MANIFEST_FIELDS[15]}"
BUILDCACHE_SHA="${MANIFEST_FIELDS[16]}"

resolve_artifact() {
    local relative_path="$1"
    if [[ -z "${relative_path}" ]]; then
        return 0
    fi
    python3 - "${MANIFEST_DIR}" "${relative_path}" <<'PY'
import pathlib
import sys

print((pathlib.Path(sys.argv[1]) / sys.argv[2]).resolve())
PY
}

verify_checksum() {
    local path="$1"
    local expected="$2"
    if [[ -z "${path}" || -z "${expected}" ]]; then
        return 0
    fi
    local actual
    actual="$(cse_sha256 "${path}")"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "ERROR: checksum mismatch for ${path}" >&2
        echo "       expected ${expected}" >&2
        echo "       actual   ${actual}" >&2
        exit 1
    fi
}

LOCKFILE_PATH="$(resolve_artifact "${LOCKFILE_REL}")"
SOURCE_MIRROR_ARCHIVE="$(resolve_artifact "${SOURCE_MIRROR_REL}")"
BOOTSTRAP_BUNDLE_PATH="$(resolve_artifact "${BOOTSTRAP_REL}")"
SPACK_SEED_PATH="$(resolve_artifact "${SPACK_SEED_REL}")"
BUILDCACHE_ARCHIVE="$(resolve_artifact "${BUILDCACHE_REL}")"

for required_path in "${LOCKFILE_PATH}" "${SOURCE_MIRROR_ARCHIVE}" "${BOOTSTRAP_BUNDLE_PATH}"; do
    if [[ ! -f "${required_path}" ]]; then
        echo "ERROR: required artifact missing: ${required_path}" >&2
        exit 1
    fi
done
if [[ "${NETWORK_MODE}" == "airgapped" && ! -f "${SPACK_SEED_PATH}" ]]; then
    echo "ERROR: air-gapped manifest must include a Spack seed bundle." >&2
    exit 1
fi

verify_checksum "${LOCKFILE_PATH}" "${LOCKFILE_SHA}"
verify_checksum "${SOURCE_MIRROR_ARCHIVE}" "${SOURCE_MIRROR_SHA}"
verify_checksum "${BOOTSTRAP_BUNDLE_PATH}" "${BOOTSTRAP_SHA}"
verify_checksum "${SPACK_SEED_PATH}" "${SPACK_SEED_SHA}"
verify_checksum "${BUILDCACHE_ARCHIVE}" "${BUILDCACHE_SHA}"

ARTIFACT_STAGE_DIR="${SHARED_PATH}/cse/${RELEASE}/${VARIANT}/network-artifacts"
SOURCE_MIRROR_DIR="${ARTIFACT_STAGE_DIR}/source-mirror"
BUILDCACHE_DIR="${ARTIFACT_STAGE_DIR}/buildcache"

if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[dry-run] network_deploy: would extract ${SOURCE_MIRROR_ARCHIVE} to ${SOURCE_MIRROR_DIR}"
    if [[ -n "${BUILDCACHE_ARCHIVE}" ]]; then
        echo "[dry-run] network_deploy: would extract ${BUILDCACHE_ARCHIVE} to ${BUILDCACHE_DIR}"
    fi
else
    mkdir -p "${ARTIFACT_STAGE_DIR}"
    cse_extract_archive "${SOURCE_MIRROR_ARCHIVE}" "${SOURCE_MIRROR_DIR}"
    if [[ -n "${BUILDCACHE_ARCHIVE}" ]]; then
        cse_extract_archive "${BUILDCACHE_ARCHIVE}" "${BUILDCACHE_DIR}"
    fi
fi

DEPLOY_ARGS=(
    "${SCRIPT_DIR}/deploy.sh"
    --variant "${VARIANT}"
    --release "${RELEASE}"
    --shared-path "${SHARED_PATH}"
    --network-mode "${NETWORK_MODE}"
    --package-set "${PACKAGE_SET}"
    --target "${TARGET}"
    --gcc-version "${GCC_VERSION}"
    --spack-version "${SPACK_VERSION}"
    --mirror-path "${SOURCE_MIRROR_DIR}"
    --bootstrap-bundle "${BOOTSTRAP_BUNDLE_PATH}"
    --lockfile "${LOCKFILE_PATH}"
    --artifact-manifest "${MANIFEST_PATH}"
)
if [[ -n "${SPACK_SEED_PATH}" ]]; then
    DEPLOY_ARGS+=(--spack-seed "${SPACK_SEED_PATH}")
fi
if [[ -n "${BUILDCACHE_ARCHIVE}" ]]; then
    DEPLOY_ARGS+=(--buildcache-uri "file://${BUILDCACHE_DIR}")
fi
if [[ -n "${FROM_STAGE}" ]]; then
    DEPLOY_ARGS+=(--from-stage "${FROM_STAGE}")
fi
if [[ "${DRY_RUN}" == "1" ]]; then
    DEPLOY_ARGS+=(--dry-run)
fi
if [[ -n "${GROUP_ARG}" ]]; then
    DEPLOY_ARGS+=(--group "${GROUP_ARG}")
fi
if [[ -n "${MODULE_SYSTEM_ARG}" ]]; then
    DEPLOY_ARGS+=(--module-system "${MODULE_SYSTEM_ARG}")
fi
if [[ -n "${INSTALL_JOBS}" ]]; then
    DEPLOY_ARGS+=(--jobs "${INSTALL_JOBS}")
fi
if [[ -n "${MAKE_JOBS}" ]]; then
    DEPLOY_ARGS+=(--make-jobs "${MAKE_JOBS}")
fi

"${DEPLOY_ARGS[@]}"
