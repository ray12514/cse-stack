#!/usr/bin/env bash
# deploy.sh — CSE deploy orchestrator.
#
# Runs Stage 1–5 in order.  Each stage script is independently runnable;
# this script just composes them and manages shared environment variables.
#
# Usage:
#   ./scripts/deploy.sh --variant {v1-openmpi|v2-mpich} \
#                       --release <tag>            \
#                       --shared-path <path>       \
#                       [--network-mode <mode>]    \
#                       [--dry-run]                \
#                       [--from-stage N]           \
#                       [--gcc-version <ver>]      \
#                       [--mpich-version <ver>]    \
#                       [--jobs <n>]               \
#                       [--make-jobs <n>]          \
#                       [--package-set <name>]     \
#                       [--target <spack-target>]  \
#                       [--cache-only]             \
#                       [--group <name>]           \
#                       [--mirror-path <path>]     \
#                       [--buildcache-uri <uri>]   \
#                       [--spack-seed <path>]      \
#                       [--bootstrap-bundle <path>] \
#                       [--lockfile <path>]        \
#                       [--module-system {lmod|tcl}]
#
# Options:
#   --variant         Required. Deployment variant: v1-openmpi or v2-mpich.
#   --release         Required. Release tag (e.g. 2026_04).
#   --shared-path     Required. Path to the shared CSE filesystem root.
#   --network-mode    Deployment network policy: online, restricted, or
#                     airgapped (default: online).
#   --dry-run         Print every command that would run; render template YAML;
#                     exit 0 without modifying any state.
#   --from-stage N    Skip stages 1 through N-1 (assumes their outputs exist).
#   --gcc-version     Spack GCC version to bootstrap (default: 13.3.0).
#                     gcc@13.2.0 is deprecated upstream; 13.3.0 is the current
#                     supported 13.x release.
#   --mpich-version   Override auto-detected MPICH version for v2-mpich.
#                     Normally inferred from cray-mpich series via Cluster Inspector
#                     (cray-mpich 8.x → 3.4.3; 9.x → 4.2.2).
#   --jobs N          Number of packages to build in parallel (default: 4).
#                     Conservative on shared login nodes; raise on dedicated builders.
#                     Wired to `spack install -j N` in stages 2 and 4.
#   --make-jobs N     Threads per package build (default: nproc/2, clamped to [4,16]).
#                     Wired to `config:build_jobs` via templates/config.yaml.j2.
#   --package-set     Package set to render (default: full). Use
#                     hdf5-mpi-smoke for a reduced same-pipeline build.
#   --target TARGET   Spack target preference (default: x86_64). Use
#                     x86_64_v3 only when every target node supports it.
#   --cache-only      Install only from configured binary build caches; fail
#                     instead of falling back to source builds.
#   --group           Unix group that owns the shared install tree (default: installer's group).
#   --mirror-path     Path to a local Spack source mirror (file:// or directory path).
#                     Use scripts/mirror_fetch.sh on an internet-connected host to
#                     populate the mirror, then transfer it here.
#   --buildcache-uri  URI of a Spack binary build cache (file://, s3://, https://).
#                     Stage 4 pulls cache hits before building and pushes new binaries after.
#                     Use scripts/buildcache_push.sh for a standalone push.
#   --spack-seed      Path to a versioned Spack tar bundle or directory copy.
#                     Required for air-gapped deploys; optional for restricted.
#   --bootstrap-bundle Path to a prepared Spack bootstrap bundle. Required for
#                     restricted and air-gapped deploys.
#   --lockfile        Path to an authoritative Spack lockfile to reuse on the
#                     target without re-concretizing. Required for restricted
#                     and air-gapped deploys.
#   --module-system   Override auto-detected module system (lmod or tcl).
#   --mock-profile    Path to a mock Cluster Inspector YAML profile.
#                     Useful for testing v2-mpich on a non-Cray host.
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
NETWORK_MODE="${CSE_NETWORK_MODE:-online}"
DRY_RUN=0
FROM_STAGE=1
GCC_VERSION_OVERRIDE=""
MPICH_VERSION_OVERRIDE=""
INSTALL_JOBS_OVERRIDE=""
MAKE_JOBS_OVERRIDE=""
PACKAGE_SET_OVERRIDE=""
SPACK_TARGET_OVERRIDE=""
SPACK_CACHE_ONLY=0
CSE_GROUP_OVERRIDE=""
MIRROR_PATH="${MIRROR_PATH:-}"
BUILDCACHE_URI="${BUILDCACHE_URI:-}"
SPACK_SEED="${SPACK_SEED:-}"
BOOTSTRAP_BUNDLE="${BOOTSTRAP_BUNDLE:-}"
AUTHORITATIVE_LOCKFILE="${AUTHORITATIVE_LOCKFILE:-}"
REQUEST_MANIFEST="${CSE_REQUEST_MANIFEST:-}"
ARTIFACT_MANIFEST="${CSE_ARTIFACT_MANIFEST:-}"
MODULE_SYSTEM_OVERRIDE=""
MOCK_PROFILE=""
SPACK_VERSION_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant)        VARIANT="$2";                shift 2 ;;
        --release)        RELEASE="$2";                shift 2 ;;
        --shared-path)    SHARED_PATH="$2";            shift 2 ;;
        --network-mode)   NETWORK_MODE="$2";           shift 2 ;;
        --dry-run)        DRY_RUN=1;                   shift   ;;
        --from-stage)     FROM_STAGE="$2";             shift 2 ;;
        --gcc-version)    GCC_VERSION_OVERRIDE="$2";    shift 2 ;;
        --mpich-version)  MPICH_VERSION_OVERRIDE="$2"; shift 2 ;;
        --jobs)           INSTALL_JOBS_OVERRIDE="$2";  shift 2 ;;
        --make-jobs)      MAKE_JOBS_OVERRIDE="$2";     shift 2 ;;
        --package-set)    PACKAGE_SET_OVERRIDE="$2";   shift 2 ;;
        --target)         SPACK_TARGET_OVERRIDE="$2";   shift 2 ;;
        --cache-only)     SPACK_CACHE_ONLY=1;          shift   ;;
        --group)          CSE_GROUP_OVERRIDE="$2";     shift 2 ;;
        --mirror-path)    MIRROR_PATH="$2";            shift 2 ;;
        --buildcache-uri) BUILDCACHE_URI="$2";         shift 2 ;;
        --spack-seed)     SPACK_SEED="$2";             shift 2 ;;
        --bootstrap-bundle) BOOTSTRAP_BUNDLE="$2";     shift 2 ;;
        --lockfile)       AUTHORITATIVE_LOCKFILE="$2"; shift 2 ;;
        --request-manifest) REQUEST_MANIFEST="$2";     shift 2 ;;
        --artifact-manifest) ARTIFACT_MANIFEST="$2";   shift 2 ;;
        --module-system)  MODULE_SYSTEM_OVERRIDE="$2"; shift 2 ;;
        --mock-profile)   MOCK_PROFILE="$2";           shift 2 ;;
        --spack-version)  SPACK_VERSION_OVERRIDE="$2"; shift 2 ;;
        -h|--help)
            sed -n '3,49p' "${BASH_SOURCE[0]}"
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
    echo "ERROR: --variant is required (v1-openmpi | v2-mpich)" >&2
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
if [[ "${VARIANT}" != "v1-openmpi" && "${VARIANT}" != "v2-mpich" ]]; then
    echo "ERROR: --variant must be v1-openmpi or v2-mpich" >&2
    errors=1
fi
if [[ -n "${PACKAGE_SET_OVERRIDE}" && ! -f "${REPO_ROOT}/package-sets/${PACKAGE_SET_OVERRIDE}.yaml" ]]; then
    echo "ERROR: --package-set not found: ${PACKAGE_SET_OVERRIDE}" >&2
    echo "       Expected ${REPO_ROOT}/package-sets/${PACKAGE_SET_OVERRIDE}.yaml" >&2
    errors=1
fi
if [[ "${NETWORK_MODE}" != "online" && "${NETWORK_MODE}" != "restricted" && "${NETWORK_MODE}" != "airgapped" ]]; then
    echo "ERROR: --network-mode must be online, restricted, or airgapped" >&2
    errors=1
fi
if [[ "${NETWORK_MODE}" == "restricted" || "${NETWORK_MODE}" == "airgapped" ]]; then
    if [[ -z "${MIRROR_PATH}" ]]; then
        echo "ERROR: --network-mode ${NETWORK_MODE} requires --mirror-path" >&2
        errors=1
    fi
    if [[ -z "${BOOTSTRAP_BUNDLE}" ]]; then
        echo "ERROR: --network-mode ${NETWORK_MODE} requires --bootstrap-bundle" >&2
        errors=1
    fi
    if [[ -z "${AUTHORITATIVE_LOCKFILE}" ]]; then
        echo "ERROR: --network-mode ${NETWORK_MODE} requires --lockfile" >&2
        errors=1
    fi
fi
if [[ "${NETWORK_MODE}" == "airgapped" && -z "${SPACK_SEED}" ]]; then
    echo "ERROR: --network-mode airgapped requires --spack-seed" >&2
    errors=1
fi
if [[ "${SPACK_CACHE_ONLY}" == "1" && -z "${BUILDCACHE_URI}" ]]; then
    echo "ERROR: --cache-only requires --buildcache-uri or BUILDCACHE_URI" >&2
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
export CSE_NETWORK_MODE="${NETWORK_MODE}"
# MIRROR_PATH: if set, stage 4 writes mirrors.yaml so Spack fetches from here
# instead of the internet.  Accepts a filesystem path or file:// / http:// URL.
export MIRROR_PATH
# BUILDCACHE_URI: if set, stage 4 pulls cache hits before installing and pushes
# new binaries after.  Accepts file://, s3://, or https:// URIs.
export BUILDCACHE_URI
export SPACK_SEED
export BOOTSTRAP_BUNDLE
export AUTHORITATIVE_LOCKFILE
export CSE_REQUEST_MANIFEST="${REQUEST_MANIFEST}"
export CSE_ARTIFACT_MANIFEST="${ARTIFACT_MANIFEST}"
# GCC_VERSION is used by stage2_spack.sh (bootstrap) and the render context.
# Both variants now bootstrap GCC from Spack.
export GCC_VERSION="${GCC_VERSION_OVERRIDE:-${GCC_VERSION:-13.3.0}}"
export SPACK_VERSION="${SPACK_VERSION_OVERRIDE:-${SPACK_VERSION:-v1.1.1}}"
# MPICH_VERSION: explicit override for v2-mpich; when unset render.py auto-detects
# from cray-mpich series via Cluster Inspector (8.x→3.4.3, 9.x→4.2.2).
if [[ -n "${MPICH_VERSION_OVERRIDE}" ]]; then
    export MPICH_VERSION="${MPICH_VERSION_OVERRIDE}"
fi
# Parallelism knobs.
#   SPACK_INSTALL_JOBS — `spack install -j N` (packages built in parallel).
#   SPACK_MAKE_JOBS    — config:build_jobs in config.yaml (threads per package).
# Default install jobs to 4 (conservative on shared login nodes); default make
# jobs to nproc/2 clamped to [4,16] so a single package can saturate cores
# without overwhelming the box when combined with parallel installs.
DEFAULT_MAKE_JOBS=$(( $(nproc 2>/dev/null || echo 8) / 2 ))
DEFAULT_MAKE_JOBS=$(( DEFAULT_MAKE_JOBS < 4 ? 4 : DEFAULT_MAKE_JOBS ))
DEFAULT_MAKE_JOBS=$(( DEFAULT_MAKE_JOBS > 16 ? 16 : DEFAULT_MAKE_JOBS ))
export SPACK_INSTALL_JOBS="${INSTALL_JOBS_OVERRIDE:-${SPACK_INSTALL_JOBS:-4}}"
export SPACK_MAKE_JOBS="${MAKE_JOBS_OVERRIDE:-${SPACK_MAKE_JOBS:-${DEFAULT_MAKE_JOBS}}}"
export CSE_PACKAGE_SET="${PACKAGE_SET_OVERRIDE:-${CSE_PACKAGE_SET:-full}}"
export SPACK_CACHE_ONLY
# Build target preference. Keep x86_64 as the portable default; sites can opt
# into x86_64_v3/x86_64_v4 after confirming every target node supports it.
export SPACK_TARGET="${SPACK_TARGET_OVERRIDE:-${SPACK_TARGET:-x86_64}}"
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
    if command -v lmod &>/dev/null || [[ -n "${LMOD_CMD:-}" ]]; then
        MODULE_SYSTEM="lmod"
    elif command -v modulecmd.tcl &>/dev/null \
         || command -v modulecmd &>/dev/null \
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
echo "  network mode : ${NETWORK_MODE}"
echo "  group        : ${CSE_GROUP}"
echo "  spack version: ${SPACK_VERSION}"
echo "  gcc version  : ${GCC_VERSION}"
if [[ "${VARIANT}" == "v2-mpich" ]]; then
    echo "  mpich version: ${MPICH_VERSION:-auto-detect from profile}"
fi
echo "  module system: ${MODULE_SYSTEM}"
echo "  install jobs : ${SPACK_INSTALL_JOBS} (parallel package builds)"
echo "  make jobs    : ${SPACK_MAKE_JOBS} (threads per package)"
echo "  package set  : ${CSE_PACKAGE_SET}"
echo "  target       : ${SPACK_TARGET}"
if [[ "${SPACK_CACHE_ONLY}" == "1" ]]; then
    echo "  cache only   : yes"
fi
if [[ -n "${MIRROR_PATH}" ]]; then
    echo "  mirror       : ${MIRROR_PATH}"
fi
if [[ -n "${SPACK_SEED}" ]]; then
    echo "  spack seed   : ${SPACK_SEED}"
fi
if [[ -n "${BOOTSTRAP_BUNDLE}" ]]; then
    echo "  bootstrap    : ${BOOTSTRAP_BUNDLE}"
fi
if [[ -n "${AUTHORITATIVE_LOCKFILE}" ]]; then
    echo "  lockfile     : ${AUTHORITATIVE_LOCKFILE}"
fi
if [[ ${DRY_RUN} == 1 ]]; then
    echo "  mode         : DRY-RUN (no changes will be made)"
fi
echo "========================================================"
echo ""

if [[ -n "${REQUEST_MANIFEST}" && ! -f "${REQUEST_MANIFEST}" ]]; then
    echo "ERROR: request manifest not found: ${REQUEST_MANIFEST}" >&2
    exit 1
fi
if [[ -n "${ARTIFACT_MANIFEST}" && ! -f "${ARTIFACT_MANIFEST}" ]]; then
    echo "ERROR: artifact manifest not found: ${ARTIFACT_MANIFEST}" >&2
    exit 1
fi
if [[ -n "${SPACK_SEED}" && ! -e "${SPACK_SEED}" ]]; then
    echo "ERROR: Spack seed not found: ${SPACK_SEED}" >&2
    exit 1
fi
if [[ -n "${BOOTSTRAP_BUNDLE}" && ! -e "${BOOTSTRAP_BUNDLE}" ]]; then
    echo "ERROR: bootstrap bundle not found: ${BOOTSTRAP_BUNDLE}" >&2
    exit 1
fi
if [[ -n "${AUTHORITATIVE_LOCKFILE}" && ! -f "${AUTHORITATIVE_LOCKFILE}" ]]; then
    echo "ERROR: lockfile not found: ${AUTHORITATIVE_LOCKFILE}" >&2
    exit 1
fi
if [[ "${DRY_RUN}" != "1" && "${SPACK_CACHE_ONLY}" == "1" && "${BUILDCACHE_URI}" == file://* ]]; then
    if [[ ! -d "${BUILDCACHE_URI#file://}" ]]; then
        echo "ERROR: local buildcache directory not found: ${BUILDCACHE_URI#file://}" >&2
        exit 1
    fi
fi
if [[ "${DRY_RUN}" != "1" && -n "${MIRROR_PATH}" && "${MIRROR_PATH}" != *://* && ! -d "${MIRROR_PATH}" ]]; then
    echo "ERROR: local source mirror directory not found: ${MIRROR_PATH}" >&2
    exit 1
fi

python3 - "${REQUEST_MANIFEST}" "${ARTIFACT_MANIFEST}" "${VARIANT}" "${RELEASE}" "${NETWORK_MODE}" "${CSE_PACKAGE_SET:-${PACKAGE_SET_OVERRIDE:-full}}" "${SPACK_TARGET_OVERRIDE:-${SPACK_TARGET:-x86_64}}" "${SPACK_VERSION}" "${GCC_VERSION}" <<'PY'
import json
import pathlib
import sys

request_manifest, artifact_manifest, variant, release, network_mode, package_set, target, spack_version, gcc_version = sys.argv[1:10]

def load(path_str):
    if not path_str:
        return None
    path = pathlib.Path(path_str)
    with path.open() as fh:
        return json.load(fh)

def norm_spack_version(value):
    if not value:
        return ""
    return str(value).lstrip("v")

def validate(name, data):
    if not data:
        return
    checks = {
        "variant": variant,
        "release": release,
        "network_mode": network_mode,
        "package_set": package_set,
        "target": target,
    }
    if "spack_version" in data:
        if norm_spack_version(data["spack_version"]) != norm_spack_version(spack_version):
            raise SystemExit(f"ERROR: {name} Spack version {data['spack_version']} does not match requested {spack_version}")
    if "gcc_version" in data and str(data["gcc_version"]) != gcc_version:
        raise SystemExit(f"ERROR: {name} GCC version {data['gcc_version']} does not match requested {gcc_version}")
    for key, expected in checks.items():
        actual = data.get(key)
        if actual is not None and str(actual) != expected:
            raise SystemExit(f"ERROR: {name} field {key}={actual} does not match requested {expected}")

validate("request manifest", load(request_manifest))
validate("artifact manifest", load(artifact_manifest))
PY

python3 "${REPO_ROOT}/scripts/lib/package_sets.py" \
    --repo-root "${REPO_ROOT}" \
    --package-set "${CSE_PACKAGE_SET}" \
    --variant "${VARIANT}" \
    --mpich-version "${MPICH_VERSION:-}"

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
    if [[ "${VARIANT}" == "v1-openmpi" ]]; then
        echo "   module load cse-init/openmpi"
    else
        echo "   module load cse-init/mpich"
    fi
    echo "   module avail cse"
fi
echo "========================================================"
