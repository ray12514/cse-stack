#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_TAG="${CSE_DOCKER_IMAGE_TAG:-cse-hdf5-serial-smoke:latest}"
SHARED_PATH="${CSE_DOCKER_SHARED_PATH:-/tmp/cse-docker-hdf5-serial}"
RELEASE="${CSE_DOCKER_RELEASE:-docker-hdf5-serial}"

docker build -t "${IMAGE_TAG}" - <<'EOF'
FROM rockylinux:9

RUN dnf -y install --allowerasing \
      environment-modules \
      gcc \
      gcc-c++ \
      gcc-gfortran \
      git \
      patch \
      which \
      diffutils \
      findutils \
      file \
      bzip2 \
      xz \
      tar \
      gzip \
      unzip \
      curl \
      libcurl-devel \
      openssl-devel \
      perl-core \
      python3 \
      python3-jinja2 \
      python3-pyyaml \
    && dnf clean all

SHELL ["/bin/bash", "-lc"]
EOF

docker run --rm \
  -v "${REPO_ROOT}:/workspace/cse-stack" \
  -v "${SHARED_PATH}:${SHARED_PATH}" \
  "${IMAGE_TAG}" \
  /bin/bash -lc "
set -euo pipefail

source /etc/profile.d/modules.sh
if ! type module >/dev/null 2>&1; then
    echo 'ERROR: module command is not available after sourcing /etc/profile.d/modules.sh' >&2
    exit 1
fi

cd /workspace/cse-stack
./scripts/deploy.sh \
  --variant gcc-serial \
  --release '${RELEASE}' \
  --shared-path '${SHARED_PATH}' \
  --package-set hdf5-serial-smoke \
  --module-system tcl \
  --mock-profile profiles/mock-cray.yaml \
  --use-system-gcc \
  --restart-release \
  --jobs 2 \
  --make-jobs 4 \
  --verify-runtime
"
