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
export SPACK_DISABLE_LOCAL_CONFIG=1
export SPACK_USER_CACHE_PATH="${SHARED_PATH}/cse/cache/spack"
export SPACK_SYSTEM_CONFIG_PATH="/dev/null"

render_stage5_template() {
    local tpl="$1" out="$2"
    local args=(
        --template "${REPO_ROOT}/templates/${tpl}"
        --output "${out}"
        --variant "${CSE_VARIANT}"
        --shared-path "${SHARED_PATH}"
        --release "${CSE_RELEASE}"
    )
    if [[ -n "${PROFILE_FILE:-}" && -f "${PROFILE_FILE}" ]]; then
        args+=(--profile "${PROFILE_FILE}")
    fi
    python3 "${REPO_ROOT}/scripts/lib/render.py" "${args[@]}"
}

detect_generated_module_root() {
    local base="$1"
    local module_file=""
    local cse_dir=""

    module_file="$(find "${base}" -type f -path "*/cse/*/*" 2>/dev/null | sort | head -1 || true)"
    if [[ -n "${module_file}" ]]; then
        cse_dir="${module_file%/cse/*}"
        printf '%s\n' "${cse_dir}"
        return 0
    fi

    # Fall back to namespace directories for module systems that create marker
    # files or unusual file depths.
    cse_dir="$(find "${base}" -type d -name cse 2>/dev/null | sort | head -1 || true)"
    if [[ -n "${cse_dir}" ]]; then
        dirname "${cse_dir}"
        return 0
    fi

    return 1
}

# Determine which cse-init file to install
if [[ "${CSE_VARIANT}" == "v1-openmpi" ]]; then
    INIT_NAME="openmpi"
else
    INIT_NAME="mpich"
fi

if [[ "${MODULE_SYSTEM}" == "lmod" ]]; then
    INIT_TEMPLATE="${REPO_ROOT}/templates/cse-init.lua.j2"
    INIT_DST="${SITE_MODULE_PATH}/cse-init/${INIT_NAME}.lua"
    SPACK_MODULE_CMD="lmod"
else
    INIT_TEMPLATE="${REPO_ROOT}/templates/cse-init.tcl.j2"
    INIT_DST="${SITE_MODULE_PATH}/cse-init/${INIT_NAME}"
    SPACK_MODULE_CMD="tcl"
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] Stage 5: would run:"
    echo "[dry-run]   render modules.yaml and spack.yaml"
    echo "[dry-run]   spack env activate -d ${VARIANT_ENV_DIR}"
    echo "[dry-run]   spack env view regenerate"
    echo "[dry-run]   spack module ${SPACK_MODULE_CMD} refresh --delete-tree -y"
    echo "[dry-run]   mkdir -p $(dirname "${INIT_DST}")"
    echo "[dry-run]   python3 ${REPO_ROOT}/scripts/lib/render.py --template ${INIT_TEMPLATE} --output ${INIT_DST} --variant ${CSE_VARIANT} --shared-path ${SHARED_PATH} --release ${CSE_RELEASE}"
    exit 0
fi

if [[ -z "${SPACK_ROOT:-}" ]]; then
    SPACK_ROOT="${SHARED_PATH}/cse/spack-site"
fi
# shellcheck source=/dev/null
. "${SPACK_ROOT}/share/spack/setup-env.sh"

echo "Stage 5: refreshing module and view configuration..."
render_stage5_template "modules.yaml.j2" "${VARIANT_ENV_DIR}/modules.yaml"
render_stage5_template "spack.yaml.j2" "${VARIANT_ENV_DIR}/spack.yaml"

echo "Stage 5: activating environment and refreshing modulefiles..."
spack env activate -d "${VARIANT_ENV_DIR}"
spack env view regenerate
spack module "${SPACK_MODULE_CMD}" refresh --delete-tree -y

MODULE_ROOT_BASE="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}/modules"
if ! CSE_INIT_MODULE_ROOT="$(detect_generated_module_root "${MODULE_ROOT_BASE}")"; then
    echo "ERROR: could not find generated cse module namespace under ${MODULE_ROOT_BASE}" >&2
    exit 1
fi
export CSE_INIT_MODULE_ROOT
echo "Stage 5: detected generated module root ${CSE_INIT_MODULE_ROOT}"

echo "Stage 5: rendering cse-init/${INIT_NAME} to ${INIT_DST}..."
umask 022
mkdir -p "$(dirname "${INIT_DST}")"
rm -f "${SITE_MODULE_PATH}/cse-init/${INIT_NAME}" \
      "${SITE_MODULE_PATH}/cse-init/${INIT_NAME}.tcl" \
      "${SITE_MODULE_PATH}/cse-init/${INIT_NAME}.lua"
python3 "${REPO_ROOT}/scripts/lib/render.py" \
    --template "${INIT_TEMPLATE}" \
    --output "${INIT_DST}" \
    --variant "${CSE_VARIANT}" \
    --shared-path "${SHARED_PATH}" \
    --release "${CSE_RELEASE}"
chgrp "${CSE_GROUP:-$(id -gn)}" "${INIT_DST}" 2>/dev/null || true

echo "Stage 5: done."
echo ""
echo "Users can now load the CSE environment with:"
echo "  module use ${SITE_MODULE_PATH}"
if [[ "${CSE_VARIANT}" == "v1-openmpi" ]]; then
    echo "  module load cse-init/openmpi"
else
    echo "  module load cse-init/mpich"
fi
echo "  module avail cse"
