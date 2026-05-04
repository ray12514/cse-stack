#!/usr/bin/env bash
# mirror_fetch.sh — Create a Spack source mirror on an internet-connected host.
#
# Run this AFTER stage 4 has concretized the environment (the lockfile must
# exist at <env-dir>/spack.lock).  All source tarballs for the concretized
# spec closure are downloaded into MIRROR_PATH.
#
# Usage:
#   ./scripts/mirror_fetch.sh \
#       --mirror-path /path/to/mirror \
#       --variant v1-minimal-externals \
#       --release 2026_04              \
#       --shared-path /workdir/cse
#
# Transfer to the restricted system:
#   rsync -av --progress /path/to/mirror user@target:/path/to/mirror
#   # or
#   scp -r /path/to/mirror user@target:/path/to/mirror
#
# Then deploy on the restricted system with:
#   ./scripts/deploy.sh ... --mirror-path /path/to/mirror
#
# Environment:
#   SPACK_ROOT   — override Spack location (normally inferred from variant)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MIRROR_PATH=""
VARIANT=""
RELEASE=""
SHARED_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mirror-path)  MIRROR_PATH="$2";  shift 2 ;;
        --variant)      VARIANT="$2";      shift 2 ;;
        --release)      RELEASE="$2";      shift 2 ;;
        --shared-path)  SHARED_PATH="$2";  shift 2 ;;
        *) echo "mirror_fetch.sh: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${MIRROR_PATH}" || -z "${VARIANT}" || -z "${RELEASE}" || -z "${SHARED_PATH}" ]]; then
    echo "Usage: mirror_fetch.sh --mirror-path <dir> --variant <v> --release <r> --shared-path <p>" >&2
    exit 1
fi

VARIANT_ENV_DIR="${SHARED_PATH}/cse/${RELEASE}/${VARIANT}/env"

if [[ ! -f "${VARIANT_ENV_DIR}/spack.lock" ]]; then
    echo "ERROR: ${VARIANT_ENV_DIR}/spack.lock not found." >&2
    echo "       Run stage 4 (spack concretize) on this machine first." >&2
    exit 1
fi

# Locate Spack — both variants use the bootstrap spack instance
if [[ -z "${SPACK_ROOT:-}" ]]; then
    SPACK_ROOT="${SHARED_PATH}/cse/${RELEASE}/${VARIANT}/spack-bootstrap/spack"
fi

if [[ ! -f "${SPACK_ROOT}/share/spack/setup-env.sh" ]]; then
    echo "ERROR: Spack not found at ${SPACK_ROOT}." >&2
    echo "       Run stage 2 first, or set SPACK_ROOT." >&2
    exit 1
fi

export SPACK_DISABLE_LOCAL_CONFIG=1
# shellcheck source=/dev/null
. "${SPACK_ROOT}/share/spack/setup-env.sh"

mkdir -p "${MIRROR_PATH}"

echo "mirror_fetch: activating environment at ${VARIANT_ENV_DIR}..."
spack env activate -d "${VARIANT_ENV_DIR}"

echo "mirror_fetch: fetching sources into ${MIRROR_PATH}..."
echo "             (this downloads every tarball in the concretized closure)"
spack mirror create -d "${MIRROR_PATH}" --all

echo ""
echo "mirror_fetch: done."
echo ""
echo "Transfer to the restricted system with one of:"
echo "  rsync -av --progress ${MIRROR_PATH} user@target:${MIRROR_PATH}"
echo "  scp -r ${MIRROR_PATH} user@target:${MIRROR_PATH}"
echo ""
echo "Then deploy on the restricted system:"
echo "  ./scripts/deploy.sh --variant ${VARIANT} --release ${RELEASE} \\"
echo "      --shared-path ${SHARED_PATH} --mirror-path ${MIRROR_PATH} \\"
echo "      [--buildcache-uri file:///path/to/cache] ..."
