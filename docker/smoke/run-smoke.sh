#!/usr/bin/env bash
#
# End-to-end smoke runner for the cluster-inspector + stack-composer + Spack
# pipeline. Builds the helper artifacts on the host into a persistent runtime
# tree, then dispatches one of: build, profile, render, build-step, pipeline,
# shell (default actions live at the bottom).
#
# Persistent runtime tree (override with RUNTIME_DIR env var):
#   $RUNTIME_DIR/stack.yaml           smoke stack input (kept across runs)
#   $RUNTIME_DIR/deployment.yaml      installer-owned render paths
#   $RUNTIME_DIR/workspace/           profile.yaml + rendered out/ tree
#   $RUNTIME_DIR/shared/              view roots / module roots / buildcache
#   $RUNTIME_DIR/spack-opt/           persistent Spack install tree
#   $RUNTIME_DIR/reports/             spack-build per-lane reports
#   $RUNTIME_DIR/cluster-inspector    host-built linux/amd64 binary
#   $RUNTIME_DIR/stack-composer.pyz   host-built release pyz
#   $RUNTIME_DIR/spack-build          host-copied driver script

set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ROOT="${DEV_ROOT:-$(cd "${SMOKE_DIR}/../../.." && pwd)}"

CI_DIR="${CI_DIR:-${DEV_ROOT}/cluster-inspector}"
SC_DIR="${SC_DIR:-${DEV_ROOT}/stack-composer}"
# stack-content holds the production template set + per-system/stack inputs.
# When present it is the render source of truth; otherwise we fall back to the
# stack-composer test fixtures.
CONTENT_DIR="${CONTENT_DIR:-${DEV_ROOT}/stack-content}"
RUNTIME_DIR="${RUNTIME_DIR:-${DEV_ROOT}/smoke-runtime}"

IMAGE_TAG="${SMOKE_IMAGE:-smoke:latest}"
SPACK_REF="${SPACK_REF:-v1.1.1}"
ROCKY_TAG="${ROCKY_TAG:-9}"

ACTION="${1:-pipeline}"

log() { printf '\033[1;34m[smoke]\033[0m %s\n' "$*"; }

ensure_runtime_tree() {
  mkdir -p \
    "${RUNTIME_DIR}/workspace" \
    "${RUNTIME_DIR}/shared/stack/spack/opt" \
    "${RUNTIME_DIR}/shared/stack/spack/source-cache" \
    "${RUNTIME_DIR}/shared/stack/buildcache" \
    "${RUNTIME_DIR}/spack-opt" \
    "${RUNTIME_DIR}/reports"
  if [[ ! -f "${RUNTIME_DIR}/stack.yaml" ]]; then
    log "no ${RUNTIME_DIR}/stack.yaml found; seeding from ${SMOKE_DIR}/stack.yaml"
    cp "${SMOKE_DIR}/stack.yaml" "${RUNTIME_DIR}/stack.yaml"
  fi
  if [[ ! -f "${RUNTIME_DIR}/deployment.yaml" ]]; then
    if [[ -f "${CONTENT_DIR}/systems/smoke/deployment.yaml" ]]; then
      log "no ${RUNTIME_DIR}/deployment.yaml found; seeding from stack-content smoke deployment"
      cp "${CONTENT_DIR}/systems/smoke/deployment.yaml" "${RUNTIME_DIR}/deployment.yaml"
    else
      log "no ${RUNTIME_DIR}/deployment.yaml found; seeding from ${SMOKE_DIR}/deployment.yaml"
      cp "${SMOKE_DIR}/deployment.yaml" "${RUNTIME_DIR}/deployment.yaml"
    fi
  fi
}

build_image() {
  log "building ${IMAGE_TAG} (rockylinux:${ROCKY_TAG}, Spack ${SPACK_REF})"
  docker build \
    --build-arg "ROCKY_TAG=${ROCKY_TAG}" \
    --build-arg "SPACK_REF=${SPACK_REF}" \
    -t "${IMAGE_TAG}" \
    "${SMOKE_DIR}"
}

build_cluster_inspector() {
  ensure_runtime_tree
  log "building cluster-inspector (linux/amd64) into ${RUNTIME_DIR}/cluster-inspector"
  (
    cd "${CI_DIR}"
    GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
      go build -o "${RUNTIME_DIR}/cluster-inspector" ./cmd/cluster-inspector
  )
}

build_stack_composer_pyz() {
  ensure_runtime_tree
  log "building stack-composer.pyz into ${RUNTIME_DIR}/stack-composer.pyz"
  (
    cd "${SC_DIR}"
    PYTHON="${SC_PYTHON:-.venv/bin/python}" scripts/build-pyz.sh
  )
  cp "${SC_DIR}/dist/stack-composer.pyz" "${RUNTIME_DIR}/stack-composer.pyz"
  cp "${SC_DIR}/scripts/spack-build" "${RUNTIME_DIR}/spack-build"
  chmod +x "${RUNTIME_DIR}/spack-build"
}

ensure_artifacts() {
  ensure_runtime_tree
  [[ -x "${RUNTIME_DIR}/cluster-inspector" ]] || build_cluster_inspector
  [[ -f "${RUNTIME_DIR}/stack-composer.pyz" ]] || build_stack_composer_pyz
  [[ -x "${RUNTIME_DIR}/spack-build" ]] || build_stack_composer_pyz
}

docker_mounts=(
  -v "${RUNTIME_DIR}/workspace:/workspace/stack"
  -v "${RUNTIME_DIR}/stack.yaml:/workspace/stack/stack.yaml:ro"
  -v "${RUNTIME_DIR}/deployment.yaml:/workspace/stack/deployment.yaml:ro"
  -v "${RUNTIME_DIR}/cluster-inspector:/workspace/cluster-inspector:ro"
  -v "${RUNTIME_DIR}/stack-composer.pyz:/workspace/stack-composer.pyz:ro"
  -v "${RUNTIME_DIR}/spack-build:/workspace/spack-build:ro"
  -v "${RUNTIME_DIR}/shared:/shared"
  -v "${RUNTIME_DIR}/spack-opt:/home/spack/spack/opt"
  -v "${RUNTIME_DIR}/reports:/workspace/reports"
  -v "${SC_DIR}:/workspace/stack-composer-src:ro"
)
# Mount stack-content read-only when it exists so render consumes it directly.
[[ -d "${CONTENT_DIR}/templates" ]] && docker_mounts+=( -v "${CONTENT_DIR}:/workspace/stack-content:ro" )

docker_run() {
  local tty_flag=""
  [[ -t 0 && -t 1 ]] && tty_flag="-t"
  docker run --rm -i ${tty_flag} "${docker_mounts[@]}" "${IMAGE_TAG}" \
    /bin/bash -l -c "$1"
}

docker_shell() {
  docker run --rm -it "${docker_mounts[@]}" "${IMAGE_TAG}" "$@"
}

case "${ACTION}" in
  build)
    build_image
    ;;
  cluster-inspector)
    build_cluster_inspector
    ;;
  pyz)
    build_stack_composer_pyz
    ;;
  init)
    ensure_runtime_tree
    log "runtime tree ready at ${RUNTIME_DIR}"
    ;;
  shell)
    ensure_artifacts
    docker_shell /bin/bash -l
    ;;
  profile)
    ensure_artifacts
    docker_run "
      set -euo pipefail
      /workspace/cluster-inspector profile \
        --system smoke \
        --node-type compute=this:role=both \
        --output /workspace/stack/profile.yaml
      echo 'wrote /workspace/stack/profile.yaml'
    "
    ;;
  render)
    ensure_artifacts
    docker_run "
      set -euo pipefail
      if [ -d /workspace/stack-content/templates ]; then
        TEMPLATES=/workspace/stack-content/templates
        PKGSETS=/workspace/stack-content/package-sets
        PKGREPOS=/workspace/stack-content/package-repos
        echo 'render source: stack-content'
      else
        TEMPLATES=/workspace/stack-composer-src/tests/fixtures/template-sets
        PKGSETS=/workspace/stack-composer-src/tests/fixtures/package-sets
        PKGREPOS=/workspace/stack-composer-src/tests/fixtures/package-repos
        echo 'render source: stack-composer fixtures (fallback)'
      fi
      python3.11 /workspace/stack-composer.pyz render \
        --profile /workspace/stack/profile.yaml \
        --deployment /workspace/stack/deployment.yaml \
        --stack /workspace/stack/stack.yaml \
        --templates \"\$TEMPLATES\" \
        --package-sets \"\$PKGSETS\" \
        --package-repos \"\$PKGREPOS\" \
        --output-root /workspace/stack/out \
        --release smoke \
        --rendered-at 1970-01-01T00:00:00Z \
        --source-repo file:///workspace/stack \
        --source-commit 0000000000000000000000000000000000000000 \
        --overwrite
    "
    ;;
  build-step)
    ensure_artifacts
    docker_run "
      set -euo pipefail
      workspace=\$(find /workspace/stack/out -mindepth 3 -maxdepth 3 -type d -name 'smoke' | head -1)
      if [[ -z \"\${workspace}\" ]]; then
        echo 'no rendered workspace found under /workspace/stack/out' >&2
        exit 1
      fi
      echo \"workspace: \${workspace}\"
      # Bind-mounts arrive owned by the host uid; hand them to the container's
      # spack user (1000) so install + module generation can write.
      sudo chown -R spack:spack /home/spack/spack/opt /shared
      /workspace/spack-build \
        --workspace \"\${workspace}\" \
        --reports /workspace/reports \
        --skip-push

      # Generate tcl modulefiles for every concretized lane into /shared/modules.
      mkdir -p /tmp/modcfg
      cat > /tmp/modcfg/modules.yaml <<'YAML'
modules:
  default:
    enable: [tcl]
    roots:
      tcl: /shared/modules/tcl
    tcl:
      hash_length: 7
      all:
        autoload: direct
YAML
      for sy in \$(find \"\${workspace}/environments\" -mindepth 3 -maxdepth 3 -name spack.yaml | sort); do
        env=\$(dirname \"\${sy}\")
        lane=\${env#\${workspace}/environments/}
        echo \"=== installed specs (\${lane}) ===\"
        spack -e \"\${env}\" find -lp || true
        echo \"=== generate tcl modulefiles (\${lane}) ===\"
        spack -C /tmp/modcfg -e \"\${env}\" module tcl refresh -y || true
      done
      echo '=== install tree (package prefixes) ==='
      find /home/spack/spack/opt/spack -mindepth 3 -maxdepth 3 -type d 2>/dev/null | sort
      echo '=== generated modulefiles ==='
      find /shared/modules -type f 2>/dev/null | sort
    "
    ;;
  pipeline)
    ensure_artifacts
    "${BASH_SOURCE[0]}" profile
    "${BASH_SOURCE[0]}" render
    "${BASH_SOURCE[0]}" build-step
    ;;
  clean)
    log "wiping runtime workspace + shared at ${RUNTIME_DIR}"
    rm -rf "${RUNTIME_DIR}/workspace" "${RUNTIME_DIR}/shared/stack/releases" "${RUNTIME_DIR}/reports"
    ensure_runtime_tree
    ;;
  *)
    cat <<USAGE
usage: $(basename "$0") <action>

actions:
  build               build the smoke Docker image
  init                pre-create the persistent runtime tree at \$RUNTIME_DIR
  cluster-inspector   cross-build cluster-inspector (linux/amd64) into runtime
  pyz                 build stack-composer.pyz + copy spack-build into runtime
  shell               start an interactive shell inside the smoke image
  profile             run cluster-inspector inside the container
  render              run stack-composer render inside the container
  build-step          drive concretize + install + verify via spack-build
  pipeline            profile + render + build-step (default)
  clean               wipe workspace/ + shared/stack/releases + reports/
                      (preserves stack.yaml, spack-opt, source-cache, buildcache)
USAGE
    exit 2
    ;;
esac
