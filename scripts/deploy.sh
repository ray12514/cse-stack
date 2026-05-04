#!/usr/bin/env bash
# deploy.sh — CSE deploy orchestrator.
#
# Runs Stage 1–5 in order.  Each stage script is independently runnable;
# this script just composes them and manages shared environment variables.
#
# Usage:
#   ./scripts/deploy.sh --variant {v1-minimal-externals|v2-cray-integrated} \
#                       --release <tag>       \
#                       --shared-path <path>  \
#                       [--dry-run]           \
#                       [--from-stage N]      \
#                       [--gcc-version <ver>] \
#                       [--group <name>]      \
#                       [--mirror-path <path>]\
#                       [--module-system {lmod|tcl}]
#
# Options:
#   --variant         Required. Which deployment variant to build.
#   --release         Required. Release tag (e.g. 2026_04).
#   --shared-path     Required. Path to the shared CSE filesystem root.
#   --dry-run         Print every command that would run; render template YAML;
#                     exit 0 without modifying any state.
#   --from-stage N    Skip stages 1 through N-1 (assumes their outputs exist).
#   --gcc-version     GCC version for Variant A (default: 13.2.0).
#                     Ignored for Variant B; that version comes from PrgEnv-gnu
#                     via Stage 1 (Cluster Inspector).
#   --group           Unix group that owns the shared install tree (default: installer's group).
#   --mirror-path     Path to a local Spack source mirror (file:// or directory path).
#                     Use scripts/mirror_fetch.sh on an internet-connected host to
#                     populate the mirror, then transfer it here.
#   --module-system   Override auto-detected module system (lmod or tcl).
#   --mock-profile    Path to a mock Cluster Inspector YAML profile.
#                     Useful for testing Variant B on a non-Cray host.
set -euo pipefail

# ------------------------------------------------------------------
# Locate the repository root regardless of where the script is called from
# ------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# ------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------
VARIANT=""
RELEASE=""
SHARED_PATH=""
DRY_RUN=0
FROM_STAGE=1
GCC_VERSION_OVERRIDE=""
CSE_GROUP_OVERRIDE=""
MIRROR_PATH=""
MODULE_SYSTEM_OVERRIDE=""
MOCK_PROFILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant)        VARIANT="$2";                shift 2 ;;
        --release)        RELEASE="$2";                shift 2 ;;
        --shared-path)    SHARED_PATH="$2";            shift 2 ;;
        --dry-run)        DRY_RUN=1;                   shift   ;;
        --from-stage)     FROM_STAGE="$2";             shift 2 ;;
        --gcc-version)    GCC_VERSION_OVERRIDE="$2";   shift 2 ;;
        --group)          CSE_GROUP_OVERRIDE="$2";     shift 2 ;;
        --mirror-path)    MIRROR_PATH="$2";            shift 2 ;;
        --module-system)  MODULE_SYSTEM_OVERRIDE="$2"; shift 2 ;;
        --mock-profile)   MOCK_PROFILE="$2";           shift 2 ;;
        -h|--help)
            sed -n '3,30p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "deploy.sh: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------
# Validate required arguments
# ------------------------------------------------------------------
errors=0
if [[ -z "${VARIANT}" ]]; then
    echo "ERROR: --variant is required (v1-minimal-externals | v2-cray-integrated)" >&2
    errors=1
fi
if [[ -z "${RELEASE}" ]]; then
    echo "ERROR: --release is required (e.g. 2026_04)" >&2
    errors=1
fi
if [[ -z "${SHARED_PATH}" ]]; then
    echo "ERROR: --shared-path is required" >&2
    errors=1
fi
if [[ "${VARIANT}" != "v1-minimal-externals" && "${VARIANT}" != "v2-cray-integrated" ]]; then
    echo "ERROR: --variant must be v1-minimal-externals or v2-cray-integrated" >&2
    errors=1
fi
if [[ "${FROM_STAGE}" -lt 1 || "${FROM_STAGE}" -gt 5 ]]; then
    echo "ERROR: --from-stage must be between 1 and 5" >&2
    errors=1
fi
if [[ ${errors} -gt 0 ]]; then
    exit 1
fi

# ------------------------------------------------------------------
# Export environment for stage scripts
# ------------------------------------------------------------------
export SHARED_PATH
export CSE_RELEASE="${RELEASE}"
export CSE_RELEASE_DEFAULT="${RELEASE}"
export CSE_SHARED_PATH="${SHARED_PATH}"
export CSE_VARIANT="${VARIANT}"
export DRY_RUN
export MOCK_PROFILE
# MIRROR_PATH: if set, stage 4 writes mirrors.yaml so Spack fetches from here
# instead of the internet.  Accepts a filesystem path or file:// / http:// URL.
export MIRROR_PATH
# GCC_VERSION is used by stage2_spack.sh (bootstrap) and the render context.
# Variant B ignores this; it takes GCC from PrgEnv-gnu via Cluster Inspector.
export GCC_VERSION="${GCC_VERSION_OVERRIDE:-${GCC_VERSION:-13.2.0}}"
# CSE_GROUP is the Unix group owning the shared install tree.
# Defaults to the installer's own primary group so personal builds work out of
# the box.  Pass --group <name> to target a shared system group (e.g. cse).
export CSE_GROUP="${CSE_GROUP_OVERRIDE:-${CSE_GROUP:-$(id -gn)}}"
# Prevent Spack from merging the installer's personal ~/.spack/ config into
# the environment.  Without this, stale user-scope packages.yaml entries
# (wrong compiler constraints, old versions, etc.) silently override the
# environment's authoritative packages.yaml.
export SPACK_DISABLE_LOCAL_CONFIG=1

# ------------------------------------------------------------------
# Auto-detect module system (or use override)
# ------------------------------------------------------------------
if [[ -n "${MODULE_SYSTEM_OVERRIDE}" ]]; then
    MODULE_SYSTEM="${MODULE_SYSTEM_OVERRIDE}"
else
    if command -v lmod &>/dev/null || command -v modulecmd &>/dev/null \
       || [[ -n "${LMOD_CMD:-}" ]]; then
        MODULE_SYSTEM="lmod"
    elif command -v modulecmd.tcl &>/dev/null \
         || [[ -f /usr/share/modules/init/bash ]]; then
        MODULE_SYSTEM="tcl"
    else
        MODULE_SYSTEM="lmod"    # assume Lmod; override with --module-system if needed
    fi
fi
export MODULE_SYSTEM

# ------------------------------------------------------------------
# Header
# ------------------------------------------------------------------
echo "========================================================"
echo " CSE Deploy"
echo "  variant      : ${VARIANT}"
echo "  release      : ${RELEASE}"
echo "  shared-path  : ${SHARED_PATH}"
echo "  group        : ${CSE_GROUP}"
if [[ "${VARIANT}" == "v1-minimal-externals" ]]; then
    echo "  gcc version  : ${GCC_VERSION}"
fi
echo "  module system: ${MODULE_SYSTEM}"
if [[ -n "${MIRROR_PATH}" ]]; then
    echo "  mirror       : ${MIRROR_PATH}"
fi
if [[ ${DRY_RUN} == 1 ]]; then
    echo "  mode         : DRY-RUN (no changes will be made)"
fi
echo "========================================================"
echo ""

# ------------------------------------------------------------------
# Stage runner
# ------------------------------------------------------------------
run_stage() {
    local n="$1" script="$2"
    if [[ "${FROM_STAGE}" -gt "${n}" ]]; then
        echo "--- Stage ${n}: skipped (--from-stage ${FROM_STAGE})"
        return 0
    fi
    echo "--- Stage ${n}: ${script}"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/${script}"
    echo ""
}

run_stage 1 stage1_profile.sh
run_stage 2 stage2_spack.sh
run_stage 3 stage3_externals.sh
run_stage 4 stage4_build.sh
run_stage 5 stage5_modules.sh

echo "========================================================"
if [[ ${DRY_RUN} == 1 ]]; then
    echo " Dry-run complete.  No changes were made."
else
    echo " Deploy complete."
    echo " Users can now load the CSE environment with:"
    if [[ "${VARIANT}" == "v1-minimal-externals" ]]; then
        echo "   module load cse-init/openmpi"
    else
        echo "   module load PrgEnv-gnu"
        echo "   module load cse-init/cray-mpich"
    fi
    echo "   module avail cse"
fi
echo "========================================================"
