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
# Prevent Spack from reading ~/.spack/ config or /etc/spack/ site config,
# and redirect both the user cache and user config out of the home directory.
# DISABLE_LOCAL_CONFIG blocks config scopes; USER_CACHE_PATH redirects the
# cache; USER_CONFIG_PATH redirects the user-scope config (where `spack
# compiler add` writes compilers.yaml); SYSTEM_CONFIG_PATH blocks /etc/spack/
# site-wide config that HPC admins sometimes pre-populate.
export SPACK_DISABLE_LOCAL_CONFIG=1
export SPACK_USER_CACHE_PATH="${SHARED_PATH}/cse/cache/bootstrap"
export SPACK_USER_CONFIG_PATH="${SHARED_PATH}/cse/${CSE_RELEASE}/spack-user-config"
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
BOOTSTRAP_PREFIX="${VARIANT_DIR}/bootstrap/gcc-${GCC_VERSION}"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] Stage 2: would bootstrap GCC ${GCC_VERSION} at ${BOOTSTRAP_PREFIX}"
    echo "[dry-run]   git clone --depth 1 --branch ${SPACK_VERSION} https://github.com/spack/spack.git ${BOOTSTRAP_DIR}/spack"
    echo "[dry-run]   . ${BOOTSTRAP_DIR}/spack/share/spack/setup-env.sh"
    echo "[dry-run]   spack install -j ${SPACK_INSTALL_JOBS:-4} --no-checksum gcc@${GCC_VERSION} ~bootstrap +binutils"
    echo "[dry-run]   spack view copy ${BOOTSTRAP_PREFIX} /<hash>"
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

    if [[ -f "${BOOTSTRAP_PREFIX}/bin/gcc" ]]; then
        echo "Stage 2: bootstrap GCC already present at ${BOOTSTRAP_PREFIX}"
    else
        echo "Stage 2: bootstrapping GCC ${GCC_VERSION} (this may take a while)..."
        mkdir -p "${BOOTSTRAP_DIR}"
        if [[ ! -d "${BOOTSTRAP_DIR}/spack" ]]; then
            git clone --depth 1 --branch "${SPACK_VERSION}" \
                https://github.com/spack/spack.git "${BOOTSTRAP_DIR}/spack"
        fi
        # shellcheck source=/dev/null
        . "${BOOTSTRAP_DIR}/spack/share/spack/setup-env.sh"

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

        # Ensure the redirected user-config dir exists before any
        # `spack compiler` command tries to write compilers.yaml to it.
        mkdir -p "${SPACK_USER_CONFIG_PATH}/linux"

        BOOTSTRAP_GCC=$(_find_newest_gcc)
        if [[ -z "${BOOTSTRAP_GCC}" ]]; then
            echo "ERROR: No GCC found in PATH. Cannot register a bootstrap compiler." >&2
            exit 1
        fi
        echo "Stage 2: registering bootstrap compiler: ${BOOTSTRAP_GCC} ($(${BOOTSTRAP_GCC} -dumpversion))"
        # Writes compilers.yaml under SPACK_USER_CONFIG_PATH (redirected
        # away from ~/.spack), so no --scope flag is required.
        spack compiler add "$(dirname "${BOOTSTRAP_GCC}")"
        spack compiler list
        # ---- End bootstrap compiler detection ----

        spack install -j "${SPACK_INSTALL_JOBS:-4}" --no-checksum "gcc@${GCC_VERSION}" ~bootstrap +binutils
        GCC_HASH=$(spack find --format '{hash:7}' "gcc@${GCC_VERSION}" | head -n1)
        if [[ -z "${GCC_HASH}" ]]; then
            echo "==> Error: gcc@${GCC_VERSION} not found after install." >&2
            exit 1
        fi
        # Select the installed package by hash only — `/gcc@version/hash` is
        # fragile across Spack releases; `/<hash>` is the canonical form.
        spack view --verbose copy "${BOOTSTRAP_PREFIX}" "/${GCC_HASH}"
        echo "Stage 2: bootstrap GCC installed at ${BOOTSTRAP_PREFIX}"

        # Register the freshly-built GCC as the primary compiler from the
        # view path directly. Avoids `spack location -i`, which fails with
        # "Spec matches no installed packages" when the env/scope context
        # changes between install and lookup. Downstream stages (stage 4)
        # will concretize using this version, not the system GCC that was
        # only needed to compile it. Writes to the redirected
        # SPACK_USER_CONFIG_PATH, never to ~/.spack.
        echo "Stage 2: registering gcc@${GCC_VERSION} as primary compiler from ${BOOTSTRAP_PREFIX}..."
        spack compiler add "${BOOTSTRAP_PREFIX}/bin"
        spack compiler list

        # Record the freshly-built GCC as an external in the environment's
        # packages.yaml so downstream stages reuse it (faster, no rebuild).
        # Idempotent: only appends if the file exists and the entry isn't
        # already present.
        PKGS_YAML="${VARIANT_DIR}/packages.yaml"
        if [[ -f "${PKGS_YAML}" ]] && ! grep -q "gcc@${GCC_VERSION}" "${PKGS_YAML}"; then
            echo "Stage 2: adding gcc@${GCC_VERSION} external to ${PKGS_YAML}..."
            cat >> "${PKGS_YAML}" <<EOF

  # Bootstrap GCC built by stage2 — added automatically
  gcc:
    externals:
    - spec: gcc@${GCC_VERSION} languages='c,c++,fortran'
      prefix: ${BOOTSTRAP_PREFIX}
      extra_attributes:
        compilers:
          c:       ${BOOTSTRAP_PREFIX}/bin/gcc
          cxx:     ${BOOTSTRAP_PREFIX}/bin/g++
          fortran: ${BOOTSTRAP_PREFIX}/bin/gfortran
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
