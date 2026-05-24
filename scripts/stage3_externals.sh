#!/usr/bin/env bash
# Stage 3: Render packages.yaml and toolchains.yaml from the system profile
# captured in Stage 1.
#
# Environment:
#   SHARED_PATH, CSE_RELEASE, CSE_VARIANT  — set by deploy.sh / activate.sh
#   PROFILE_FILE                           — path to Cluster Inspector YAML (Stage 1 output)
#   DRY_RUN                                — "1" for dry-run
set -euo pipefail
export SPACK_DISABLE_LOCAL_CONFIG=1
export SPACK_USER_CACHE_PATH="${SHARED_PATH:-/tmp}/cse/cache/bootstrap"
export SPACK_SYSTEM_CONFIG_PATH="/dev/null"
export SPACK_USER_CONFIG_PATH="/dev/null"

: "${SHARED_PATH:?}"
: "${CSE_RELEASE:?}"
: "${CSE_VARIANT:?}"
: "${REPO_ROOT:?stage3_externals.sh must be run via deploy.sh}"

VARIANT_ENV_DIR="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}/env"

BASE_RENDER_ARGS=(
    --variant   "${CSE_VARIANT}"
    --shared-path "${SHARED_PATH}"
    --release   "${CSE_RELEASE}"
)
if [[ -n "${PROFILE_FILE:-}" && -f "${PROFILE_FILE}" ]]; then
    BASE_RENDER_ARGS+=(--profile "${PROFILE_FILE}")
fi

_render() {
    local tpl="$1" out="$2"
    python3 "${REPO_ROOT}/scripts/lib/render.py" "${BASE_RENDER_ARGS[@]}" \
        --template "${tpl}" --output "${out}"
}

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] Stage 3: rendering packages.yaml.j2 → ${VARIANT_ENV_DIR}/packages.yaml"
    python3 "${REPO_ROOT}/scripts/lib/render.py" "${BASE_RENDER_ARGS[@]}" \
        --template "${REPO_ROOT}/templates/packages.yaml.j2" --dry-run
    echo "[dry-run] Stage 3: rendering toolchains.yaml.j2 → ${VARIANT_ENV_DIR}/toolchains.yaml"
    python3 "${REPO_ROOT}/scripts/lib/render.py" "${BASE_RENDER_ARGS[@]}" \
        --template "${REPO_ROOT}/templates/toolchains.yaml.j2" --dry-run
else
    umask 002
    mkdir -p "${VARIANT_ENV_DIR}"
    echo "Stage 3: rendering packages.yaml..."
    _render "${REPO_ROOT}/templates/packages.yaml.j2" "${VARIANT_ENV_DIR}/packages.yaml"
    echo "Stage 3: packages.yaml written to ${VARIANT_ENV_DIR}/packages.yaml"
    echo "Stage 3: rendering toolchains.yaml..."
    _render "${REPO_ROOT}/templates/toolchains.yaml.j2" "${VARIANT_ENV_DIR}/toolchains.yaml"
    echo "Stage 3: toolchains.yaml written to ${VARIANT_ENV_DIR}/toolchains.yaml"
fi
