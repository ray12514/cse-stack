# cse-stack Handoff

This file is preserved as a short handoff note. The current implementation
state is documented in `README.md`, `docs/implementation_plan.md`, and
`docs/phase_two_summary.md`. Build troubleshooting and lessons learned are
tracked in `docs/build_process_notes.md`.

## Current Decisions

- Variants use the `<compiler>-<mpi>` slug format (e.g. `gcc-openmpi`,
  `gcc-mpich`, `cce-craympich`). The old `v1-openmpi` and `v2-mpich` slugs
  are accepted as deprecated aliases that print a warning and redirect.
- Both `gcc-*` variants bootstrap `gcc@13.3.0` from Spack.
- `deploy.sh --use-system-gcc` exists for Docker smoke tests and disposable
  local builds; production releases should keep the Spack-built GCC baseline.
- `scripts/docker_hdf5_serial_smoke_test.sh` is the preferred Docker smoke
  path: it uses `gcc-serial`, builds serial HDF5 only, and verifies the module
  command before deploy.
- All variants use the shared Spack instance at `${SHARED_PATH}/cse/spack-site`.
- Compiler registration for Stage 4 comes only from `gcc-bootstrap.yaml`.
- Non-GCC PE variants (`cce-*`, `aocc-*`, `nvhpc-*`, `rocmcc-*`) consume
  compiler and MPI externals from the profile's `vendor_substrate.compiler_externals`.
  The relevant `PrgEnv-*` module must be loaded before Stage 1 runs.
- Spack config isolation: both `SPACK_SYSTEM_CONFIG_PATH` and
  `SPACK_USER_CONFIG_PATH` are set to `/dev/null` in every stage script.
- Stage 3 renders `packages.yaml` and `toolchains.yaml` (compiler `require:`
  constraints for non-GCC PE compilers). `spack.yaml` includes `toolchains.yaml`
  when the file is present.
- Deploys carry an explicit network mode: `online`, `restricted`, or `airgapped`.
- `science-full` is the expanded two-version science package set. Miniforge is
  latest-only, and `netcdf-cxx4` currently has one available Spack version.
- `science-full-legacy-openssl` keeps that expanded catalog but uses the
  legacy OpenMPI policy for sites with older external OpenSSL.
- `hdf5-mpi-smoke-spack-openssl` is a proof-of-concept package set that lets
  Spack build its own OpenSSL instead of forcing the site external.
- `hdf5-serial-smoke` is the fast Docker/pipeline package set for validating
  HDF5, module generation, and Stage 6 without pulling in an MPI stack.
- Restricted and air-gapped flows can use request/fulfillment/deploy wrappers
  plus authoritative lockfiles and artifact manifests.
- Failed release retries should use `deploy.sh --restart-release`; if
  `--buildcache-uri` is set, deploy exports installed packages to that cache
  before clearing the release-local env/store/views/modules.
- `cse-init/<COMPILER_UPPER>/<mpi_label>` exposes the CSE baseline and variant
  module tree (e.g. `cse-init/GCC/mpi-openmpi`, `cse-init/CCE/mpi-craympich`).
- Spack-generated package modules use clean view-backed paths and curated
  public dependency loads instead of broad recursive autoload.
- The generated module catalog follows explicit root package-set specs;
  low-level transitive dependencies remain installed but hidden.
- `deploy.sh --render-only` renders all YAML files and exits without preparing
  Spack/compiler state. `deploy.sh --render-handoff` prepares the shared Spack
  tree, locks the compiler decision, preserves `profile.yaml` and
  `render-metadata.json`, and writes `env/setup-build-env.sh` for the manual
  builder. `--skip-render` skips rendering and proceeds directly to install or
  later stages.
- The docs now describe the rendered directory layout, prepared handoff
  continuation, and a draft per-system GitLab repository model.
- `deploy.sh --fetch` concretizes and pre-fetches sources on a login node;
  `--build` runs the install only inside a compute allocation.
- Stage 6 runs by default after Stage 5. It uses `spack verify` for install
  integrity, then verifies CSE module and compile workflows from a clean module
  environment with exact external module versions from `packages.yaml`.
- Stage 6 also checks a published `cse/miniforge3/*` module by running
  `conda --version`; with `--verify-runtime`, it runs `conda info --base`.

## Deferred Items

- Optional Cray `cray-mpich` runtime splice via `CSE_MPICH_SPLICE=1`.
- Decide whether PnetCDF should become a top-level `cse/parallel-netcdf` module.
- Add Ansible orchestration after the bash proof-of-concept is stable.
- Finalize the per-system GitLab repository policy: release tag naming,
  promotion ownership, artifact retention, and where custom package sets live.
- Flesh out a first-class custom package-set workflow. The current repo-local
  `--package-set <name>` mechanism works for tracked files under
  `package-sets/`, but follow-up work should define and document a supported
  bring-your-own package-set path such as `--package-set-file`.
