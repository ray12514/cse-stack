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
VARIANT_DIR="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}"
GCC_BOOTSTRAP_YAML="${VARIANT_DIR}/gcc-bootstrap.yaml"
NETWORK_MODE="${CSE_NETWORK_MODE:-online}"
LOCKFILE_PATH="${AUTHORITATIVE_LOCKFILE:-}"
# Full Spack isolation: no ~/.spack/ config, no /etc/spack/ site config,
# and no writes to ~/.spack/cache — all cache lives under the shared path.
export SPACK_DISABLE_LOCAL_CONFIG=1
export SPACK_USER_CACHE_PATH="${SHARED_PATH}/cse/cache/spack"
export SPACK_SYSTEM_CONFIG_PATH="/dev/null"

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

reset_spack_views() {
    local views_root="${VARIANT_DIR}/views"
    local view_path=""

    for view_path in \
        "${views_root}/modules" "${views_root}/._modules" \
        "${views_root}/mpi" "${views_root}/._mpi" \
        "${views_root}/serial" "${views_root}/._serial"; do
        case "${view_path}" in
            "${VARIANT_DIR}/views/"*) ;;
            *)
                echo "ERROR: refusing to remove unexpected view path: ${view_path}" >&2
                exit 1
                ;;
        esac
        if [[ -e "${view_path}" || -L "${view_path}" ]]; then
            echo "Stage 4: removing stale Spack view ${view_path}"
            rm -rf "${view_path}"
        fi
    done
}

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] Stage 4: would render config.yaml, modules.yaml, spack.yaml"
    _render "config.yaml.j2"  "${VARIANT_ENV_DIR}/config.yaml"
    _render "modules.yaml.j2" "${VARIANT_ENV_DIR}/modules.yaml"
    _render "spack.yaml.j2"   "${VARIANT_ENV_DIR}/spack.yaml"
    if [[ -n "${MIRROR_PATH:-}" ]]; then
        echo "[dry-run] Stage 4: would add source mirror ${MIRROR_PATH} to mirrors.yaml"
    fi
    if [[ -n "${BUILDCACHE_URI:-}" ]]; then
        echo "[dry-run] Stage 4: would add build cache ${BUILDCACHE_URI} to mirrors.yaml"
    fi
    echo "[dry-run] Stage 4: would run:"
    echo "[dry-run]   spack env activate -d ${VARIANT_ENV_DIR}"
    if [[ -n "${LOCKFILE_PATH}" ]]; then
        echo "[dry-run]   cp ${LOCKFILE_PATH} ${VARIANT_ENV_DIR}/spack.lock"
        echo "[dry-run]   # authoritative lockfile present; skip concretize"
    else
        echo "[dry-run]   remove stale Spack views under ${VARIANT_DIR}/views/{modules,mpi,serial}"
        echo "[dry-run]   spack concretize --fresh"
    fi
    if [[ -n "${MIRROR_PATH:-}" || -n "${BUILDCACHE_URI:-}" ]]; then
        echo "[dry-run]   spack mirror list"
    fi
    echo "[dry-run]   remove stale Spack views under ${VARIANT_DIR}/views/{modules,mpi,serial}"
    if [[ "${SPACK_CACHE_ONLY:-0}" == "1" ]]; then
        _DRY_RUN_INSTALL="spack install --cache-only"
    else
        _DRY_RUN_INSTALL="spack install"
    fi
    if [[ "${SPACK_NO_CHECK_SIGNATURE:-0}" == "1" && -n "${BUILDCACHE_URI:-}" ]]; then
        _DRY_RUN_INSTALL="${_DRY_RUN_INSTALL} --no-check-signature"
    fi
    echo "[dry-run]   ${_DRY_RUN_INSTALL} --concurrent-packages ${SPACK_INSTALL_JOBS:-4} --jobs ${SPACK_MAKE_JOBS:-16} --fail-fast"
    if [[ "${SPACK_CACHE_ONLY:-0}" != "1" && -n "${BUILDCACHE_URI:-}" ]]; then
        echo "[dry-run]   spack buildcache push --unsigned ${BUILDCACHE_URI}"
    fi
    return 0 2>/dev/null || exit 0
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

if [[ ! -f "${GCC_BOOTSTRAP_YAML}" ]]; then
    echo "ERROR: missing ${GCC_BOOTSTRAP_YAML}." >&2
    echo "       Stage 2 must complete successfully before Stage 4 can concretize." >&2
    exit 1
fi

if [[ "${NETWORK_MODE}" != "online" && -z "${MIRROR_PATH:-}" ]]; then
    echo "ERROR: network mode ${NETWORK_MODE} requires a local source mirror." >&2
    exit 1
fi
if [[ "${NETWORK_MODE}" != "online" && -z "${LOCKFILE_PATH}" ]]; then
    echo "ERROR: network mode ${NETWORK_MODE} requires an authoritative lockfile." >&2
    exit 1
fi

# Write mirrors.yaml if a source mirror or build cache was provided
if [[ -n "${MIRROR_PATH:-}" || -n "${BUILDCACHE_URI:-}" ]]; then
    : > "${VARIANT_ENV_DIR}/mirrors.yaml"
    printf 'mirrors:\n' >> "${VARIANT_ENV_DIR}/mirrors.yaml"
    if [[ -n "${MIRROR_PATH:-}" ]]; then
        if [[ "${MIRROR_PATH}" != *://* ]]; then
            _MIRROR_URI="file://${MIRROR_PATH}"
        else
            _MIRROR_URI="${MIRROR_PATH}"
        fi
        echo "Stage 4: configuring source mirror at ${_MIRROR_URI}..."
        printf '  cse-local: %s\n' "${_MIRROR_URI}" >> "${VARIANT_ENV_DIR}/mirrors.yaml"
    fi
    if [[ -n "${BUILDCACHE_URI:-}" ]]; then
        echo "Stage 4: configuring build cache at ${BUILDCACHE_URI}..."
        printf '  cse-buildcache: %s\n' "${BUILDCACHE_URI}" >> "${VARIANT_ENV_DIR}/mirrors.yaml"
    fi
fi
_render "spack.yaml.j2"   "${VARIANT_ENV_DIR}/spack.yaml"

# Activate Spack — both variants use the shared site Spack instance.
if [[ -z "${SPACK_ROOT:-}" ]]; then
    SPACK_ROOT="${SHARED_PATH}/cse/spack-site"
fi
# shellcheck source=/dev/null
. "${SPACK_ROOT}/share/spack/setup-env.sh"

if [[ "${SPACK_CACHE_ONLY:-0}" == "1" && "${SPACK_NO_CHECK_SIGNATURE:-0}" != "1" && -n "${BUILDCACHE_URI:-}" ]]; then
    if command -v timeout >/dev/null 2>&1; then
        timeout 60 spack buildcache keys --install --trust --force || true
    else
        spack buildcache keys --install --trust --force || true
    fi
fi

echo "Stage 4: activating Spack environment at ${VARIANT_ENV_DIR}..."
spack env activate -d "${VARIANT_ENV_DIR}"
if [[ -n "${MIRROR_PATH:-}" || -n "${BUILDCACHE_URI:-}" ]]; then
    echo "Stage 4: active Spack mirrors:"
    spack mirror list || true
fi
reset_spack_views

if [[ -n "${LOCKFILE_PATH}" ]]; then
    echo "Stage 4: reusing authoritative lockfile ${LOCKFILE_PATH}..."
    cp "${LOCKFILE_PATH}" "${VARIANT_ENV_DIR}/spack.lock"
else
    if [[ -f "${VARIANT_ENV_DIR}/spack.lock" ]]; then
        rm -f "${VARIANT_ENV_DIR}/spack.lock"
    fi
    echo "Stage 4: concretizing..."
    spack concretize --fresh
fi

echo "Stage 4: installing (this will take a while on first run)..."
reset_spack_views
_INSTALL_ARGS=(install --concurrent-packages "${SPACK_INSTALL_JOBS:-4}" --jobs "${SPACK_MAKE_JOBS:-16}" --fail-fast)
if [[ "${SPACK_NO_CHECK_SIGNATURE:-0}" == "1" && -n "${BUILDCACHE_URI:-}" ]]; then
    _INSTALL_ARGS+=(--no-check-signature)
fi
if [[ "${SPACK_CACHE_ONLY:-0}" == "1" ]]; then
    _INSTALL_ARGS+=(--cache-only)
fi
spack "${_INSTALL_ARGS[@]}"

if [[ "${SPACK_CACHE_ONLY:-0}" != "1" && -n "${BUILDCACHE_URI:-}" ]]; then
    echo "Stage 4: pushing installed packages to build cache at ${BUILDCACHE_URI}..."
    spack buildcache push --unsigned "${BUILDCACHE_URI}"
fi

echo "Stage 4: done."
