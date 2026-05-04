#!/usr/bin/env bash
# Stage 4: Render remaining templates and run spack concretize + install.
#
# Environment:
#   SHARED_PATH, CSE_RELEASE, CSE_VARIANT  — set by deploy.sh / activate.sh
#   CSE_GROUP                              — owning group for install tree (default: caller's primary group)
#   PROFILE_FILE                           — path to Cluster Inspector YAML (Stage 1 output)
#   SPACK_ROOT                             — set by Stage 2
#   DRY_RUN                                — "1" for dry-run
set -euo pipefail

: "${SHARED_PATH:?}"
: "${CSE_RELEASE:?}"
: "${CSE_VARIANT:?}"
: "${REPO_ROOT:?stage4_build.sh must be run via deploy.sh}"

VARIANT_ENV_DIR="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}/env"
# Isolate from personal ~/.spack/ config — prevents stale user-scope entries
# (wrong %compiler constraints, old package versions, etc.) from overriding
# the environment's authoritative packages.yaml.
export SPACK_DISABLE_LOCAL_CONFIG=1

_render() {
    local tpl="$1" out="$2"
    local args=(
        --template  "${REPO_ROOT}/templates/${tpl}"
        --variant   "${CSE_VARIANT}"
        --shared-path "${SHARED_PATH}"
        --release   "${CSE_RELEASE}"
    )
    if [[ -n "${PROFILE_FILE:-}" && -f "${PROFILE_FILE}" ]]; then
        args+=(--profile "${PROFILE_FILE}")
    fi
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "[dry-run] Stage 4: rendering ${tpl} → ${out}"
        python3 "${REPO_ROOT}/scripts/lib/render.py" "${args[@]}" --dry-run
    else
        python3 "${REPO_ROOT}/scripts/lib/render.py" "${args[@]}" --output "${out}"
    fi
}

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] Stage 4: would render config.yaml, modules.yaml, spack.yaml"
    _render "config.yaml.j2"  "${VARIANT_ENV_DIR}/config.yaml"
    _render "modules.yaml.j2" "${VARIANT_ENV_DIR}/modules.yaml"
    _render "spack.yaml.j2"   "${VARIANT_ENV_DIR}/spack.yaml"
    if [[ -n "${MIRROR_PATH:-}" ]]; then
        echo "[dry-run] Stage 4: would write mirrors.yaml → ${MIRROR_PATH}"
    fi
    echo "[dry-run] Stage 4: would run:"
    echo "[dry-run]   spack env activate -d ${VARIANT_ENV_DIR}"
    echo "[dry-run]   spack concretize --fresh"
    echo "[dry-run]   spack install --fail-fast"
    exit 0
fi

# ------------------------------------------------------------------
# Group ownership advisory check
# ------------------------------------------------------------------
_EXPECTED_GROUP="${CSE_GROUP:-$(id -gn)}"
_ACTUAL_GROUP="$(stat -c '%G' "${SHARED_PATH}/cse" 2>/dev/null || echo '')"
if [[ -n "${_ACTUAL_GROUP}" && "${_ACTUAL_GROUP}" != "${_EXPECTED_GROUP}" ]]; then
    echo "WARNING: ${SHARED_PATH}/cse is owned by group '${_ACTUAL_GROUP}'," >&2
    echo "         expected '${_EXPECTED_GROUP}' (set via --group)." >&2
    echo "         On a shared HPC system run the one-time setup from the README." >&2
fi

# ------------------------------------------------------------------
# Install-meta safeguard: prevent personal and shared builds at the same path
# ------------------------------------------------------------------
_META_FILE="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}/.cse-install-meta"
_THIS_USER="$(id -un)"
if [[ -f "${_META_FILE}" ]]; then
    _META_USER="$(grep '^install_user:' "${_META_FILE}" | awk '{print $2}')"
    _META_GROUP="$(grep '^install_group:' "${_META_FILE}" | awk '{print $2}')"
    if [[ "${_META_USER}" != "${_THIS_USER}" || "${_META_GROUP}" != "${_EXPECTED_GROUP}" ]]; then
        echo "WARNING: This install path was previously built by user '${_META_USER}'" >&2
        echo "         (group '${_META_GROUP}'). You are '${_THIS_USER}' (group '${_EXPECTED_GROUP}')." >&2
        echo "         Mixing personal and shared builds at the same path may corrupt the install." >&2
        echo "         Use a different --release tag or --shared-path to keep them separate." >&2
    fi
fi

umask 002
mkdir -p "${VARIANT_ENV_DIR}"

# Write (or refresh) install metadata
mkdir -p "$(dirname "${_META_FILE}")"
cat > "${_META_FILE}" <<EOF
install_user: ${_THIS_USER}
install_group: ${_EXPECTED_GROUP}
install_date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
variant: ${CSE_VARIANT}
release: ${CSE_RELEASE}
EOF

echo "Stage 4: rendering config.yaml, modules.yaml, spack.yaml..."
_render "config.yaml.j2"  "${VARIANT_ENV_DIR}/config.yaml"
_render "modules.yaml.j2" "${VARIANT_ENV_DIR}/modules.yaml"
_render "spack.yaml.j2"   "${VARIANT_ENV_DIR}/spack.yaml"

# Write mirrors.yaml if a local mirror was provided
if [[ -n "${MIRROR_PATH:-}" ]]; then
    # Normalise to a file:// URI if a plain directory path was given
    if [[ "${MIRROR_PATH}" != *://* ]]; then
        _MIRROR_URI="file://${MIRROR_PATH}"
    else
        _MIRROR_URI="${MIRROR_PATH}"
    fi
    echo "Stage 4: configuring local mirror at ${_MIRROR_URI}..."
    cat > "${VARIANT_ENV_DIR}/mirrors.yaml" <<EOF
mirrors:
  cse-local: ${_MIRROR_URI}
EOF
fi

# Activate Spack
if [[ -z "${SPACK_ROOT:-}" ]]; then
    if [[ "${CSE_VARIANT}" == "v1-minimal-externals" ]]; then
        SPACK_ROOT="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}/spack-bootstrap/spack"
    else
        SPACK_ROOT="${SHARED_PATH}/cse/spack-site"
    fi
fi
# shellcheck source=/dev/null
. "${SPACK_ROOT}/share/spack/setup-env.sh"

echo "Stage 4: activating Spack environment at ${VARIANT_ENV_DIR}..."
spack env activate -d "${VARIANT_ENV_DIR}"

echo "Stage 4: concretizing..."
spack concretize --fresh

echo "Stage 4: installing (this will take a while on first run)..."
spack install --fail-fast

echo "Stage 4: done."
