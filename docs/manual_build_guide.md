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
module load cse/netcdf-fortran-mpi
module list
```

The loaded module list should include NetCDF-Fortran, NetCDF-C, HDF5, MPI, and
their direct dependency modules. This is driven by Spack `autoload: direct`.

## Notes

- `cse-init` exposes the compiler baseline but does not set global `CC`, `CXX`,
  or `FC`.
- MPI builds should use the MPI wrapper compilers from `cse/openmpi` or
  `cse/mpich`.
- On Cray/PBS systems, `cray-pals` is relevant to launcher behavior; on Slurm
  systems use `srun`.
- Advanced users can chain their own Spack instance to the CSE install tree via
  `upstreams.yaml`.

## Docker Real-Build Probe

Use the reduced Docker probe when you want Linux Spack behavior without waiting
for the full CSE stack:

```bash
./scripts/docker_cse_buildcache_test.sh --dry-run
./scripts/docker_cse_buildcache_test.sh --cache-only
```

The script runs the real staged deploy path with `--package-set
public-buildcache-smoke` by default. The default root spec is:

```text
pkgconf@2.5.1
```

Use `CSE_DOCKER_PACKAGE_SET=hdf5-mpi-smoke` when you want the reduced HDF5+MPI
functional stack instead of the public-cache-hit smoke set.

For the default `public-buildcache-smoke` case, the Docker script exports
`CSE_USE_SYSTEM_GCC=1` and uses the container's system GCC as the CSE compiler
baseline. That keeps the deploy stages and module generation intact while
avoiding a cache-only failure on the pinned GCC bootstrap chain.

Persistent state lives under `.docker-spack/cse-buildcache-test`, including
the Spack site, CSE environment, install store, source cache, build stage,
modulefiles, and logs. Delete that directory for a clean rebuild, or run with
`--rebuild-image` to rebuild the Docker image dependency layer.
