#!/usr/bin/env bash
# Stage 1: Gather a system profile via Cluster Inspector.
# Writes the profile to profiles/<hostname>-<timestamp>.yaml and exports PROFILE_FILE.
#
# Environment:
#   REPO_ROOT   — path to the cse-stack repository root (set by deploy.sh)
#   DRY_RUN     — if "1", print what would happen and exit 0 without writing files
#   MOCK_PROFILE — if set, use this file as the profile instead of running Cluster Inspector
set -euo pipefail

: "${REPO_ROOT:?stage1_profile.sh must be run via deploy.sh (REPO_ROOT not set)}"

PROFILES_DIR="${REPO_ROOT}/profiles"
HOSTNAME_SLUG=$(hostname -s 2>/dev/null || echo "unknown")
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PROFILE_OUT="${PROFILES_DIR}/${HOSTNAME_SLUG}-${TIMESTAMP}.yaml"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] Stage 1: would run: clusterinspector profile --local --format yaml --include-modules"
    echo "[dry-run]           output  : ${PROFILE_OUT}"
    if [[ -n "${MOCK_PROFILE:-}" ]]; then
        echo "[dry-run]           using mock profile: ${MOCK_PROFILE}"
        export PROFILE_FILE="${MOCK_PROFILE}"
    else
        # In dry-run without a mock, use an empty stub so later stages can still render
        export PROFILE_FILE=""
    fi
    return 0 2>/dev/null || exit 0
fi

# Use a mock profile if one was provided (useful for Variant B testing on non-Cray hosts)
if [[ -n "${MOCK_PROFILE:-}" ]]; then
    echo "Stage 1: using mock profile: ${MOCK_PROFILE}"
    export PROFILE_FILE="${MOCK_PROFILE}"
    return 0 2>/dev/null || exit 0
fi

# Check that Cluster Inspector is available
if ! command -v clusterinspector &>/dev/null; then
    echo "ERROR: 'clusterinspector' is not on PATH." >&2
    echo "       Install it with: pip install -e /path/to/clusterinspector" >&2
    echo "       Or set MOCK_PROFILE to a pre-captured profile YAML to skip this stage." >&2
    exit 1
fi

mkdir -p "${PROFILES_DIR}"

echo "Stage 1: collecting system profile..."
clusterinspector profile --local --format yaml --include-modules \
    > "${PROFILE_OUT}"

echo "Stage 1: profile written to ${PROFILE_OUT}"
export PROFILE_FILE="${PROFILE_OUT}"
