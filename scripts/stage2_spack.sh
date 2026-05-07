#!/usr/bin/env bash
# Stage 2: Clone/initialise Spack and bootstrap GCC.
#
# Design: ONE spack instance (SPACK_SITE).  GCC is built and stored there.
# No separate bootstrap clone — the old two-spack pattern is gone.
#
# Environment:
#   SHARED_PATH, CSE_RELEASE, CSE_VARIANT  — set by deploy.sh / activate.sh
#   CSE_GROUP                              — owning group (default: current group)
#   DRY_RUN                                — "1" for dry-run
#   SPACK_VERSION                          — git tag to clone (default: v1.1.1)
#   GCC_VERSION                            — GCC version to build (default: 13.3.0)
#   SPACK_INSTALL_JOBS                     — parallel jobs for spack install
#   SPACK_TARGET                           — Spack build target preference (default: x86_64)
#   SPACK_CACHE_ONLY                       — "1" to install only from build cache
#   SPACK_NO_CHECK_SIGNATURE               — "1" to skip binary signature checks
#   CSE_USE_SYSTEM_GCC                     — "1" to skip GCC bootstrap and register
#                                            the detected system GCC as the CSE compiler
set -euo pipefail

: "${SHARED_PATH:?}"
: "${CSE_RELEASE:?}"
: "${CSE_VARIANT:?}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib/network_common.sh"

NETWORK_MODE="${CSE_NETWORK_MODE:-online}"
SPACK_VERSION="${SPACK_VERSION:-v1.1.1}"
GCC_VERSION="${GCC_VERSION:-13.3.0}"
SPACK_TARGET="${SPACK_TARGET:-x86_64}"
SPACK_SITE="${SHARED_PATH}/cse/spack-site"
VARIANT_DIR="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}"
USE_SYSTEM_GCC="${CSE_USE_SYSTEM_GCC:-0}"
BOOTSTRAP_ROOT="${SHARED_PATH}/cse/cache/bootstrap"
COMPILER_VIEW_ROOT="${VARIANT_DIR}/views/compiler/gcc"

_normalize_spack_version() {
    local normalized="${1#v}"
    normalized="${normalized%% *}"
    printf '%s\n' "${normalized}"
}

_stage2_install_bootstrap_bundle() {
    local bundle_path="$1"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "[dry-run] Stage 2: would seed bootstrap root ${BOOTSTRAP_ROOT} from ${bundle_path}"
        return 0
    fi
    echo "Stage 2: seeding bootstrap root from ${bundle_path}..."
    cse_extract_archive "${bundle_path}" "${BOOTSTRAP_ROOT}"
}

_stage2_install_spack_seed() {
    local seed_path="$1"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "[dry-run] Stage 2: would install Spack seed ${seed_path} into ${SPACK_SITE}"
        return 0
    fi
    echo "Stage 2: installing Spack seed from ${seed_path} into ${SPACK_SITE}..."
    cse_extract_archive "${seed_path}" "${SPACK_SITE}"
}

_find_installed_gcc_bin() {
    local prefix=""
    prefix="$(spack location -i "gcc@${GCC_VERSION}" 2>/dev/null || true)"
    if [[ -n "${prefix}" && -x "${prefix}/bin/gcc" ]]; then
        printf '%s\n' "${prefix}/bin/gcc"
        return 0
    fi

    find "${SPACK_SITE}/opt" -path "*/gcc-${GCC_VERSION}*/bin/gcc" 2>/dev/null | head -1
}

_publish_compiler_view() {
    local gcc_prefix="$1" gcc_version="$2"
    local clean_prefix="${COMPILER_VIEW_ROOT}/${gcc_version}"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "[dry-run] Stage 2: would link ${clean_prefix} -> ${gcc_prefix}"
        return 0
    fi

    mkdir -p "${COMPILER_VIEW_ROOT}"
    if [[ -e "${clean_prefix}" && ! -L "${clean_prefix}" ]]; then
        echo "ERROR: compiler view path exists and is not a symlink: ${clean_prefix}" >&2
        exit 1
    fi
    ln -sfn "${gcc_prefix}" "${clean_prefix}"
    chgrp -h "${CSE_GROUP:-$(id -gn)}" "${clean_prefix}" 2>/dev/null || true
}

# Prevent Spack from reading ~/.spack/ or /etc/spack/ — we write all config
# directly as YAML files so this environment is fully reproducible.
export SPACK_DISABLE_LOCAL_CONFIG=1
export SPACK_USER_CACHE_PATH="${BOOTSTRAP_ROOT}"
export SPACK_SYSTEM_CONFIG_PATH="/dev/null"

_run() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "[dry-run]   $*"
    else
        "$@"
    fi
}

# ------------------------------------------------------------------
# 1. Clone Spack into the shared site directory (idempotent)
# ------------------------------------------------------------------
if [[ -n "${BOOTSTRAP_BUNDLE:-}" ]]; then
    _stage2_install_bootstrap_bundle "${BOOTSTRAP_BUNDLE}"
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    if [[ -n "${SPACK_SEED:-}" ]]; then
        echo "[dry-run] Stage 2: would install Spack ${SPACK_VERSION} from seed ${SPACK_SEED}"
    else
        echo "[dry-run] Stage 2: would clone spack ${SPACK_VERSION} into ${SPACK_SITE}"
    fi
else
    if [[ ! -f "${SPACK_SITE}/share/spack/setup-env.sh" ]]; then
        if [[ -n "${SPACK_SEED:-}" ]]; then
            _stage2_install_spack_seed "${SPACK_SEED}"
        elif [[ "${NETWORK_MODE}" == "airgapped" ]]; then
            echo "ERROR: air-gapped mode requires a local Spack seed." >&2
            exit 1
        else
            echo "Stage 2: cloning Spack ${SPACK_VERSION} into ${SPACK_SITE}..."
            mkdir -p "$(dirname "${SPACK_SITE}")"
            git clone --depth 1 --branch "${SPACK_VERSION}" \
                https://github.com/spack/spack.git "${SPACK_SITE}"
        fi
    else
        echo "Stage 2: Spack already present at ${SPACK_SITE}"
    fi
fi

if [[ "${DRY_RUN:-0}" != "1" ]]; then
    if [[ ! -x "${SPACK_SITE}/bin/spack" ]]; then
        echo "ERROR: Spack executable not found under ${SPACK_SITE}" >&2
        exit 1
    fi
    INSTALLED_SPACK_VERSION="$("${SPACK_SITE}/bin/spack" --version)"
    if [[ "$(_normalize_spack_version "${INSTALLED_SPACK_VERSION}")" != "$(_normalize_spack_version "${SPACK_VERSION}")" ]]; then
        echo "ERROR: Spack at ${SPACK_SITE} is version ${INSTALLED_SPACK_VERSION}," >&2
        echo "       expected ${SPACK_VERSION}." >&2
        exit 1
    fi
fi

# ------------------------------------------------------------------
# 2. Bootstrap GCC into SPACK_SITE (single spack instance)
# ------------------------------------------------------------------
GCC_BOOTSTRAP_YAML="${VARIANT_DIR}/gcc-bootstrap.yaml"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] Stage 2: would source ${SPACK_SITE}/share/spack/setup-env.sh"
    if [[ -n "${BUILDCACHE_URI:-}" ]]; then
        echo "[dry-run] Stage 2: would configure build cache ${BUILDCACHE_URI}"
    fi
    echo "[dry-run] Stage 2: would register system GCC in ${SPACK_SITE}/etc/spack/compilers.yaml"
    if [[ "${USE_SYSTEM_GCC}" == "1" ]]; then
        echo "[dry-run] Stage 2: would skip GCC bootstrap and use the detected system compiler as CSE GCC"
    else
        if [[ "${SPACK_CACHE_ONLY:-0}" == "1" ]]; then
            if [[ "${SPACK_NO_CHECK_SIGNATURE:-0}" == "1" ]]; then
                echo "[dry-run] Stage 2: would run: spack install --cache-only --no-check-signature --deprecated -j ${SPACK_INSTALL_JOBS:-4} --no-checksum gcc@${GCC_VERSION} ~bootstrap +binutils target=${SPACK_TARGET}"
            else
                echo "[dry-run] Stage 2: would run: spack install --cache-only --deprecated -j ${SPACK_INSTALL_JOBS:-4} --no-checksum gcc@${GCC_VERSION} ~bootstrap +binutils target=${SPACK_TARGET}"
            fi
        else
            echo "[dry-run] Stage 2: would run: spack install --deprecated -j ${SPACK_INSTALL_JOBS:-4} --no-checksum gcc@${GCC_VERSION} ~bootstrap +binutils target=${SPACK_TARGET}"
        fi
    fi
    echo "[dry-run] Stage 2: would write ${GCC_BOOTSTRAP_YAML}"
    echo "[dry-run] Stage 2: would publish compiler view at ${COMPILER_VIEW_ROOT}/${GCC_VERSION}"
    echo "[dry-run] Stage 2: would remove temporary ${SPACK_SITE}/etc/spack/compilers.yaml"
else
    # Advisory group ownership check
    _EXPECTED_GROUP="${CSE_GROUP:-$(id -gn)}"
    _ACTUAL_GROUP="$(stat -c '%G' "${SHARED_PATH}/cse" 2>/dev/null || echo '')"
    if [[ -n "${_ACTUAL_GROUP}" && "${_ACTUAL_GROUP}" != "${_EXPECTED_GROUP}" ]]; then
        echo "WARNING: ${SHARED_PATH}/cse is owned by group '${_ACTUAL_GROUP}'," >&2
        echo "         expected '${_EXPECTED_GROUP}' (set via --group)." >&2
        echo "         On a shared HPC system run the one-time setup from the README." >&2
    fi

    umask 002

    # Source the ONE spack instance
    # shellcheck source=/dev/null
    . "${SPACK_SITE}/share/spack/setup-env.sh"

    if [[ -n "${BUILDCACHE_URI:-}" ]]; then
        mkdir -p "${SPACK_SITE}/etc/spack"
        cat > "${SPACK_SITE}/etc/spack/mirrors.yaml" <<EOF
mirrors:
  cse-buildcache: ${BUILDCACHE_URI}
EOF
        if [[ "${SPACK_CACHE_ONLY:-0}" == "1" && "${SPACK_NO_CHECK_SIGNATURE:-0}" != "1" ]]; then
            if command -v timeout >/dev/null 2>&1; then
                timeout 60 spack buildcache keys --install --trust --force || true
            else
                spack buildcache keys --install --trust --force || true
            fi
        fi
    fi

    # Detect OS (e.g. rhel8) — used in compiler YAML entries
    OS_SPACK=$(spack arch --operating-system 2>/dev/null || echo "rhel8")
    # Always use the architecture family (x86_64), NOT spack arch --target which
    # returns microarchitectures like "zen3" or "zen" that break compiler lookup.
    ARCH_SPACK="x86_64"

    # ---- Find highest-versioned system GCC in PATH ----
    # Walk PATH directly; prefer versioned binaries (gcc-13, gcc-12, …)
    # over the plain gcc symlink so we pick the newest available.
    _find_newest_gcc() {
        local best="" best_ver=0
        local dir bin ver
        for dir in $(echo "$PATH" | tr ':' ' '); do
            for bin in "$dir"/gcc "$dir"/gcc-[0-9]*; do
                [[ -x "$bin" ]] || continue
                ver=$("$bin" -dumpversion 2>/dev/null | cut -d. -f1)
                [[ "$ver" =~ ^[0-9]+$ ]] || continue
                (( ver > best_ver )) && { best_ver=$ver; best=$bin; }
            done
        done
        echo "$best"
    }

    SYS_GCC=$(_find_newest_gcc)
    if [[ -z "${SYS_GCC}" ]]; then
        echo "ERROR: No GCC found in PATH. Cannot register a bootstrap compiler." >&2
        exit 1
    fi
    _SGCC_VER="$(${SYS_GCC} -dumpversion)"
    _SGCC_NAME="$(basename "${SYS_GCC}")"
    _SGCC_SUFFIX="${_SGCC_NAME#gcc}"           # e.g. "-8" or ""
    _SGCC_BIN="$(dirname "${SYS_GCC}")"
    _SGPP="${_SGCC_BIN}/g++${_SGCC_SUFFIX}";   [[ -x "${_SGPP}" ]] || _SGPP="${_SGCC_BIN}/g++"
    _SGFC="${_SGCC_BIN}/gfortran${_SGCC_SUFFIX}"; [[ -x "${_SGFC}" ]] || _SGFC="${_SGCC_BIN}/gfortran"
    echo "Stage 2: using system compiler: ${SYS_GCC} (${_SGCC_VER}) to build gcc@${GCC_VERSION}"

    # Register system GCC in SPACK_SITE so spack can use it to build gcc@GCC_VERSION.
    # Writing to etc/spack/ inside the spack tree is always read regardless of
    # SPACK_DISABLE_LOCAL_CONFIG — no `spack compiler add` invocation needed.
    mkdir -p "${SPACK_SITE}/etc/spack"
    cat > "${SPACK_SITE}/etc/spack/compilers.yaml" <<SYSEOF
compilers:
- compiler:
    spec: gcc@${_SGCC_VER}
    paths:
      cc:  ${SYS_GCC}
      cxx: ${_SGPP}
      f77: ${_SGFC}
      fc:  ${_SGFC}
    flags: {}
    operating_system: ${OS_SPACK}
    target: ${ARCH_SPACK}
    modules: []
    environment: {}
    extra_rpaths: []
SYSEOF

    echo "Stage 2: registered system gcc@${_SGCC_VER} as bootstrap compiler"
    spack compiler list

    if [[ "${USE_SYSTEM_GCC}" == "1" ]]; then
        GCC_BIN="${SYS_GCC}"
        GCC_PREFIX="$(dirname "$(dirname "${GCC_BIN}")")"
        GCC_VERSION="${_SGCC_VER}"
        echo "Stage 2: using system gcc@${GCC_VERSION} as the CSE compiler baseline."
    else
        # ---- Install gcc@GCC_VERSION into SPACK_SITE ----
        GCC_BIN="$(_find_installed_gcc_bin)"
        if [[ -n "${GCC_BIN}" && -x "${GCC_BIN}" ]]; then
            echo "Stage 2: gcc@${GCC_VERSION} already installed — skipping build."
        else
            echo "Stage 2: building gcc@${GCC_VERSION} (this may take a while)..."
            _INSTALL_ARGS=(install --deprecated -j "${SPACK_INSTALL_JOBS:-4}" --no-checksum)
            if [[ "${SPACK_CACHE_ONLY:-0}" == "1" ]]; then
                _INSTALL_ARGS+=(--cache-only)
                if [[ "${SPACK_NO_CHECK_SIGNATURE:-0}" == "1" ]]; then
                    _INSTALL_ARGS+=(--no-check-signature)
                fi
            fi
            spack "${_INSTALL_ARGS[@]}" "gcc@${GCC_VERSION}" ~bootstrap +binutils "target=${SPACK_TARGET}"
            GCC_BIN="$(_find_installed_gcc_bin)"
        fi

        if [[ -z "${GCC_BIN}" || ! -x "${GCC_BIN}" ]]; then
            echo "ERROR: cannot locate gcc-${GCC_VERSION} under ${SPACK_SITE}/opt/spack after install" >&2
            exit 1
        fi

        GCC_PREFIX=$(dirname "$(dirname "${GCC_BIN}")")
        echo "Stage 2: gcc@${GCC_VERSION} prefix: ${GCC_PREFIX}"
    fi

    # ---- Write gcc-bootstrap.yaml (packages external, included by spack.yaml) ----
    mkdir -p "${VARIANT_DIR}"
    echo "Stage 2: writing ${GCC_BOOTSTRAP_YAML}..."
    cat > "${GCC_BOOTSTRAP_YAML}" <<EOF
packages:
  gcc:
    externals:
    - spec: gcc@${GCC_VERSION} languages='c,c++,fortran'
      prefix: ${GCC_PREFIX}
      extra_attributes:
        compilers:
          c:       ${GCC_PREFIX}/bin/gcc
          cxx:     ${GCC_PREFIX}/bin/g++
          fortran: ${GCC_PREFIX}/bin/gfortran
    buildable: false
EOF

    echo "Stage 2: publishing compiler view ${COMPILER_VIEW_ROOT}/${GCC_VERSION} -> ${GCC_PREFIX}"
    _publish_compiler_view "${GCC_PREFIX}" "${GCC_VERSION}"

    # The site compilers.yaml is only a temporary bootstrap aid. Stage 4 uses
    # gcc-bootstrap.yaml so compiler registration has one source of truth.
    rm -f "${SPACK_SITE}/etc/spack/compilers.yaml"

    echo "Stage 2: GCC bootstrap complete."
fi

# ------------------------------------------------------------------
# 3. Export SPACK_ROOT for subsequent stages
# ------------------------------------------------------------------
export SPACK_ROOT="${SPACK_SITE}"

if [[ "${DRY_RUN:-0}" != "1" ]]; then
    # shellcheck source=/dev/null
    . "${SPACK_ROOT}/share/spack/setup-env.sh"
    echo "Stage 2: SPACK_ROOT=${SPACK_ROOT}"
fi
