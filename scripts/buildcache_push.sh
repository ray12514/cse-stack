#!/usr/bin/env bash
# buildcache_push.sh — Push Spack binary packages to a build cache.
#
# Run after stage 4 (spack install must have completed) to populate a
# binary build cache.  Subsequent deploys on any compatible system will
# pull pre-built binaries from the cache instead of compiling from source.
#
# Usage:
#   ./scripts/buildcache_push.sh \
#       --cache-uri file:///shared/cse-buildcache \
#       --variant   gcc-mpich                     \
#       --release   2026_04                       \
#       --shared-path /shared                     \
#       [--allow-partial]
#
# Use --allow-partial after a failed build. The script first tries to push the
# full environment; if that fails because not every root spec installed, it
# falls back to pushing the installed specs that Spack can see in the active
# environment.
#
# Transfer flow (air-gapped):
#   1. Run this script to push to a local file:// cache
#   2. rsync the cache directory to the target system:
#        rsync -av --progress /shared/cse-buildcache/ user@target:/shared/cse-buildcache/
#   3. Deploy on target with:
#        ./scripts/deploy.sh ... --buildcache-uri file:///shared/cse-buildcache
#
# Cache entries are keyed by Spack hash (which encodes OS, arch, compiler,
# variant flags, and all dependencies). Entries from incompatible systems
# coexist harmlessly — Spack ignores hashes that do not match the current
# concretization.
#
# Environment:
#   SPACK_ROOT   — override Spack location (normally inferred from variant)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CACHE_URI=""
VARIANT=""
RELEASE=""
SHARED_PATH=""
ALLOW_PARTIAL=0

require_arg_value() {
    local opt="$1"
    local next="${2:-}"
    if [[ -z "${next}" || "${next}" == --* ]]; then
        echo "ERROR: ${opt} requires a value" >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cache-uri)    require_arg_value "$1" "${2:-}"; CACHE_URI="$2";    shift 2 ;;
        --variant)      require_arg_value "$1" "${2:-}"; VARIANT="$2";      shift 2 ;;
        --release)      require_arg_value "$1" "${2:-}"; RELEASE="$2";      shift 2 ;;
        --shared-path)  require_arg_value "$1" "${2:-}"; SHARED_PATH="$2";  shift 2 ;;
        --allow-partial) ALLOW_PARTIAL=1; shift ;;
        *) echo "buildcache_push.sh: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${CACHE_URI}" || -z "${VARIANT}" || -z "${RELEASE}" || -z "${SHARED_PATH}" ]]; then
    echo "Usage: buildcache_push.sh --cache-uri <uri> --variant <v> --release <r> --shared-path <p> [--allow-partial]" >&2
    exit 1
fi

VARIANT_ENV_DIR="${SHARED_PATH}/cse/${RELEASE}/${VARIANT}/env"

if [[ ! -f "${VARIANT_ENV_DIR}/spack.lock" ]]; then
    echo "ERROR: ${VARIANT_ENV_DIR}/spack.lock not found." >&2
    echo "       Run stage 4 (spack install) first." >&2
    exit 1
fi

if [[ -z "${SPACK_ROOT:-}" ]]; then
    SPACK_ROOT="${SHARED_PATH}/cse/spack-site"
fi

if [[ ! -f "${SPACK_ROOT}/share/spack/setup-env.sh" ]]; then
    echo "ERROR: Spack not found at ${SPACK_ROOT}." >&2
    echo "       Run stage 2 first, or set SPACK_ROOT." >&2
    exit 1
fi

export SPACK_DISABLE_LOCAL_CONFIG=1
export SPACK_USER_CACHE_PATH="${SHARED_PATH}/cse/cache/spack"
export SPACK_SYSTEM_CONFIG_PATH="/dev/null"
export SPACK_USER_CONFIG_PATH="/dev/null"
# shellcheck source=/dev/null
. "${SPACK_ROOT}/share/spack/setup-env.sh"

echo "buildcache_push: activating environment at ${VARIANT_ENV_DIR}..."
spack env activate -d "${VARIANT_ENV_DIR}"

push_environment() {
    echo "buildcache_push: pushing environment binaries to ${CACHE_URI}..."
    spack buildcache push --unsigned "${CACHE_URI}"
}

push_installed_specs() {
    local specs=()
    local spec=""

    while IFS= read -r spec; do
        [[ -n "${spec}" ]] || continue
        specs+=("${spec}")
    done < <(spack find --deps --format '/{hash}' 2>/dev/null | awk '!seen[$0]++')

    if [[ ${#specs[@]} -eq 0 ]]; then
        echo "ERROR: no installed specs found in ${VARIANT_ENV_DIR}" >&2
        return 1
    fi

    echo "buildcache_push: pushing ${#specs[@]} installed specs to ${CACHE_URI}..."
    spack buildcache push --unsigned "${CACHE_URI}" "${specs[@]}"
}

if [[ "${ALLOW_PARTIAL}" == "1" ]]; then
    if ! push_environment; then
        echo "buildcache_push: full environment push failed; falling back to installed specs only."
        push_installed_specs
    fi
else
    push_environment
fi

echo ""
echo "buildcache_push: done."
echo ""
echo "Transfer cache to other systems with:"
echo "  rsync -av --progress <local-cache-dir>/ user@target:<remote-cache-dir>/"
echo ""
echo "Deploy on target with:"
echo "  ./scripts/deploy.sh --variant ${VARIANT} --release ${RELEASE} \\"
echo "      --shared-path ${SHARED_PATH} --buildcache-uri ${CACHE_URI} ..."
