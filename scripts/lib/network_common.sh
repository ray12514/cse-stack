#!/usr/bin/env bash
# Shared helpers for staged network-aware deploy flows.
set -euo pipefail

cse_sha256() {
    local path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${path}" | awk '{print $1}'
    else
        shasum -a 256 "${path}" | awk '{print $1}'
    fi
}

cse_extract_archive() {
    local source_path="$1"
    local dest_path="$2"
    local tmp_dir=""

    rm -rf "${dest_path}"
    mkdir -p "$(dirname "${dest_path}")"

    if [[ -d "${source_path}" ]]; then
        cp -a "${source_path}" "${dest_path}"
        return 0
    fi

    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cse-net.XXXXXX")"
    tar -xf "${source_path}" -C "${tmp_dir}"

    local entry_count
    entry_count=$(find "${tmp_dir}" -mindepth 1 -maxdepth 1 | wc -l | awk '{print $1}')
    if [[ "${entry_count}" == "1" ]] && [[ -d "$(find "${tmp_dir}" -mindepth 1 -maxdepth 1)" ]]; then
        mv "$(find "${tmp_dir}" -mindepth 1 -maxdepth 1)" "${dest_path}"
    else
        mkdir -p "${dest_path}"
        find "${tmp_dir}" -mindepth 1 -maxdepth 1 -exec mv {} "${dest_path}/" \;
    fi

    rm -rf "${tmp_dir}"
}

cse_path_to_uri() {
    local path="$1"
    if [[ "${path}" == *://* ]]; then
        printf '%s\n' "${path}"
    else
        printf 'file://%s\n' "${path}"
    fi
}
