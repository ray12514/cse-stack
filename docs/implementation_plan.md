# Computational Software Environment (CSE) — Spack Scaffold Implementation Plan

**Version 2.0 — May 2026**

---

## Document Control

| Item | Value |
|------|-------|
| Prepared for | Internal review with CSE working group |
| Scope | Spack-only implementation plan for the Computational Software Environment |
| Initial package set | HDF5 (serial and parallel), NetCDF-C (serial and parallel), NetCDF-Fortran, NetCDF-CXX4, MPI (Open MPI or MPICH depending on variant) |
| Target Spack version | 1.1.1 (compilers configured in `packages.yaml`) |
| Target module system | Lmod or Tcl Modules (auto-detected per host) |
| Out of scope for v1.0 | Ansible orchestration, CI/CD, container images, multi-site federation, AI/ML baseline, full T2/T3 communication validation |

---

## 1. Executive Summary

The CSE exposes a supported set of scientific libraries through a single namespace of modules. This document defines the Spack-based implementation of that stack with two MPI-based variants designed for reproducible, portable deployment across HPC systems.

The key design principle is **full MPI ownership**: both variants build GCC and MPI entirely from Spack source, with no dependency on vendor compilers or vendor MPI at build time. This ensures identical software versions across every deployment site, with only the hash differing by OS and microarchitecture.

The user-facing contract is constant across both variants. A user runs `module load cse-init/<mpi>`, which reveals a flat namespace of `cse/<package>` modules.

---

## 2. Goals, Scope, and Non-Goals

### 2.1 Goals

- Stand up a single CSE release on any supported Linux system using either variant.
- Produce a flat `cse/<package>` module namespace gated by a `cse-init/<mpi>` activation module.
- Ensure `cse/<package>` modules expose the environment variables required for both compile-time linking and run-time execution.
- Produce parallel and serial HDF5 modules and parallel and serial NetCDF-C modules.
- Support source mirrors for air-gapped deployments and binary build caches for fast re-deploys.
- Position v2-mpich for a future cray-mpich ABI splice (Phase 2; not yet implemented).

### 2.2 Non-Goals

- Centralizing every Python package, framework, or application is out of scope.
- Multi-compiler or multi-MPI matrices in a single release are out of scope.
- Phase 2 ABI splice is out of scope for v1.0.

### 2.3 Final Working Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Module system | Lmod or Tcl Modules, selected per system | Both are supported; pipeline auto-detects |
| Module layout | Flat per-variant tree, gated by `cse-init` | Avoids fighting Spack's hierarchical generator |
| Compiler config style | `packages.yaml` externals (Spack 1.1 model) | Aligns with current Spack; no `compilers.yaml` |
| Compiler source | Spack-built GCC (both variants) | Reproducibility; no PrgEnv-gnu dependency |
| MPI handling | One MPI per variant | Keeps the dependency closure small |
| Variant differentiation | Suffix scheme `-mpi` and `-serial` | Clearer than a hash or hidden variant |
| MPICH transport | `device=ch4 netmod=ofi pmi=pmix` | OFI for Slingshot; PMIx for PBS/PALS and Slurm |
| MPICH version | Auto-detected from cray-mpich series | ABI match for future splice; `--mpich-version` to override |

---

## 3. Architecture

### 3.1 Three-Layer Model

| Layer | Contents | Owner |
|-------|----------|-------|
| Substrate | OS packages, kernel, drivers; on Cray: libfabric (OFI) and cray-pals (PMIx) as externals | Site administrators |
| Site-managed CSE layer | Spack install tree, `cse-init` modules, `cse/<package>` modules, Spack environment manifests, release tag in Git | CSE maintainers |
| User overlay | User Spack instances chained upstream to the CSE store, user virtual environments, user source builds | Users |

### 3.2 Where Spack Fits

Spack owns: the release manifest (`spack.yaml`), the lockfile (`spack.lock`), the install tree, generation of modulefiles, and the externals declaration.

### 3.3 Where the Module System Fits

The system `module` command is the user-facing front door. It loads `cse-init/<mpi>` to expose the variant-specific module tree and enforces mutual exclusion between `cse-init/openmpi` and `cse-init/mpich`.

---

## 4. Variant Definitions

| Variant | Target | Compiler | MPI | Fabric |
|---------|--------|----------|-----|--------|
| `v1-openmpi` | Any Linux | Spack GCC@13.2.0 | OpenMPI@5.0.5 | auto (UCX/OFI/verbs) |
| `v2-mpich` | Any Linux; optimised for Cray | Spack GCC@13.2.0 | MPICH@3.4.3 or @4.2.2 | OFI/libfabric; libfabric external on Cray |

**MPICH version selection:**
- `cray-mpich 8.x` detected in profile → `mpich@3.4.3`
- `cray-mpich 9.x` detected in profile → `mpich@4.2.2`
- Non-Cray / undetected → `mpich@4.2.2`
- Override with `./deploy.sh --mpich-version <ver>`

---

## 5. Module Design

### 5.1 The `cse-init` Activation Pattern

Loading `cse-init/<mpi>` does three things:

1. Prepends the variant-specific module tree to `MODULEPATH` so `cse/*` modules become visible.
2. Sets identifying environment variables (`CSE_RELEASE`, `CSE_VARIANT`, `CSE_MPI`, `CSE_ROOT`).
3. Declares membership in the `cse_init` family so loading the other variant automatically unloads the first.

### 5.2 The `cse/<package>` Namespace

After `cse-init/<mpi>` is loaded:

| Module | v1-openmpi | v2-mpich |
|--------|-----------|---------|
| `cse/openmpi` | Built by Spack | Not present |
| `cse/mpich` | Not present | Built by Spack |
| `cse/cmake` | Built by Spack | Built by Spack |
| `cse/zlib` | Built by Spack | Built by Spack |
| `cse/hdf5-mpi` | HDF5 `+mpi ^openmpi` | HDF5 `+mpi ^mpich` |
| `cse/hdf5-serial` | HDF5 `~mpi` | HDF5 `~mpi` |
| `cse/netcdf-c-mpi` | NetCDF-C `+mpi` | NetCDF-C `+mpi` |
| `cse/netcdf-c-serial` | NetCDF-C `~mpi` | NetCDF-C `~mpi` |
| `cse/netcdf-fortran-mpi` | vs `cse/netcdf-c-mpi` | vs `cse/netcdf-c-mpi` |
| `cse/netcdf-fortran-serial` | vs `cse/netcdf-c-serial` | vs `cse/netcdf-c-serial` |
| `cse/netcdf-cxx4-mpi` | vs `cse/netcdf-c-mpi` | vs `cse/netcdf-c-mpi` |
| `cse/netcdf-cxx4-serial` | vs `cse/netcdf-c-serial` | vs `cse/netcdf-c-serial` |

### 5.3 Mutual Exclusion

- **Lmod**: both `cse-init` modulefiles declare `family("cse_init")`.
- **Tcl Modules**: each declares `conflict cse-init/openmpi` and `conflict cse-init/mpich`.

### 5.4 Environment Variable Contract

Every `cse/<package>` module sets:

| Variable family | Purpose |
|----------------|---------|
| `<NAME>_ROOT`, `<NAME>_DIR`, `<NAME>_HOME` | Compile-time prefix discovery |
| `PATH` | Run-time binary access |
| `LD_LIBRARY_PATH` | Run-time linker resolution |
| `MANPATH`, `PKG_CONFIG_PATH` | Discovery for downstream builds |
| `MPI_HOME`, `MPI_ROOT`, `MPI_DIR`, `OMPI_DIR` (v1-openmpi) | MPI prefix |
| `MPI_HOME`, `MPI_ROOT`, `MPICH_DIR` (v2-mpich) | MPI prefix |

---

## 6. Spack Operating Model

### 6.1 Externals Strategy

| Package | v1-openmpi | v2-mpich (non-Cray) | v2-mpich (Cray) |
|---------|-----------|---------------------|-----------------|
| `openssl`, `curl`, `glibc`, `perl` | external, `buildable: false` | same | same |
| `python` | external, `buildable: true` | same | same |
| `gcc` | Spack-built (bootstrap) | same | same |
| `libfabric` | not present | not present | external from system module |
| `cray-pals` | not present | not present | external (PBS Cray only) |
| `openmpi` | Spack-built | not present | not present |
| `mpich` | not present | Spack-built | Spack-built |
| `cmake`, `zlib`, `hdf5`, `netcdf-*` | Spack-built | same | same |

### 6.2 Compiler Strategy

Both variants: GCC is installed by Spack into `<variant>/bootstrap/gcc-<ver>`, then registered as an external in `packages.yaml` with compiler attribute entries. Spack uses this GCC for all subsequent builds.

### 6.3 Key `spack.yaml` Settings

```yaml
concretizer:
  unify: when_possible
  reuse: true
```

### 6.4 `modules.yaml` Key Features

- `hierarchy: []` (Lmod only) — namespace gated externally by `cse-init`, not Lmod's hierarchy.
- `hash_length: 0` — suffix scheme plus explicit version disambiguates.
- `projections: { all: 'cse/{name}' }` — produces the `cse/<name>` namespace.
- `autoload: direct` — loading `cse/netcdf-c-mpi` autoloads direct dependencies.
- `hide_implicits: true` — transitive packages do not clutter `module avail`.

### 6.5 Permissions

```yaml
packages:
  all:
    permissions:
      read:  world
      write: group
      group: <group>   # default: $(id -gn); override with --group
```

Installed files: `-rw-rw-r--`; executables: `-rwxrwxr-x`; directories: `drwxrwxr-x` (mode 775).

### 6.6 Site Views

Two views per variant for non-module workflows:
- `views/mpi` — MPI-aware packages + platform-neutral tooling
- `views/serial` — serial packages + platform-neutral tooling

### 6.7 Build Cache and Source Mirror

```bash
# Source mirror (air-gapped / restricted networks)
./deploy.sh --variant v1-openmpi ... --mirror-path /path/to/mirror

# Binary build cache (fast re-deploy)
./deploy.sh --variant v1-openmpi ... --buildcache-uri file:///path/or/s3://bucket
```

After `spack install`, stage4 automatically pushes to the build cache URI if set. On subsequent deploys, Spack pulls matching binaries before falling back to source.

### 6.8 User-Side Spack via Upstream Chaining

```yaml
# ~/.spack/upstreams.yaml
upstreams:
  cse:
    install_tree: $SHARED_PATH/cse/$CSE_RELEASE/<variant>/store
```

---

## 7. Variant A: v1-openmpi

### User Workflow

```bash
$ module load cse-init/openmpi
$ module avail cse
$ module load cse/openmpi cse/netcdf-fortran-mpi
$ echo "$NETCDF_FORTRAN_DIR"
/shared_path/cse/2026_04/v1-openmpi/store/.../netcdf-fortran-4.6.1-...
$ mpif90 -I$NETCDF_FORTRAN_DIR/include -L$NETCDF_FORTRAN_DIR/lib \
         -lnetcdff my_program.f90 -o my_program
$ srun -n 4 ./my_program
```

---

## 8. Variant B: v2-mpich

### User Workflow (any Linux)

```bash
$ module load cse-init/mpich
$ module avail cse
$ module load cse/mpich cse/hdf5-mpi cse/netcdf-fortran-mpi
$ echo "$MPICH_DIR"
/shared_path/cse/2026_04/v2-mpich/store/.../mpich-4.2.2-...
$ mpif90 -I$NETCDF_FORTRAN_DIR/include -L$NETCDF_FORTRAN_DIR/lib \
         -lnetcdff my_program.f90 -o my_program
$ srun -n 4 ./my_program
```

### Cray / Slingshot Specifics

On Cray systems with Slingshot HSN, libfabric is detected from `modules.loaded` in the Cluster Inspector profile and registered as an external. MPICH is then built with `netmod=ofi` and uses the system libfabric for OFI transport automatically.

Phase 2 (future): when `CSE_MPICH_SPLICE=1`, the `cse-init/mpich` module will swap in `cray-mpich` at runtime via `LD_LIBRARY_PATH`, exploiting MPICH ABI compatibility. The Spack-built MPICH version is deliberately matched to the installed cray-mpich series to ensure ABI stability.

### Launcher: Slurm vs PBS + PALS

| System type | Launcher | MPICH PMI |
|-------------|----------|-----------|
| Any (Slurm) | `srun` | `pmi=pmix` (Slurm PMIx) |
| Cray PBS | `mpiexec` from cray-pals | `pmi=pmix` (PALS PMIx) |

cray-pals is detected automatically by Stage 1 and added as an external only on PBS Cray systems.

---

## 9. Validation Gates

| Check | Pass Criterion |
|-------|---------------|
| Spack environment concretizes | `spack concretize --fresh` exits zero, lockfile produced |
| Every spec installs | `spack install` exits zero on a clean store |
| `module avail cse` shows expected names | All 12 `cse/*` modules present after `cse-init` load |
| Env vars set correctly | `module show cse/<pkg>` confirms `*_HOME`, `*_DIR`, `*_ROOT` |
| MPI variants are mutually exclusive | Loading `cse-init/mpich` after `cse-init/openmpi` unloads the latter |
| Parallel HDF5 smoke test | `h5pcc` builds; `srun -n 4 ./hello-h5` reads/writes a parallel file |
| Serial HDF5 smoke test | `h5cc` builds a serial reader |
| Parallel NetCDF-C smoke test | `nc-config --has-parallel` is `yes`; small parallel write runs |
| Serial NetCDF-Fortran smoke test | `nf-config` reports install prefix; serial write runs |
| Modules visible on compute nodes | `srun module avail cse` matches login node |
| Install tree permissions | `find $SHARED_PATH/cse -not -group <group>` returns nothing |
| Site views consistent | `views/mpi/bin/h5dump` and `views/serial/bin/h5dump` both exist |
| Build cache round-trip | Clean store + `--buildcache-uri` → binaries pulled on re-install |

---

## 10. Open Decisions

*(Fill in before the pilot build; none of these change the scaffold structure.)*

1. **Shared path root** — Currently `${SHARED_PATH}` rendered as `/shared_path`. Confirm the actual filesystem root per site.
2. **Release tag scheme** — Currently `2026_04`. Alternatives: semver (`v1.0.0`) or a build-number scheme.
3. **Target microarchitecture** — Both variants use `x86_64_v3` by default; auto-detected from Cluster Inspector `hardware.cpu.microarch` when available.
4. **PnetCDF as `cse/parallel-netcdf` module or transitive dep** — Currently transitive.
5. **Phase 2 cray-mpich splice** — `CSE_MPICH_SPLICE=1` path reserved; implementation deferred.

---

## Appendix A: Environment Variable Reference

| Module | Variables Set Explicitly | Via `prefix_inspections` |
|--------|--------------------------|--------------------------|
| `cse/openmpi` | `MPI_HOME`, `MPI_ROOT`, `MPI_DIR`, `OMPI_DIR` | `PATH`, `LD_LIBRARY_PATH`, `MANPATH`, `PKG_CONFIG_PATH`, `CPATH` |
| `cse/mpich` | `MPI_HOME`, `MPI_ROOT`, `MPICH_DIR` | `PATH`, `LD_LIBRARY_PATH`, `MANPATH`, `PKG_CONFIG_PATH`, `CPATH` |
| `cse/hdf5-mpi`, `cse/hdf5-serial` | `HDF5_ROOT`, `HDF5_DIR`, `HDF5_HOME` | `PATH`, `LD_LIBRARY_PATH`, `CPATH`, `PKG_CONFIG_PATH` |
| `cse/netcdf-c-{mpi,serial}` | `NETCDF_ROOT`, `NETCDF_DIR`, `NETCDF_HOME`, `NETCDF_C_ROOT` | `PATH`, `LD_LIBRARY_PATH`, `CPATH`, `PKG_CONFIG_PATH` |
| `cse/netcdf-fortran-{mpi,serial}` | `NETCDF_FORTRAN_ROOT`, `NETCDF_FORTRAN_DIR` | `PATH`, `LD_LIBRARY_PATH`, `CPATH`, `PKG_CONFIG_PATH` |
| `cse/netcdf-cxx4-{mpi,serial}` | `NETCDF_CXX_ROOT` | `PATH`, `LD_LIBRARY_PATH`, `CPATH`, `PKG_CONFIG_PATH` |
| `cse/cmake`, `cse/zlib` | `CMAKE_ROOT/DIR/HOME`, `ZLIB_ROOT/DIR/HOME` | `PATH`, `LD_LIBRARY_PATH`, `CPATH`, `PKG_CONFIG_PATH` |
| `cse-init/openmpi` | `CSE_RELEASE`, `CSE_VARIANT`, `CSE_MPI=openmpi`, `CSE_ROOT`, `MODULEPATH` prepend | — |
| `cse-init/mpich` | `CSE_RELEASE`, `CSE_VARIANT`, `CSE_MPI=mpich`, `CSE_ROOT`, `MODULEPATH` prepend | — |
