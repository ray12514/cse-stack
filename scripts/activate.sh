#!/usr/bin/env bash
# source me — sets the environment variables used by all CSE stage scripts.
#
# Usage:
#   source scripts/activate.sh
#   source scripts/activate.sh --shared-path /lus/mysite/sw --release 2026_04
#
# Override defaults by passing --shared-path and --release as arguments,
# or by exporting SHARED_PATH and CSE_RELEASE before sourcing.

while [[ $# -gt 0 ]]; do
    case "$1" in
        --shared-path) export SHARED_PATH="$2"; shift 2 ;;
        --release)     export CSE_RELEASE="$2";  shift 2 ;;
        *) echo "activate.sh: unknown argument $1" >&2; return 1 ;;
    esac
done

export SHARED_PATH="${SHARED_PATH:-/shared_path}"     # TODO: confirm actual filesystem root
export CSE_RELEASE="${CSE_RELEASE:-2026_04}"
export CSE_SHARED_PATH="${SHARED_PATH}"
export CSE_RELEASE_DEFAULT="${CSE_RELEASE}"

echo "CSE environment:"
echo "  SHARED_PATH  = ${SHARED_PATH}"
echo "  CSE_RELEASE  = ${CSE_RELEASE}"
