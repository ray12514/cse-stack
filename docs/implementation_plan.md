# Computational Software Environment (CSE) — Spack Scaffold Implementation Plan

**Version 1.0 — April 2026**

---

## Document Control

| Item | Value |
|------|-------|
| Prepared for | Internal review with CSE working group |
| Scope | Spack-only implementation plan for the Computational Software Environment |
| Initial package set | HDF5 (serial and parallel), NetCDF-C (serial and parallel), NetCDF-Fortran, NetCDF-CXX4, MPI (Open MPI or Cray-MPICH depending on variant) |
| Target Spack version | 1.2.x (compilers configured in `packages.yaml`) |
| Target module system | Lmod or Tcl Modules (auto-detected per host) |
| Out of scope for v1.0 | Ansible orchestration, CI/CD, container images, multi-site federation, AI/ML baseline, full T2/T3 communication validation |

---

## 1. Executive Summary

The CSE exposes a supported set of scientific libraries through a single namespace of modules. This document defines the Spack-based implementation of that stack and proposes two implementation variants for review.

The user-facing contract is constant across both variants. A user runs `module load cse-init/<mpi>`, which reveals a flat namespace of `cse/<package>` modules. Every `cse/<package>` module sets the conventional environment variables a user needs at compile time and at run time, including `HDF5_HOME`, `NETCDF_DIR`, `MPI_HOME`, and the matching path additions for `bin`, `lib`, and `include`.

---

## 2. Goals, Scope, and Non-Goals

### 2.1 Goals

- Stand up a single CSE release on one system using each variant.
- Produce a flat `cse/<package>` module namespace gated by a `cse-init/<mpi>` activation module.
- Ensure `cse/<package>` modules expose the environment variables required for both compile-time linking and run-time execution, including MPI launcher visibility.
- Produce parallel and serial HDF5 modules and parallel and serial NetCDF-C modules that are clearly distinguishable by name.
- Demonstrate that a user can build a downstream application against either the MPI or serial variant without manual `LD_LIBRARY_PATH` or include-path manipulation.

### 2.2 Non-Goals

- Replacing system MPI on Cray with a Spack-built MPI is not a goal of either variant.
- Centralizing every Python package, framework, or application is out of scope.
- Buildcache distribution, mirroring, and sharing across sites is out of scope for v1.0.
- Multi-compiler or multi-MPI matrices in a single release are out of scope.

### 2.3 Final Working Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Module system | Lmod or Tcl Modules, selected per system | Both are supported; pipeline auto-detects |
| Module layout | Flat per-variant tree, gated by `cse-init` | Avoids fighting Spack's hierarchical generator |
| Compiler config style | `packages.yaml` externals (Spack 1.2 model) | Aligns with current Spack; no `compilers.yaml` |
| Variant A compiler | Spack-built GCC | Reproducibility over build time |
| Variant B compiler | PrgEnv-gnu (system GCC) | Matches Cray-validated programming environment |
| MPI handling | One MPI per variant | Keeps the dependency closure small |
| Variant differentiation | Suffix scheme `-mpi` and `-serial` | Clearer than a hash or hidden variant |

---

## 3. Architecture

### 3.1 Three-Layer Model

| Layer | Contents | Owner |
|-------|----------|-------|
| Substrate | OS packages, kernel, drivers, vendor compilers (Cray PrgEnv on Variant B), vendor MPI on Variant B | Site administrators and the vendor |
| Site-managed CSE layer | Spack install tree, `cse-init` modules, `cse/<package>` modules, Spack environment manifests, release tag in Git | CSE maintainers |
| User overlay | User Spack instances chained upstream to the CSE store, user virtual environments, user source builds | Users |

### 3.2 Where Spack Fits

Spack owns: the release manifest (`spack.yaml`), the lockfile (`spack.lock`), the install tree, generation of modulefiles, and the externals declaration.

### 3.3 Where the Module System Fits

The system `module` command is the user-facing front door. It loads `cse-init/<mpi>` to expose the variant-specific module tree and enforces mutual exclusion between `cse-init/openmpi` and `cse-init/cray-mpich`.

---

## 4. Module Design

### 4.1 The `cse-init` Activation Pattern

Loading `cse-init/<mpi>` does three things:

1. Prepends the variant-specific module tree to `MODULEPATH` so `cse/*` modules become visible.
2. Sets identifying environment variables (`CSE_RELEASE`, `CSE_VARIANT`, `CSE_MPI`, `CSE_ROOT`).
3. Declares membership in the `cse_init` family so loading the other variant automatically unloads the first.

### 4.2 The `cse/<package>` Namespace

After `cse-init/<mpi>` is loaded, the following modules become available:

| Module | Variant A | Variant B |
|--------|-----------|-----------|
| `cse/openmpi` | Built by Spack | Not present |
| `cse/cray-mpich` | Not present | External, exposed |
| `cse/cray-libsci` | Not present | External, exposed |
| `cse/cray-pals` | Not present | External on PBS Cray; omitted on Slurm Cray |
| `cse/cmake` | Built by Spack | Built by Spack |
| `cse/zlib` | Built by Spack | Built by Spack |
| `cse/hdf5-mpi` | HDF5 `+mpi` vs openmpi | HDF5 `+mpi` vs cray-mpich |
| `cse/hdf5-serial` | HDF5 `~mpi` | HDF5 `~mpi` |
| `cse/netcdf-c-mpi` | NetCDF-C `+mpi` | NetCDF-C `+mpi` |
| `cse/netcdf-c-serial` | NetCDF-C `~mpi` | NetCDF-C `~mpi` |
| `cse/netcdf-fortran-mpi` | vs `cse/netcdf-c-mpi` | vs `cse/netcdf-c-mpi` |
| `cse/netcdf-fortran-serial` | vs `cse/netcdf-c-serial` | vs `cse/netcdf-c-serial` |
| `cse/netcdf-cxx4-mpi` | vs `cse/netcdf-c-mpi` | vs `cse/netcdf-c-mpi` |
| `cse/netcdf-cxx4-serial` | vs `cse/netcdf-c-serial` | vs `cse/netcdf-c-serial` |

### 4.3 Mutual Exclusion

- **Lmod**: both `cse-init` modulefiles declare `family("cse_init")`.
- **Tcl Modules**: each declares `conflict cse-init/openmpi` and `conflict cse-init/cray-mpich`.

### 4.4 Environment Variable Contract

Every `cse/<package>` module sets:

| Variable family | Purpose |
|----------------|---------|
| `<NAME>_ROOT`, `<NAME>_DIR`, `<NAME>_HOME` | Compile-time prefix discovery |
| `PATH` | Run-time binary access |
| `LD_LIBRARY_PATH` | Run-time linker resolution |
| `MANPATH`, `PKG_CONFIG_PATH`, `CMAKE_PREFIX_PATH` | Discovery for downstream builds |
| `MPI_HOME`, `MPI_ROOT`, `OMPI_DIR` (Variant A) | MPI prefix |
| `MPICH_DIR`, `CRAY_MPICH_PREFIX_DIR` (Variant B) | MPI prefix on Cray |

---

## 5. Spack Operating Model

### 5.1 Externals Strategy

| Package | Variant A | Variant B |
|---------|-----------|-----------|
| `openssl`, `curl`, `glibc`, `perl` | external, `buildable: false` | same |
| `python` | external, `buildable: true` | same |
| `gcc` | Spack-built (bootstrap) | external (PrgEnv-gnu), `buildable: false` |
| `cray-mpich` | not present | external, `buildable: false` |
| `cray-libsci` | not present | external, `buildable: false` |
| `openmpi` | Spack-built | not present |
| `cmake`, `zlib`, `hdf5`, `netcdf-*` | Spack-built | Spack-built |

### 5.2 Compiler Strategy

**Variant A**: GCC is installed in two stages. A host compiler builds GCC into the CSE store; Spack then registers that GCC as an external in `packages.yaml`.

**Variant B**: The GCC inside PrgEnv-gnu is registered in `packages.yaml` with a `modules:` field so Spack loads PrgEnv-gnu automatically during concretization.

### 5.3 Key `spack.yaml` Settings

```yaml
concretizer:
  unify: true   # single MPI and single compiler for the entire environment
  reuse: true
```

### 5.4 `modules.yaml` Key Features

- `hierarchy: []` — namespace gated externally by `cse-init`, not by Lmod's hierarchy generator.
- `hash_length: 0` — suffix scheme plus explicit version is sufficient to disambiguate.
- `projections: { all: 'cse/{name}' }` — produces the `cse/<name>` namespace.
- `autoload: direct` — loading `cse/netcdf-c-mpi` autoloads its direct dependencies.
- `hide_implicits: true` — transitive packages do not clutter `module avail`.

### 5.5 Permissions

```yaml
packages:
  all:
    permissions:
      read:  world
      write: group
      group: cse
```

Installed files: `-rw-rw-r--`; executables: `-rwxrwxr-x`; directories: `drwxrwxr-x` (mode 775).

### 5.6 Site Views

Two views per variant for non-module workflows:
- `views/mpi` — MPI-aware packages + platform-neutral tooling
- `views/serial` — serial packages + platform-neutral tooling

### 5.7 User-Side Spack via Upstream Chaining

```yaml
# ~/.spack/upstreams.yaml
upstreams:
  cse:
    install_tree: $SHARED_PATH/cse/$CSE_RELEASE/<variant>/store
```

---

## 6. Variant A: Minimal Externals

### Key `packages.yaml` (Variant A)

- `target: [x86_64_v3]`
- `providers.mpi: [openmpi]`
- `require: ["%gcc@13.2.0"]`  *(TODO: confirm version)*
- OS externals: openssl, curl, glibc, perl (all `buildable: false`)
- Bootstrapped GCC registered as external after `stage2_spack.sh`

### Key `spack.yaml` Specs (Variant A)

```yaml
specs:
  - openmpi@5.0.5 +legacylaunchers fabrics=auto schedulers=slurm
  - cmake@3.29.6
  - zlib@1.3.1
  - hdf5@1.14.4 +mpi  +fortran +cxx +hl +threadsafe
  - hdf5@1.14.4 ~mpi  +fortran +cxx +hl +threadsafe
  - netcdf-c@4.9.2 +mpi  +parallel-netcdf  ^hdf5@1.14.4+mpi
  - netcdf-c@4.9.2 ~mpi                    ^hdf5@1.14.4~mpi
  - netcdf-fortran@4.6.1                   ^netcdf-c@4.9.2+mpi
  - netcdf-fortran@4.6.1                   ^netcdf-c@4.9.2~mpi
  - netcdf-cxx4@4.3.1                      ^netcdf-c@4.9.2+mpi
  - netcdf-cxx4@4.3.1                      ^netcdf-c@4.9.2~mpi
```

### User Workflow (Variant A)

```bash
$ module load cse-init/openmpi
$ module avail cse
$ module load cse/openmpi cse/netcdf-fortran-mpi
$ echo "$NETCDF_FORTRAN_DIR"
/shared_path/cse/2026_04/v1-minimal/store/.../netcdf-fortran-4.6.1-...
$ mpif90 -I$NETCDF_FORTRAN_DIR/include -L$NETCDF_FORTRAN_DIR/lib \
         -lnetcdff my_program.f90 -o my_program
$ srun -n 4 ./my_program
```

---

## 7. Variant B: Cray-Integrated

### Key `packages.yaml` (Variant B)

- `target: [zen3]`  *(TODO: confirm against actual Cray node CPU)*
- `providers: { mpi: [cray-mpich], blas: [cray-libsci], lapack: [cray-libsci] }`
- GCC from PrgEnv-gnu with `modules: [PrgEnv-gnu, gcc/<version>]`
- cray-mpich, cray-libsci, cray-pals as externals with `modules:` field
- No openmpi spec; no GCC bootstrap

### Launcher: Slurm vs PBS + PALS

| System type | Launcher | Required |
|-------------|----------|----------|
| Cray with Slurm | `srun` | `cray-mpich` only |
| Cray with PBS Pro | `mpiexec` from `cray-pals` | `cray-mpich` + `cray-pals` |

### User Workflow (Variant B — Slurm Cray)

```bash
$ module load PrgEnv-gnu
$ module load cse-init/cray-mpich
$ module load cse/cray-mpich cse/netcdf-fortran-mpi
$ mpif90 -I$NETCDF_FORTRAN_DIR/include -L$NETCDF_FORTRAN_DIR/lib \
         -lnetcdff my_program.f90 -o my_program
$ srun -n 4 ./my_program
```

*Note: Use `mpicc`/`mpif90` from `cray-mpich`, not the PrgEnv wrappers `cc`/`ftn`/`CC`. The PrgEnv wrappers inject flags that assume the Cray PE defaults; linking against the CSE libraries with those wrappers can introduce silent ABI mismatches.*

---

## 8. Validation Gates

| Check | Pass Criterion |
|-------|---------------|
| Spack environment concretizes | `spack concretize --fresh` exits zero, lockfile produced |
| Every spec installs | `spack install` exits zero on a clean store |
| `module avail cse` shows expected names | All 12 `cse/*` modules present after `cse-init` load |
| Env vars set correctly | `module show cse/<pkg>` confirms `*_HOME`, `*_DIR`, `*_ROOT` |
| MPI variants are mutually exclusive | Loading `cse-init/cray-mpich` after `cse-init/openmpi` unloads the latter |
| Parallel HDF5 smoke test | `h5pcc` builds; `srun -n 4 ./hello-h5` reads/writes a parallel file |
| Serial HDF5 smoke test | `h5cc` builds a serial reader |
| Parallel NetCDF-C smoke test | `nc-config --has-parallel` is `yes`; small parallel write runs |
| Serial NetCDF-Fortran smoke test | `nf-config` reports install prefix; serial write runs |
| Modules visible on compute nodes | `srun module avail cse` matches login node |
| Install tree permissions | `find $SHARED_PATH/cse -not -group cse` returns nothing |
| Site views consistent | `views/mpi/bin/h5dump` and `views/serial/bin/h5dump` both exist |
| Bootstrap reproducibility (Variant A) | Re-running `stage2_spack.sh` from clean state produces same GCC hash |

---

## 9. Open Decisions

*(Fill in before the pilot build; none of these change the scaffold structure.)*

1. **Shared path root** — Currently `${SHARED_PATH}` rendered as `/shared_path`. Confirm the actual filesystem root per site.
2. **Release tag scheme** — Currently `2026_04`. Alternatives: semver (`v1.0.0`) or a build-number scheme.
3. **Target microarchitecture** — Variant A uses `x86_64_v3`; Variant B uses `zen3` as a placeholder.
4. **GCC version for Variant A** — Default `13.2.0`.
5. **PrgEnv-gnu GCC version on the target Cray** — Placeholder `12.3.0`.
6. **cray-mpich and cray-libsci versions** — Placeholders only; filled by Stage 1 (Cluster Inspector).
7. **PnetCDF as `cse/parallel-netcdf` module or transitive dep** — Currently transitive.
8. **Slurm vs PBS pilot for Variant B** — Determines whether `cray-pals` is included on day one.

---

## Appendix A: Environment Variable Reference

| Module | Variables Set Explicitly | Via `prefix_inspections` |
|--------|--------------------------|--------------------------|
| `cse/openmpi` | `MPI_HOME`, `MPI_ROOT`, `MPI_DIR`, `OMPI_DIR` | `PATH`, `LD_LIBRARY_PATH`, `MANPATH`, `PKG_CONFIG_PATH`, `CPATH` |
| `cse/cray-mpich` | `MPI_HOME`, `MPI_ROOT`, `MPICH_DIR`, `CRAY_MPICH_PREFIX_DIR` | (delegated to system module) |
| `cse/cray-libsci` | `CRAY_LIBSCI_PREFIX_DIR`, `LIBSCI_BASE_DIR` | (delegated to system module) |
| `cse/cray-pals` | `CRAY_PALS_PREFIX_DIR` | (delegated to system module) |
| `cse/hdf5-mpi`, `cse/hdf5-serial` | `HDF5_ROOT`, `HDF5_DIR`, `HDF5_HOME` | `PATH`, `LD_LIBRARY_PATH`, `CPATH`, `PKG_CONFIG_PATH` |
| `cse/netcdf-c-{mpi,serial}` | `NETCDF_ROOT`, `NETCDF_DIR`, `NETCDF_HOME`, `NETCDF_C_ROOT` | `PATH`, `LD_LIBRARY_PATH`, `CPATH`, `PKG_CONFIG_PATH` |
| `cse/netcdf-fortran-{mpi,serial}` | `NETCDF_FORTRAN_ROOT`, `NETCDF_FORTRAN_DIR` | `PATH`, `LD_LIBRARY_PATH`, `CPATH`, `PKG_CONFIG_PATH` |
| `cse/netcdf-cxx4-{mpi,serial}` | `NETCDF_CXX_ROOT` | `PATH`, `LD_LIBRARY_PATH`, `CPATH`, `PKG_CONFIG_PATH` |
| `cse/cmake`, `cse/zlib` | `CMAKE_ROOT/DIR/HOME`, `ZLIB_ROOT/DIR/HOME` | `PATH`, `LD_LIBRARY_PATH`, `CPATH`, `PKG_CONFIG_PATH` |
| `cse-init/openmpi` | `CSE_RELEASE`, `CSE_VARIANT`, `CSE_MPI`, `CSE_ROOT`, `MODULEPATH` prepend | — |
| `cse-init/cray-mpich` | Same as above with `CSE_MPI=cray-mpich` | — |
