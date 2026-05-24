# Computational Software Environment (CSE) — Phase Two Summary

**Version 1.0 — April 2026**

## Overview

The Computational Software Environment (CSE) is a site-managed software stack that delivers a curated set of scientific libraries (e.g., HDF5, NetCDF, MPI, and supporting tooling) to users on every system the team supports. The goal is to give users one consistent way to find, load, and link against these libraries regardless of which system they log into, while letting the underlying build adapt to each platform.

The CSE is built and managed using Spack, the package manager already used in the broader HPC community. Users do not interact with Spack directly. They interact with environment modules, which is the mechanism users on these systems already know. From a user's perspective, loading the CSE looks the same as loading any other module:

```
module load cse-init/GCC/mpi-openmpi
module load cse/netcdf-fortran/4.6.1-mpi
```

The `cse-init` module name encodes the compiler family and MPI lane
(`cse-init/<COMPILER_UPPER>/<mpi_label>`). Common examples:
`cse-init/GCC/mpi-openmpi`, `cse-init/GCC/mpi-mpich`,
`cse-init/CCE/mpi-craympich`, `cse-init/GCC/serial`.

After those two commands, the user has the compilers, the MPI launcher, and the NetCDF libraries available, with all the environment variables expected by standard build tools already set.

## Implementation Approach

The implementation has three layers, with clean ownership boundaries:

1. **The system substrate.** The operating system, vendor compilers, vendor MPI on Cray systems, and drivers are owned by system administration and the vendor. CSE does not replace any of it.

2. **The CSE layer.** The curated package builds, the module namespace, and the release process are owned by the CSE maintainers and built with Spack.

3. **The user overlay.** Anything users install on top of CSE for their own work is supported only to the extent that it builds on the published CSE baseline.

Each CSE release is captured as a Spack environment with a lockfile that pins every dependency, compiler, and build flag. The maintainers tag the release in version control, build it on the target system, and publish the resulting modules to a shared filesystem visible from login, build, and compute nodes. Users see a stable namespace of `cse/<package>` modules that does not change until the next release. Newer releases are deployed alongside older ones so users can move forward on their own schedule.

## Variant Naming

Variants use a `<compiler>-<mpi>` slug that encodes the toolchain identity
directly in the name. Examples: `gcc-openmpi`, `gcc-mpich`, `cce-craympich`,
`nvhpc-craympich`, `aocc-openmpi`. Each variant produces its own release with
its own modules, but the user-facing `cse/<package>` module names are the same
across all variants so users do not have to relearn the module namespace when
moving between systems.

**`gcc-*` variants** (generic Linux): Spack treats only the operating system as
a given (OpenSSL, glibc, Perl, Python, curl). It builds its own GCC and its own
MPI, then builds the rest of the stack on top. Portable across any Linux system.

**PE variants** (`cce-*`, `aocc-*`, `nvhpc-*`, `rocmcc-*`): On systems with a
vendor programming environment, Spack treats the PE compiler, cray-mpich, and
related vendor libraries as externals. The resulting binaries link against
vendor-validated MPI and interconnect libraries, which is the supported
configuration for high-performance fabrics. Requires the relevant `PrgEnv-*`
module to be loaded before Stage 1 so the Cluster Inspector compiler probe can
capture the external versions and install prefixes.

The default on commodity Linux systems is `gcc-openmpi`. The default on Cray
systems is typically `cce-craympich` or `gcc-craympich` depending on whether
CCE or GCC is the preferred compiler.

## What Success Looks Like

A successful CSE release means a user on any supported system can load `cse-init` and the packages they need, build their application against those packages without manual flag-wrangling, and run it. Maintainers can reproduce that release months later from the lockfile in the release tag. New systems can be onboarded by writing a system profile and choosing the appropriate variant, without inventing a new build system.
