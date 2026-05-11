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
VARIANT_DIR="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}"
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

render_stage5_list() {
    local list_name="$1"
    local args=(
        --list "${list_name}"
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

module_file_exists() {
    local module_name="$1"
    [[ -f "${CSE_INIT_MODULE_ROOT}/${module_name}" ]] \
        || [[ -f "${CSE_INIT_MODULE_ROOT}/${module_name}.lua" ]] \
        || [[ -f "${CSE_INIT_MODULE_ROOT}/${module_name}.tcl" ]]
}

collect_generated_modules() {
    local cse_dir="${CSE_INIT_MODULE_ROOT}/cse"
    local path rel

    [[ -d "${cse_dir}" ]] || return 0
    find "${cse_dir}" -type f 2>/dev/null | while IFS= read -r path; do
        rel="${path#${CSE_INIT_MODULE_ROOT}/}"
        case "${rel}" in
            *.modulerc|*.modulerc.lua|*.version|*.version.lua)
                continue
                ;;
        esac
        rel="${rel%.lua}"
        rel="${rel%.tcl}"
        printf '%s\n' "${rel}"
    done | sort -u
}

validate_generated_modules() {
    local expected_file="" actual_file="" curated_file=""
    local module_name="" missing="" unexpected=""

    expected_file="$(mktemp)"
    actual_file="$(mktemp)"
    curated_file="$(mktemp)"

    render_stage5_list public-modules | sort -u > "${expected_file}"
    render_stage5_list curated-loads | sort -u > "${curated_file}"
    collect_generated_modules > "${actual_file}"

    while IFS= read -r module_name; do
        [[ -n "${module_name}" ]] || continue
        if ! module_file_exists "${module_name}"; then
            missing="${missing}${module_name}"$'\n'
        fi
    done < "${expected_file}"

    while IFS= read -r module_name; do
        [[ -n "${module_name}" ]] || continue
        if ! module_file_exists "${module_name}"; then
            missing="${missing}${module_name}"$'\n'
        fi
    done < "${curated_file}"

    unexpected="$(comm -13 "${expected_file}" "${actual_file}" || true)"

    if [[ -n "${missing}" ]]; then
        echo "ERROR: generated module tree does not match the public CSE catalog." >&2
        echo "Missing expected/curated module targets:" >&2
        printf '%s' "${missing}" >&2
        echo "Module root checked: ${CSE_INIT_MODULE_ROOT}" >&2
        exit 1
    fi

    if [[ -n "${unexpected}" ]]; then
        echo "WARNING: generated module tree contains modules outside the public CSE catalog." >&2
        echo "         They may be Spack-generated dependency modules; cse-init still exposes the curated namespace." >&2
        echo "Unexpected generated modules:" >&2
        printf '%s\n' "${unexpected}" >&2
        echo "Module root checked: ${CSE_INIT_MODULE_ROOT}" >&2
    fi

    rm -f "${expected_file}" "${actual_file}" "${curated_file}"
    echo "Stage 5: validated public module catalog under ${CSE_INIT_MODULE_ROOT}"
}

publish_compiler_view_from_bootstrap() {
    local bootstrap_yaml="${VARIANT_DIR}/gcc-bootstrap.yaml"
    local gcc_prefix="" gcc_version="" clean_root="" clean_prefix=""

    if [[ ! -f "${bootstrap_yaml}" ]]; then
        echo "ERROR: missing ${bootstrap_yaml}; Stage 2 must publish the compiler baseline first." >&2
        exit 1
    fi

    gcc_prefix="$(awk '/^[[:space:]]*prefix:/ {print $2; exit}' "${bootstrap_yaml}")"
    gcc_version="$(sed -n -E 's/^[[:space:]]*-[[:space:]]*spec:[[:space:]]*gcc@([^[:space:]]+).*/\1/p' "${bootstrap_yaml}" | head -1)"
    if [[ -z "${gcc_prefix}" || -z "${gcc_version}" ]]; then
        echo "ERROR: could not read GCC prefix/version from ${bootstrap_yaml}" >&2
        exit 1
    fi

    clean_root="${VARIANT_DIR}/views/compiler/gcc"
    clean_prefix="${clean_root}/${gcc_version}"
    mkdir -p "${clean_root}"
    if [[ -e "${clean_prefix}" && ! -L "${clean_prefix}" ]]; then
        echo "ERROR: compiler view path exists and is not a symlink: ${clean_prefix}" >&2
        exit 1
    fi
    ln -sfn "${gcc_prefix}" "${clean_prefix}"
    chgrp -h "${CSE_GROUP:-$(id -gn)}" "${clean_prefix}" 2>/dev/null || true
    echo "Stage 5: compiler view ${clean_prefix} -> ${gcc_prefix}"
}

reset_spack_views() {
    local views_root="${VARIANT_DIR}/views"
    local view_path=""

    for view_path in \
        "${views_root}/modules" "${views_root}/._modules" \
        "${views_root}/mpi" "${views_root}/._mpi" \
        "${views_root}/serial" "${views_root}/._serial"; do
        case "${view_path}" in
            "${VARIANT_DIR}/views/"*) ;;
            *)
                echo "ERROR: refusing to remove unexpected view path: ${view_path}" >&2
                exit 1
                ;;
        esac
        if [[ -e "${view_path}" || -L "${view_path}" ]]; then
            echo "Stage 5: removing stale Spack view ${view_path}"
            rm -rf "${view_path}"
        fi
    done
}

# Determine which cse-init file to install
if [[ "${CSE_VARIANT}" == "v1-openmpi" ]]; then
    INIT_NAME="openmpi"
else
    INIT_NAME="mpich"
fi

if [[ "${MODULE_SYSTEM}" == "lmod" ]]; then
    INIT_TEMPLATE="${REPO_ROOT}/templates/cse-init.lua.j2"
    INIT_CURRENT_DST="${SITE_MODULE_PATH}/cse-init/${INIT_NAME}.lua"
    INIT_VERSIONED_DST="${SITE_MODULE_PATH}/cse-init/${CSE_RELEASE}/${INIT_NAME}.lua"
    SPACK_MODULE_CMD="lmod"
else
    INIT_TEMPLATE="${REPO_ROOT}/templates/cse-init.tcl.j2"
    INIT_CURRENT_DST="${SITE_MODULE_PATH}/cse-init/${INIT_NAME}"
    INIT_VERSIONED_DST="${SITE_MODULE_PATH}/cse-init/${CSE_RELEASE}/${INIT_NAME}"
    SPACK_MODULE_CMD="tcl"
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] Stage 5: would run:"
    echo "[dry-run]   render modules.yaml and spack.yaml"
    echo "[dry-run]   refresh compiler view from ${VARIANT_DIR}/gcc-bootstrap.yaml"
    echo "[dry-run]   spack env activate -d ${VARIANT_ENV_DIR}"
    echo "[dry-run]   remove stale Spack views under ${VARIANT_DIR}/views/{modules,mpi,serial}"
    echo "[dry-run]   spack env view regenerate"
    echo "[dry-run]   spack module ${SPACK_MODULE_CMD} refresh --delete-tree -y"
    echo "[dry-run]   validate public module catalog and curated load targets"
    echo "[dry-run]   mkdir -p $(dirname "${INIT_CURRENT_DST}")"
    echo "[dry-run]   mkdir -p $(dirname "${INIT_VERSIONED_DST}")"
    echo "[dry-run]   python3 ${REPO_ROOT}/scripts/lib/render.py --template ${INIT_TEMPLATE} --output ${INIT_CURRENT_DST} --variant ${CSE_VARIANT} --shared-path ${SHARED_PATH} --release ${CSE_RELEASE}"
    echo "[dry-run]   python3 ${REPO_ROOT}/scripts/lib/render.py --template ${INIT_TEMPLATE} --output ${INIT_VERSIONED_DST} --variant ${CSE_VARIANT} --shared-path ${SHARED_PATH} --release ${CSE_RELEASE}"
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
publish_compiler_view_from_bootstrap

echo "Stage 5: activating environment and refreshing modulefiles..."
spack env activate -d "${VARIANT_ENV_DIR}"
reset_spack_views
spack env view regenerate
spack module "${SPACK_MODULE_CMD}" refresh --delete-tree -y

MODULE_ROOT_BASE="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}/modules"
if ! CSE_INIT_MODULE_ROOT="$(detect_generated_module_root "${MODULE_ROOT_BASE}")"; then
    echo "ERROR: could not find generated cse module namespace under ${MODULE_ROOT_BASE}" >&2
    exit 1
fi
export CSE_INIT_MODULE_ROOT
echo "Stage 5: detected generated module root ${CSE_INIT_MODULE_ROOT}"
validate_generated_modules

echo "Stage 5: rendering cse-init/${INIT_NAME} to ${INIT_CURRENT_DST}..."
echo "Stage 5: rendering cse-init/${CSE_RELEASE}/${INIT_NAME} to ${INIT_VERSIONED_DST}..."
umask 022
mkdir -p "$(dirname "${INIT_CURRENT_DST}")"
mkdir -p "$(dirname "${INIT_VERSIONED_DST}")"
rm -f "${SITE_MODULE_PATH}/cse-init/${INIT_NAME}" \
      "${SITE_MODULE_PATH}/cse-init/${INIT_NAME}.tcl" \
      "${SITE_MODULE_PATH}/cse-init/${INIT_NAME}.lua"
rm -f "${SITE_MODULE_PATH}/cse-init/${CSE_RELEASE}/${INIT_NAME}" \
      "${SITE_MODULE_PATH}/cse-init/${CSE_RELEASE}/${INIT_NAME}.tcl" \
      "${SITE_MODULE_PATH}/cse-init/${CSE_RELEASE}/${INIT_NAME}.lua"
for init_dst in "${INIT_CURRENT_DST}" "${INIT_VERSIONED_DST}"; do
    python3 "${REPO_ROOT}/scripts/lib/render.py" \
        --template "${INIT_TEMPLATE}" \
        --output "${init_dst}" \
        --variant "${CSE_VARIANT}" \
        --shared-path "${SHARED_PATH}" \
        --release "${CSE_RELEASE}"
    chgrp "${CSE_GROUP:-$(id -gn)}" "${init_dst}" 2>/dev/null || true
done

echo "Stage 5: done."
echo ""
echo "Users can now load the CSE environment with:"
echo "  module use ${SITE_MODULE_PATH}"
if [[ "${CSE_VARIANT}" == "v1-openmpi" ]]; then
    echo "  module load cse-init/openmpi"
    echo "  module load cse-init/${CSE_RELEASE}/openmpi"
else
    echo "  module load cse-init/mpich"
    echo "  module load cse-init/${CSE_RELEASE}/mpich"
fi
echo "  module avail cse"
