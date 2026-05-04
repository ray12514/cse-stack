# cse-stack

Configuration, scripts, and module templates for deploying the Computational Software Environment (CSE) on HPC systems using [Spack](https://spack.io).

The CSE provides a curated set of scientific libraries (HDF5, NetCDF-C, NetCDF-Fortran, NetCDF-CXX4, MPI) through a stable `cse/<package>` module namespace. Two deployment variants are supported.

---

## Two Variants

| Variant | Directory | Target System |
|---------|-----------|---------------|
| **v1-minimal-externals** | `variants/v1-minimal-externals/` | Generic Linux — Spack builds its own GCC and Open MPI |
| **v2-cray-integrated** | `variants/v2-cray-integrated/` | Cray systems — PrgEnv-gnu, cray-mpich, and cray-libsci are consumed as externals |

Both variants expose identical `cse/<package>` module names so users who move between systems need to relearn nothing.

---

## Prerequisites

These must be satisfied on the target host **before** running `deploy.sh`.

1. **Python 3.6+** with `jinja2` and `pyyaml`:
   ```bash
   pip install jinja2 pyyaml
   ```

2. **Git** and a C compiler (needed by Spack):
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

4. **Group `cse`** must exist and the build user must be a member:
   ```bash
   getent group cse           # confirm group exists
   groups                     # confirm you are in the group
   ```

### One-Time Host Setup

Before the first `deploy.sh` run, create the shared root with the correct group ownership and setgid bit:

```bash
mkdir -p "${SHARED_PATH}/cse/${CSE_RELEASE}"
chgrp -R cse "${SHARED_PATH}/cse"
chmod -R g+rwxs "${SHARED_PATH}/cse"
chmod o+rx "${SHARED_PATH}/cse"
```

This is a one-time operation per site. The setgid bit on every directory ensures that files created later (by Spack or by hand) inherit group `cse` regardless of the creator's primary group.

---

## Quick Start: Dry-Run

Validate the scaffold without modifying any system state:

```bash
# Clone and enter the repo
git clone https://github.com/your-org/cse-stack.git
cd cse-stack

# Variant A (generic Linux)
./scripts/deploy.sh \
    --variant v1-minimal-externals \
    --release 2026_04 \
    --shared-path /tmp/cse-test \
    --dry-run

# Variant B (Cray) — use the bundled mock profile if not on a real Cray
./scripts/deploy.sh \
    --variant v2-cray-integrated \
    --release 2026_04 \
    --shared-path /tmp/cse-test \
    --mock-profile profiles/mock-cray.yaml \
    --dry-run
```

Dry-run prints every command that would run, renders the YAML templates to stdout, and exits 0 without writing anything.

---

## Full Deploy

```bash
# Source the environment helper first
source scripts/activate.sh --shared-path /your/shared/path --release 2026_04

# Deploy Variant A
./scripts/deploy.sh \
    --variant v1-minimal-externals \
    --release 2026_04 \
    --shared-path /your/shared/path

# Deploy Variant B (on a Cray host with PrgEnv-gnu loaded)
module load PrgEnv-gnu
./scripts/deploy.sh \
    --variant v2-cray-integrated \
    --release 2026_04 \
    --shared-path /your/shared/path
```

### `deploy.sh` Options

| Option | Required | Description |
|--------|----------|-------------|
| `--variant` | Yes | `v1-minimal-externals` or `v2-cray-integrated` |
| `--release` | Yes | Release tag, e.g. `2026_04` |
| `--shared-path` | Yes | Path to the shared CSE filesystem root |
| `--dry-run` | No | Print plan and rendered YAML; do not modify system |
| `--from-stage N` | No | Skip stages 1 through N-1 (assumes outputs exist) |
| `--module-system` | No | Override auto-detected module system (`lmod` or `tcl`) |
| `--mock-profile` | No | Path to a mock Cluster Inspector YAML for Variant B testing |

### Staged Scripts

Each stage is independently runnable. `deploy.sh` composes them.

| Script | Purpose |
|--------|---------|
| `stage1_profile.sh` | Run Cluster Inspector, write `profiles/<hostname>-<timestamp>.yaml` |
| `stage2_spack.sh` | Clone Spack; bootstrap GCC (Variant A only) |
| `stage3_externals.sh` | Render `packages.yaml` from the system profile |
| `stage4_build.sh` | Render remaining YAML templates; `spack concretize + install` |
| `stage5_modules.sh` | `spack module refresh`; install `cse-init` activation module |

---

## User-Facing Module Commands

After a successful deploy:

### Variant A (generic Linux)

```bash
module load cse-init/openmpi
module avail cse
# cse/cmake  cse/hdf5-mpi  cse/hdf5-serial  cse/netcdf-c-mpi  ...
module load cse/openmpi cse/netcdf-fortran-mpi
mpif90 -I$NETCDF_FORTRAN_DIR/include -L$NETCDF_FORTRAN_DIR/lib \
       -lnetcdff my_program.f90 -o my_program
srun -n 4 ./my_program
```

### Variant B (Cray — Slurm)

```bash
module load PrgEnv-gnu
module load cse-init/cray-mpich
module load cse/cray-mpich cse/netcdf-fortran-mpi
mpif90 -I$NETCDF_FORTRAN_DIR/include -L$NETCDF_FORTRAN_DIR/lib \
       -lnetcdff my_program.f90 -o my_program
srun -n 4 ./my_program
```

### Variant B (Cray — PBS + PALS)

```bash
module load PrgEnv-gnu
module load cse-init/cray-mpich
module load cse/cray-mpich cse/cray-pals cse/netcdf-fortran-mpi
mpif90 -I$NETCDF_FORTRAN_DIR/include -L$NETCDF_FORTRAN_DIR/lib \
       -lnetcdff my_program.f90 -o my_program
mpiexec -n 4 ./my_program
```

> **Note**: Use `mpicc`/`mpif90`/`mpiCC` from `cray-mpich` directly — not the PrgEnv wrappers `cc`/`ftn`/`CC`. The PrgEnv wrappers inject flags that assume the Cray PE defaults; linking against CSE libraries through those wrappers can introduce silent ABI mismatches.

---

## Non-Module Workflow (Site Views)

Users who prefer a flat tree of headers, libraries, and binaries without `module load`:

```bash
export CSE_VIEW=$SHARED_PATH/cse/$CSE_RELEASE/v1-minimal/views/mpi
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
├── variants/
│   ├── v1-minimal-externals/       # reference YAML (rendered versions in env/ at deploy time)
│   └── v2-cray-integrated/
├── modules/
│   └── cse-init/                   # hand-written activation modulefiles (Lua + Tcl)
├── scripts/
│   ├── deploy.sh                   # orchestrator
│   ├── stage{1..5}_*.sh            # individual stages
│   ├── activate.sh                 # source me
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

## Open Items (v1.1)

The following placeholder values in the YAML templates need to be confirmed before the pilot build. None of them change the scaffold structure; they are marked `TODO` in the relevant files.

- Exact GCC version for Variant A (default: `gcc@13.2.0`)
- PrgEnv-gnu GCC, cray-mpich, cray-libsci, cray-pals versions for Variant B (filled by Stage 1 at runtime)
- Whether `parallel-netcdf` (PnetCDF) gets its own `cse/parallel-netcdf` module (currently a transitive dep of NetCDF-C)
- Shared path root per site (currently `/shared_path`)
- Pilot system identity for Variant B
