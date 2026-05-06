#!/usr/bin/env bash
# Source this file. It creates/reuses the CSE deploy Python virtualenv and
# exports CSE_PYTHON for scripts that need Jinja2/PyYAML.

cse_python_requirements_hash() {
    local python_bin="$1" requirements="$2"
    "${python_bin}" - "${requirements}" <<'PY'
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
print(hashlib.sha256(path.read_bytes()).hexdigest())
PY
}

cse_python_imports_ok() {
    local python_bin="$1"
    "${python_bin}" - <<'PY' >/dev/null 2>&1
import jinja2
import yaml
PY
}

cse_python_bootstrap() {
    if [[ "${CSE_PYTHON_BOOTSTRAPPED:-0}" == "1" && -n "${CSE_PYTHON:-}" && -x "${CSE_PYTHON}" ]]; then
        return 0
    fi

    : "${REPO_ROOT:?cse_python_bootstrap requires REPO_ROOT}"
    : "${SHARED_PATH:?cse_python_bootstrap requires SHARED_PATH}"

    local requirements="${CSE_PYTHON_REQUIREMENTS:-${REPO_ROOT}/requirements-deploy.txt}"
    local venv_dir="${CSE_PYTHON_VENV:-${SHARED_PATH}/cse/cache/python-venv}"
    local wheelhouse="${CSE_PYTHON_WHEELHOUSE:-}"
    local host_python="${CSE_HOST_PYTHON:-}"

    if [[ ! -f "${requirements}" ]]; then
        echo "ERROR: deploy Python requirements not found: ${requirements}" >&2
        return 1
    fi

    if [[ -z "${host_python}" ]]; then
        if command -v python3 >/dev/null 2>&1; then
            host_python="$(command -v python3)"
        else
            echo "ERROR: python3 is required on PATH to bootstrap the CSE deploy environment." >&2
            return 1
        fi
    fi

    if [[ ! -x "${venv_dir}/bin/python" ]]; then
        mkdir -p "$(dirname "${venv_dir}")"
        if ! "${host_python}" -m venv "${venv_dir}"; then
            echo "ERROR: failed to create Python virtualenv at ${venv_dir}." >&2
            echo "       Install the OS python3-venv/ensurepip package or set CSE_PYTHON_VENV." >&2
            return 1
        fi
    fi

    export CSE_PYTHON="${venv_dir}/bin/python"

    if ! "${CSE_PYTHON}" -m pip --version >/dev/null 2>&1; then
        if ! "${CSE_PYTHON}" -m ensurepip --upgrade >/dev/null 2>&1; then
            echo "ERROR: pip is unavailable in ${venv_dir} and ensurepip failed." >&2
            echo "       Install the OS python3-venv/ensurepip package or provide a usable CSE_PYTHON_VENV." >&2
            return 1
        fi
    fi

    local stamp="${venv_dir}/.cse-requirements.sha256"
    local want_hash=""
    want_hash="$(cse_python_requirements_hash "${CSE_PYTHON}" "${requirements}")"

    if [[ ! -f "${stamp}" ]] || [[ "$(cat "${stamp}")" != "${want_hash}" ]] || ! cse_python_imports_ok "${CSE_PYTHON}"; then
        if [[ -n "${wheelhouse}" ]]; then
            if [[ ! -d "${wheelhouse}" ]]; then
                echo "ERROR: CSE Python wheelhouse not found: ${wheelhouse}" >&2
                return 1
            fi
            if ! "${CSE_PYTHON}" -m pip install --no-index --find-links "${wheelhouse}" -r "${requirements}"; then
                return 1
            fi
        else
            if ! "${CSE_PYTHON}" -m pip install -r "${requirements}"; then
                return 1
            fi
        fi
        printf '%s\n' "${want_hash}" > "${stamp}"
    fi

    export CSE_PYTHON_BOOTSTRAPPED=1
}

cse_python_download_wheelhouse() {
    local output_dir="$1"
    : "${REPO_ROOT:?cse_python_download_wheelhouse requires REPO_ROOT}"
    : "${CSE_PYTHON:?cse_python_download_wheelhouse requires CSE_PYTHON}"

    local requirements="${CSE_PYTHON_REQUIREMENTS:-${REPO_ROOT}/requirements-deploy.txt}"
    mkdir -p "${output_dir}"
    "${CSE_PYTHON}" -m pip wheel -r "${requirements}" -w "${output_dir}"
}
