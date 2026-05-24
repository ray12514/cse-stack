#!/usr/bin/env bash
# spack_build.sh — Standalone Spack build driver for pre-rendered environments.
#
# Intended for "User B" who receives a pre-rendered env directory (packages.yaml,
# config.yaml, spack.yaml, etc.) from the operator and just needs to build.
# Does NOT require the cse-stack repository at runtime — only the env dir and
# a Spack installation.
#
# Usage:
#   ./scripts/spack_build.sh \
#       --env-dir   <path-to-rendered-env-dir>   \
#       --spack-root <path-to-spack-root>         \
#       [--jobs N]                                \
#       [--make-jobs N]                           \
#       [--cache-only]                            \
#       [--buildcache-uri <uri>]                  \
#       [--no-check-signature]                    \
#       [--dry-run]
#
# Options:
#   --env-dir         Required. Path to a rendered Spack environment directory
#                     (must contain spack.yaml; typically the env/ subdirectory
#                     of a CSE variant tree).
#   --spack-root      Required. Path to a Spack installation.
#   --jobs N          Parallel package installs (default: 4).
#   --make-jobs N     Threads per package build (default: 16).
#   --cache-only      Install only from binary build caches; fail on cache miss.
#   --buildcache-uri  URI of a binary build cache to pull from before building.
#   --no-check-signature  Skip GPG signature check on buildcache hits.
#   --dry-run         Print what would run; do not call spack install.
set -euo pipefail

ENV_DIR=""
SPACK_ROOT=""
INSTALL_JOBS="${SPACK_INSTALL_JOBS:-4}"
MAKE_JOBS="${SPACK_MAKE_JOBS:-16}"
CACHE_ONLY=0
BUILDCACHE_URI=""
NO_CHECK_SIG=0
DRY_RUN=0

require_arg_value() {
    local opt="$1" next="${2:-}"
    if [[ -z "${next}" || "${next}" == --* ]]; then
        echo "ERROR: ${opt} requires a value" >&2; exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-dir)          require_arg_value "$1" "${2:-}"; ENV_DIR="$2";       shift 2 ;;
        --spack-root)       require_arg_value "$1" "${2:-}"; SPACK_ROOT="$2";   shift 2 ;;
        --jobs)             require_arg_value "$1" "${2:-}"; INSTALL_JOBS="$2"; shift 2 ;;
        --make-jobs)        require_arg_value "$1" "${2:-}"; MAKE_JOBS="$2";    shift 2 ;;
        --cache-only)       CACHE_ONLY=1;                                        shift   ;;
        --buildcache-uri)   require_arg_value "$1" "${2:-}"; BUILDCACHE_URI="$2"; shift 2 ;;
        --no-check-signature) NO_CHECK_SIG=1;                                   shift   ;;
        --dry-run)          DRY_RUN=1;                                           shift   ;;
        -h|--help)
            sed -n '3,36p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "spack_build.sh: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${ENV_DIR}" ]]; then
    echo "ERROR: --env-dir is required" >&2; exit 1
fi
if [[ -z "${SPACK_ROOT}" ]]; then
    echo "ERROR: --spack-root is required" >&2; exit 1
fi
if [[ ! -f "${ENV_DIR}/spack.yaml" ]]; then
    echo "ERROR: ${ENV_DIR}/spack.yaml not found; --env-dir must point to a rendered environment" >&2
    exit 1
fi
if [[ ! -f "${SPACK_ROOT}/share/spack/setup-env.sh" ]]; then
    echo "ERROR: ${SPACK_ROOT}/share/spack/setup-env.sh not found; --spack-root must point to a Spack installation" >&2
    exit 1
fi

export SPACK_DISABLE_LOCAL_CONFIG=1
export SPACK_USER_CACHE_PATH="${SPACK_USER_CACHE_PATH:-${ENV_DIR}/../cache}"
export SPACK_SYSTEM_CONFIG_PATH="/dev/null"
export SPACK_USER_CONFIG_PATH="/dev/null"

if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[dry-run] spack_build.sh would run:"
    echo "[dry-run]   source ${SPACK_ROOT}/share/spack/setup-env.sh"
    echo "[dry-run]   spack env activate -d ${ENV_DIR}"
    _INSTALL="spack install${CACHE_ONLY:+ --cache-only}${NO_CHECK_SIG:+ --no-check-signature}"
    echo "[dry-run]   ${_INSTALL} --concurrent-packages ${INSTALL_JOBS} --jobs ${MAKE_JOBS} --fail-fast"
    exit 0
fi

# shellcheck source=/dev/null
. "${SPACK_ROOT}/share/spack/setup-env.sh"

if [[ "${CACHE_ONLY}" == "1" && "${NO_CHECK_SIG}" != "1" && -n "${BUILDCACHE_URI}" ]]; then
    if command -v timeout >/dev/null 2>&1; then
        timeout 60 spack buildcache keys --install --trust --force || true
    else
        spack buildcache keys --install --trust --force || true
    fi
fi

echo "spack_build.sh: activating environment at ${ENV_DIR}..."
spack env activate -d "${ENV_DIR}"

if [[ ! -f "${ENV_DIR}/spack.lock" ]]; then
    echo "spack_build.sh: no spack.lock found; concretizing..."
    spack concretize --fresh
fi

echo "spack_build.sh: installing..."
_INSTALL_ARGS=(install
    --concurrent-packages "${INSTALL_JOBS}"
    --jobs "${MAKE_JOBS}"
    --fail-fast
)
[[ "${CACHE_ONLY}"   == "1" ]] && _INSTALL_ARGS+=(--cache-only)
[[ "${NO_CHECK_SIG}" == "1" && -n "${BUILDCACHE_URI}" ]] && _INSTALL_ARGS+=(--no-check-signature)
spack "${_INSTALL_ARGS[@]}"

echo "spack_build.sh: done."
