#!/usr/bin/env bash
# Stage 2: Clone/initialise Spack and (for Variant A) bootstrap GCC.
#
# Environment:
#   SHARED_PATH, CSE_RELEASE, CSE_VARIANT  — set by deploy.sh / activate.sh
#   CSE_GROUP                              — owning group for install tree (default: cse)
#   DRY_RUN                                — "1" for dry-run
#   SPACK_VERSION                          — git tag to clone (default: v1.1.1)
set -euo pipefail

: "${SHARED_PATH:?}"
: "${CSE_RELEASE:?}"
: "${CSE_VARIANT:?}"

SPACK_VERSION="${SPACK_VERSION:-v1.1.1}"
SPACK_SITE="${SHARED_PATH}/cse/spack-site"
# Prevent Spack from reading ~/.spack/ config or /etc/spack/ site config.
# Compiler entries are written directly as YAML files and included by
# spack.yaml, so we no longer need SPACK_USER_CONFIG_PATH.
# DISABLE_LOCAL_CONFIG blocks the user-scope config (~/.spack);
# SYSTEM_CONFIG_PATH blocks /etc/spack/ site-wide config that HPC admins
# sometimes pre-populate.
export SPACK_DISABLE_LOCAL_CONFIG=1
export SPACK_USER_CACHE_PATH="${SHARED_PATH}/cse/cache/bootstrap"
export SPACK_SYSTEM_CONFIG_PATH="/dev/null"
VARIANT_DIR="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}"

_run() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "[dry-run]   $*"
    else
        "$@"
    fi
}

# ------------------------------------------------------------------
# Clone Spack into the shared site directory (idempotent)
# ------------------------------------------------------------------
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] Stage 2: would clone spack ${SPACK_VERSION} into ${SPACK_SITE}"
else
    if [[ ! -d "${SPACK_SITE}/.git" ]]; then
        echo "Stage 2: cloning Spack ${SPACK_VERSION} into ${SPACK_SITE}..."
        mkdir -p "$(dirname "${SPACK_SITE}")"
        git clone --depth 1 --branch "${SPACK_VERSION}" \
            https://github.com/spack/spack.git "${SPACK_SITE}"
    else
        echo "Stage 2: Spack already present at ${SPACK_SITE}"
    fi
fi

# ------------------------------------------------------------------
# Bootstrap GCC (both variants build their own GCC via a throwaway
# spack-bootstrap instance so GCC is not entangled with the CSE store)
# ------------------------------------------------------------------
GCC_VERSION="${GCC_VERSION:-13.3.0}"
BOOTSTRAP_DIR="${VARIANT_DIR}/spack-bootstrap"
GCC_BOOTSTRAP_YAML="${VARIANT_DIR}/gcc-bootstrap.yaml"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] Stage 2: would bootstrap GCC ${GCC_VERSION} via ${BOOTSTRAP_DIR}/spack"
    echo "[dry-run]   git clone --depth 1 --branch ${SPACK_VERSION} https://github.com/spack/spack.git ${BOOTSTRAP_DIR}/spack"
    echo "[dry-run]   . ${BOOTSTRAP_DIR}/spack/share/spack/setup-env.sh"
    echo "[dry-run]   spack install -j ${SPACK_INSTALL_JOBS:-4} --no-checksum gcc@${GCC_VERSION} ~bootstrap +binutils"
    echo "[dry-run]   GCC_PREFIX=\$(spack find --format '{prefix}' gcc@${GCC_VERSION}+binutils)"
    echo "[dry-run]   write \${VARIANT_DIR}/gcc-compilers.yaml (gcc@${GCC_VERSION} compiler at \${GCC_PREFIX})"
    echo "[dry-run]   write ${GCC_BOOTSTRAP_YAML} (gcc@${GCC_VERSION} external at \${GCC_PREFIX})"
else
    # Warn if the install root is not owned by the expected group.
    # This is advisory — a mismatch on a personal workdir is fine.
    _EXPECTED_GROUP="${CSE_GROUP:-$(id -gn)}"
    _ACTUAL_GROUP="$(stat -c '%G' "${SHARED_PATH}/cse" 2>/dev/null || echo '')"
    if [[ -n "${_ACTUAL_GROUP}" && "${_ACTUAL_GROUP}" != "${_EXPECTED_GROUP}" ]]; then
        echo "WARNING: ${SHARED_PATH}/cse is owned by group '${_ACTUAL_GROUP}'," >&2
        echo "         expected '${_EXPECTED_GROUP}' (set via --group)." >&2
        echo "         On a shared HPC system run the one-time setup from the README." >&2
    fi

    umask 002

    if grep -q "gcc@${GCC_VERSION}" "${GCC_BOOTSTRAP_YAML}" 2>/dev/null; then
        echo "Stage 2: bootstrap GCC already registered (${GCC_BOOTSTRAP_YAML})"
    else
        mkdir -p "${BOOTSTRAP_DIR}"
        if [[ ! -d "${BOOTSTRAP_DIR}/spack" ]]; then
            git clone --depth 1 --branch "${SPACK_VERSION}" \
                https://github.com/spack/spack.git "${BOOTSTRAP_DIR}/spack"
        fi
        # shellcheck source=/dev/null
        . "${BOOTSTRAP_DIR}/spack/share/spack/setup-env.sh"

        # Detect OS/arch now that spack is on PATH.
        OS_SPACK=$(spack arch --operating-system 2>/dev/null || echo "rhel8")
        TARGET_SPACK=$(spack arch --target 2>/dev/null || echo "x86_64")

        # ---- Bootstrap compiler detection ----
        # Find the highest-versioned GCC in PATH by walking PATH directly.
        # This is more reliable than `compgen -c` (which depends on shell
        # command-completion state) and prefers versioned binaries
        # (gcc-13, gcc-12, …) over the plain `gcc` symlink.
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

        BOOTSTRAP_GCC=$(_find_newest_gcc)
        if [[ -z "${BOOTSTRAP_GCC}" ]]; then
            echo "ERROR: No GCC found in PATH. Cannot register a bootstrap compiler." >&2
            exit 1
        fi
        _BGCC_VER="$(${BOOTSTRAP_GCC} -dumpversion)"
        _BGCC_NAME="$(basename "${BOOTSTRAP_GCC}")"
        _BGCC_SUFFIX="${_BGCC_NAME#gcc}"          # e.g. "-13" or ""
        _BGCC_BIN="$(dirname "${BOOTSTRAP_GCC}")"
        _BGPP="${_BGCC_BIN}/g++${_BGCC_SUFFIX}";  [[ -x "${_BGPP}" ]] || _BGPP="${_BGCC_BIN}/g++"
        _BGFC="${_BGCC_BIN}/gfortran${_BGCC_SUFFIX}"; [[ -x "${_BGFC}" ]] || _BGFC="${_BGCC_BIN}/gfortran"
        echo "Stage 2: registering bootstrap compiler: ${BOOTSTRAP_GCC} (${_BGCC_VER})"
        # Write directly to the bootstrap spack's site scope — read regardless
        # of SPACK_DISABLE_LOCAL_CONFIG, no spack compiler add needed.
        mkdir -p "${BOOTSTRAP_DIR}/spack/etc/spack"
        cat > "${BOOTSTRAP_DIR}/spack/etc/spack/compilers.yaml" << BSEOF
compilers:
- compiler:
    spec: gcc@${_BGCC_VER}
    paths:
      cc:  ${BOOTSTRAP_GCC}
      cxx: ${_BGPP}
      f77: ${_BGFC}
      fc:  ${_BGFC}
    flags: {}
    operating_system: ${OS_SPACK}
    target: ${TARGET_SPACK}
    modules: []
    environment: {}
    extra_rpaths: []
BSEOF
        spack compiler list
        # ---- End bootstrap compiler detection ----

        # Skip build if GCC already in the Spack store.
        if spack find "gcc@${GCC_VERSION}+binutils" &>/dev/null; then
            echo "Stage 2: gcc@${GCC_VERSION} already installed — skipping build."
        else
            echo "Stage 2: bootstrapping GCC ${GCC_VERSION} (this may take a while)..."
            spack install -j "${SPACK_INSTALL_JOBS:-4}" --no-checksum "gcc@${GCC_VERSION}" ~bootstrap +binutils
        fi
        # +binutils uniquely identifies our build; avoids picking up a dependency prefix.
        GCC_PREFIX=$(spack find --format '{prefix}' "gcc@${GCC_VERSION}+binutils" 2>/dev/null | head -n1)
        if [[ -z "${GCC_PREFIX}" || ! -x "${GCC_PREFIX}/bin/gcc" ]]; then
            echo "==> Error: cannot locate gcc@${GCC_VERSION} install prefix (no bin/gcc found)."
            exit 1
        fi
        echo "Stage 2: gcc@${GCC_VERSION} at ${GCC_PREFIX}"
        GCC_COMPILERS_YAML="${VARIANT_DIR}/gcc-compilers.yaml"
        echo "Stage 2: writing compiler config to ${GCC_COMPILERS_YAML}..."
        cat > "${GCC_COMPILERS_YAML}" << EOF
compilers:
- compiler:
    spec: gcc@${GCC_VERSION}
    paths:
      cc:  ${GCC_PREFIX}/bin/gcc
      cxx: ${GCC_PREFIX}/bin/g++
      f77: ${GCC_PREFIX}/bin/gfortran
      fc:  ${GCC_PREFIX}/bin/gfortran
    flags: {}
    operating_system: ${OS_SPACK}
    target: ${TARGET_SPACK}
    modules: []
    environment: {}
    extra_rpaths:
    - ${GCC_PREFIX}/lib64
EOF
        spack compiler list  # verify it's visible

        # Record the freshly-built GCC as an external in a dedicated include
        # file alongside the environment. spack.yaml's `include:` picks this
        # up; stage 4 re-renders of packages.yaml/config.yaml/modules.yaml
        # leave this file untouched. `cat >` (overwrite) is intentional —
        # makes re-runs idempotent and lets the caller change GCC_PREFIX.
        if ! grep -q "gcc@${GCC_VERSION}" "${GCC_BOOTSTRAP_YAML}" 2>/dev/null; then
            echo "Stage 2: writing gcc@${GCC_VERSION} external to ${GCC_BOOTSTRAP_YAML}..."
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
        fi
    fi
fi

# ------------------------------------------------------------------
# Export SPACK_ROOT for subsequent stages
# ------------------------------------------------------------------
export SPACK_ROOT="${VARIANT_DIR}/spack-bootstrap/spack"

if [[ "${DRY_RUN:-0}" != "1" ]]; then
    # shellcheck source=/dev/null
    . "${SPACK_ROOT}/share/spack/setup-env.sh"
    echo "Stage 2: SPACK_ROOT=${SPACK_ROOT}"
fi
