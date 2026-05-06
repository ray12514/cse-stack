#!/usr/bin/env bash
# Fulfill a restricted or air-gapped request bundle on a connected helper host.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${REPO_ROOT}/scripts"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib/network_common.sh"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib/python_env.sh"

REQUEST_DIR=""
OUTPUT_DIR=""
SHARED_PATH=""
WITH_BUILDCACHE=0
BUILDCACHE_DIR=""
DEPLOY_JOBS=""
MAKE_JOBS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --request-dir) REQUEST_DIR="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --shared-path) SHARED_PATH="$2"; shift 2 ;;
        --with-buildcache) WITH_BUILDCACHE=1; shift ;;
        --buildcache-dir) BUILDCACHE_DIR="$2"; WITH_BUILDCACHE=1; shift 2 ;;
        --jobs) DEPLOY_JOBS="$2"; shift 2 ;;
        --make-jobs) MAKE_JOBS="$2"; shift 2 ;;
        *) echo "network_fulfill_request.sh: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${REQUEST_DIR}" || -z "${OUTPUT_DIR}" || -z "${SHARED_PATH}" ]]; then
    echo "Usage: network_fulfill_request.sh --request-dir <dir> --output-dir <dir> --shared-path <helper-shared-path> [--with-buildcache]" >&2
    exit 1
fi

REQUEST_MANIFEST="${REQUEST_DIR}/request.json"
PROFILE_PATH="${REQUEST_DIR}/profile.yaml"
if [[ ! -f "${REQUEST_MANIFEST}" || ! -f "${PROFILE_PATH}" ]]; then
    echo "ERROR: request bundle must contain request.json and profile.yaml" >&2
    exit 1
fi

REQUEST_FIELDS=()
while IFS= read -r line; do
    REQUEST_FIELDS+=("${line}")
done < <(python3 - "${REQUEST_MANIFEST}" <<'PY'
import json
import sys

with open(sys.argv[1]) as fh:
    data = json.load(fh)

for key in [
    "network_mode",
    "variant",
    "release",
    "package_set",
    "target",
    "gcc_version",
    "spack_version",
    "mpich_version",
]:
    print(data.get(key, ""))
PY
)

NETWORK_MODE="${REQUEST_FIELDS[0]}"
VARIANT="${REQUEST_FIELDS[1]}"
RELEASE="${REQUEST_FIELDS[2]}"
PACKAGE_SET="${REQUEST_FIELDS[3]}"
TARGET="${REQUEST_FIELDS[4]}"
GCC_VERSION="${REQUEST_FIELDS[5]}"
SPACK_VERSION="${REQUEST_FIELDS[6]}"
MPICH_VERSION="${REQUEST_FIELDS[7]}"

if [[ "${NETWORK_MODE}" != "restricted" && "${NETWORK_MODE}" != "airgapped" ]]; then
    echo "ERROR: request network_mode must be restricted or airgapped." >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"
ARTIFACT_DIR="${OUTPUT_DIR}/artifacts"
mkdir -p "${ARTIFACT_DIR}"

export SHARED_PATH
cse_python_bootstrap

DEPLOY_ARGS=(
    "${SCRIPT_DIR}/deploy.sh"
    --variant "${VARIANT}"
    --release "${RELEASE}"
    --shared-path "${SHARED_PATH}"
    --network-mode online
    --mock-profile "${PROFILE_PATH}"
    --package-set "${PACKAGE_SET}"
    --target "${TARGET}"
    --gcc-version "${GCC_VERSION}"
    --spack-version "${SPACK_VERSION}"
)
if [[ -n "${MPICH_VERSION}" ]]; then
    DEPLOY_ARGS+=(--mpich-version "${MPICH_VERSION}")
fi
if [[ -n "${DEPLOY_JOBS}" ]]; then
    DEPLOY_ARGS+=(--jobs "${DEPLOY_JOBS}")
fi
if [[ -n "${MAKE_JOBS}" ]]; then
    DEPLOY_ARGS+=(--make-jobs "${MAKE_JOBS}")
fi

"${DEPLOY_ARGS[@]}"

VARIANT_ROOT="${SHARED_PATH}/cse/${RELEASE}/${VARIANT}"
ENV_DIR="${VARIANT_ROOT}/env"
LOCKFILE_PATH="${ENV_DIR}/spack.lock"
BOOTSTRAP_ROOT="${SHARED_PATH}/cse/cache/bootstrap"
SPACK_SITE="${SHARED_PATH}/cse/spack-site"
SOURCE_MIRROR_DIR="${ARTIFACT_DIR}/source-mirror"
SOURCE_MIRROR_TAR="${ARTIFACT_DIR}/source-mirror.tar.gz"
BOOTSTRAP_TAR="${ARTIFACT_DIR}/bootstrap-bundle.tar.gz"
LOCKFILE_COPY="${ARTIFACT_DIR}/spack.lock"
SPACK_SEED_TAR="${ARTIFACT_DIR}/spack-seed-${SPACK_VERSION#v}.tar.gz"
PYTHON_WHEELHOUSE_DIR="${ARTIFACT_DIR}/python-wheelhouse"
PYTHON_WHEELHOUSE_TAR="${ARTIFACT_DIR}/python-wheelhouse.tar.gz"

cse_python_download_wheelhouse "${PYTHON_WHEELHOUSE_DIR}"
tar -czf "${PYTHON_WHEELHOUSE_TAR}" -C "${ARTIFACT_DIR}" "$(basename "${PYTHON_WHEELHOUSE_DIR}")"

cp "${LOCKFILE_PATH}" "${LOCKFILE_COPY}"

"${SCRIPT_DIR}/mirror_fetch.sh" \
    --mirror-path "${SOURCE_MIRROR_DIR}" \
    --variant "${VARIANT}" \
    --release "${RELEASE}" \
    --shared-path "${SHARED_PATH}"
tar -czf "${SOURCE_MIRROR_TAR}" -C "${ARTIFACT_DIR}" "$(basename "${SOURCE_MIRROR_DIR}")"

tar -czf "${BOOTSTRAP_TAR}" -C "$(dirname "${BOOTSTRAP_ROOT}")" "$(basename "${BOOTSTRAP_ROOT}")"

BUILDCACHE_TAR=""
BUILDCACHE_URI=""
if [[ "${WITH_BUILDCACHE}" == "1" ]]; then
    if [[ -z "${BUILDCACHE_DIR}" ]]; then
        BUILDCACHE_DIR="${ARTIFACT_DIR}/buildcache"
    fi
    mkdir -p "${BUILDCACHE_DIR}"
    BUILDCACHE_URI="$(cse_path_to_uri "${BUILDCACHE_DIR}")"
    "${SCRIPT_DIR}/buildcache_push.sh" \
        --cache-uri "${BUILDCACHE_URI}" \
        --variant "${VARIANT}" \
        --release "${RELEASE}" \
        --shared-path "${SHARED_PATH}"
    BUILDCACHE_TAR="${ARTIFACT_DIR}/buildcache.tar.gz"
    tar -czf "${BUILDCACHE_TAR}" -C "$(dirname "${BUILDCACHE_DIR}")" "$(basename "${BUILDCACHE_DIR}")"
fi

if [[ "${NETWORK_MODE}" == "airgapped" ]]; then
    tar -czf "${SPACK_SEED_TAR}" -C "$(dirname "${SPACK_SITE}")" "$(basename "${SPACK_SITE}")"
fi

"${CSE_PYTHON}" - "${OUTPUT_DIR}/manifest.json" "${REQUEST_MANIFEST}" "${ARTIFACT_DIR}" "${NETWORK_MODE}" "${VARIANT}" "${RELEASE}" "${PACKAGE_SET}" "${TARGET}" "${GCC_VERSION}" "${SPACK_VERSION}" "${LOCKFILE_COPY}" "${SOURCE_MIRROR_TAR}" "${BOOTSTRAP_TAR}" "${SPACK_SEED_TAR}" "${BUILDCACHE_TAR}" "${PYTHON_WHEELHOUSE_TAR}" <<'PY'
import json
import pathlib
import sys
import hashlib

(
    output,
    request_manifest,
    artifact_dir,
    network_mode,
    variant,
    release,
    package_set,
    target,
    gcc_version,
    spack_version,
    lockfile_path,
    source_mirror_tar,
    bootstrap_tar,
    spack_seed_tar,
    buildcache_tar,
    python_wheelhouse_tar,
) = sys.argv[1:17]

artifact_dir = pathlib.Path(artifact_dir)
request_data = json.loads(pathlib.Path(request_manifest).read_text())

def checksum(path_str):
    path = pathlib.Path(path_str)
    if not path.exists():
        return ""
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def rel(path_str):
    path = pathlib.Path(path_str)
    if not path.exists():
        return ""
    return str(path.relative_to(pathlib.Path(output).parent))

manifest = {
    "schema_version": 1,
    "request_manifest": pathlib.Path(request_manifest).name,
    "request_network_mode": request_data["network_mode"],
    "network_mode": network_mode,
    "variant": variant,
    "release": release,
    "package_set": package_set,
    "target": target,
    "gcc_version": gcc_version,
    "spack_version": spack_version,
    "artifacts": {
        "lockfile": {"path": rel(lockfile_path), "sha256": checksum(lockfile_path)},
        "source_mirror": {"path": rel(source_mirror_tar), "sha256": checksum(source_mirror_tar)},
        "bootstrap_bundle": {"path": rel(bootstrap_tar), "sha256": checksum(bootstrap_tar)},
        "python_wheelhouse": {"path": rel(python_wheelhouse_tar), "sha256": checksum(python_wheelhouse_tar)},
    },
}
if pathlib.Path(spack_seed_tar).exists():
    manifest["artifacts"]["spack_seed"] = {"path": rel(spack_seed_tar), "sha256": checksum(spack_seed_tar)}
if pathlib.Path(buildcache_tar).exists():
    manifest["artifacts"]["buildcache"] = {"path": rel(buildcache_tar), "sha256": checksum(buildcache_tar)}

pathlib.Path(output).write_text(json.dumps(manifest, indent=2) + "\n")
PY

cp "${REQUEST_MANIFEST}" "${OUTPUT_DIR}/request.json"

echo "Artifact bundle written to ${OUTPUT_DIR}"
echo "  manifest : ${OUTPUT_DIR}/manifest.json"
echo "  lockfile : ${LOCKFILE_COPY}"
echo "  mirror   : ${SOURCE_MIRROR_TAR}"
echo "  bootstrap: ${BOOTSTRAP_TAR}"
echo "  python   : ${PYTHON_WHEELHOUSE_TAR}"
if [[ "${NETWORK_MODE}" == "airgapped" ]]; then
    echo "  spack    : ${SPACK_SEED_TAR}"
fi
if [[ -n "${BUILDCACHE_TAR}" ]]; then
    echo "  buildcache: ${BUILDCACHE_TAR}"
fi
