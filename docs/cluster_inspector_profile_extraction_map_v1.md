# Cluster-Inspector Profile Extraction Map v1

## Purpose

This document maps each v6 `profile.yaml` fact to the probe that should extract
it for the new `cluster-inspector` tool. In this document, "metric" means any
observable or derived profile fact, not only numeric measurements.

This is not the primary build plan. The build plan lives in
`cluster_inspector_stack_profile_design_v1.md`. This document is the extraction
map: it explains how each profile fact should be discovered, normalized, and
validated. The sections are grouped by probe area so a reader can reason about
one class of facts at a time. They also happen to be sensible implementation
slices, but their main purpose is to keep the extraction logic understandable.

## Extraction Principles

- Prefer observed facts over guesses.
- Treat operator input as explicit evidence, not as hidden policy.
- Keep package intent out of the profile.
- Do not emit `packages.yaml`, template contracts, stack defaults, or template
  trees. Profile corpora feed `spack-composer` analysis/scaffolding on the stack
  side, not `cluster-inspector` output.
- Never call Spack to discover facts.
- Do not depend on the source checkout after the tool is built.
- Use non-login shells for subprocess probes. Preserve the operator-selected
  environment only when that is the probe's explicit input; otherwise start from
  a controlled clean shell and load exactly the modules being verified.
- If a command is missing, record `unknown` with evidence instead of crashing,
  unless the missing fact is required for a renderable profile.
- Use bundled resource tables for normalization, such as CPU target aliases, GPU
  architecture mappings, CUDA driver ceilings, and ROCm component lists.
- Keep probe side effects tightly scoped. The only normal write operation is a
  tiny create/remove test under a declared build-stage candidate path.

## Confidence Vocabulary

| Confidence | Meaning |
|---|---|
| `probed` | Directly observed by reading a file, running a command, loading a module, or testing a path. |
| `inferred` | Derived from probed facts plus a bundled table or an explicit operator hint. |
| `unknown` | Not known from available probes and hints. |

Evidence should record the command, file, hint, or resource table used. The
durable profile may carry compact evidence, while full command output belongs in
an optional diagnostics artifact.

## Pipeline Overview

```text
operator args + hints + bundled resources
          │
          ├── probe-system     → system fragment
          ├── probe-node(s)    → one node fragment per node type
          └── merge            → v6 profile.yaml + optional evidence report
```

The all-in-one `cluster-inspector profile` command runs this pipeline. The lower
level `probe-system`, `probe-node`, and `merge` commands expose the same stages
for sites that need manual control.

## Section 1: Identity, OS, And Module Tool

This is the first implementation slice because it works on almost every Linux
host and validates the self-contained CLI/output model.

| Profile field | Probe location | Primary extraction | Normalize to | Confidence | Fallback |
|---|---|---|---|---|---|
| `schema_version` | merge | Built-in constant from bundled schema. | integer `1` | `probed` from tool version | none |
| `system.name` | args | Required `--system <name>` for multi-node profiles. | short slug preserving `[-_.a-zA-Z0-9]` | `inferred` from operator input | current hostname only for local diagnostic mode |
| `system.family` | probe-system | Combine OS ID with Cray detection. Detect Cray from `/opt/cray/pe`, `CRAYPE_VERSION`, `module avail PrgEnv-*`, or `PE_ENV` after module load. | `cray-rhel`, `cray-sles`, `linux-rhel9`, `linux-sles`, etc. | `probed` when Cray evidence exists, otherwise `inferred` from OS | operator hint `system.family` |
| `system.description` | args or hints | Optional `--description` or `inspector-hints.yaml`. | free text | `inferred` from operator input | omit |
| `os.name` | probe-system | Parse `/etc/os-release` `ID`. | lowercase distro ID such as `rhel`, `sles`, `ubuntu` | `probed` | `uname -s` only gives `linux`, so keep unknown distro |
| `os.major` | probe-system | Parse `/etc/os-release` `VERSION_ID`. | integer major | `probed` | package-manager release files such as `/etc/redhat-release` |
| `os.minor` | probe-system | Parse `/etc/os-release` `VERSION_ID`. | integer minor when present | `probed` | omit |
| `os.glibc` | probe-system | Prefer `getconf GNU_LIBC_VERSION`; fallback `ldd --version` first line. | version string such as `2.28` | `probed` | unknown is validation failure for renderable profile |
| `modules_system.tool` | probe-system | Run clean shell: `type module`, `command -v modulecmd`, inspect `$LMOD_VERSION` and `$MODULESHOME`. | `lmod` or `tcl` | `probed` | unknown is validation failure if module-backed externals are required |
| `modules_system.version` | probe-system | `module --version 2>&1`, `modulecmd --version`, or `$LMOD_VERSION`. | version string | `probed` | omit |

### Basic Extraction Flow

The first probe should be one self-contained local system probe that runs in a
plain shell and prints key/value lines. The Go implementation parses those lines
into a typed fragment. Keep this boring and deterministic.

```bash
set -eu

printf 'HOSTNAME=%s\n' "$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
printf 'UNAME_S=%s\n' "$(uname -s 2>/dev/null || true)"
printf 'UNAME_M=%s\n' "$(uname -m 2>/dev/null || true)"

if [ -r /etc/os-release ]; then
  . /etc/os-release
  printf 'OS_ID=%s\n' "${ID:-}"
  printf 'OS_VERSION_ID=%s\n' "${VERSION_ID:-}"
  printf 'OS_PRETTY_NAME=%s\n' "${PRETTY_NAME:-}"
fi

glibc=""
if command -v getconf >/dev/null 2>&1; then
  glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true)"
fi
if [ -z "$glibc" ] && command -v ldd >/dev/null 2>&1; then
  glibc="$(ldd --version 2>&1 | sed -n '1s/.* //p' || true)"
fi
printf 'GLIBC=%s\n' "$glibc"

printf 'LMOD_VERSION=%s\n' "${LMOD_VERSION:-}"
printf 'MODULESHOME=%s\n' "${MODULESHOME:-}"
printf 'MODULEPATH=%s\n' "${MODULEPATH:-}"

module_version=""
if command -v modulecmd >/dev/null 2>&1; then
  module_version="$(modulecmd --version 2>&1 | sed -n '1p' || true)"
elif type module >/dev/null 2>&1; then
  module_version="$(module --version 2>&1 | sed -n '1p' || true)"
fi
printf 'MODULE_VERSION_TEXT=%s\n' "$module_version"

if [ -d /opt/cray/pe ]; then
  printf 'CRAY_PE_DIR=present\n'
else
  printf 'CRAY_PE_DIR=absent\n'
fi
printf 'CRAYPE_VERSION=%s\n' "${CRAYPE_VERSION:-}"
```

The final implementation does not need to use this exact shell text, but it
should collect the same values and keep each command failure local to that value.
No missing command in this section should abort the whole probe.

### Basic Parsing Rules

| Raw value | Parser rule | Output |
|---|---|---|
| `OS_ID=rhel` | Lowercase, strip quotes. | `os.name: rhel` |
| `OS_ID=rocky` or `almalinux` | Keep exact distro ID unless the stack decides aliases are wanted. | `os.name: rocky` or `almalinux` |
| `OS_VERSION_ID=8.9` | Split on the first dot. | `os.major: 8`, `os.minor: 9` |
| `OS_VERSION_ID=15-SP5` | Extract first integer as major; preserve non-numeric tail only in evidence. | `os.major: 15` |
| `GLIBC=2.28` | Require a dotted version string. | `os.glibc: "2.28"` |
| `LMOD_VERSION` non-empty | Prefer Lmod over Tcl module detection. | `modules_system.tool: lmod` |
| `MODULESHOME` non-empty and no `LMOD_VERSION` | Treat as Tcl Environment Modules. | `modules_system.tool: tcl` |
| `MODULE_VERSION_TEXT=Modules Release 4.7.1` | Extract first version-looking token. | `modules_system.version: "4.7.1"` |
| `CRAY_PE_DIR=present` or `CRAYPE_VERSION` non-empty | Mark Cray evidence present. | used for `system.family` |

### Basic Normalization Rules

`system.name` comes from `--system` for every renderable profile. The hostname is
only a diagnostic fallback because the hostname is often a login node name, not a
stable system identifier.

`system.family` is derived after OS and Cray evidence are known:

| Inputs | Output |
|---|---|
| Cray evidence + `os.name: rhel` | `cray-rhel` |
| Cray evidence + `os.name: sles` | `cray-sles` |
| No Cray evidence + `os.name: rhel`, `rocky`, `almalinux`, or `centos` | `linux-rhel<major>` unless hints force a more specific family |
| No Cray evidence + `os.name: sles` | `linux-sles` |
| No Cray evidence + `os.name: ubuntu` | `linux-ubuntu` |
| Unknown OS | validation error for renderable profile |

The RHEL-compatible distro choice is intentionally conservative. The profile
should preserve the actual distro in `os.name`; `system.family` can group related
render behavior when the template supports it.

### Minimal Section 1 Output

With this section alone, the tool should be able to write a profile skeleton like
this:

```yaml
schema_version: 1
system:
  name: example-local
  family: linux-rhel9
os:
  name: rhel
  major: 9
  minor: 4
  glibc: "2.34"
modules_system:
  tool: lmod
  version: "8.7"
vendor_cray: null
compilers_external: []
mpi: []
gpu_toolkit_modules: {}
filesystem:
  install_tree_candidates: []
node_types:
  login:
    role: both
    description: "Local host"
    cpu:
      detected: unknown
      preferred: unknown
      alternates: []
    gpu: null
    build_stage: []
capabilities:
  lanes_capable: []
```

That skeleton is not yet sufficient for a production render, but it exercises the
schema, deterministic YAML output, and validation path before the harder probes
arrive.

Section 1 acceptance:

- `cluster-inspector profile --system local --node-type login=this:role=both`
  emits a deterministic skeleton with identity, OS, glibc, and module tool facts.
- Missing module tool is represented as `unknown`, not a crash.
- The tool runs from the built artifact without importing from the source tree.

## Section 2: Node Type Role, CPU, And Build Stage

This slice proves the one-profile-many-node-types model without needing GPUs or
module enumeration.

| Profile field | Probe location | Primary extraction | Normalize to | Confidence | Fallback |
|---|---|---|---|---|---|
| `node_types.<name>` key | args | `--node-type <name>=...` | YAML map key | `inferred` from operator input | none; required |
| `node_types.<name>.role` | args | `role=build_host`, `role=runtime`, or `role=both` in `--node-type`. | enum | `inferred` from operator input | default `runtime` only in diagnostic mode |
| `node_types.<name>.description` | args or hints | Optional node-type description. | free text | `inferred` | omit |
| `node_types.<name>.cpu.detected` | probe-node | Built-in CPU detector using `/proc/cpuinfo`, `lscpu`, CPUID data when available, and bundled arch mapping. | arch label such as `zen3`, `zen4`, `x86_64_v3` | `probed` when matched exactly, `inferred` when mapped from model string | `x86_64_v3` or `x86_64` only with low confidence |
| `node_types.<name>.cpu.preferred` | probe-node + hints | Default to detected target; allow hint to prefer a compatible lower target. | arch label | `inferred` | detected target |
| `node_types.<name>.cpu.alternates` | probe-node | Bundled compatibility table from detected target. | list of compatible lower targets | `inferred` | empty list |
| `node_types.<name>.build_stage[*].path` | probe-node | Candidate scan from `$TMPDIR`, `/tmp/$USER`, `/local_scratch/$USER`, `/scratch/$USER`, scheduler temp vars, and hints. | path string, variables preserved only when intentional | `probed` for existing paths, `inferred` for hinted templates | omit unusable missing paths unless hinted |
| `node_types.<name>.build_stage[*].visibility` | probe-node | Compare mount path against known shared candidates and scheduler context; optional hint. | `shared`, `compute-only`, `node-local`, or `unknown` | `inferred` | `unknown` |
| `node_types.<name>.build_stage[*].writable` | probe-node | Create and remove a tiny file in the candidate path. | boolean | `probed` | false if test fails |
| `node_types.<name>.build_stage[*].free_gb` | probe-node | `df -Pk <path>`. | integer GB | `probed` | omit |
| `node_types.<name>.build_stage[*].free_inodes` | probe-node | `df -Pi <path>`. | integer inode count | `probed` | omit |
| `node_types.<name>.build_stage[*].mount_opts` | probe-node | `findmnt -n -o OPTIONS --target <path>`. | list of options | `probed` | empty list |
| `node_types.<name>.build_stage[*].throughput_class` | probe-node | Filesystem type + optional tiny write/read timing. | `fast`, `medium`, `slow`, `unknown` | `inferred` | `unknown` |

CPU target detection must not require an external `archspec` installation at
runtime. A small bundled architecture mapping is acceptable and easier to make
self-contained.

Section 2 acceptance:

- A login node and one CPU compute node fragment merge into one profile.
- The same fragments merge to byte-identical YAML on repeated runs.
- Build-stage checks clean up after themselves.

## Section 3: GPU Node Facts

This slice handles GPU node types and the target labels the renderer uses for
GPU lanes.

| Profile field | Probe location | Primary extraction | Normalize to | Confidence | Fallback |
|---|---|---|---|---|---|
| `node_types.<name>.gpu` | probe-node | If no GPU command or PCI GPU is detected, emit explicit `null`. | map or null | `probed` | null |
| `gpu.vendor` | probe-node | `nvidia-smi -L`, `rocm-smi`, `rocminfo`, or `lspci -nn` vendor IDs. | `nvidia` or `amd` | `probed` | `unknown` invalid for a GPU node type |
| `gpu.driver_version` | probe-node | NVIDIA: `nvidia-smi --query-gpu=driver_version`; AMD: `rocm-smi --showdriverversion`, `modinfo amdgpu`, or ROCm stack version when driver version is not separately exposed. | version string | `probed` or `inferred` | unknown triggers validation warning; may fail GPU stack validation |
| `gpu.toolkit_ceiling` | probe-node + resource table | NVIDIA: driver version to max CUDA table. AMD: ROCm driver/runtime compatibility table, with installed ROCm module as upper bound when needed. | toolkit version string | `inferred` | operator hint required when table cannot decide |
| `gpu.arch_target` | probe-node + resource table | NVIDIA: compute capability from `nvidia-smi`; AMD: prefer `rocminfo` agent name such as `gfx90a`, fallback PCI ID/product-name map. | `sm_90`, `sm_80`, `gfx90a`, `gfx942`, etc. | `probed` when direct, `inferred` when table-mapped | operator hint required for unknown GPU model |
| `gpu.cuda_compat_available` | probe-node | NVIDIA only: look for CUDA compatibility library/module, e.g. `cuda-compat`, `/usr/local/cuda/compat`, or `libcuda.so` compatibility path. | boolean | `probed` | false |

GPU topology such as NVLink, XGMI, or GPU-to-NIC distance is useful diagnostic
evidence, but it is not part of the minimum v6 profile unless the schema grows a
topology block. Keep it in the optional evidence report for v1.

Section 3 acceptance:

- MI250X normalizes to `vendor: amd` and `arch_target: gfx90a`.
- MI300A normalizes to `vendor: amd` and `arch_target: gfx942`.
- NVIDIA H100 normalizes to `vendor: nvidia` and `arch_target: sm_90`.
- Unknown GPU models fail validation unless an operator hint supplies the arch.

## Section 4: Fabric And Shared Filesystems

This slice produces system-wide facts that control buildcache safety and runtime
fabric externalization.

| Profile field | Probe location | Primary extraction | Normalize to | Confidence | Fallback |
|---|---|---|---|---|---|
| `fabric.type` | probe-system | Check Slingshot CXI devices, `/sys/class/infiniband`, `ibstat`, `ibv_devinfo`, `fi_info -l`, NIC names, and PCI IDs. | `slingshot`, `infiniband`, `roce`, `omnipath`, `ethernet` | `probed` | `ethernet` only when no fast fabric evidence exists |
| `fabric.generation` | probe-system | Slingshot: CXI evidence; InfiniBand: link layer and device generation from `ibstat`/PCI IDs; hints can refine HDR/NDR. | `cxi`, `hdr`, `ndr`, etc. | `probed` or `inferred` | omit |
| `fabric.drivers[*].name` | probe-system | Driver/library commands and packages: `rpm -q rdma-core`, `dpkg-query`, `ldconfig -p`, `modinfo`, `/opt/cray/pe/cxi`. | package/library name | `probed` | omit if absent |
| `fabric.drivers[*].version` | probe-system | Package manager query, library symlink, `modinfo`, or command version. | version string | `probed` | unknown string only for diagnostics; renderable profile should prefer exact version |
| `fabric.drivers[*].prefix` | probe-system | Prefix from binary/library path, package file list, or known system prefix `/usr`. | absolute path | `probed` | `/usr` for system libraries when evidence points there |
| `fabric.userspace[*].name` | probe-system | `fi_info`, `ucx_info`, module candidates. | `libfabric`, `ucx`, etc. | `probed` | empty list |
| `fabric.userspace[*].version` | probe-system | `fi_info --version`, `ucx_info -v`, module version, package manager. | version string | `probed` | unknown omitted unless externalization needs it |
| `fabric.userspace[*].prefix` | probe-system | `command -v`, module env, package file list. | absolute path | `probed` | `/usr` when system package-backed |
| `filesystem.install_tree_candidates[*].path` | probe-system + hints | Operator hints are primary; optional scan of known roots like `/shared/stack/spack/opt`, `/apps/spack/opt`, `/opt/spack/opt`. | absolute path | `inferred` from hint, `probed` when path exists | validation failure if none supplied/found |
| `filesystem.install_tree_candidates[*].type` | probe-system | `findmnt -n -o FSTYPE --target <path>`. | filesystem type | `probed` | `unknown` |
| `filesystem.install_tree_candidates[*].locks_honored` | probe-system | Local `flock` test; optional cross-node lock test if a peer node runner is available. | boolean | `probed` for local, `inferred` for known FS defaults | false/unknown triggers warning |
| `filesystem.install_tree_candidates[*].free_gb` | probe-system | `df -Pk <path>`. | integer GB | `probed` | omit |
| `filesystem.source_cache_candidate` | probe-system + hints | Explicit hint or sibling of install tree, verified with parent path checks. | absolute path | `inferred` then `probed` if exists/writable | omit |
| `filesystem.buildcache_candidate` | probe-system + hints | Explicit hint or sibling of install tree, verified with parent path checks. | absolute path | `inferred` then `probed` if exists/writable | omit |

Section 4 acceptance:

- Slingshot systems emit `fabric.type: slingshot` and `generation: cxi` when CXI
  evidence is present.
- InfiniBand/RoCE systems do not get mislabeled as Ethernet when IB devices exist.
- Install-tree candidates are reviewable and never silently invented without
  evidence or hints.

## Section 5: Module Inventory, Compilers, MPI, And GPU Toolkits

This is the largest slice. It should come after the basic profile and node model
are stable.

### Module Candidate Discovery

| Metric | Extraction | Notes |
|---|---|---|
| Raw module list | `module avail -t`, MODULEPATH directory walks, optional `spider` on Lmod. | Capture raw names as diagnostics. |
| Candidate category | Bundled `module_patterns.yaml`. | Categories: compiler, MPI, GPU toolkit, fabric userspace, Cray PE. |
| Hints filtering | `inspector-hints.yaml` include/exclude/extras. | Hints make discovery repeatable. |
| Verification | Controlled non-login shell, purge/clear module state, `module load <candidate>`, then probe env/commands. | Verified candidates can enter `profile.yaml`; failed candidates remain diagnostics. |

### Generic Compiler Externals

| Profile field | Probe location | Primary extraction | Normalize to | Confidence | Fallback |
|---|---|---|---|---|---|
| `compilers_external[*].name` | probe-system | Candidate module name, compiler command identity, or explicit hint. | `gcc`, `aocc`, `intel`, `nvhpc`, etc. | `probed` after load verification | hint-only entries require prefix validation |
| `compilers_external[*].version` | probe-system | Compiler command version: `gcc -dumpfullversion`, `clang --version`, AOCC/NVHPC/Intel env vars. | exact version string | `probed` | module version string if command version unavailable |
| `compilers_external[*].prefix` | probe-system | Prefix from compiler binary path, env vars such as `AOCC_HOME`, `ONEAPI_ROOT`, `NVHPC_ROOT`, or module show output. | absolute path | `probed` | hint required |
| `compilers_external[*].modules` | probe-system | Module list used during clean-shell verification. | list of module names | `probed` | omit for prefix-only system compiler |
| `compilers_external[*].languages` | probe-system | Presence of C, C++, and Fortran drivers under prefix or after module load. | `[c, c++, fortran]` subset | `probed` | omit missing languages |

Generic compiler externals exclude Cray PE compiler entries that belong under
`vendor_cray`.

### Cray PE

| Profile field | Probe location | Primary extraction | Normalize to | Confidence | Fallback |
|---|---|---|---|---|---|
| `vendor_cray` | probe-system | Present when Cray PE evidence exists: `/opt/cray/pe`, `CRAYPE_VERSION`, `PrgEnv-*`, or Cray wrappers. | map or null | `probed` | null |
| `vendor_cray.pe_version` | probe-system | `$CRAYPE_VERSION`, module metadata, `/opt/cray/pe` release files. | version string | `probed` | hint required for renderable Cray profile |
| `vendor_cray.cce.version` | module verification | Load `PrgEnv-cray` + CCE module; read `$CRAY_CC_VERSION`, `cce --version`, or module version. | version string | `probed` | omit if CCE absent |
| `vendor_cray.cce.prefix` | module verification | `$CRAY_PE_CCE_PREFIX`, `command -v craycc`, module show, `/opt/cray/pe/cce/<version>`. | absolute path | `probed` | hint required if module hides prefix |
| `vendor_cray.cce.modules` | hints + verification | Modules loaded to expose CCE. | list such as `[PrgEnv-cray, cce/17.0.1]` | `probed` | hint required |
| `vendor_cray.gcc.*` | module verification | Load `PrgEnv-gnu` and GCC module; read `$GCC_PATH`, GCC version. | version, prefix, modules | `probed` | omit if absent |
| `vendor_cray.rocmcc.*` | module verification | Load `PrgEnv-amd` or ROCm compiler module; read `$ROCM_PATH`, `amdclang --version`. | version, prefix, modules | `probed` | omit if absent |
| `vendor_cray.nvhpc.*` | module verification | Load NVIDIA/PrgEnv-nvidia when present; read `$NVHPC_ROOT`, compiler versions. | version, prefix, modules | `probed` | omit if absent |
| `vendor_cray.cray_mpich.version` | module verification | Load `cray-mpich`; read `$CRAY_MPICH_VERSION`, module version, or `mpichversion`. | version string | `probed` | hint required if wrappers hide version |
| `vendor_cray.cray_mpich.flavors.<compiler>.prefix` | module verification | For each PrgEnv/compiler flavor, load matching modules and read `$MPICH_DIR` or wrapper paths. | absolute prefix | `probed` | omit unavailable flavor |
| `vendor_cray.cray_mpich.flavors.<compiler>.modules` | module verification | Module list needed at runtime for that flavor. | list, usually `[cray-mpich/<v>]` | `probed` | hint required |
| `vendor_cray.libsci.version` | module verification | `$CRAY_LIBSCI_VERSION`, module version, or directory under `/opt/cray/pe/libsci`. | version string | `probed` | omit |
| `vendor_cray.libsci.prefix` | module verification | `$CRAY_LIBSCI_PREFIX_DIR` or `/opt/cray/pe/libsci/<version>`. | absolute path | `probed` | omit |

Cray MPICH is expressed under `vendor_cray.cray_mpich`, not as a generic
`mpi[*]` entry, because its per-compiler flavor prefixes are platform-specific.

### Generic MPI Inventory

| Profile field | Probe location | Primary extraction | Normalize to | Confidence | Fallback |
|---|---|---|---|---|---|
| `mpi[*].name` | module verification | MPI module name, `mpicc -show`, `mpirun --version`. | `openmpi`, `mpich`, `mvapich`, `intel-mpi`, etc. | `probed` | hint-only requires wrapper verification |
| `mpi[*].provenance` | probe-system | Site module/prefix -> `site`; OS package path -> `system`; vendor stack -> `vendor_bundled`. | enum | `inferred` from source | `site` for hinted site module |
| `mpi[*].version` | module verification | `mpirun --version`, `ompi_info`, `mpichversion`, module version. | exact version string | `probed` | module version string |
| `mpi[*].prefix` | module verification | Prefix from `command -v mpicc`, env vars such as `MPI_HOME`, or module show output. | absolute path | `probed` | hint required |
| `mpi[*].compiler` | module verification | Decode wrapper output and loaded compiler module; cross-check against compiler inventory. | compiler spec such as `aocc@4.2.0` | `inferred` from wrapper evidence | omit if unknown |
| `mpi[*].modules` | module verification | Modules loaded to expose MPI. | list | `probed` | empty for prefix-only MPI |

### GPU Toolkit Modules

| Profile field | Probe location | Primary extraction | Normalize to | Confidence | Fallback |
|---|---|---|---|---|---|
| `gpu_toolkit_modules.rocm.version` | module verification | Load ROCm module; read `$ROCM_PATH`, `hipcc --version`, `rocminfo`, module version. | version string | `probed` | module version string |
| `gpu_toolkit_modules.rocm.module` | hints + verification | Module loaded for ROCm. | module name | `probed` | hint required |
| `gpu_toolkit_modules.rocm.prefix` | module verification | `$ROCM_PATH`, `command -v hipcc`, module show. | absolute path | `probed` | hint required |
| `gpu_toolkit_modules.rocm.spack_components[*].package` | resource table | Bundled ROCm component list keyed by ROCm major/minor version. | Spack package names | `inferred` from resource table | validation failure if no component template exists |
| `gpu_toolkit_modules.rocm.spack_components[*].prefix` | module verification + resource table | Prefix from component-specific subdirs under ROCm prefix; verify path exists when possible. | absolute path | `probed` if path exists, otherwise `inferred` | validation failure for required components |
| `gpu_toolkit_modules.cudatoolkit.version` | module verification | Load CUDA toolkit module; `nvcc --version`, module version, `$CUDA_HOME`. | version string | `probed` | module version string |
| `gpu_toolkit_modules.cudatoolkit.module` | hints + verification | CUDA toolkit module. | module name | `probed` | hint required |
| `gpu_toolkit_modules.cudatoolkit.prefix` | module verification | `$CUDA_HOME`, `command -v nvcc`, module show. | absolute path | `probed` | hint required |
| `gpu_toolkit_modules.nvhpc.version` | module verification | `$NVHPC_ROOT`, `nvc --version`, module version. | version string | `probed` | module version string |
| `gpu_toolkit_modules.nvhpc.module` | hints + verification | NVHPC module used as toolkit. | module name | `probed` | omit if absent |
| `gpu_toolkit_modules.nvhpc.prefix` | module verification | `$NVHPC_ROOT`, compiler path, module show. | absolute path | `probed` | omit if absent |

Section 5 acceptance:

- False compiler modules can be excluded through hints.
- Verified Cray compiler modules produce `vendor_cray` fields, not generic
  compiler entries.
- Site OpenMPI produces `mpi[*]` with prefix, version, compiler, and modules.
- ROCm emits component externals; `rocm/<version>` alone is never considered
  sufficient for a renderable AMD GPU profile.

## Section 6: Derived Capabilities

Capabilities are derived from merged facts. They are not directly probed and
must not encode package roots or release policy.

| Profile field | Derivation | Notes |
|---|---|---|
| `capabilities.gpu_lane_supported` | true if any `node_types[*].gpu` is non-null. | Optional convenience flag. |
| `capabilities.fabric_class` | `vendor_tuned` for Cray/Slingshot or vendor MPI/fabric; `open` for generic IB/RoCE with UCX/libfabric; `ethernet_only` otherwise. | Derived from `fabric` and MPI facts. |
| `capabilities.lanes_capable[*].compiler` | Available compiler IDs from `vendor_cray` plus generic `compilers_external`. | This says possible platform/compiler surfaces, not stack intent. |
| `capabilities.lanes_capable[*].lane` | Derived lane labels such as `core`, `serial`, `mpi-craympich`, `mpi-site`, `gpu-craympich-gfx90a`. | Names must match template contract expectations. |
| `capabilities.lanes_capable[*].runtime_node_types` | Runtime or both node types compatible with the lane. GPU lanes bind only to matching GPU arch node types. | Login-only node types should not host payload runtime lanes. |

Default derivation rules:

- Core lanes are possible for every compiler that can be used by the stack and at
  least one build host node type exists.
- Serial payload lanes are possible for every compiler and every CPU-compatible
  runtime node type.
- Cray MPI lanes are possible only when `vendor_cray.cray_mpich.flavors` contains
  the matching compiler flavor.
- Site MPI lanes are possible only when an `mpi[*]` entry exists and its compiler
  can be matched to a compiler external.
- GPU lanes are possible only for runtime node types with a GPU block and a
  compatible toolkit module.
- Default Cray GPU lanes use GNU host plus the standalone GPU toolkit module;
  vendor-host GPU lanes are exception capabilities only when the relevant vendor
  compiler and toolkit facts exist.
- Spack-built MPI capability should be conservative. The inspector may report
  that the system has the compilers/fabric needed to build MPI, but the decision
  to render a `mpi-openmpi` lane belongs to `stack.yaml` and the template
  contract.

Section 6 acceptance:

- The Cray example derives CCE/GCC core, serial, MPI-CrayMPICH, and GNU-host GPU
  capabilities by GPU arch.
- A generic Linux site-MPI example derives site MPI capabilities without claiming
  package roots or build policy.
- Capability derivation is deterministic and explainable from profile facts.

## Section 7: Verification And Diagnostics

`cluster-inspector verify` should validate profiles whether they were generated
by the tool or written by hand.

| Check | Input | Failure behavior |
|---|---|---|
| Schema completeness | `profile.yaml` | Error for missing required v6 fields. |
| Enum values | `system.family`, node roles, fabric type, GPU vendor | Error for invalid values. |
| Version strings | OS/glibc, compiler, MPI, GPU toolkit | Warning for unknown optional versions; error when render requires exact version. |
| Path shape | prefixes, filesystem candidates, build-stage paths | Warning if path is relative where absolute is required. |
| Cray MPICH flavors | `vendor_cray.cray_mpich.flavors` | Error if Cray MPI lane capability exists without a matching flavor prefix. |
| ROCm components | `gpu_toolkit_modules.rocm.spack_components` | Error if AMD GPU toolkit exists without coherent components. |
| Node role consistency | `node_types` | Error if no build host exists or no runtime node exists. |
| Capability references | `capabilities.lanes_capable` | Error if a listed runtime node type is absent. |

Diagnostics should answer "why did the inspector believe this?" without bloating
the durable profile. A separate evidence report can contain full command output,
failed candidate modules, rejected paths, and confidence details.

## Extraction Sections And Suggested Delivery Order

The extraction sections are ordered from least environment-specific to most
site-specific. That order is also a practical delivery order, but the table is
here to orient the extraction map rather than replace the design plan.

| Section | Delivers | Why first/next |
|---|---|---|
| 1. Identity, OS, module tool | Minimal local profile skeleton | Establishes CLI, packaging, YAML, validation. |
| 2. Node CPU/build-stage | One profile with multiple node types | Proves merge model and scheduler runner shape. |
| 3. GPU node facts | GPU arch labels and toolkit ceilings | Required before GPU lane rendering is credible. |
| 4. Fabric/filesystems | Cache and external ABI facts | Needed for buildcache safety and fabric scopes. |
| 5. Modules/compilers/MPI/toolkits | Platform externals inventory | Largest and most site-specific slice. |
| 6. Capabilities | Renderer-facing lane eligibility | Should wait until facts are stable. |
| 7. Verification/diagnostics | Trust and hand-edit support | Makes generated and human profiles equally usable. |

This order keeps the project manageable. Each section can ship with fixtures and
tests before the next section starts.
