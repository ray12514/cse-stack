#!/usr/bin/env bash
# Stage 3: Render packages.yaml from the system profile captured in Stage 1.
#
# Environment:
#   SHARED_PATH, CSE_RELEASE, CSE_VARIANT  — set by deploy.sh / activate.sh
#   PROFILE_FILE                           — path to Cluster Inspector YAML (Stage 1 output)
#   DRY_RUN                                — "1" for dry-run
set -euo pipefail

: "${SHARED_PATH:?}"
: "${CSE_RELEASE:?}"
: "${CSE_VARIANT:?}"
: "${REPO_ROOT:?stage3_externals.sh must be run via deploy.sh}"

VARIANT_ENV_DIR="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}/env"
TEMPLATE="${REPO_ROOT}/templates/packages.yaml.j2"
OUTPUT="${VARIANT_ENV_DIR}/packages.yaml"

RENDER_ARGS=(
    --template  "${TEMPLATE}"
    --variant   "${CSE_VARIANT}"
    --shared-path "${SHARED_PATH}"
    --release   "${CSE_RELEASE}"
)
if [[ -n "${PROFILE_FILE:-}" && -f "${PROFILE_FILE}" ]]; then
    RENDER_ARGS+=(--profile "${PROFILE_FILE}")
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] Stage 3: rendering packages.yaml.j2 → ${OUTPUT}"
    python3 "${REPO_ROOT}/scripts/lib/render.py" "${RENDER_ARGS[@]}" --dry-run
else
    umask 002
    mkdir -p "${VARIANT_ENV_DIR}"
    echo "Stage 3: rendering packages.yaml..."
    python3 "${REPO_ROOT}/scripts/lib/render.py" "${RENDER_ARGS[@]}" --output "${OUTPUT}"
    echo "Stage 3: packages.yaml written to ${OUTPUT}"
fi
