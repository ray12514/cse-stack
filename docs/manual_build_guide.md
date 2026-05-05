# CSE Manual Build Guide

**May 2026**

This document walks through building a CSE release by hand using Spack directly — no deploy scripts, no automation. It is intended for a teammate who wants to understand the process or reproduce a build on a new system step by step.

---

## What We Are Building

A curated set of scientific libraries under a `cse/<package>` module namespace, built against a single compiler and a single MPI implementation. The same package versions are deployed on every system; only the hash changes by OS and CPU.

### Package Set

| Spack spec | Module name | Notes |
|---|---|---|
| `openmpi@5.0.5` or `mpich@4.2.2` | `cse/openmpi` / `cse/mpich` | One MPI per variant |
| `hdf5@1.14.4 +mpi` | `cse/hdf5-mpi` | Parallel HDF5 |
| `hdf5@1.14.4 ~mpi` | `cse/hdf5-serial` | Serial HDF5 |
| `netcdf-c@4.9.2 +mpi +parallel-netcdf` | `cse/netcdf-c-mpi` | Parallel NetCDF |
| `netcdf-c@4.9.2 ~mpi` | `cse/netcdf-c-serial` | Serial NetCDF |
| `netcdf-fortran@4.6.1` | `cse/netcdf-fortran-mpi` / `-serial` | vs either NetCDF-C |
| `netcdf-cxx4@4.3.1` | `cse/netcdf-cxx4-mpi` / `-serial` | vs either NetCDF-C |
| `cmake@3.29.6` | `cse/cmake` | |
| `zlib@1.3.1` | `cse/zlib` | |

Two variants are supported. Choose one per deployment:

| Variant | MPI | Notes |
|---|---|---|
| `v1-openmpi` | Spack-built OpenMPI 5.0.5 | Any Linux |
| `v2-mpich` | Spack-built MPICH 4.2.2 (or 3.4.3 on cray-mpich 8.x systems) | Any Linux; uses system libfabric on Cray/Slingshot |

Both variants build GCC 13.3.0 from Spack. Neither depends on vendor compilers.

---

## Prerequisites

On the target system before starting:

```bash
# Python with Jinja2 and PyYAML (for the template renderer — not needed if
# you write the YAML files by hand as shown in this guide)
pip install jinja2 pyyaml

# Git and a host C/C++/Fortran compiler (to compile GCC from source)
# RHEL/Rocky:
dnf install git gcc g++ gfortran make patch
# Debian/Ubuntu:
apt-get install git build-essential gfortran
```

---

## Directory Layout

Everything lives under a shared root. Replace `/shared/cse` and `2026_04` with
your actual path and release tag.

```
/shared/cse/
├── spack-site/            ← Spack clone (shared across releases)
├── cache/
│   ├── source/            ← downloaded tarballs (shared across releases)
│   └── bootstrap/         ← Spack internal bootstrap cache
└── 2026_04/
    └── v1-openmpi/        ← one directory per variant per release
        ├── spack-bootstrap/
        │   └── spack/     ← throwaway Spack instance used to build GCC
        ├── bootstrap/
        │   └── gcc-13.3.0/← the GCC view (bin/, lib64/, include/)
        ├── gcc-bootstrap.yaml  ← GCC registered as external (written in Step 3)
        ├── env/           ← Spack environment (the four YAML files live here)
        │   ├── spack.yaml
        │   ├── packages.yaml
        │   ├── config.yaml
        │   └── modules.yaml
        ├── store/         ← Spack install tree
        ├── modules/       ← generated modulefiles
        └── views/
            ├── mpi/       ← flat view of MPI packages
            └── serial/    ← flat view of serial packages
```

---

## Step 1 — Clone Spack

```bash
SHARED=/shared/cse
SPACK_SITE=$SHARED/spack-site

git clone --depth 1 --branch v1.1.1 \
    https://github.com/spack/spack.git "$SPACK_SITE"
```

Keep this clone as the shared Spack installation. Both variants reference it.

---

## Step 2 — Bootstrap GCC

A throwaway Spack instance builds GCC so the CSE store is not entangled with
the bootstrap compiler. This takes 30–90 minutes on first run.

```bash
RELEASE=2026_04
VARIANT=v1-openmpi
VARIANT_DIR=$SHARED/$RELEASE/$VARIANT
GCC_VERSION=13.3.0

# Isolate from personal and system Spack config
export SPACK_DISABLE_LOCAL_CONFIG=1
export SPACK_USER_CACHE_PATH=$SHARED/cache/bootstrap
export SPACK_SYSTEM_CONFIG_PATH=/dev/null

# Clone a separate Spack instance just for bootstrapping GCC
git clone --depth 1 --branch v1.1.1 \
    https://github.com/spack/spack.git "$VARIANT_DIR/spack-bootstrap/spack"

. "$VARIANT_DIR/spack-bootstrap/spack/share/spack/setup-env.sh"

# Register the host compiler so Spack can build GCC
spack compiler add /usr/bin   # or wherever gcc/g++/gfortran live

# Build GCC
spack install -j 4 gcc@$GCC_VERSION ~bootstrap +binutils

# Copy the installed GCC into a clean view (a flat prefix tree)
GCC_HASH=$(spack find --format '{hash:7}' "gcc@$GCC_VERSION" | head -1)
spack view copy "$VARIANT_DIR/bootstrap/gcc-$GCC_VERSION" "/$GCC_HASH"
```

---

## Step 3 — Register the Bootstrapped GCC as an External

Write `gcc-bootstrap.yaml` next to the env directory. The `spack.yaml` in the
next step includes this file so Spack uses the GCC you just built instead of
trying to build another one.

```bash
mkdir -p "$VARIANT_DIR/env"
GCC_PREFIX=$VARIANT_DIR/bootstrap/gcc-$GCC_VERSION

cat > "$VARIANT_DIR/gcc-bootstrap.yaml" <<EOF
packages:
  gcc:
    buildable: false
    externals:
      - spec: gcc@$GCC_VERSION languages='c,c++,fortran'
        prefix: $GCC_PREFIX
        extra_attributes:
          compilers:
            c:       $GCC_PREFIX/bin/gcc
            cxx:     $GCC_PREFIX/bin/g++
            fortran: $GCC_PREFIX/bin/gfortran
          extra_rpaths:
            - $GCC_PREFIX/lib64
EOF
```

---

## Step 4 — Write the Environment Files

Four YAML files live in `env/`. Write them by hand or copy from the examples
below. Adjust paths, versions, and group name to match your site.

### `env/packages.yaml`

Tells Spack which packages are already on the system (OS externals) and which
compiler to use for everything.

```yaml
packages:
  all:
    target: [x86_64]
    providers:
      mpi: [openmpi]        # use [mpich] for v2-mpich
    require:
      - "%gcc@13.3.0"
    permissions:
      read:  world
      write: group
      group: cse            # shared filesystem group

  # OS-level packages — get actual versions from the system:
  #   openssl version, curl --version, perl -e 'printf "%vd\n",$^V', python3 --version
  openssl:
    buildable: false
    externals:
      - spec: openssl@<detected-version>
        prefix: /usr

  curl:
    buildable: true
    externals:
      - spec: curl@<detected-version>
        prefix: /usr

  glibc:
    buildable: false
    externals:
      - spec: glibc@<detected-version>
        prefix: /usr

  perl:
    buildable: true
    externals:
      - spec: perl@<detected-version>
        prefix: /usr

  python:
    buildable: true
    externals:
      - spec: python@<detected-version>
        prefix: /usr
```

> **Important**: Run `openssl version`, `curl --version`, etc. on the target
> system and fill in the real version numbers. Do not guess or copy from another
> system — a wrong version with `buildable: false` will cause concretization to fail.

For `v2-mpich` on a Cray with Slingshot, add libfabric and (if PBS) cray-pals:

```yaml
  libfabric:
    buildable: false
    externals:
      - spec: libfabric@1.15.2        # check: module show libfabric
        prefix: /opt/cray/pe/libfabric/1.15.2
        modules: [libfabric/1.15.2]

  pals:
    buildable: false
    externals:
      - spec: pals@1.4.0              # check: module show cray-pals
        prefix: /opt/cray/pe/pals/1.4.0
        modules: [cray-pals/1.4.0]
```

### `env/config.yaml`

Controls the install tree location, build parallelism, and binary relocation.

```yaml
config:
  install_tree:
    root: /shared/cse/2026_04/v1-openmpi/store
    projections:
      all: '{architecture}/{compiler.name}-{compiler.version}/{name}-{version}-{hash:7}'
    padded_length: 256    # makes installed binaries relocatable for build cache

  build_stage:
    - $tempdir/$user/spack-stage

  source_cache: /shared/cse/cache/source
  misc_cache:   /shared/cse/cache/misc
  build_jobs:   16

  shared_linking:
    type: rpath
    bind: true
```

### `env/modules.yaml`

Controls how Spack generates the `cse/<package>` modulefiles.

```yaml
modules:
  prefix_inspections:
    bin:     [PATH]
    lib:     [LD_LIBRARY_PATH]
    lib64:   [LD_LIBRARY_PATH]
    include: [CPATH]
    lib/pkgconfig:   [PKG_CONFIG_PATH]
    lib64/pkgconfig: [PKG_CONFIG_PATH]
    share/man:       [MANPATH]

  default:
    enable:
      - lmod          # or tcl — match what your system uses
    use_view: false
    roots:
      lmod: /shared/cse/2026_04/v1-openmpi/modules
    lmod:
      hierarchy: []
      hash_length: 0
      hide_implicits: true
      exclude_implicits: true
      projections:
        all: 'cse/{name}'
      all:
        autoload: direct
        environment:
          set:
            '{name}_ROOT': '{prefix}'
            '{name}_DIR':  '{prefix}'
            '{name}_HOME': '{prefix}'

      hdf5:
        suffixes:
          '+mpi': 'mpi'
          '~mpi': 'serial'

      netcdf-c:
        suffixes:
          '+mpi': 'mpi'
          '~mpi': 'serial'

      netcdf-fortran:
        suffixes:
          '^netcdf-c +mpi': 'mpi'
          '^netcdf-c ~mpi': 'serial'

      netcdf-cxx4:
        suffixes:
          '^netcdf-c +mpi': 'mpi'
          '^netcdf-c ~mpi': 'serial'

      openmpi:
        environment:
          set:
            MPI_HOME:  '{prefix}'
            MPI_ROOT:  '{prefix}'
            MPI_DIR:   '{prefix}'
            OMPI_DIR:  '{prefix}'

      # For v2-mpich, replace the openmpi block above with:
      # mpich:
      #   environment:
      #     set:
      #       MPI_HOME:  '{prefix}'
      #       MPI_ROOT:  '{prefix}'
      #       MPICH_DIR: '{prefix}'
```

### `env/spack.yaml`

The environment manifest — references the other three files and lists every spec
to install.

```yaml
spack:
  include:
    - ./packages.yaml
    - ./config.yaml
    - ./modules.yaml
    - ../gcc-bootstrap.yaml    # written in Step 3

  view:
    mpi:
      root: /shared/cse/2026_04/v1-openmpi/views/mpi
      select: ["+mpi", openmpi, cmake, zlib]
      link: all
      link_type: symlink
    serial:
      root: /shared/cse/2026_04/v1-openmpi/views/serial
      select: ["hdf5~mpi", "netcdf-c~mpi", "netcdf-fortran ^netcdf-c~mpi",
               "netcdf-cxx4 ^netcdf-c~mpi", cmake, zlib]
      link: all
      link_type: symlink

  concretizer:
    unify: when_possible
    reuse: true

  specs:
    # MPI — pick one:
    - openmpi@5.0.5 fabrics=auto schedulers=slurm
    # - mpich@4.2.2 device=ch4 netmod=ofi pmi=pmix   # v2-mpich

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

---

## Step 5 — Concretize and Install

```bash
# Point at the bootstrap Spack (the same one used in Step 2)
export SPACK_ROOT=$VARIANT_DIR/spack-bootstrap/spack
export SPACK_DISABLE_LOCAL_CONFIG=1
export SPACK_USER_CACHE_PATH=$SHARED/cache/spack
export SPACK_SYSTEM_CONFIG_PATH=/dev/null

. "$SPACK_ROOT/share/spack/setup-env.sh"

# Activate the environment
spack env activate -d "$VARIANT_DIR/env"

# Concretize — resolves the full dependency closure and writes spack.lock
# Use --fresh to ignore any cached concretization from a previous run
spack concretize --fresh

# Review what will be built (optional but recommended on first run)
spack concretize --fresh 2>&1 | grep -E "^( - |\+)" | head -40

# Install everything
# --fail-fast stops at the first failure so you see a clean error
spack install -j 4 --fail-fast
```

If a package fails, fix the issue (usually a missing system library or wrong
external version) and re-run `spack install`. Spack will skip already-installed
packages and continue from where it left off.

---

## Step 6 — Generate Modulefiles

```bash
spack module lmod refresh --delete-tree -y
# or for Tcl:
# spack module tcl refresh --delete-tree -y
```

Modulefiles land in `/shared/cse/2026_04/v1-openmpi/modules/`. Each package gets
a file under `cse/<name>/<version>.lua` (or `.tcl`).

---

## Step 7 — Install the `cse-init` Activation Module

The `cse-init/<mpi>` module is the front door. It prepends the variant's module
tree to `MODULEPATH` so `cse/*` packages become visible.

Copy the hand-written modulefiles from this repo to your site modulefile
directory (wherever `module avail` looks for system modules):

```bash
SITE_MODULES=/your/site/modulefiles

# For v1-openmpi:
mkdir -p "$SITE_MODULES/cse-init"
cp modules/cse-init/openmpi.lua "$SITE_MODULES/cse-init/openmpi.lua"
# or for Tcl:
# cp modules/cse-init/openmpi.tcl "$SITE_MODULES/cse-init/openmpi"

# For v2-mpich:
# cp modules/cse-init/mpich.lua "$SITE_MODULES/cse-init/mpich.lua"
```

Set two environment variables in your shell before testing (or set them
site-wide in your module system config):

```bash
export CSE_RELEASE=2026_04
export CSE_SHARED_PATH=/shared/cse
```

---

## Step 8 — Verify

```bash
module load cse-init/openmpi
module avail cse
# Should list: cse/cmake, cse/hdf5-mpi, cse/hdf5-serial, cse/netcdf-c-mpi,
#              cse/netcdf-c-serial, cse/netcdf-fortran-mpi, cse/netcdf-fortran-serial,
#              cse/netcdf-cxx4-mpi, cse/netcdf-cxx4-serial, cse/openmpi, cse/zlib

module load cse/openmpi cse/hdf5-mpi cse/netcdf-fortran-mpi

echo $HDF5_HOME         # should point into the store
echo $NETCDF_FORTRAN_DIR

# Compile a quick smoke test
cat > /tmp/hello.f90 <<'EOF'
program hello
  use netcdf
  implicit none
  integer :: ncid, status
  status = nf90_create('/tmp/test.nc', NF90_CLOBBER, ncid)
  status = nf90_close(ncid)
  print *, 'NetCDF OK'
end program
EOF

mpif90 -I$NETCDF_FORTRAN_DIR/include -L$NETCDF_FORTRAN_DIR/lib \
       -lnetcdff /tmp/hello.f90 -o /tmp/hello
/tmp/hello
```

---

## What Each File Controls

| File | Controls |
|---|---|
| `spack.yaml` | Which specs to install; view definitions; which other files to include |
| `packages.yaml` | OS externals (versions you detect from the system); compiler registration; MPI provider preference; file permissions |
| `config.yaml` | Where packages install (`store/`); build parallelism; source/misc cache location; binary relocation padding |
| `modules.yaml` | Which module system to generate files for; module naming (`cse/{name}`); environment variables each module sets; `-mpi`/`-serial` suffix logic |
| `gcc-bootstrap.yaml` | Registers the Spack-built GCC as the external compiler — kept separate so it survives re-renders of the env files |

---

## Common Issues

**"cannot build openssl — buildable: false, no external satisfies the request"**
The version in `packages.yaml` does not match what Spack's dependency solver needs.
Run `openssl version` on the login node to get the real version and update the spec.

**"no compiler matches %gcc@13.3.0"**
The bootstrap GCC view (`bootstrap/gcc-13.3.0/`) is not registered in `gcc-bootstrap.yaml`,
or the file is not included in `spack.yaml`. Check that `../gcc-bootstrap.yaml` is in
the `include:` list and that `spack find gcc@13.3.0` shows the compiler.

**"concretize fails with unresolvable dependency"**
Run `spack concretize --fresh 2>&1 | tail -40` for the full error. Common cause is
`unify: true` conflicting with the dual MPI+serial HDF5 specs — keep `unify: when_possible`.

**Modules not visible after `module avail cse`**
Check that `CSE_SHARED_PATH` and `CSE_RELEASE` are set, that the `cse-init` modulefile
is in a directory on `MODULEPATH`, and that `spack module lmod refresh` completed
without errors.
