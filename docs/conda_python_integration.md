# Conda And Python Integration

## Purpose

CSE should give users a reliable compiled software baseline without taking over
every Python workflow. Spack is the authority for compiled libraries, MPI,
compiler baseline, modules, lockfiles, source mirrors, and buildcache policy.
Conda or compatible tools may still be useful for Python application
environments, notebooks, and user overlays, but those environments must not
silently replace the compiled CSE ABI.

This document defines the integration model for Python and Conda-like tooling.

## Python Layers

| Layer | Managed By | Purpose |
|---|---|---|
| System Python | OS or site admins | Operating system tools and vendor packages |
| Spack Python | CSE maintainers | Build-time and runtime Python required by CSE packages |
| CSE Python modules | CSE maintainers | Public Python packages that need CSE ABI integration |
| Conda environments | Users or app teams | Application-level Python dependencies and notebooks |

The critical boundary is ABI ownership. Packages that link to CSE MPI, HDF5,
NetCDF, or other compiled CSE libraries should either be built by Spack or be
clearly documented as a user overlay that depends on loaded CSE modules.

## Supported Patterns

### Spack-Built Python Package

Use this when the Python package wraps compiled CSE libraries or must be part
of the stable module interface.

Examples:

- `py-mpi4py` built against `cse/openmpi` or `cse/mpich`.
- `py-h5py` built against the CSE HDF5 ABI.
- Python bindings for NetCDF or other catalog libraries.

Publication model:

```bash
module load cse-init/openmpi
module load cse/py-mpi4py/<version>-mpi
```

### User Conda Overlay On CSE Modules

Use this when users need Python packages that do not have to become part of the
site-supported CSE catalog.

Expected flow:

```bash
module load cse-init/openmpi
module load cse/hdf5/<version>-mpi
conda activate my-analysis
```

Guidance:

- Create the Conda environment after loading the intended CSE modules when
  building packages from source.
- Prefer pure-Python Conda packages when mixing with CSE compiled libraries.
- Avoid installing Conda MPI, HDF5, NetCDF, or compiler runtime packages into
  an environment intended to use CSE ABI libraries.
- Document environment files with the required CSE modules next to the Conda
  dependencies.

### Curated Conda Application Environment

Use this only when a project needs a managed Python application stack but not a
general CSE module. The release manifest should record:

- Conda environment file or lockfile.
- Required CSE modules.
- Solver platform.
- Creation tool and version.
- Smoke test command.

The environment should live outside the core CSE module namespace unless the
team agrees to support it as a public module.

## Unsupported Patterns

- Replacing CSE MPI, HDF5, NetCDF, or compiler runtimes with Conda packages in
  the same shell after loading CSE modules.
- Publishing Conda environments as stable CSE modules without a lockfile and
  smoke test.
- Treating Conda as the release authority for compiled HPC libraries that are
  already in the CSE catalog.
- Mixing incompatible MPI implementations between Conda packages and loaded
  CSE modules.

## Roadmap

### Phase 1: Documentation And Guardrails

- Add user-facing guidance for creating Conda overlays on top of CSE modules.
- Add examples for pure-Python overlays and compiled-extension overlays.
- Add troubleshooting notes for `LD_LIBRARY_PATH`, `PATH`, and MPI mismatch
  symptoms.

### Phase 2: Catalog Integration

- Add optional catalog fields for Python bindings and Conda overlay examples.
- Define module naming for Spack-built Python packages, such as
  `cse/py-mpi4py/<version>-mpi`.
- Add smoke tests that import Python modules and verify linked library paths.

### Phase 3: Curated Application Environments

- Support checked-in Conda environment lockfiles for selected application
  teams.
- Record Conda artifacts in the release manifest.
- Validate that curated environments do not mask CSE-provided MPI or core CSE
  libraries unless that masking is explicit and supported.

## Validation Commands

Useful smoke checks include:

```bash
python -c "import mpi4py.MPI as MPI; print(MPI.Get_library_version())"
python -c "import h5py; print(h5py.version.info)"
python -c "import netCDF4; print(netCDF4.__netcdf4libversion__)"
which mpicc
mpicc --show
```

For Conda overlays, compare loaded libraries with `ldd` or platform-specific
equivalents and confirm the MPI provider matches the loaded CSE module.
