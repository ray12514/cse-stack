#!/usr/bin/env bash
# Create a portable request bundle for restricted or air-gapped deploys.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REQUEST_DIR=""
VARIANT=""
RELEASE=""
SHARED_PATH=""
NETWORK_MODE=""
PACKAGE_SET="${CSE_PACKAGE_SET:-full}"
SPACK_TARGET="${SPACK_TARGET:-x86_64}"
GCC_VERSION="${GCC_VERSION:-13.3.0}"
SPACK_VERSION="${SPACK_VERSION:-v1.1.1}"
MOCK_PROFILE=""
MPICH_VERSION="${MPICH_VERSION:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --request-dir) REQUEST_DIR="$2"; shift 2 ;;
        --variant) VARIANT="$2"; shift 2 ;;
        --release) RELEASE="$2"; shift 2 ;;
        --shared-path) SHARED_PATH="$2"; shift 2 ;;
        --network-mode) NETWORK_MODE="$2"; shift 2 ;;
        --package-set) PACKAGE_SET="$2"; shift 2 ;;
        --target) SPACK_TARGET="$2"; shift 2 ;;
        --gcc-version) GCC_VERSION="$2"; shift 2 ;;
        --spack-version) SPACK_VERSION="$2"; shift 2 ;;
        --mock-profile) MOCK_PROFILE="$2"; shift 2 ;;
        --mpich-version) MPICH_VERSION="$2"; shift 2 ;;
        *) echo "network_prepare_request.sh: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${REQUEST_DIR}" || -z "${VARIANT}" || -z "${RELEASE}" || -z "${SHARED_PATH}" || -z "${NETWORK_MODE}" ]]; then
    echo "Usage: network_prepare_request.sh --request-dir <dir> --variant <v> --release <r> --shared-path <p> --network-mode <restricted|airgapped>" >&2
    exit 1
fi
if [[ "${NETWORK_MODE}" != "restricted" && "${NETWORK_MODE}" != "airgapped" ]]; then
    echo "ERROR: request bundles are only used for restricted or air-gapped modes." >&2
    exit 1
fi

mkdir -p "${REQUEST_DIR}"

PROFILE_OUT="${REQUEST_DIR}/profile.yaml"
if [[ -n "${MOCK_PROFILE}" ]]; then
    cp "${MOCK_PROFILE}" "${PROFILE_OUT}"
elif command -v clusterinspector >/dev/null 2>&1; then
    clusterinspector profile --local --format yaml --include-modules > "${PROFILE_OUT}"
else
    echo "ERROR: clusterinspector is required unless --mock-profile is provided." >&2
    exit 1
fi

LOCKFILE_SRC="${SHARED_PATH}/cse/${RELEASE}/${VARIANT}/env/spack.lock"
LOCKFILE_OUT=""
if [[ -f "${LOCKFILE_SRC}" ]]; then
    LOCKFILE_OUT="${REQUEST_DIR}/spack.lock"
    cp "${LOCKFILE_SRC}" "${LOCKFILE_OUT}"
fi

python3 - "${REQUEST_DIR}/request.json" "${NETWORK_MODE}" "${VARIANT}" "${RELEASE}" "${PACKAGE_SET}" "${SPACK_TARGET}" "${GCC_VERSION}" "${SPACK_VERSION}" "${PROFILE_OUT}" "${LOCKFILE_OUT}" "${MPICH_VERSION}" <<'PY'
import json
import pathlib
import sys

output, network_mode, variant, release, package_set, target, gcc_version, spack_version, profile_path, lockfile_path, mpich_version = sys.argv[1:12]

payload = {
    "schema_version": 1,
    "network_mode": network_mode,
    "variant": variant,
    "release": release,
    "package_set": package_set,
    "target": target,
    "gcc_version": gcc_version,
    "spack_version": spack_version,
    "profile": pathlib.Path(profile_path).name,
}
if lockfile_path:
    payload["requested_lockfile"] = pathlib.Path(lockfile_path).name
if mpich_version:
    payload["mpich_version"] = mpich_version

pathlib.Path(output).write_text(json.dumps(payload, indent=2) + "\n")
PY

echo "Request bundle written to ${REQUEST_DIR}"
echo "  manifest : ${REQUEST_DIR}/request.json"
echo "  profile  : ${PROFILE_OUT}"
if [[ -n "${LOCKFILE_OUT}" ]]; then
    echo "  lockfile : ${LOCKFILE_OUT}"
fi
