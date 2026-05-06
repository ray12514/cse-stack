# Computational Software Environment (CSE) — Phase Two Summary

**Version 1.0 — April 2026**

## Overview

The Computational Software Environment (CSE) is a site-managed software stack that delivers a curated set of scientific libraries (e.g., HDF5, NetCDF, MPI, and supporting tooling) to users on every system the team supports. The goal is to give users one consistent way to find, load, and link against these libraries regardless of which system they log into, while letting the underlying build adapt to each platform.

The CSE is built and managed using Spack, the package manager already used in the broader HPC community. Users do not interact with Spack directly. They interact with environment modules, which is the mechanism users on these systems already know. From a user's perspective, loading the CSE looks the same as loading any other module:

```
module load cse-init/<mpi>
module load cse/netcdf-fortran/4.6.1-mpi
```

After those two commands, the user has the CSE compiler baseline, the MPI launcher, and the NetCDF libraries available through compiler wrappers, pkg-config, CMake prefix paths, and standard include/library paths.

## Implementation Approach

The implementation has three layers, with clean ownership boundaries:

1. **The system substrate.** The operating system, vendor compilers, vendor MPI on Cray systems, and drivers are owned by system administration and the vendor. CSE does not replace any of it.

2. **The CSE layer.** The curated package builds, the module namespace, and the release process are owned by the CSE maintainers and built with Spack.

3. **The user overlay.** Anything users install on top of CSE for their own work is supported only to the extent that it builds on the published CSE baseline.

Each CSE release is captured as a Spack environment with a lockfile that pins every dependency, compiler, and build flag. The maintainers tag the release in version control, build it on the target system, and publish the resulting modules to a shared filesystem visible from login, build, and compute nodes. Users see a stable namespace of `cse/<package>` modules that does not change until the next release. Newer releases are deployed alongside older ones so users can move forward on their own schedule.

## Two Implementation Variants

The plan proposes two variants. Both deliver the same user-facing modules and the same package set. They differ in the MPI provider used by the stack.

**Variant A: Open MPI.** Spack treats only the operating system as a given (OpenSSL, glibc, Perl, Python, curl). It builds its own compiler and Open MPI implementation, then builds the rest of the stack on top of that compiler and MPI. The advantage is portability: the same approach works on any Linux system, including future systems that do not have a vendor-supplied programming environment. The cost is build time, since the compiler is built from source as part of every release.

**Variant B: MPICH with OFI.** Spack builds MPICH with OFI support and may consume detected Cray libfabric and launcher components as externals. The advantage is a generic MPICH path that can still use site fabric components where they exist. A future runtime splice to external `cray-mpich` remains deferred work rather than the current build path.

A first-draft recommendation is to operate both variants in parallel: Variant A as the default on commodity Linux systems, Variant B as the default on Cray systems. Each variant is a separate release with its own modules, but the user-facing module names are identical, so a user who moves between systems does not have to relearn anything.

## What Success Looks Like

A successful CSE release means a user on any supported system can load `cse-init` and the packages they need, build their application against those packages without manual flag-wrangling, and run it. Maintainers can reproduce that release months later from the lockfile in the release tag. New systems can be onboarded by writing a system profile and choosing the appropriate variant, without inventing a new build system.
