# Cluster Test Runbook

This runbook is for first-pass testing on a cluster from a personal home,
scratch, or work directory. It does not require a production shared filesystem.

Run commands from a `cse-stack` checkout on the cluster.

## 0. Choose A Test Location

Pick a path that is writable from the node where you will build. For smoke
tests, `$HOME` is usually fine. For larger builds, prefer `$WORK` or `$SCRATCH`.

```bash
cd /path/to/cse-stack

export CSE_SHARED_PATH="${WORK:-${SCRATCH:-$HOME}}/cse-stack-test"
export CSE_RELEASE="test-${USER}-$(hostname -s)-$(date +%Y%m%d-%H%M)"
export CSE_VARIANT="gcc-serial"
export CSE_PACKAGE_SET="hdf5-serial-smoke"
export CSE_INSTALL_JOBS="${CSE_INSTALL_JOBS:-16}"
export CSE_CONCURRENT_PACKAGES="${CSE_CONCURRENT_PACKAGES:-2}"

mkdir -p "$CSE_SHARED_PATH"

printf 'CSE_SHARED_PATH=%s\n' "$CSE_SHARED_PATH"
printf 'CSE_RELEASE=%s\n' "$CSE_RELEASE"
printf 'CSE_VARIANT=%s\n' "$CSE_VARIANT"
printf 'CSE_PACKAGE_SET=%s\n' "$CSE_PACKAGE_SET"
```

For an MPI smoke test, change the variant and package set before running a flow:

```bash
export CSE_VARIANT="gcc-openmpi"
export CSE_PACKAGE_SET="hdf5-mpi-smoke"
```

If the site OpenSSL is too old for the default MPI smoke set, use:

```bash
export CSE_PACKAGE_SET="hdf5-mpi-smoke-legacy-openssl"
```

## 1. Fully Automatic Build

This runs the normal staged flow end to end: profile, prepare Spack/compiler,
render, concretize, install, generate modules, and verify.

For a quick personal smoke test, use the system GCC already on `PATH`:

```bash
./scripts/deploy.sh \
  --variant "$CSE_VARIANT" \
  --release "$CSE_RELEASE" \
  --shared-path "$CSE_SHARED_PATH" \
  --package-set "$CSE_PACKAGE_SET" \
  --use-system-gcc
```

For a production-like GCC test, omit `--use-system-gcc` so Stage 2 bootstraps
the pinned Spack GCC baseline:

```bash
./scripts/deploy.sh \
  --variant "$CSE_VARIANT" \
  --release "$CSE_RELEASE" \
  --shared-path "$CSE_SHARED_PATH" \
  --package-set "$CSE_PACKAGE_SET"
```

Check the result:

```bash
cat "$CSE_SHARED_PATH/cse/$CSE_RELEASE/$CSE_VARIANT/verify/summary.txt"
find "$CSE_SHARED_PATH/cse/$CSE_RELEASE/$CSE_VARIANT" -maxdepth 2 -type f | sort
```

## 2. Render-Only Inspection

Use this when you only want to inspect the rendered YAML. It does not prepare
Spack, register a compiler, concretize, or install.

```bash
./scripts/deploy.sh \
  --variant "$CSE_VARIANT" \
  --release "$CSE_RELEASE" \
  --shared-path "$CSE_SHARED_PATH" \
  --package-set "$CSE_PACKAGE_SET" \
  --render-only
```

Inspect the rendered files:

```bash
find "$CSE_SHARED_PATH/cse/$CSE_RELEASE/$CSE_VARIANT/env" -maxdepth 1 -type f | sort
sed -n '1,180p' "$CSE_SHARED_PATH/cse/$CSE_RELEASE/$CSE_VARIANT/env/spack.yaml"
sed -n '1,220p' "$CSE_SHARED_PATH/cse/$CSE_RELEASE/$CSE_VARIANT/env/packages.yaml"
```

Start a fresh release name before switching from `--render-only` to a buildable
flow, because `--render-only` intentionally does not prepare the compiler state.

## 3. Prepared Handoff And Manual Build

Use this when one person captures the cluster facts and renders the environment,
then the same person or another user manually runs the Spack concretize/install.
The manual builder should not rerun Cluster Inspector unless the site state has
changed.

Render the buildable handoff:

```bash
./scripts/deploy.sh \
  --variant "$CSE_VARIANT" \
  --release "$CSE_RELEASE" \
  --shared-path "$CSE_SHARED_PATH" \
  --package-set "$CSE_PACKAGE_SET" \
  --use-system-gcc \
  --render-handoff
```

Source the generated setup script:

```bash
source "$CSE_SHARED_PATH/cse/$CSE_RELEASE/$CSE_VARIANT/env/setup-build-env.sh"
```

Confirm the handoff environment:

```bash
printf 'SPACK_ROOT=%s\n' "$SPACK_ROOT"
printf 'SPACK_ENV=%s\n' "$SPACK_ENV"
printf 'CSE_RELEASE=%s\n' "$CSE_RELEASE"
printf 'CSE_VARIANT=%s\n' "$CSE_VARIANT"
spack env status
```

Concretize and install manually:

```bash
spack concretize --fresh
spack install \
  --concurrent-packages "$CSE_CONCURRENT_PACKAGES" \
  --jobs "$CSE_INSTALL_JOBS" \
  --fail-fast
```

Return to the staged flow for module generation and verification:

```bash
./scripts/deploy.sh \
  --variant "$CSE_VARIANT" \
  --release "$CSE_RELEASE" \
  --shared-path "$CSE_SHARED_PATH" \
  --package-set "$CSE_PACKAGE_SET" \
  --skip-render \
  --from-stage 5
```

Check the final verification summary:

```bash
cat "$CSE_SHARED_PATH/cse/$CSE_RELEASE/$CSE_VARIANT/verify/summary.txt"
```

## 4. Runtime Verification

Runtime execution is opt-in because schedulers and launchers vary by cluster.
After a successful build, rerun Stage 6 with runtime checks:

```bash
./scripts/deploy.sh \
  --variant "$CSE_VARIANT" \
  --release "$CSE_RELEASE" \
  --shared-path "$CSE_SHARED_PATH" \
  --package-set "$CSE_PACKAGE_SET" \
  --skip-render \
  --from-stage 6 \
  --verify-runtime
```

If runtime verification fails, capture the exact command, loaded modules, node
type, scheduler allocation details, and error text.

## 5. Useful Cluster Notes To Capture

Save this with the test result when comparing clusters:

```bash
{
  date
  hostname -f 2>/dev/null || hostname
  whoami
  id
  printf 'PWD=%s\n' "$PWD"
  printf 'CSE_SHARED_PATH=%s\n' "$CSE_SHARED_PATH"
  printf 'CSE_RELEASE=%s\n' "$CSE_RELEASE"
  printf 'CSE_VARIANT=%s\n' "$CSE_VARIANT"
  printf 'CSE_PACKAGE_SET=%s\n' "$CSE_PACKAGE_SET"
  command -v module >/dev/null 2>&1 && module list 2>&1
  df -h "$CSE_SHARED_PATH"
  mount | grep -F "$CSE_SHARED_PATH" || true
} | tee "$CSE_SHARED_PATH/cse/$CSE_RELEASE-$CSE_VARIANT-cluster-notes.txt"
```

