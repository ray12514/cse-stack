# cse-stack

Configuration, scripts, and module templates for deploying the Computational Software Environment (CSE) on HPC systems using [Spack](https://spack.io).

The CSE provides a curated set of scientific libraries (HDF5, NetCDF-C, NetCDF-Fortran, NetCDF-CXX4, MPI) through a stable `cse/<package>` module namespace. Two deployment variants are supported.

---

## Two Variants

| Variant | Target System | MPI | Compiler |
|---------|---------------|-----|----------|
| **v1-openmpi** | Any Linux | Spack-built OpenMPI@5.0.5 | Spack-built GCC@13.2.0 |
| **v2-mpich** | Any Linux; optimised for Cray/Slingshot | Spack-built MPICH@3.4.3 or @4.2.2 | Spack-built GCC@13.2.0 |

Both variants build GCC and MPI entirely from Spack — no dependency on vendor compilers or vendor MPI at build time. This produces identical software versions across every deployment site, with only the Spack hash differing by OS and microarchitecture.

On Cray systems, `v2-mpich` detects libfabric and (on PBS) cray-pals from the system modules and registers them as externals so MPICH uses the Slingshot high-speed network automatically.

Both variants expose identical `cse/<package>` module names so users who move between systems need to relearn nothing.

---

## Prerequisites

These must be satisfied on the target host **before** running `deploy.sh`.

1. **Python 3.6+** with `jinja2` and `pyyaml`:
   ```bash
   pip install jinja2 pyyaml
   ```

2. **Git** and a C/C++/Fortran compiler (needed by Spack to bootstrap):
   ```bash
   # RHEL/Rocky
   dnf install git gcc g++ gfortran
   # Debian/Ubuntu
   apt-get install git build-essential gfortran
   ```

3. **Cluster Inspector** (used by Stage 1 to capture the system profile):
   ```bash
   pip install -e /path/to/clusterinspector
   clusterinspector profile --local   # smoke test
   ```

### One-Time Host Setup

Before the first `deploy.sh` run, create the shared root with correct group ownership:

```bash
mkdir -p "${SHARED_PATH}/cse/${CSE_RELEASE}"
chgrp -R "${CSE_GROUP}" "${SHARED_PATH}/cse"
chmod -R g+rwxs "${SHARED_PATH}/cse"
chmod o+rx "${SHARED_PATH}/cse"
```

The setgid bit ensures that files created later (by Spack or by hand) inherit the correct group regardless of the creator's primary group. Pass `--group <name>` to `deploy.sh` if your shared filesystem group differs from your primary group; it defaults to `$(id -gn)`.

---

## Quick Start: Dry-Run

Validate the scaffold without modifying any system state:

```bash
# Clone and enter the repo
git clone https://github.com/ray12514/cse-stack.git
cd cse-stack

# Variant A (any Linux)
./scripts/deploy.sh \
    --variant v1-openmpi \
    --release 2026_04 \
    --shared-path /tmp/cse-test \
    --dry-run

# Variant B (Cray) — use the bundled mock profile if not on a real Cray
./scripts/deploy.sh \
    --variant v2-mpich \
    --release 2026_04 \
    --shared-path /tmp/cse-test \
    --mock-profile profiles/mock-cray.yaml \
    --dry-run
```

Dry-run prints every command that would run, renders the YAML templates to stdout, and exits 0 without writing anything.

---

## Full Deploy

```bash
# Deploy v1-openmpi
./scripts/deploy.sh \
    --variant v1-openmpi \
    --release 2026_04 \
    --shared-path /your/shared/path

# Deploy v2-mpich (MPICH version auto-detected from system; override if needed)
./scripts/deploy.sh \
    --variant v2-mpich \
    --release 2026_04 \
    --shared-path /your/shared/path

# Deploy with a source mirror (air-gapped or restricted networks)
./scripts/deploy.sh \
    --variant v1-openmpi \
    --release 2026_04 \
    --shared-path /your/shared/path \
    --mirror-path /path/to/mirror

# Deploy with a binary build cache (fast re-deploy)
./scripts/deploy.sh \
    --variant v1-openmpi \
    --release 2026_04 \
    --shared-path /your/shared/path \
    --buildcache-uri file:///path/to/cache
```

### `deploy.sh` Options

| Option | Required | Description |
|--------|----------|-------------|
| `--variant` | Yes | `v1-openmpi` or `v2-mpich` |
| `--release` | Yes | Release tag, e.g. `2026_04` |
| `--shared-path` | Yes | Path to the shared CSE filesystem root |
| `--dry-run` | No | Print plan and rendered YAML; do not modify system |
| `--from-stage N` | No | Skip stages 1 through N-1 (assumes outputs exist) |
| `--module-system` | No | Override auto-detected module system (`lmod` or `tcl`) |
| `--mock-profile` | No | Path to a mock Cluster Inspector YAML for testing |
| `--group` | No | Shared filesystem group (default: `$(id -gn)`) |
| `--gcc-version` | No | GCC version to bootstrap (default: `13.2.0`) |
| `--mpich-version` | No | MPICH version for v2-mpich (default: auto-detected from profile) |
| `--mirror-path` | No | Local path to a Spack source mirror |
| `--buildcache-uri` | No | URI for a Spack binary build cache (push after install, pull before) |

### Staged Scripts

Each stage is independently runnable. `deploy.sh` composes them.

| Script | Purpose |
|--------|---------|
| `stage1_profile.sh` | Run Cluster Inspector, write `profiles/<hostname>-<timestamp>.yaml` |
| `stage2_spack.sh` | Clone Spack (v1.1.1); bootstrap GCC into `<variant>/bootstrap/` |
| `stage3_externals.sh` | Render `packages.yaml` from the system profile |
| `stage4_build.sh` | Render remaining YAML templates; `spack concretize + install`; push build cache |
| `stage5_modules.sh` | `spack module refresh`; install `cse-init` activation module |

---

## User-Facing Module Commands

After a successful deploy:

### v1-openmpi

```bash
module load cse-init/openmpi
module avail cse
# cse/cmake  cse/hdf5-mpi  cse/hdf5-serial  cse/netcdf-c-mpi  ...
module load cse/openmpi cse/netcdf-fortran-mpi
mpif90 -I$NETCDF_FORTRAN_DIR/include -L$NETCDF_FORTRAN_DIR/lib \
       -lnetcdff my_program.f90 -o my_program
srun -n 4 ./my_program
```

### v2-mpich (any Linux or Cray)

```bash
module load cse-init/mpich
module avail cse
# cse/cmake  cse/mpich  cse/hdf5-mpi  cse/hdf5-serial  cse/netcdf-c-mpi  ...
module load cse/mpich cse/hdf5-mpi cse/netcdf-fortran-mpi
mpif90 -I$NETCDF_FORTRAN_DIR/include -L$NETCDF_FORTRAN_DIR/lib \
       -lnetcdff my_program.f90 -o my_program
srun -n 4 ./my_program
```

On Cray/Slingshot, MPICH uses the system libfabric for OFI transport automatically — no extra module loads or environment flags required.

For PBS systems with PALS, substitute `mpiexec -n 4 ./my_program`.

---

## MPICH Version Selection (v2-mpich)

The MPICH version is chosen to match the ABI of the installed cray-mpich for future runtime splice compatibility:

| cray-mpich series | Spack MPICH spec |
|-------------------|-----------------|
| 8.x | `mpich@3.4.3` |
| 9.x | `mpich@4.2.2` |
| Non-Cray / not detected | `mpich@4.2.2` |

Override with `--mpich-version <ver>` if needed.

---

## Non-Module Workflow (Site Views)

Users who prefer a flat tree of headers, libraries, and binaries without `module load`:

```bash
export CSE_VIEW=$SHARED_PATH/cse/$CSE_RELEASE/v1-openmpi/views/mpi
gcc -I$CSE_VIEW/include -L$CSE_VIEW/lib -lnetcdf my_program.c
```

Two views exist per variant: `views/mpi` (parallel packages + tooling) and `views/serial` (serial packages + tooling).

---

## User-Side Spack via Upstream Chaining

Advanced users who want to build their own Spack environments on top of the CSE baseline:

```yaml
# ~/.spack/upstreams.yaml
upstreams:
  cse:
    install_tree: /your/shared/path/cse/2026_04/<variant>/store
```

With this configuration, `spack install` will reuse CSE-installed packages rather than rebuilding them from source.

---

## Repository Layout

```
cse-stack/
├── README.md
├── HANDOFF.md                      # original agent handoff brief
├── modules/
│   └── cse-init/                   # hand-written activation modulefiles (Lua + Tcl)
│       ├── openmpi.lua / openmpi.tcl
│       └── mpich.lua   / mpich.tcl
├── scripts/
│   ├── deploy.sh                   # orchestrator
│   ├── stage{1..5}_*.sh            # individual stages
│   ├── mirror_fetch.sh             # pre-populate a source mirror
│   ├── buildcache_push.sh          # push binaries to a build cache after install
│   └── lib/
│       ├── profile.py              # typed accessors for Cluster Inspector YAML
│       └── render.py               # Jinja2 template renderer
├── templates/                      # Jinja2 templates (*.j2)
├── profiles/
│   └── mock-cray.yaml              # mock Cluster Inspector output for Cray testing
└── docs/
    ├── phase_two_summary.md
    └── implementation_plan.md
```

---

## Open Items

- Phase 2: cray-mpich ABI splice via `LD_LIBRARY_PATH` in `cse-init/mpich` (`CSE_MPICH_SPLICE=1` reserved; not yet implemented).
- Whether `parallel-netcdf` (PnetCDF) gets its own `cse/parallel-netcdf` module (currently a transitive dep of NetCDF-C).
- Shared path root per site (currently `/shared_path` as default).
