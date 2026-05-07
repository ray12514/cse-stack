# Manual Build Guide

This guide mirrors what `scripts/deploy.sh` does. Prefer `deploy.sh` unless you
are debugging a specific stage.

## Personal Test Build

```bash
./scripts/deploy.sh \
  --variant v1-openmpi \
  --release test \
  --shared-path /tmp/cse-test
```

For a rendering-only check:

```bash
./scripts/deploy.sh \
  --variant v2-mpich \
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
3. Stage 3 renders `packages.yaml`.
4. Stage 4 renders config/modules/spack YAML, reuses an authoritative
   lockfile when supplied, and installs.
5. Stage 5 refreshes Spack modules and renders `cse-init`.

## Package Sets And OpenSSL

`deploy.sh --package-set <name>` is the supported way to switch between the
preferred MPI/PMIx stack and the legacy OpenSSL-compatible stack.

OpenSSL is always a site external and is never built by Spack. If the site
OpenSSL is too old for the selected package set, deploy fails before
concretization and tells you which legacy package set to use.

## Restricted And Air-Gapped Flow

Use the wrapper scripts for prepared deploys:

```bash
./scripts/network_prepare_request.sh --request-dir /tmp/cse-request ...
./scripts/network_fulfill_request.sh --request-dir /tmp/cse-request --output-dir /tmp/cse-artifacts ...
./scripts/network_deploy.sh --manifest /tmp/cse-artifacts/manifest.json --shared-path /shared/cse
```

`restricted` requires a bootstrap bundle, source mirror, and authoritative
lockfile. `airgapped` additionally requires a versioned Spack seed bundle.

## Module Verification

After a successful build:

```bash
module use /tmp/cse-test/cse/modulefiles
module load cse-init/openmpi
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
