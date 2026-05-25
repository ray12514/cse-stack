# Manual Build Guide

This guide mirrors what `scripts/deploy.sh` does. Prefer `deploy.sh` unless you
are debugging a specific stage.

For copy-paste cluster test flows covering automatic builds, render-only
inspection, and prepared handoff/manual builds, see
`docs/cluster_test_runbook.md`.

## Personal Test Build

```bash
./scripts/deploy.sh \
  --variant gcc-openmpi \
  --release test \
  --shared-path /tmp/cse-test
```

For a Docker or disposable local smoke build where compiler reproducibility is
not the goal, skip the GCC bootstrap and use the GCC already in the image:

```bash
./scripts/deploy.sh \
  --variant gcc-serial \
  --release docker-hdf5-serial \
  --shared-path /tmp/cse-test \
  --package-set hdf5-serial-smoke \
  --use-system-gcc \
  --verify-runtime
```

The matching Docker wrapper is:

```bash
./scripts/docker_hdf5_serial_smoke_test.sh
```

It installs `environment-modules`, sources `/etc/profile.d/modules.sh`, and
fails before deploy if the `module` command is not available. This is
intentionally not the production path.

For a rendering-only check (no Spack calls):

```bash
./scripts/deploy.sh \
  --variant gcc-mpich \
  --release test \
  --shared-path /tmp/cse-test \
  --mock-profile profiles/mock-cray.yaml \
  --render-only
```

For a dry-run that prints every Spack command without executing:

```bash
./scripts/deploy.sh \
  --variant gcc-mpich \
  --release test \
  --shared-path /tmp/cse-test \
  --mock-profile profiles/mock-cray.yaml \
  --dry-run
```

## Stage Flow

1. Stage 1 captures a Cluster Inspector profile.
2. Stage 2 installs Spack to `${SHARED_PATH}/cse/spack-site` from Git or a
   transferred seed bundle, optionally seeds the bootstrap root from a
   prepared bundle, builds `gcc@13.3.0`, and writes `gcc-bootstrap.yaml`.
3. Stage 3 renders `packages.yaml` (externals) and `toolchains.yaml` (compiler
   `require:` constraints for non-GCC PE variants).
4. Stage 4 renders config/modules/spack YAML, reuses an authoritative
   lockfile when supplied, and installs.
5. Stage 5 refreshes Spack modules and renders `cse-init`.
6. Stage 6 verifies the completed release with Spack integrity checks and
   clean-shell module smoke tests.

## Rendered Directory Layout

Rendered and built release state is under:

```bash
${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}/
```

Important subdirectories and files:

```text
env/                    # rendered Spack environment
env/packages.yaml       # site externals from the captured profile
env/toolchains.yaml     # compiler/MPI constraints
env/config.yaml         # install tree, cache, bootstrap config
env/modules.yaml        # public module policy
env/spack.yaml          # top-level environment
env/spack.lock          # written after concretize/fetch/build
store/                  # release-local Spack install tree
views/compiler/         # clean compiler view exposed by cse-init
views/modules/          # clean package view used by generated modules
modules/                # Spack-generated package module tree
verify/summary.txt      # Stage 6 report
```

The shared cross-release pieces are:

```text
${SHARED_PATH}/cse/spack-site/    # shared Spack installation
${SHARED_PATH}/cse/cache/         # source, misc, and Spack user cache
${SHARED_PATH}/cse/modulefiles/   # cse-init front-door modules
```

## Package Sets And OpenSSL

`deploy.sh --package-set <name>` is the supported way to switch between the
preferred MPI/PMIx stack and the legacy OpenSSL-compatible stack.

By default OpenSSL is a site external and is never built by Spack. If the site
OpenSSL is too old for the selected package set, deploy fails before
concretization and tells you which legacy package set to use.

Package sets may also set `openssl.mode: spack` to let Spack build its own
OpenSSL. The `hdf5-mpi-smoke-spack-openssl` package set demonstrates this.
When active, the OpenSSL preflight check is skipped and no `openssl:` block is
written to `packages.yaml`.

For fast Docker and pipeline validation, use `hdf5-serial-smoke` with
`gcc-serial`. It avoids the MPI dependency graph while still testing Spack
concretization, HDF5 build, module generation, and Stage 6 compile/runtime
verification.

## Login-Node Fetch / Compute-Node Build

On clusters where internet access is limited to login nodes:

```bash
# On a login node: concretize and download all sources
./scripts/deploy.sh --variant gcc-openmpi --release 20260601 ... --fetch

# Inside a compute allocation: build from pre-fetched sources
./scripts/deploy.sh --variant gcc-openmpi --release 20260601 ... --build
```

`--fetch` writes `spack.lock` and populates the source cache then exits.
`--build` reads the existing lockfile and skips concretization entirely.

## Render-Only And Prepared Handoff

To render environment YAML without calling Spack at all, use `--render-only`.
This is for inspection and template debugging; it does not prepare the shared
Spack tree or lock the compiler choice.

```bash
./scripts/deploy.sh --variant gcc-openmpi --release 20260601 ... --render-only
```

For a buildable handoff, use `--render-handoff`. The renderer runs Cluster
Inspector or accepts `--mock-profile`, prepares Spack, locks either the Spack
GCC baseline or the `--use-system-gcc` external baseline, renders all YAML, and
then stops before concretize/install.

```bash
./scripts/deploy.sh \
  --variant gcc-openmpi \
  --release 20260601 \
  --shared-path /shared \
  --render-handoff
```

The release directory then contains:

- `profile.yaml`: the captured Cluster Inspector profile.
- `render-metadata.json`: release, variant, package set, compiler mode,
  Spack/GCC versions, module system, target, render host/user/time, and the
  original command.
- `env/setup-build-env.sh`: sourceable setup for the manual builder.

The builder should not rerun Cluster Inspector by default. Source the generated
setup script and run the printed commands:

```bash
source /shared/cse/20260601/gcc-openmpi/env/setup-build-env.sh
spack concretize --fresh
spack install --concurrent-packages 4 --jobs 16 --fail-fast
```

If site state changed after rendering, rerun `--render-handoff` so the profile,
compiler decision, and rendered environment agree. After install, return to
cse-stack for module generation and verification:

```bash
./scripts/deploy.sh \
  --variant gcc-openmpi \
  --release 20260601 \
  --shared-path /shared \
  --skip-render \
  --from-stage 5
```

For older pre-rendered environments without a generated setup script,
`scripts/spack_build.sh` remains available:

```bash
./scripts/spack_build.sh \
  --env-dir /shared/cse/20260601/gcc-openmpi/env \
  --spack-root /shared/cse/spack-site
```

`spack_build.sh` only concretizes and installs. A cse-stack checkout is still
needed afterward to run Stage 5/6 and publish `cse-init` plus package modules.

## Per-System GitLab Repository

Use one GitLab project per system or closely related system family when releases
need local audit history. The system repo should not fork cse-stack by default;
instead it records the release inputs and outputs:

- captured profiles under `profiles/`
- copied handoff `profile.yaml`, `render-metadata.json`, rendered `env/*.yaml`,
  and final `spack.lock` under `releases/<release>/<variant>/`
- Stage 6 `verify/summary.txt` and any build notes
- release notes for promoted builds
- site package-set overrides, if needed
- artifact manifests that point at mirrors, bootstrap bundles, and buildcaches

Large artifacts should live in GitLab Package Registry, object storage, or a
site filesystem path referenced by a manifest. Do not commit large source
mirror or buildcache tarballs directly to Git.

Open policy details remain: promotion approval for current `cse-init`, release
tag naming, artifact retention, and the supported mechanism for custom
package-set files.

## Restricted And Air-Gapped Flow

Use the wrapper scripts for prepared deploys:

```bash
./scripts/network_prepare_request.sh --request-dir /tmp/cse-request ...
./scripts/network_fulfill_request.sh --request-dir /tmp/cse-request --output-dir /tmp/cse-artifacts ...
./scripts/network_deploy.sh --manifest /tmp/cse-artifacts/manifest.json --shared-path /shared/cse
```

`restricted` requires a bootstrap bundle, source mirror, and authoritative
lockfile. `airgapped` additionally requires a versioned Spack seed bundle.

## Stage 6 Verification

Stage 6 runs by default after Stage 5. It first activates the rendered Spack
environment and runs:

```bash
spack verify manifest  # run by Stage 6 against non-external installs
spack verify libraries # run by Stage 6 against public CSE package modules
```

`manifest` and `libraries` failures are fatal. Stage 6 filters manifest checks
to non-external installs so system packages under paths such as `/usr` do not
fail because they were not installed by Spack. Library checks target public CSE
package modules rather than build tools, which keeps system external linker
behavior from failing an otherwise usable release.

Stage 6 then starts from a clean module environment, loads any exact site
external modules recorded in `packages.yaml`, loads the versioned `cse-init`
module, and compiles representative C, C++, Fortran, MPI, HDF5, NetCDF, and
Python/Numpy smoke checks when those modules exist in the selected package set.
If `miniforge3` is published, Stage 6 also loads that module and verifies that
`conda` starts.
Runtime checks are disabled by default; pass `--verify-runtime` to run compiled
binaries and MPI launcher checks.

The summary is written to:

```bash
${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}/verify/summary.txt
```

To skip Stage 6:

```bash
./scripts/deploy.sh --variant gcc-openmpi --release test --shared-path /tmp/cse-test --skip-verify
```

For a manual module check after a successful build:

```bash
module use /tmp/cse-test/cse/modulefiles
module load cse-init/GCC/mpi-openmpi
which gcc
echo "$CSE_GCC_ROOT"
module load cse/netcdf-fortran/4.6.1-mpi
module list
```

The loaded module list should include NetCDF-Fortran, NetCDF-C, HDF5, MPI, and
no full low-level MPI dependency graph. This is driven by curated public module
loads in `modules.yaml`. `module avail cse` should show only explicit root
package-set specs, not transitive dependencies such as bzip2 or zlib.

## Notes

- `cse-init` exposes the compiler baseline but does not set global `CC`, `CXX`,
  or `FC`.
- `CSE_GCC_ROOT`, `CSE_CC`, `CSE_CXX`, and `CSE_FC` point through the clean
  compiler view path under `views/compiler/gcc/<version>`, not the hashed Spack
  store path.
- MPI builds should use the MPI wrapper compilers from `cse/openmpi/<version>`
  or `cse/mpich/<version>`.
- On Cray/PBS systems, `cray-pals` is relevant to launcher behavior; on Slurm
  systems use `srun`.
- Advanced users can chain their own Spack instance to the CSE install tree via
  `upstreams.yaml`.
