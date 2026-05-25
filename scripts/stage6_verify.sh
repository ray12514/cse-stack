#!/usr/bin/env bash
# Stage 6: Verify the installed CSE release.
#
# Runs Spack integrity checks, then validates the user-facing module workflow in
# a clean module environment so inherited login-shell modules do not mask
# conflicts or missing site externals.
set -euo pipefail

: "${SHARED_PATH:?}"
: "${CSE_RELEASE:?}"
: "${CSE_VARIANT:?}"
: "${REPO_ROOT:?stage6_verify.sh must be run via deploy.sh}"

VARIANT_ENV_DIR="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}/env"
VARIANT_DIR="${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}"
SITE_MODULE_PATH="${SITE_MODULE_PATH:-${SHARED_PATH}/cse/modulefiles}"
VERIFY_DIR="${VARIANT_DIR}/verify"
SUMMARY="${VERIFY_DIR}/summary.txt"
WORK_DIR="${VERIFY_DIR}/work"
EXTERNAL_MODULES_FILE="${VERIFY_DIR}/external-modules.txt"
PUBLIC_MODULES_FILE="${VERIFY_DIR}/public-modules.txt"
STRICT="${CSE_VERIFY_STRICT:-0}"
RUNTIME="${CSE_VERIFY_RUNTIME:-0}"
export SPACK_DISABLE_LOCAL_CONFIG=1
export SPACK_USER_CACHE_PATH="${SHARED_PATH}/cse/cache/spack"
export SPACK_SYSTEM_CONFIG_PATH="/dev/null"
export SPACK_USER_CONFIG_PATH="/dev/null"

compiler_upper="$(echo "${CSE_VARIANT%%-*}" | tr '[:lower:]' '[:upper:]')"
mpi_lane="${CSE_VARIANT#*-}"
if [[ "${mpi_lane}" == "serial" ]]; then
    init_name="${compiler_upper}/serial"
else
    init_name="${compiler_upper}/mpi-${mpi_lane}"
fi
init_current="cse-init/${init_name}"
init_versioned="cse-init/${CSE_RELEASE}/${init_name}"

render_stage6_list() {
    local list_name="$1"
    local args=(
        --list "${list_name}"
        --variant "${CSE_VARIANT}"
        --shared-path "${SHARED_PATH}"
        --release "${CSE_RELEASE}"
    )
    if [[ -n "${PROFILE_FILE:-}" && -f "${PROFILE_FILE}" ]]; then
        args+=(--profile "${PROFILE_FILE}")
    fi
    python3 "${REPO_ROOT}/scripts/lib/render.py" "${args[@]}"
}

log() {
    echo "$*"
    printf '%s\n' "$*" >> "${SUMMARY}"
}

run_required() {
    local label="$1"
    shift
    log ""
    log "== ${label}"
    if "$@" >> "${SUMMARY}" 2>&1; then
        log "PASS: ${label}"
    else
        log "FAIL: ${label}"
        return 1
    fi
}

run_optional() {
    local label="$1"
    shift
    log ""
    log "== ${label}"
    if "$@" >> "${SUMMARY}" 2>&1; then
        log "PASS: ${label}"
    elif [[ "${STRICT}" == "1" ]]; then
        log "FAIL: ${label}"
        return 1
    else
        log "WARN: ${label}"
    fi
}

verify_local_manifest() {
    # Use a per-call scratch dir so cleanup is unambiguous. A `trap ... RETURN`
    # set inside a function leaks to subsequent function returns unless the
    # function has the `trace` attribute or `set -T` is in effect — neither
    # holds here, so we clean up explicitly instead.
    local scratch all_hashes external_hashes local_hashes rc=0
    scratch="$(mktemp -d "${VERIFY_DIR}/spack-verify.XXXXXX")"
    all_hashes="${scratch}/all"
    external_hashes="${scratch}/external"
    local_hashes="${scratch}/local"

    spack find -H | sort > "${all_hashes}"
    spack find -e -H | sort > "${external_hashes}"
    comm -23 "${all_hashes}" "${external_hashes}" > "${local_hashes}"

    if [[ ! -s "${local_hashes}" ]]; then
        echo "no non-external Spack installs found to verify"
        rm -rf "${scratch}"
        return 1
    fi

    xargs spack verify manifest < "${local_hashes}" || rc=$?
    rm -rf "${scratch}"
    return "${rc}"
}

verify_public_libraries() {
    local package_names=()
    mapfile -t package_names < <(awk -F/ '/^cse\/[^/]+\// { print $2 }' "${PUBLIC_MODULES_FILE}" | sort -u)

    if [[ "${#package_names[@]}" -eq 0 ]]; then
        echo "no public CSE package modules found to verify"
        return 1
    fi

    spack verify libraries "${package_names[@]}"
}

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] Stage 6: would run:"
    echo "[dry-run]   spack env activate -d ${VARIANT_ENV_DIR}"
    echo "[dry-run]   spack verify manifest for non-external installed specs"
    echo "[dry-run]   spack verify libraries for public CSE package modules"
    echo "[dry-run]   purge/reset modules, load exact external modules from packages.yaml"
    echo "[dry-run]   module use ${SITE_MODULE_PATH}"
    echo "[dry-run]   module load ${init_versioned}"
    echo "[dry-run]   compile C/C++/Fortran plus package-specific smoke checks when present"
    echo "[dry-run]   verify Miniforge conda command when present"
    echo "[dry-run]   compile MPI smoke checks only for MPI variants"
    if [[ "${RUNTIME}" == "1" ]]; then
        echo "[dry-run]   run serial smoke binaries and MPI launcher checks"
    fi
    return 0 2>/dev/null || exit 0
fi

mkdir -p "${VERIFY_DIR}" "${WORK_DIR}"
: > "${SUMMARY}"

log "Stage 6: verifying ${CSE_RELEASE}/${CSE_VARIANT}"
log "summary: ${SUMMARY}"

if [[ ! -f "${VARIANT_ENV_DIR}/spack.lock" ]]; then
    log "FAIL: missing ${VARIANT_ENV_DIR}/spack.lock"
    exit 1
fi

if [[ -z "${SPACK_ROOT:-}" ]]; then
    SPACK_ROOT="${SHARED_PATH}/cse/spack-site"
fi
# shellcheck source=/dev/null
. "${SPACK_ROOT}/share/spack/setup-env.sh"

log ""
log "Stage 6: activating Spack environment at ${VARIANT_ENV_DIR}"
spack env activate -d "${VARIANT_ENV_DIR}" >> "${SUMMARY}" 2>&1

render_stage6_list public-modules | sort -u > "${PUBLIC_MODULES_FILE}"

run_required "spack verify manifest" verify_local_manifest
run_required "spack verify libraries" verify_public_libraries

python3 - "${VARIANT_ENV_DIR}/packages.yaml" > "${EXTERNAL_MODULES_FILE}" <<'PY'
import sys
from pathlib import Path

import yaml

path = Path(sys.argv[1])
if not path.exists():
    sys.exit(0)

data = yaml.safe_load(path.read_text()) or {}
seen = set()
for pkg in (data.get("packages") or {}).values():
    if not isinstance(pkg, dict):
        continue
    for ext in pkg.get("externals") or []:
        for module in ext.get("modules") or []:
            module = str(module).strip()
            if module and module not in seen:
                seen.add(module)
                print(module)
PY

module_smoke() {
    init_module_command() {
        if type module >/dev/null 2>&1; then
            return 0
        fi
        local init_file=""
        for init_file in \
            "${MODULESHOME:-}/init/bash" \
            /usr/share/lmod/lmod/init/bash \
            /usr/share/Modules/init/bash \
            /etc/profile.d/lmod.sh \
            /etc/profile.d/modules.sh; do
            if [[ -n "${init_file}" && -f "${init_file}" ]]; then
                # shellcheck source=/dev/null
                source "${init_file}"
                if type module >/dev/null 2>&1; then
                    return 0
                fi
            fi
        done
        echo "module command is not available"
        return 1
    }

    first_module() {
        local pattern="$1"
        grep -E "${pattern}" "${PUBLIC_MODULES_FILE}" | head -1 || true
    }

    compile_serial_smokes() {
        "${CSE_CC}" "${WORK_DIR}/c_hello.c" -o "${WORK_DIR}/c_hello"
        "${CSE_CXX}" "${WORK_DIR}/cxx_hello.cpp" -o "${WORK_DIR}/cxx_hello"
        "${CSE_FC}" "${WORK_DIR}/fortran_hello.f90" -o "${WORK_DIR}/fortran_hello"
        if [[ "${RUNTIME}" == "1" ]]; then
            "${WORK_DIR}/c_hello"
            "${WORK_DIR}/cxx_hello"
            "${WORK_DIR}/fortran_hello"
        fi
    }

    init_module_command
    module purge >/dev/null 2>&1 || module reset >/dev/null 2>&1 || true

    while IFS= read -r external_module; do
        [[ -n "${external_module}" ]] || continue
        echo "loading external module ${external_module}"
        module load "${external_module}"
    done < "${EXTERNAL_MODULES_FILE}"

    module use "${SITE_MODULE_PATH}"
    module load "${init_versioned}" || module load "${init_current}"

    [[ -n "${CSE_GCC_ROOT:-}" && -d "${CSE_GCC_ROOT}" ]]
    [[ -n "${CSE_CC:-}" && -x "${CSE_CC}" ]]
    [[ -n "${CSE_CXX:-}" && -x "${CSE_CXX}" ]]
    [[ -n "${CSE_FC:-}" && -x "${CSE_FC}" ]]

    cat > "${WORK_DIR}/c_hello.c" <<'EOF'
#include <stdio.h>
int main(void) { puts("cse-c-ok"); return 0; }
EOF
    cat > "${WORK_DIR}/cxx_hello.cpp" <<'EOF'
#include <iostream>
int main() { std::cout << "cse-cxx-ok\n"; return 0; }
EOF
    cat > "${WORK_DIR}/fortran_hello.f90" <<'EOF'
program hello
  print *, "cse-fortran-ok"
end program hello
EOF
    compile_serial_smokes

    if [[ "${mpi_lane}" != "serial" ]]; then
        local mpi_module=""
        mpi_module="$(first_module '^cse/(openmpi|mpich|cray-mpich)/')"
        if [[ -n "${mpi_module}" ]]; then
            module load "${mpi_module}"
            cat > "${WORK_DIR}/mpi_hello.c" <<'EOF'
#include <mpi.h>
int main(int argc, char **argv) {
  MPI_Init(&argc, &argv);
  MPI_Finalize();
  return 0;
}
EOF
            # Require an actual MPI wrapper. Falling back to a bare `cc` would
            # silently compile against host headers (or fail at link time with
            # a confusing message); both outcomes mask the real failure mode —
            # that the loaded MPI module did not put a wrapper on PATH.
            local mpi_cc=""
            mpi_cc="$(command -v mpicc || command -v mpicxx || command -v mpic++ || true)"
            if [[ -z "${mpi_cc}" ]]; then
                echo "no MPI compiler wrapper (mpicc/mpicxx) found on PATH after loading ${mpi_module}"
                return 1
            fi
            "${mpi_cc}" "${WORK_DIR}/mpi_hello.c" -o "${WORK_DIR}/mpi_hello"
            if [[ "${RUNTIME}" == "1" ]]; then
                if command -v srun >/dev/null 2>&1; then
                    srun -n 2 "${WORK_DIR}/mpi_hello"
                elif command -v mpiexec >/dev/null 2>&1; then
                    mpiexec -n 2 "${WORK_DIR}/mpi_hello"
                else
                    echo "no MPI launcher found for runtime check"
                    return 1
                fi
            fi
        fi
    fi

    local hdf5_module=""
    if [[ "${mpi_lane}" == "serial" ]]; then
        hdf5_module="$(first_module '^cse/hdf5/.+-serial$')"
    else
        hdf5_module="$(first_module '^cse/hdf5/.+-mpi$')"
    fi
    if [[ -n "${hdf5_module}" ]]; then
        module load "${hdf5_module}"
        command -v h5cc >/dev/null 2>&1
        cat > "${WORK_DIR}/hdf5_smoke.c" <<'EOF'
#include "hdf5.h"
int main(void) {
  hid_t file = H5Fcreate("cse-hdf5-smoke.h5", H5F_ACC_TRUNC, H5P_DEFAULT, H5P_DEFAULT);
  if (file < 0) return 1;
  return H5Fclose(file) < 0;
}
EOF
        (cd "${WORK_DIR}" && h5cc hdf5_smoke.c -o hdf5_smoke)
        [[ "${RUNTIME}" != "1" ]] || (cd "${WORK_DIR}" && ./hdf5_smoke)
    fi

    local netcdf_module=""
    if [[ "${mpi_lane}" == "serial" ]]; then
        netcdf_module="$(first_module '^cse/netcdf-c/.+-serial$')"
    else
        netcdf_module="$(first_module '^cse/netcdf-c/.+-mpi$')"
    fi
    if [[ -n "${netcdf_module}" ]]; then
        module load "${netcdf_module}"
        command -v nc-config >/dev/null 2>&1
        cat > "${WORK_DIR}/netcdf_c_smoke.c" <<'EOF'
#include <netcdf.h>
int main(void) {
  int ncid = 0;
  int rc = nc_create("cse-netcdf-smoke.nc", NC_CLOBBER, &ncid);
  if (rc != NC_NOERR) return 1;
  return nc_close(ncid) != NC_NOERR;
}
EOF
        (cd "${WORK_DIR}" && $(nc-config --cc) netcdf_c_smoke.c $(nc-config --cflags --libs) -o netcdf_c_smoke)
        [[ "${RUNTIME}" != "1" ]] || (cd "${WORK_DIR}" && ./netcdf_c_smoke)
    fi

    local netcdf_fortran_module=""
    if [[ "${mpi_lane}" == "serial" ]]; then
        netcdf_fortran_module="$(first_module '^cse/netcdf-fortran/.+-serial$')"
    else
        netcdf_fortran_module="$(first_module '^cse/netcdf-fortran/.+-mpi$')"
    fi
    if [[ -n "${netcdf_fortran_module}" ]]; then
        module load "${netcdf_fortran_module}"
        command -v nf-config >/dev/null 2>&1
        cat > "${WORK_DIR}/netcdf_fortran_smoke.f90" <<'EOF'
program netcdf_fortran_smoke
  use netcdf
  integer :: ncid, status
  status = nf90_create("cse-netcdf-fortran-smoke.nc", NF90_CLOBBER, ncid)
  if (status /= nf90_noerr) stop 1
  status = nf90_close(ncid)
  if (status /= nf90_noerr) stop 1
end program netcdf_fortran_smoke
EOF
        (cd "${WORK_DIR}" && $(nf-config --fc) netcdf_fortran_smoke.f90 $(nf-config --fflags --flibs) -o netcdf_fortran_smoke)
        [[ "${RUNTIME}" != "1" ]] || (cd "${WORK_DIR}" && ./netcdf_fortran_smoke)
    fi

    local numpy_module=""
    numpy_module="$(first_module '^cse/py-numpy/')"
    if [[ -n "${numpy_module}" ]]; then
        module load "${numpy_module}"
        python -c 'import numpy; print(numpy.__version__)'
    fi

    local miniforge_module=""
    miniforge_module="$(first_module '^cse/miniforge3/')"
    if [[ -n "${miniforge_module}" ]]; then
        module load "${miniforge_module}"
        command -v conda >/dev/null 2>&1
        conda --version
        if [[ "${RUNTIME}" == "1" ]]; then
            conda info --base >/dev/null
        fi
    fi
}

run_required "clean module and compile smoke tests" module_smoke

log ""
log "Stage 6: verification complete."
