#!/usr/bin/env bash
# Stage 4: Render remaining templates and run spack concretize + install.
#
# Environment:
#   SHARED_PATH, CSE_RELEASE, CSE_VARIANT  — set by deploy.sh / activate.sh
#   PROFILE_FILE                           — path to Cluster Inspector YAML (Stage 1 output)
#   SPACK_ROOT                             — set by Stage 2
#   DRY_RUN                                — "1" for dry-run
set -euo pipefail

: "${SHARED_PATH:?}"
: "${CSE_RELEASE:?}"
: "${CSE_VARIANT:?}"
: "${REPO_ROOT:?stage4_build.sh must be run via deploy.sh}"

VARIANT_ENV_DIR="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}/env"

_render() {
    local tpl="$1" out="$2"
    local args=(
        --template  "${REPO_ROOT}/templates/${tpl}"
        --variant   "${CSE_VARIANT}"
        --shared-path "${SHARED_PATH}"
        --release   "${CSE_RELEASE}"
    )
    if [[ -n "${PROFILE_FILE:-}" && -f "${PROFILE_FILE}" ]]; then
        args+=(--profile "${PROFILE_FILE}")
    fi
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "[dry-run] Stage 4: rendering ${tpl} → ${out}"
        python3 "${REPO_ROOT}/scripts/lib/render.py" "${args[@]}" --dry-run
    else
        python3 "${REPO_ROOT}/scripts/lib/render.py" "${args[@]}" --output "${out}"
    fi
}

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] Stage 4: would render config.yaml, modules.yaml, spack.yaml"
    _render "config.yaml.j2"  "${VARIANT_ENV_DIR}/config.yaml"
    _render "modules.yaml.j2" "${VARIANT_ENV_DIR}/modules.yaml"
    _render "spack.yaml.j2"   "${VARIANT_ENV_DIR}/spack.yaml"
    echo "[dry-run] Stage 4: would run:"
    echo "[dry-run]   spack env activate -d ${VARIANT_ENV_DIR}"
    echo "[dry-run]   spack concretize --fresh"
    echo "[dry-run]   spack install --fail-fast"
    exit 0
fi

# Verify group ownership before writing anything
if [[ "$(stat -c '%G' "${SHARED_PATH}/cse" 2>/dev/null)" != "cse" ]]; then
    echo "ERROR: ${SHARED_PATH}/cse is not owned by group cse." >&2
    exit 1
fi

umask 002
mkdir -p "${VARIANT_ENV_DIR}"

echo "Stage 4: rendering config.yaml, modules.yaml, spack.yaml..."
_render "config.yaml.j2"  "${VARIANT_ENV_DIR}/config.yaml"
_render "modules.yaml.j2" "${VARIANT_ENV_DIR}/modules.yaml"
_render "spack.yaml.j2"   "${VARIANT_ENV_DIR}/spack.yaml"

# Activate Spack
if [[ -z "${SPACK_ROOT:-}" ]]; then
    if [[ "${CSE_VARIANT}" == "v1-minimal-externals" ]]; then
        SPACK_ROOT="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}/spack-bootstrap/spack"
    else
        SPACK_ROOT="${SHARED_PATH}/cse/spack-site"
    fi
fi
# shellcheck source=/dev/null
. "${SPACK_ROOT}/share/spack/setup-env.sh"

echo "Stage 4: activating Spack environment at ${VARIANT_ENV_DIR}..."
spack env activate -d "${VARIANT_ENV_DIR}"

echo "Stage 4: concretizing..."
spack concretize --fresh

echo "Stage 4: installing (this will take a while on first run)..."
spack install --fail-fast

echo "Stage 4: done."
