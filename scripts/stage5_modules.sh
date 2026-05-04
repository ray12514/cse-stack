#!/usr/bin/env bash
# Stage 5: Refresh Spack modulefiles and install the cse-init activation module.
#
# Environment:
#   SHARED_PATH, CSE_RELEASE, CSE_VARIANT  — set by deploy.sh / activate.sh
#   SPACK_ROOT                             — set by Stage 2
#   MODULE_SYSTEM                          — "lmod" or "tcl" (set by deploy.sh)
#   SITE_MODULE_PATH                       — where to install cse-init modules;
#                                            defaults to ${SHARED_PATH}/cse/modulefiles
#   DRY_RUN                                — "1" for dry-run
set -euo pipefail

: "${SHARED_PATH:?}"
: "${CSE_RELEASE:?}"
: "${CSE_VARIANT:?}"
: "${REPO_ROOT:?stage5_modules.sh must be run via deploy.sh}"
: "${MODULE_SYSTEM:?}"    # lmod or tcl

VARIANT_ENV_DIR="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}/env"
SITE_MODULE_PATH="${SITE_MODULE_PATH:-${SHARED_PATH}/cse/modulefiles}"

# Determine which cse-init file to install
if [[ "${CSE_VARIANT}" == "v1-minimal-externals" ]]; then
    INIT_NAME="openmpi"
else
    INIT_NAME="cray-mpich"
fi

if [[ "${MODULE_SYSTEM}" == "lmod" ]]; then
    INIT_SRC="${REPO_ROOT}/modules/cse-init/${INIT_NAME}.lua"
    INIT_DST="${SITE_MODULE_PATH}/cse-init/${INIT_NAME}.lua"
    SPACK_MODULE_CMD="lmod"
else
    INIT_SRC="${REPO_ROOT}/modules/cse-init/${INIT_NAME}.tcl"
    INIT_DST="${SITE_MODULE_PATH}/cse-init/${INIT_NAME}.tcl"
    SPACK_MODULE_CMD="tcl"
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] Stage 5: would run:"
    echo "[dry-run]   spack env activate -d ${VARIANT_ENV_DIR}"
    echo "[dry-run]   spack module ${SPACK_MODULE_CMD} refresh --delete-tree -y"
    echo "[dry-run]   mkdir -p $(dirname "${INIT_DST}")"
    echo "[dry-run]   cp ${INIT_SRC} ${INIT_DST}"
    exit 0
fi

if [[ -z "${SPACK_ROOT:-}" ]]; then
    if [[ "${CSE_VARIANT}" == "v1-minimal-externals" ]]; then
        SPACK_ROOT="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}/spack-bootstrap/spack"
    else
        SPACK_ROOT="${SHARED_PATH}/cse/spack-site"
    fi
fi
# shellcheck source=/dev/null
. "${SPACK_ROOT}/share/spack/setup-env.sh"

echo "Stage 5: activating environment and refreshing modulefiles..."
spack env activate -d "${VARIANT_ENV_DIR}"
spack module "${SPACK_MODULE_CMD}" refresh --delete-tree -y

echo "Stage 5: installing cse-init/${INIT_NAME} to ${INIT_DST}..."
umask 022
mkdir -p "$(dirname "${INIT_DST}")"
cp "${INIT_SRC}" "${INIT_DST}"
chgrp "${CSE_GROUP:-$(id -gn)}" "${INIT_DST}" 2>/dev/null || true

echo "Stage 5: done."
echo ""
echo "Users can now load the CSE environment with:"
if [[ "${CSE_VARIANT}" == "v1-minimal-externals" ]]; then
    echo "  module load cse-init/openmpi"
else
    echo "  module load PrgEnv-gnu"
    echo "  module load cse-init/cray-mpich"
fi
echo "  module avail cse"
