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

OpenSSL is intentionally enforced as a site external. Package sets define the
supported MPI/PMIx policies, including legacy-compatible alternatives for sites
whose external OpenSSL is older than 3.x.

## Architecture

- One Spack instance lives at `${SHARED_PATH}/cse/spack-site`.
- Each release/variant has its own environment under
  `${SHARED_PATH}/cse/${CSE_RELEASE}/${CSE_VARIANT}/env`.
- Stage 2 bootstraps `gcc@13.3.0` into the Spack store and writes
  `gcc-bootstrap.yaml` next to the environment.
- Stage 3 renders `packages.yaml` (externals) and `toolchains.yaml` (compiler
  `require:` constraints for non-GCC PE variants). `spack.yaml` includes
  `toolchains.yaml` when the file is present.
- Stage 4 includes `gcc-bootstrap.yaml`; no rendered `packages.yaml` GCC block
  and no legacy `gcc-compilers.yaml` are used.
- Compiler selection relies entirely on environment isolation:
  `SPACK_DISABLE_LOCAL_CONFIG=1`, `SPACK_SYSTEM_CONFIG_PATH=/dev/null`, and
  `SPACK_USER_CONFIG_PATH=/dev/null` prevent system and user compiler configs
  from leaking in, so `gcc-bootstrap.yaml` is the only compiler source Spack
  can see for `gcc-*` variants. For non-GCC PE variants, `toolchains.yaml`
  expresses the compiler constraint via `packages:all:require:`.
  `packages:all:compiler:` was tried but is deprecated in Spack v1.0.x;
  `packages:all:require:` on noarch packages causes concretization failures
  (e.g. `miniforge3`), so the compiler `require:` in `toolchains.yaml` is
  scoped carefully to only apply where correct.
- Stage 5 refreshes Spack modules and renders the `cse-init` module with
  literal release, shared path, module root, and compiler prefix values.

## Variants

Variants use the `<compiler>-<mpi>` slug format. The compiler token encodes
which toolchain drives the build; the MPI token encodes the MPI implementation.

| Variant slug | Compiler | MPI | Notes |
|---|---|---|---|
| `gcc-openmpi` | Spack GCC 13 | OpenMPI (Spack-built) | Generic Linux default |
| `gcc-mpich` | Spack GCC 13 | MPICH (Spack-built) | `device=ch4 netmod=ofi`; Cray libfabric/cray-pals externals detected from profile |
| `gcc-craympich` | Spack GCC 13 | cray-mpich (external) | Cray PE with GNU compiler |
| `gcc-serial` | Spack GCC 13 | none | Serial-only lane |
| `cce-craympich` | CCE (external) | cray-mpich (external) | Cray PE native; requires `PrgEnv-cray` loaded before Stage 1 |
| `cce-serial` | CCE (external) | none | |
| `aocc-openmpi` | AOCC (external) | OpenMPI (Spack-built) | AMD CPU clusters; requires `PrgEnv-aocc` or standalone `aocc` module |
| `nvhpc-openmpi` | NVHPC (external) | OpenMPI (Spack-built) | NVIDIA GPU nodes |
| `nvhpc-craympich` | NVHPC (external) | cray-mpich (external) | |
| `rocmcc-craympich` | ROCmCC (external) | cray-mpich (external) | AMD GPU nodes |
| `intel-impi` | Intel oneAPI (external) | Intel MPI (external) | |

The old `v1-openmpi` and `v2-mpich` slugs are accepted as deprecated aliases
that print a warning and redirect to `gcc-openmpi` and `gcc-mpich` respectively.

Non-GCC PE variants require the relevant `PrgEnv-*` or compiler module to be
loaded before Stage 1. The module sets the env vars (`CRAY_CC_VERSION`,
`AOCC_HOME`, `NVHPC_ROOT`, etc.) that the Cluster Inspector compiler probe
captures as `vendor_substrate.compiler_externals`. Without those vars the
render falls back to operator override env vars (`CSE_CCE_VERSION_OVERRIDE`,
`CSE_CRAY_MPICH_VERSION_OVERRIDE`, etc.).

`CSE_MPICH_SPLICE=1` (optional cray-mpich runtime splice) remains deferred.

## Module Loading

The module design keeps package modules first class while avoiding raw store
paths and Tcl-only module features:

- `cse-init/<COMPILER_UPPER>/<mpi_label>` prepends the generated module tree
  and exposes the CSE compiler baseline. Examples:
  `cse-init/GCC/mpi-openmpi`, `cse-init/GCC/mpi-mpich`,
  `cse-init/CCE/mpi-craympich`, `cse-init/GCC/serial`.
- Package dependencies are loaded by Spack-generated modules, not by `cse-init`.
- Broad dependency autoload is disabled.
- HDF5 MPI modules load the MPI provider module.
- NetCDF modules load only their matching public CSE dependency modules.
- MPI provider modules do not load their low-level implementation dependency
  graph.
- Explicit root entries in package-set `specs:` become public modules.
  Transitive implementation dependencies such as bzip2 and zlib remain
  installed but hidden from `module avail`.
- `use_view: cse_modules` makes generated package modulefiles point at clean
  Spack view prefixes instead of raw hashed install-store prefixes.

Expected user flow:

```bash
module load cse-init/GCC/mpi-openmpi
module load cse/netcdf-fortran/4.6.1-mpi
```

The second command should load NetCDF-Fortran plus the matching NetCDF-C, HDF5,
and MPI provider modules, without loading the full low-level dependency graph.

## Compiler Contract

`cse-init` sets these variables from the clean compiler view path
`${SHARED_PATH}/cse/<release>/<variant>/views/compiler/gcc/<version>`:

- `CSE_GCC_ROOT`
- `CSE_CC`
- `CSE_CXX`
- `CSE_FC`

It prepends GCC `bin` to `PATH`, but does not set global `CC`, `CXX`, or `FC`.
Serial user builds may opt in with `export CC=$CSE_CC`; MPI user builds should
load `cse/openmpi/<version>` or `cse/mpich/<version>` and use MPI wrapper
compilers.

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
- Dry-run `gcc-openmpi` and `gcc-mpich` variants.
- Dry-run `cce-craympich` with a mock Cray profile to verify `toolchains.yaml`
  emits `require: ["%cce@<version>"]` and `cray-mpich` external block.
- Dry-run `network_prepare_request.sh`, `network_fulfill_request.sh`, and
  `network_deploy.sh` with representative artifacts.
- Verify `deploy.sh --render-only` produces all YAML without calling Spack.
- Verify `deploy.sh --fetch` exits after `spack fetch` without calling install.
- Inspect rendered `packages.yaml`: no `openssl:` block when package set uses
  `openssl.mode: spack`.
- Inspect rendered module YAML for root-spec-derived public `include` plus
  `exclude: ["*"]`.
- Inspect generated modulefiles for curated module load/depends-on statements.
- In a clean module shell, verify loading `cse/netcdf-fortran/4.6.1-mpi` loads
  NetCDF-C, HDF5, and MPI, but not the full low-level dependency graph.
