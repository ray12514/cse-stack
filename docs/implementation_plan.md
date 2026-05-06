# CSE Stack Implementation Plan

## Summary

The CSE stack builds a small scientific software environment with Spack and
publishes it through a `cse/*` module namespace. The bash scripts are the
current implementation layer and are intentionally stage-based so Ansible can
later call them directly.

The deploy path now also carries an explicit network mode:

- `online`
- `restricted`
- `airgapped`

Restricted and air-gapped flows use transfer bundles plus an authoritative
lockfile so the target does not silently drift by re-concretizing against a
different helper environment.

## Architecture

- One Spack instance lives at `${SHARED_PATH}/cse/spack-site`.
- Each release/variant has its own environment under
  `${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}/env`.
- Stage 2 bootstraps `gcc@13.3.0` into the Spack store and writes
  `gcc-bootstrap.yaml` next to the environment.
- Stage 4 includes `gcc-bootstrap.yaml`; no rendered `packages.yaml` GCC block
  and no legacy `gcc-compilers.yaml` are used.
- Stage 5 refreshes Spack modules and renders the `cse-init` module with
  literal release, shared path, module root, and GCC prefix values.

## Variants

| Variant | MPI | Notes |
|---|---|---|
| `v1-openmpi` | OpenMPI built by Spack | Generic Linux path |
| `v2-mpich` | MPICH built by Spack | Uses `device=ch4 netmod=ofi`; Cray libfabric/cray-pals externals are detected from the profile |

The old `v2-cray-integrated` design that used external `cray-mpich` and
`cray-libsci` is superseded. `CSE_MPICH_SPLICE=1` remains a deferred Phase 2
idea, not part of the current build path.

## Module Loading

The module design follows Spack's documented production pattern:

- `cse-init/<mpi>` prepends the generated module tree and exposes CSE GCC.
- Package dependencies are loaded by Spack-generated modules, not by `cse-init`.
- `all: autoload: direct` causes direct link and run dependencies to load
  recursively.
- `hide_implicits: true` hides implicit dependency modules from `module avail`
  while keeping them available for autoload.
- `exclude_implicits` is intentionally not used because excluded modules cannot
  be autoloaded.

Expected user flow:

```bash
module load cse-init/openmpi
module load cse/netcdf-fortran-mpi
```

The second command should load NetCDF-Fortran plus the matching NetCDF-C, HDF5,
MPI, and required direct dependency modules.

## Compiler Contract

`cse-init` sets:

- `CSE_GCC_ROOT`
- `CSE_CC`
- `CSE_CXX`
- `CSE_FC`

It prepends GCC `bin` to `PATH`, but does not set global `CC`, `CXX`, or `FC`.
Serial user builds may opt in with `export CC=$CSE_CC`; MPI user builds should
load `cse/openmpi` or `cse/mpich` and use MPI wrapper compilers.

## Personal And Shared Installs

Personal proof-of-concept installs may use `/tmp/cse-test` or another
user-owned path. Group ownership checks are warnings in that mode.

Shared cluster installs should create `${SHARED_PATH}/cse` with the target Unix
group and setgid bit, then pass `--group <name>`.

## Buildcache Target Policy

Default to `target=x86_64` for the first production buildcache. The goal is to
maximize reuse while validating the CSE layout, modules, compiler handoff,
mirrors, and rebuild process.

Use optimized targets only as explicit site-specific layers:

- `x86_64`: portable baseline cache, safe across mixed nodes.
- `x86_64_v3`, `x86_64_v4`, `zen3`, etc.: optimized cache only when every
  consumer node supports that target.
- Generic and optimized caches must not share the same release/cache namespace.
  Use a target suffix or separate cache URI to avoid incompatible binary reuse.

## Validation

- `bash -n scripts/*.sh`
- `bash -n scripts/lib/*.sh`
- Python syntax/import validation for `scripts/lib/*.py`
- Dry-run both variants.
- Dry-run `network_prepare_request.sh`, `network_fulfill_request.sh`, and
  `network_deploy.sh` with representative artifacts.
- Run `./scripts/docker_smoke_test.sh` for Linux syntax/render validation.
- Run `./scripts/docker_cse_buildcache_test.sh --dry-run` for a reduced
  deploy-backed HDF5/MPI environment.
- Run `./scripts/docker_cse_buildcache_test.sh --cache-only` to prove the
  reduced environment can be restored from a buildcache without source builds.
  The default Docker package set should target a package with a high public
  cache hit probability, while the reduced HDF5+MPI set remains available for
  CSE functional validation.
- Inspect rendered YAML for one compiler handoff source.
- Inspect generated modulefiles for autoload/depends-on statements.
- In a clean module shell, verify loading `cse/netcdf-fortran-mpi` loads
  NetCDF-C, HDF5, MPI, and direct dependencies.
