#!/usr/bin/env bash
# deploy.sh — CSE deploy orchestrator.
#
# Runs Stage 1–5 in order.  Each stage script is independently runnable;
# this script just composes them and manages shared environment variables.
#
# Usage:
#   ./scripts/deploy.sh --variant <compiler>-<mpi> \
#                       --release <tag>            \
#                       --shared-path <path>       \
#                       [--network-mode <mode>]    \
#                       [--dry-run]                \
#                       [--from-stage N]           \
#                       [--restart-release]        \
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
#                       [--module-system {lmod|tcl}]   \
#                       [--preflight]              \
#                       [--preflight-strict]       \
#                       [--preflight-timeout N]    \
#                       [--render-only]            \
#                       [--skip-render]            \
#                       [--fetch]                  \
#                       [--build]
#
# Options:
#   --variant         Required. Variant slug: <compiler>-<mpi> or <compiler>-serial.
#                     Examples: gcc-openmpi, gcc-mpich, cce-craympich, aocc-openmpi.
#   --release         Required. Release tag (e.g. 2026_04).
#   --shared-path     Required. Path to the shared CSE filesystem root.
#   --network-mode    Deployment network policy: online, restricted, or
#                     airgapped (default: online).
#   --dry-run         Print every command that would run; render template YAML;
#                     exit 0 without modifying any state.
#   --from-stage N    Skip stages 1 through N-1 (assumes their outputs exist).
#   --restart-release Clear generated state for this release/variant before
#                     running. If --buildcache-uri is set and an old lockfile
#                     exists, export installed packages to that buildcache first.
#   --gcc-version     Spack GCC version to bootstrap (default: 13.3.0).
#                     gcc@13.2.0 is deprecated upstream; 13.3.0 is the current
#                     supported 13.x release.
#   --mpich-version   Override auto-detected MPICH version for *-mpich variants.
#                     Normally inferred from cray-mpich series via Cluster Inspector
#                     (cray-mpich 8.x → 3.4.3; 9.x → 4.2.2).
#   --jobs N          Number of packages to build in parallel (default: 4).
#                     Conservative on shared login nodes; raise on dedicated builders.
#                     Wired to `spack install --concurrent-packages N` in stages 2 and 4.
#   --make-jobs N     Threads per package build (default: nproc/2, clamped to [4,16]).
#                     Wired to `spack install --jobs N` and config:build_jobs.
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
#   --preflight       HEAD-check every source tarball URL after concretize and
#                     before install.  Warns on unreachable URLs; build continues.
#   --preflight-strict  Same as --preflight but abort the build if any URL is
#                     unreachable.  Implies --preflight.
#   --preflight-timeout N  Per-URL connect timeout in seconds (default: 5).
#   --render-only     Run stages 1+3 and render all remaining templates (config,
#                     modules, spack YAML), then exit without calling any spack
#                     command.  Lets a human take over with raw `spack -e` commands.
#   --skip-render     Skip stages 1-3; assume env YAML files already exist.
#                     Jump directly to spack concretize+install in stage 4.
#   --fetch           (passed to stage 4) Login-node step: concretize + spack fetch
#                     only.  No spack install.  Combine with --skip-render for
#                     compute-only installs later.
#   --build           (passed to stage 4) Compute-node step: spack install using the
#                     existing spack.lock; skip concretize and fetch.  Requires
#                     --fetch to have been run first.
#   --mock-profile    Path to a mock Cluster Inspector YAML profile.
#                     Useful for testing Cray variants on a non-Cray host.
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
RESTART_RELEASE=0
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
CSE_FETCH_PREFLIGHT=0
CSE_PREFLIGHT_STRICT=0
CSE_PREFLIGHT_TIMEOUT=5
RENDER_ONLY=0
SKIP_RENDER=0
STAGE4_BUILD_MODE="full"

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
        --variant)        require_arg_value "$1" "${2:-}"; VARIANT="$2";                shift 2 ;;
        --release)        require_arg_value "$1" "${2:-}"; RELEASE="$2";                shift 2 ;;
        --shared-path)    require_arg_value "$1" "${2:-}"; SHARED_PATH="$2";            shift 2 ;;
        --network-mode)   require_arg_value "$1" "${2:-}"; NETWORK_MODE="$2";           shift 2 ;;
        --dry-run)        DRY_RUN=1;                   shift   ;;
        --from-stage)     require_arg_value "$1" "${2:-}"; FROM_STAGE="$2";             shift 2 ;;
        --restart|--restart-release) RESTART_RELEASE=1; shift ;;
        --gcc-version)    require_arg_value "$1" "${2:-}"; GCC_VERSION_OVERRIDE="$2";   shift 2 ;;
        --mpich-version)  require_arg_value "$1" "${2:-}"; MPICH_VERSION_OVERRIDE="$2"; shift 2 ;;
        --jobs)           require_arg_value "$1" "${2:-}"; INSTALL_JOBS_OVERRIDE="$2";  shift 2 ;;
        --make-jobs)      require_arg_value "$1" "${2:-}"; MAKE_JOBS_OVERRIDE="$2";     shift 2 ;;
        --package-set)    require_arg_value "$1" "${2:-}"; PACKAGE_SET_OVERRIDE="$2";   shift 2 ;;
        --target)         require_arg_value "$1" "${2:-}"; SPACK_TARGET_OVERRIDE="$2";  shift 2 ;;
        --cache-only)     SPACK_CACHE_ONLY=1;          shift   ;;
        --group)          require_arg_value "$1" "${2:-}"; CSE_GROUP_OVERRIDE="$2";     shift 2 ;;
        --mirror-path)    require_arg_value "$1" "${2:-}"; MIRROR_PATH="$2";            shift 2 ;;
        --buildcache-uri) require_arg_value "$1" "${2:-}"; BUILDCACHE_URI="$2";         shift 2 ;;
        --spack-seed)     require_arg_value "$1" "${2:-}"; SPACK_SEED="$2";             shift 2 ;;
        --bootstrap-bundle) require_arg_value "$1" "${2:-}"; BOOTSTRAP_BUNDLE="$2";     shift 2 ;;
        --lockfile)       require_arg_value "$1" "${2:-}"; AUTHORITATIVE_LOCKFILE="$2"; shift 2 ;;
        --request-manifest) require_arg_value "$1" "${2:-}"; REQUEST_MANIFEST="$2";     shift 2 ;;
        --artifact-manifest) require_arg_value "$1" "${2:-}"; ARTIFACT_MANIFEST="$2";   shift 2 ;;
        --module-system)  require_arg_value "$1" "${2:-}"; MODULE_SYSTEM_OVERRIDE="$2"; shift 2 ;;
        --mock-profile)   require_arg_value "$1" "${2:-}"; MOCK_PROFILE="$2";           shift 2 ;;
        --spack-version)  require_arg_value "$1" "${2:-}"; SPACK_VERSION_OVERRIDE="$2"; shift 2 ;;
        --preflight)        CSE_FETCH_PREFLIGHT=1;                               shift   ;;
        --preflight-strict) CSE_FETCH_PREFLIGHT=1; CSE_PREFLIGHT_STRICT=1;      shift   ;;
        --preflight-timeout) require_arg_value "$1" "${2:-}"; CSE_PREFLIGHT_TIMEOUT="$2"; shift 2 ;;
        --render-only)      RENDER_ONLY=1;                                       shift   ;;
        --skip-render)      SKIP_RENDER=1;                                       shift   ;;
        --fetch)            SAW_FETCH=1; STAGE4_BUILD_MODE="fetch";              shift   ;;
        --build)            SAW_BUILD=1; STAGE4_BUILD_MODE="build";              shift   ;;
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
    echo "ERROR: --variant is required (e.g. gcc-openmpi, gcc-mpich, cce-craympich)" >&2
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
if [[ -n "${VARIANT}" && "${VARIANT}" != *-* ]]; then
    echo "ERROR: --variant must be <compiler>-<mpi> (e.g. gcc-openmpi, cce-craympich)" >&2
    errors=1
fi
VARIANT_COMPILER="${VARIANT%%-*}"
VARIANT_MPI="${VARIANT#*-}"
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
if [[ "${RENDER_ONLY}" == "1" && "${SKIP_RENDER}" == "1" ]]; then
    echo "ERROR: --render-only and --skip-render are mutually exclusive" >&2
    errors=1
fi
if [[ "${SAW_FETCH:-0}" == "1" && "${SAW_BUILD:-0}" == "1" ]]; then
    echo "ERROR: --fetch and --build are mutually exclusive" >&2
    errors=1
fi
if [[ "${RESTART_RELEASE}" == "1" && "${FROM_STAGE}" -gt 3 ]]; then
    echo "ERROR: --restart-release removes rendered environment files; use --from-stage 3 or lower" >&2
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
export CSE_FETCH_PREFLIGHT
export CSE_PREFLIGHT_STRICT
export CSE_PREFLIGHT_TIMEOUT
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
# MPICH_VERSION: explicit override for *-mpich variants; when unset render.py auto-detects
# from cray-mpich series via Cluster Inspector (8.x→3.4.3, 9.x→4.2.2).
if [[ -n "${MPICH_VERSION_OVERRIDE}" ]]; then
    export MPICH_VERSION="${MPICH_VERSION_OVERRIDE}"
fi
# Parallelism knobs.
#   SPACK_INSTALL_JOBS — `spack install --concurrent-packages N`.
#   SPACK_MAKE_JOBS    — `spack install --jobs N` and config:build_jobs.
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
export RENDER_ONLY
export SKIP_RENDER
export STAGE4_BUILD_MODE

# ------------------------------------------------------------------
# Auto-detect module system (or use override)
# ------------------------------------------------------------------
if [[ -n "${MODULE_SYSTEM_OVERRIDE}" ]]; then
    MODULE_SYSTEM="${MODULE_SYSTEM_OVERRIDE}"
else
    if [[ -n "${LMOD_CMD:-}" ]]; then
        MODULE_SYSTEM="lmod"
    elif command -v modulecmd.tcl &>/dev/null \
         || [[ -f /usr/share/modules/init/bash ]] \
         || [[ -n "${MODULESHOME:-}" ]]; then
        MODULE_SYSTEM="tcl"
    elif command -v lmod &>/dev/null; then
        MODULE_SYSTEM="lmod"
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
if [[ "${VARIANT_MPI}" == "mpich" ]]; then
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
if [[ "${RESTART_RELEASE}" == "1" ]]; then
    echo "  restart      : yes"
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

restart_release_state() {
    local release_dir="${SHARED_PATH}/cse/${RELEASE}/${VARIANT}"
    local old_lockfile="${release_dir}/env/spack.lock"
    local path=""

    if [[ "${RESTART_RELEASE}" != "1" ]]; then
        return 0
    fi

    case "${release_dir}" in
        "${SHARED_PATH}/cse/${RELEASE}/${VARIANT}") ;;
        *)
            echo "ERROR: refusing to restart unexpected release path: ${release_dir}" >&2
            exit 1
            ;;
    esac

    if [[ "${DRY_RUN}" == "1" ]]; then
        echo "[dry-run] restart: would prepare release restart at ${release_dir}"
        if [[ -n "${BUILDCACHE_URI}" ]]; then
            echo "[dry-run] restart: would export existing installed specs to ${BUILDCACHE_URI} before cleanup"
        fi
        echo "[dry-run] restart: would remove ${release_dir}/{env,store,views,modules,.cse-install-meta}"
        return 0
    fi

    if [[ ! -d "${release_dir}" ]]; then
        echo "restart: ${release_dir} does not exist yet; nothing to clean."
        return 0
    fi

    if [[ -n "${BUILDCACHE_URI}" ]]; then
        if [[ -f "${old_lockfile}" ]]; then
            echo "restart: exporting existing installed packages to ${BUILDCACHE_URI} before cleanup..."
            "${REPO_ROOT}/scripts/buildcache_push.sh" \
                --cache-uri "${BUILDCACHE_URI}" \
                --variant "${VARIANT}" \
                --release "${RELEASE}" \
                --shared-path "${SHARED_PATH}" \
                --allow-partial
        else
            echo "restart: no existing lockfile at ${old_lockfile}; skipping pre-cleanup buildcache export."
        fi
    else
        echo "restart: no --buildcache-uri set; existing release store will be discarded without cache export."
    fi

    for path in \
        "${release_dir}/env" \
        "${release_dir}/store" \
        "${release_dir}/views" \
        "${release_dir}/modules" \
        "${release_dir}/.cse-install-meta"; do
        case "${path}" in
            "${release_dir}/"*) ;;
            *)
                echo "ERROR: refusing to remove unexpected restart path: ${path}" >&2
                exit 1
                ;;
        esac
        if [[ -e "${path}" || -L "${path}" ]]; then
            echo "restart: removing ${path}"
            rm -rf "${path}"
        fi
    done
}

restart_release_state

# ------------------------------------------------------------------
# Stage runner
# ------------------------------------------------------------------
run_stage() {
    local n="$1" script="$2"
    if [[ "${FROM_STAGE}" -gt "${n}" ]]; then
        echo "--- Stage ${n}: skipped (--from-stage ${FROM_STAGE})"
        return 0
    fi
    if [[ "${RENDER_ONLY}" == "1" && "${n}" == "2" ]]; then
        echo "--- Stage ${n}: skipped (--render-only does not bootstrap Spack/GCC)"
        return 0
    fi
    echo "--- Stage ${n}: ${script}"
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/scripts/${script}"
    echo ""
}

if [[ "${SKIP_RENDER}" == "1" && "${FROM_STAGE}" -lt 4 ]]; then
    FROM_STAGE=4
fi

run_stage 1 stage1_profile.sh
run_stage 2 stage2_spack.sh
run_stage 3 stage3_externals.sh

if [[ "${RENDER_ONLY}" == "1" ]]; then
    # Render config.yaml, modules.yaml, spack.yaml without calling spack
    echo "--- render-only: rendering config.yaml, modules.yaml, spack.yaml..."
    _RENDER_ARGS=(
        --variant   "${VARIANT}"
        --shared-path "${SHARED_PATH}"
        --release   "${RELEASE}"
    )
    if [[ -n "${PROFILE_FILE:-}" && -f "${PROFILE_FILE}" ]]; then
        _RENDER_ARGS+=(--profile "${PROFILE_FILE}")
    fi
    _VARIANT_ENV_DIR="${SHARED_PATH}/cse/${RELEASE}/${VARIANT}/env"
    if [[ "${DRY_RUN}" == "1" ]]; then
        python3 "${REPO_ROOT}/scripts/lib/render.py" "${_RENDER_ARGS[@]}" \
            --template "${REPO_ROOT}/templates/config.yaml.j2"  --dry-run
        python3 "${REPO_ROOT}/scripts/lib/render.py" "${_RENDER_ARGS[@]}" \
            --template "${REPO_ROOT}/templates/modules.yaml.j2" --dry-run
        python3 "${REPO_ROOT}/scripts/lib/render.py" "${_RENDER_ARGS[@]}" \
            --template "${REPO_ROOT}/templates/spack.yaml.j2"   --dry-run
    else
        umask 002
        mkdir -p "${_VARIANT_ENV_DIR}"
        python3 "${REPO_ROOT}/scripts/lib/render.py" "${_RENDER_ARGS[@]}" \
            --template "${REPO_ROOT}/templates/config.yaml.j2" \
            --output "${_VARIANT_ENV_DIR}/config.yaml"
        python3 "${REPO_ROOT}/scripts/lib/render.py" "${_RENDER_ARGS[@]}" \
            --template "${REPO_ROOT}/templates/modules.yaml.j2" \
            --output "${_VARIANT_ENV_DIR}/modules.yaml"
        python3 "${REPO_ROOT}/scripts/lib/render.py" "${_RENDER_ARGS[@]}" \
            --template "${REPO_ROOT}/templates/spack.yaml.j2" \
            --output "${_VARIANT_ENV_DIR}/spack.yaml"
        echo "--- render-only: all YAML written to ${_VARIANT_ENV_DIR}"
        echo "--- render-only: run  spack -e ${_VARIANT_ENV_DIR} concretize  to continue"
    fi
else
    run_stage 4 stage4_build.sh
    run_stage 5 stage5_modules.sh
fi

echo "========================================================"
if [[ ${DRY_RUN} == 1 ]]; then
    echo " Dry-run complete.  No changes were made."
else
    echo " Deploy complete."
    echo " Users can now load the CSE environment with:"
    echo "   module use ${SITE_MODULE_PATH}"
    _COMPILER_UPPER="$(echo "${VARIANT_COMPILER}" | tr '[:lower:]' '[:upper:]')"
    if [[ "${VARIANT_MPI}" == "serial" ]]; then
        _MPI_LABEL="serial"
    else
        _MPI_LABEL="mpi-${VARIANT_MPI}"
    fi
    echo "   module load cse-init/${_COMPILER_UPPER}/${_MPI_LABEL}"
    echo "   module load cse-init/${RELEASE}/${_COMPILER_UPPER}/${_MPI_LABEL}"
    echo "   module avail cse"
fi
echo "========================================================"
