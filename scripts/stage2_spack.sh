#!/usr/bin/env bash
# Stage 2: Clone/initialise Spack and (for Variant A) bootstrap GCC.
#
# Environment:
#   SHARED_PATH, CSE_RELEASE, CSE_VARIANT  — set by deploy.sh / activate.sh
#   DRY_RUN                                — "1" for dry-run
#   SPACK_VERSION                          — git tag to clone (default: v1.2.0)
set -euo pipefail

: "${SHARED_PATH:?}"
: "${CSE_RELEASE:?}"
: "${CSE_VARIANT:?}"

SPACK_VERSION="${SPACK_VERSION:-v1.2.0}"
SPACK_SITE="${SHARED_PATH}/cse/spack-site"
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
# Variant A: bootstrap GCC
# (uses a throwaway spack-bootstrap instance so GCC is not entangled
#  with the CSE store concretization)
# ------------------------------------------------------------------
if [[ "${CSE_VARIANT}" == "v1-minimal-externals" ]]; then
    GCC_VERSION="${GCC_VERSION:-13.2.0}"    # TODO: confirm GCC version for Variant A
    BOOTSTRAP_DIR="${VARIANT_DIR}/spack-bootstrap"
    BOOTSTRAP_PREFIX="${VARIANT_DIR}/bootstrap/gcc-${GCC_VERSION}"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "[dry-run] Stage 2 (Variant A): would bootstrap GCC ${GCC_VERSION} at ${BOOTSTRAP_PREFIX}"
        echo "[dry-run]   git clone --depth 1 --branch ${SPACK_VERSION} https://github.com/spack/spack.git ${BOOTSTRAP_DIR}/spack"
        echo "[dry-run]   . ${BOOTSTRAP_DIR}/spack/share/spack/setup-env.sh"
        echo "[dry-run]   spack install --no-checksum gcc@${GCC_VERSION} ~bootstrap +binutils"
        echo "[dry-run]   spack view copy ${BOOTSTRAP_PREFIX} /gcc@${GCC_VERSION}/<hash>"
    else
        # Verify group cse + setgid on the shared root before writing anything
        if [[ "$(stat -c '%G' "${SHARED_PATH}/cse" 2>/dev/null)" != "cse" ]]; then
            echo "ERROR: ${SHARED_PATH}/cse is not owned by group cse." >&2
            echo "       Run the one-time setup from the README first." >&2
            exit 1
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
            spack install --no-checksum "gcc@${GCC_VERSION}" ~bootstrap +binutils
            GCC_HASH=$(spack find --format '{hash:7}' "gcc@${GCC_VERSION}" | head -n1)
            spack view --verbose copy "${BOOTSTRAP_PREFIX}" "/gcc@${GCC_VERSION}/${GCC_HASH}"
            echo "Stage 2: bootstrap GCC installed at ${BOOTSTRAP_PREFIX}"
        fi
    fi
fi

# ------------------------------------------------------------------
# Export SPACK_ROOT for subsequent stages
# ------------------------------------------------------------------
if [[ "${CSE_VARIANT}" == "v1-minimal-externals" ]]; then
    export SPACK_ROOT="${VARIANT_DIR}/spack-bootstrap/spack"
else
    export SPACK_ROOT="${SPACK_SITE}"
fi

if [[ "${DRY_RUN:-0}" != "1" ]]; then
    # shellcheck source=/dev/null
    . "${SPACK_ROOT}/share/spack/setup-env.sh"
    echo "Stage 2: SPACK_ROOT=${SPACK_ROOT}"
fi
