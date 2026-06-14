# Spack Stack Generation Design Notes

**Working draft - v6.0, revised June 13, 2026**

This document describes a reusable Spack-based workflow for building
user-facing HPC software stacks across diverse systems. The immediate stack can
be CSE, but the layout should also support smaller or alternate stacks with one
package, a few packages, or a full curated environment.

The central goal is not to replace Spack. The goal is to make Spack-based stack
deployment repeatable for package managers while keeping the user-facing
environment clean and understandable.

## Purpose

Package managers need a practical way to deploy curated software environments
for users across systems that differ by OS, compiler, MPI, GPU runtime, fabric,
module system, filesystem, and site policy.

This design separates five concerns:

| Concern | Artifact or actor | Purpose |
|---|---|---|
| System facts | `profile.yaml` | What exists on the target system |
| Stack intent | `stack.yaml` | What should be built and exposed to users |
| Reusable Spack model | templates, config scopes, package sets | How Spack should ingest that intent |
| Build engine | Spack | Concretize, install, generate modules/views, build caches |
| Helpers | ClusterInspector, render helper, Ansible | Reduce labor, but remain optional |

The stack must remain understandable and buildable without ClusterInspector,
without a render helper, and without Ansible. Those tools reduce error and
operator burden, but the repository layout and stack contract remain sufficient
on their own.

## Glossary

Every term used by the rest of the document is pinned to one definition here.
Where two words could plausibly mean the same thing, this glossary picks the
one the rest of the document uses and the other is a synonym, not a separate
concept.

| Term | Definition |
|---|---|
| **Stack** | The curated software environment the framework produces. A single repository can produce several stacks; the immediate one is CSE. Synonyms used informally: *software environment*, *user environment*. |
| **Profile** | The system-facts document (`profile.yaml`). Platform reality only; no package intent. |
| **Stack file** | The stack-intent document (`stack.yaml`). Stack policy only; no detected system facts. |
| **Package set** | A named list of root specs grouped by purpose (`core-foundation`, `science-full`, `science-gpu`). One file per set under `package-sets/`. Referenced by name from `stack.yaml.lanes[*].package_set`. |
| **Template set** | The collection of Jinja-style templates the render step expands. Versioned by name (`v6`) and selected by `stack.yaml.templates.set`. |
| **Lane** | A single Spack environment representing one (compiler, kind) pairing within a stack. Examples: `gcc/core`, `cce/serial`, `cce/mpi-craympich`, `gcc/gpu-craympich-gfx90a`. A lane has its own `spack.yaml`, its own lockfile, its own view, and its own module root. |
| **Lane kind** | One of `core` / `serial` / `mpi` / `gpu`. The kind controls which scopes the lane includes and which package set it expands. |
| **Front-door module** | The single user-facing module that selects a lane. Loading the front-door module prepends the lane's MODULEPATH and (for site-external lanes) the platform modules the lane depends on. Example: `CSE/CCE/mpi-craympich`. |
| **Scope** | A directory of Spack config files (`packages.yaml`, `toolchains.yaml`, etc.) that a lane's `include::` list pulls in. Lives under `templates/configs/<scope-name>/` in source and `configs/<scope-name>/` in the rendered workspace. |
| **Common scope** | `configs/common/`. The scope every lane includes. Holds `concretizer.yaml`, `mirrors.yaml`, foundation `require:` pins, and other policy that applies to every lane. |
| **Platform scope** | Any scope whose contents come from platform/system facts (`configs/vendor/cray/`, `configs/os/rhel8/`, `configs/mpi/cray-mpich/`, `configs/gpu/amd-rocm/`). |
| **Render workspace** | The on-disk tree the render step produces — `configs/` + `environments/` + manifest — that Spack reads. Ephemeral by design; regeneratable from sources. |
| **Release** | One concretized, built, verified copy of the stack with a unique tag (e.g. `2026.06`). Source records live under `releases/<tag>/<system>/<stack>/`; runtime trees live under `/shared/stack/releases/<tag>/<system>/<stack>/`. The `current` symlink points at the active runtime release. |
| **Foundation cache** | The build-cache lane that holds Core builds. Keyed by OS/glibc + Spack/package-repo generation + baseline target (e.g. `foundation/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/x86_64_v3`). An optional profile-ABI token may be inserted when one mirror spans incompatible site/vendor external surfaces. Read by every lane on a matching system. |
| **Science cache** | The build-cache lane that holds science (serial/MPI/GPU) builds. Keyed by the same OS/glibc + generation boundary; compiler/MPI/target appear in the directory label for human readability, not as reuse boundaries. |
| **Projected view** | A symlink tree generated by Spack that exposes installed packages at clean `{name}/{version}` paths instead of raw hashed install prefixes. The user-facing surface of a lane. |
| **`include::`** | The double-colon Spack directive that *replaces* the built-in include list. The committed isolation mechanism for production lanes. |
| **Toolchain** | A named bundle of compiler-and-MPI-provider constraints declared in `toolchains.yaml` and applied to a spec as `%toolchain_name`. The mechanism that pins compiler-matched MPI flavors (the canonical case: Cray cray-mpich's per-PrgEnv builds). |
| **Provenance class** | One of `Stack-built` / `Platform-backed` / `Site-external` / `Spack-built`. Emitted into every package module via `STACK_PACKAGE_PROVENANCE` so users can see where a binary came from. |
| **Helper** | An optional automation tool — ClusterInspector, the render helper, Ansible — that reduces operator labor but is not load-bearing for correctness. The manual workflow always remains executable. |
| **Manual workflow** | The reference end-to-end procedure that uses no helpers — hand-written profile and stack files, hand-rendered (or hand-edited) workspace, hand-run `spack` commands. Every helper must be replaceable by this without changing the model. |

## Guiding Principles

| Principle | Practical meaning |
|---|---|
| Spack is the build source of truth | Spack environments, lockfiles, install trees, modules, views, and build caches define what was built. |
| The stack is the user interface | Users load stack modules and clean package modules. They should not need to know Spack internals. |
| Separate intent from platform reality | `profile.yaml` describes the system. `stack.yaml` describes the desired stack. |
| Keep config isolation explicit | Production environments use `include::` to read only selected stack scopes plus Spack defaults. |
| Keep helper tools optional | ClusterInspector, render helpers, and Ansible automate steps but do not define the model. |
| Prefer lane separation | Core, serial, MPI, and GPU lanes should have separate environments, lockfiles, views, modules, and build-cache lanes where useful. |
| Make visible paths clean | Views or symlink trees should expose stable paths instead of raw hash-heavy Spack install prefixes. |
| Save solver results | `spack.lock` is the reproducibility artifact for a concrete release. |
| Prove manually first | Build and inspect the rendered environment before wrapping it in larger automation. |

## Provenance Vocabulary

Every user-facing package should have clear provenance. Modulefiles and release
metadata should make this visible when practical.

| Provenance | Meaning |
|---|---|
| Stack-built | Built by Spack as part of this managed stack. |
| Platform-backed | Provided by the platform or vendor and exposed through the stack, for example Cray PE libraries. |
| Site-external | Provided by the site and registered as a Spack external. |
| Spack-built | Built from an upstream Spack recipe without special stack ownership policy. |

## End-to-End Mental Model

A reader who only reads this section should understand the shape of
everything that follows. The framework moves declarative inputs through a
deterministic render step into a Spack-driven build, and the *outputs* the
user sees are intentionally a few clean things rather than the dozens of
artifacts Spack would otherwise leak.

```
profile.yaml + stack.yaml + package-sets/ + templates/ + release vars
                              │
                              ▼
                       render step
                  (file-in, file-out;
                   no shell, no Spack, no SSH)
                              │
                              ▼
                  rendered release workspace
        ┌─────────────────────┴─────────────────────┐
        configs/<scope>/...                          environments/<compiler>/<lane>/spack.yaml
                              │
                              ▼
                            Spack
                  (concretize → fetch → install)
                              │
       ┌────────────┬────────────┬────────────┬────────────┐
       ▼            ▼            ▼            ▼            ▼
   install     projected     front-door     spack.lock   build cache
    tree         views        modules        per lane    foundation
   (hashed)    {name}/        + package                  + science
              {version}        modules                   lanes
                                                          │
                                                          ▼
                                            release-manifest.yaml
                                            + symlink swap → current
```

**Read the picture left-to-right.** On the left are the durable inputs the
stack maintainer edits in source control. The render step is purely
mechanical and is the seam between source-of-truth (left) and runnable input
(right). Spack consumes the rendered workspace and produces the installed
artifacts. The outputs at the bottom — view paths, modulefiles, lockfiles,
build-cache entries, and the release manifest — are what survive a release
and what users and other systems see.

**Three things in this picture are reproducibility artifacts and must be
saved**: `spack.lock` per lane, the release manifest, and the build-cache
contents. Everything else is regeneratable.

**One thing in this picture is committed-and-immutable**: the rendered
workspace is *deterministic* — same inputs yield byte-identical output — but
it is *ephemeral*. It can be deleted and re-rendered at any time. Treat the
workspace as a build artifact, not a source artifact.

**Two things in this picture are optional**: the render step itself (a human
can construct the workspace by hand) and any orchestration around Spack (a
human can run `spack` directly). The arrows still connect even when the
boxes are people instead of tools — which is what *helpers are optional*
means in practice.

The rest of the document expands each box. The Repository Layout section
shows what the left side looks like on disk; the Durable Inputs section
specifies every key of `profile.yaml` and `stack.yaml`; the Render Step
section specifies the middle arrow; the Lane Model, Tcl Module Baseline,
Views, and Build Cache sections specify what comes out the right.

## How `include::` Works

`include::` is the production isolation mechanism.

In Spack 1.1 and later, `include::` replaces the built-in include list rather
than appending to it. The listed scopes plus Spack's own `defaults` are read.
User, site, and system scopes are excluded unless explicitly listed.

Important rules:

- `include:: []` means defaults only.
- `include::` followed by a list means defaults plus exactly those listed scopes.
- Do not pair `include:: []` with a separate `include:` block in the same environment.
- Use one `include::` list with the selected scopes directly underneath it.
- Do not rely on environment variables as the main isolation mechanism for production environments.

**Ordering rule: highest-precedence first.** Spack's include precedence gives
entries listed earlier higher precedence. Production environments put `common`
first when its policy must win (foundation `require:` pins,
`unify: when_possible`, mirror declarations), followed by the selected
lane/platform scopes. A lane that needs to override common policy must do so
explicitly via an inline override in its `spack.yaml`, because inline environment
config takes precedence over included scopes. Every `include::` example in this
document follows this order.

Verification commands:

```bash
spack -e <env> config scopes -vp
spack -e <env> config blame packages
spack -e <env> config blame config
spack -e <env> config blame modules
```

If config blame shows unexpected `~/.spack`, site, or system scopes, the
environment is not isolated correctly.

Example environment include list (highest-precedence → lowest-precedence,
`common` first):

```yaml
spack:
  include::
    - ../../../configs/common
    - ../../../configs/mpi/cray-mpich
    - ../../../configs/target/zen3
    - ../../../configs/vendor/cray
    - ../../../configs/os/rhel8
```

## Spack Concepts Used

| Spack concept | Use in this design |
|---|---|
| Environment | Build unit for a lane such as `gcc/serial`, `cce/mpi-craympich`, or `gcc/gpu-craympich-gfx90a`. |
| `spack.yaml` | Lane manifest: root specs, include list, views, and lane-local settings. |
| `spack.lock` | Concrete resolved DAG. Saved per release and lane. |
| `packages.yaml` | Externals, buildable policy, providers, targets, variants, and package requirements. |
| `toolchains.yaml` | Named compiler/MPI/toolchain policies, especially for compiler-matched MPI externals. |
| `config.yaml` | Install tree, source cache, build stage, misc cache, and build behavior. |
| `concretizer.yaml` | Shared concretization policy such as `unify: when_possible`. |
| `modules.yaml` | Spack-generated module behavior. Tcl is the baseline target. |
| View | Stable symlink tree exposing installed roots without raw Spack hashes. |
| Source cache | Local cache populated by `spack fetch -D`. |
| Source mirror | Curated source mirror for restricted or air-gapped systems. |
| Build cache | Binary cache of installed packages, separated by compatibility lane. |

## Spack Version Floor

The stack depends on a specific set of Spack features. Different features
arrived in different Spack releases, and a few are still settling. State the
committed minimum and note what to validate on the deployed version.

| Feature | Minimum Spack | Notes |
|---|---|---|
| `include::` isolation (this design's committed isolation mechanism) | 1.1 | Override form; Spack defaults always retained. |
| `toolchains.yaml` with `when: "%c"` conditional syntax | 1.1 | Newest part of the toolchains feature; validate exact syntax on deployed version. |
| Compiler-as-dependency (language-virtual providers) | 1.1 | Allows toolchains to name a compiler that is itself a Spack-built spec. |
| `concretizer: reuse: false` for pipeline-driving environments | 1.1 | Distinct from the build-time `reuse: true` used in science lanes. |
| `concretizer: unify: when_possible` | 1.1 | Required for multi-version science lanes (strict `unify: true` collapses versions). |
| POSIX jobserver and live terminal UI (`-j` as the single concurrency knob) | 1.2 | On 1.1 the new installer existed only as an experimental preview via `spack config add config:installer:new`. |
| Spec groups (`group:` / `needs:` / `override:`) | 1.2 | Compact multi-version manifests; on 1.1 list every version explicitly. |
| `spack.lock` as a stable cross-release artifact | 1.1 | The release reproducibility artifact this design saves. |

The committed floor for this design is **Spack 1.1.1**. Every example assumes
1.1.1 unless explicitly noted otherwise. When the deployed Spack is newer than
1.1.1 (for example 1.2 with the jobserver), the stack benefits from the newer
behavior without changing its sources; when the deployed Spack lags 1.1.1,
required features may be missing.

Before relying on a feature, run a one-shot pre-flight check on the deployed
version: `spack --version` to confirm the floor, plus a `spack -e <env> spec`
dry-run of a representative lane to confirm `include::`, `toolchains.yaml when:`,
and `concretizer: reuse:` settings resolve as written. The cost of the check is
seconds; the cost of a silent feature mismatch is a misleading build.

## Repository Layout

The repository layout should be generic enough to cover Cray systems and regular
Linux systems without creating unrelated structures for each platform.

```text
repo/
  systems/
    <system>/
      profile.yaml
  stacks/
    <stack>/
      stack.yaml
  package-sets/
    core-foundation.yaml
    science-full.yaml
    science-gpu.yaml
  templates/
    configs/
      common/
      os/
      target/
      vendor/
      mpi/
      gpu/
    environments/
      core/
      serial/
      mpi/
      gpu/
  docs/
  ansible/              # optional orchestration, not the source model
```

The important split is not Cray versus Linux at the top level. The split is
between facts, stack intent, reusable templates, package sets, and rendered
output.

## Durable Inputs

### `profile.yaml`

`profile.yaml` describes observed system facts. It can be emitted by
ClusterInspector or written by hand. It is the cross-repo contract between
whoever produces system facts (an inspector, a sysadmin, an Ansible probe) and
the stack repository that consumes them.

It should answer questions like:

- What OS and glibc are present?
- What CPU targets are available?
- Is there a GPU? What driver/runtime ceiling and architecture?
- What fabric is present?
- What compilers exist?
- What MPI implementations exist?
- What module system exists?
- What shared filesystems and build-stage candidates exist?

The full reference schema follows. Required keys are marked **R**; optional
keys are marked **O**. Defaults the render step applies for absent optional
keys are noted in line.

```yaml
schema_version: 1                               # R - profile schema version

system:                                         # R - identity block
  name: example-cray                            # R - short system identifier; used in paths
  family: cray-rhel                             # R - cray-rhel | linux-sles | linux-rhel9 | ...
  description: "Cray EX, AMD Zen 3 + MI250X"    # O - free-form, surfaces in release-manifest only

os:                                             # R - OS identity, controls cache keying
  name: rhel                                    # R - rhel | sles | ubuntu | ...
  major: 8                                      # R - major version integer
  minor: 9                                      # O - minor version, used only in release-manifest
  glibc: "2.28"                                 # R - exact glibc version string, decides cache compat

fabric:                                         # R - fabric stack, both layers
  type: slingshot                               # R - slingshot | infiniband | roce | omnipath | ethernet
  generation: cxi                               # O - cxi | hdr | ndr | ... ; omit for ethernet
  drivers:                                      # R - kernel/userspace driver libraries (externals)
    - { name: rdma-core, version: "29.0", prefix: /usr }
    - { name: cxi-userlibs, version: "1.0", prefix: /opt/cray/pe/cxi }
  userspace:                                    # O - libfabric/UCX as found; empty list if absent
    - { name: libfabric, version: "1.20", prefix: /opt/cray/libfabric/1.20 }
    - { name: ucx, version: "1.15", prefix: /usr }

modules_system:                                 # R - which module tool is on the system
  tool: tcl                                     # R - tcl | lmod
  version: "4.7"                                # O - tool version, used only in release-manifest

vendor_cray:                                    # O - present only on Cray-family systems
  pe_version: "8.1.29"                          # R within vendor_cray: PE release this profile is pinned to
  cce:                                          # R within vendor_cray if CCE is exposed
    version: "17.0.1"
    prefix: /opt/cray/pe/cce/17.0.1
    modules: [PrgEnv-cray, cce/17.0.1]          # R - module list the external loads at build time
  gcc:                                          # O - Cray-native GCC if exposed as external
    version: "13.3.0"
    prefix: /opt/cray/pe/gcc-native/13
    modules: [PrgEnv-gnu, gcc-native/13]
  rocmcc:                                       # O - ROCmCC external if exposed
    version: "6.0.0"
    prefix: /opt/rocm-6.0.0
    modules: [PrgEnv-amd, rocm/6.0.0]
  cray_mpich:                                   # R within vendor_cray if cray-mpich is exposed
    version: "8.1.29"
    flavors:                                    # R - compiler-flavored builds at distinct prefixes
      cce:
        prefix: /opt/cray/pe/mpich/8.1.29/ofi/cray/17.0
        modules: [cray-mpich/8.1.29]
      gcc:
        prefix: /opt/cray/pe/mpich/8.1.29/ofi/gnu/13.3
        modules: [cray-mpich/8.1.29]
      rocmcc:
        prefix: /opt/cray/pe/mpich/8.1.29/ofi/amd/6.0
        modules: [cray-mpich/8.1.29]
  libsci:                                       # O - cray-libsci if exposed
    version: "23.12.5"
    prefix: /opt/cray/pe/libsci/23.12.5

compilers_external:                             # O - generic site or system compilers as externals
  - name: aocc
    version: "4.2.0"
    prefix: /opt/AMD/aocc-compiler-4.2.0
    modules: [aocc/4.2.0]                       # O - omit for prefix-only externals
    languages: [c, c++, fortran]
  - name: gcc
    version: "11.4.0"
    prefix: /usr                                # system-provided baseline
    languages: [c, c++, fortran]

mpi:                                            # O - generic MPI implementations available on the system
  - name: openmpi
    provenance: site                            # site | system | vendor_bundled | absent
    version: "4.1.6"
    prefix: /opt/site/openmpi/4.1.6-aocc-4.2.0
    compiler: aocc@4.2.0                        # O - the compiler the site MPI was built with
    modules: []                                 # O - omit when prefix is sufficient

gpu_toolkit_modules:                            # O - standalone GPU toolkit modules (Cray PE Option B path)
  # Populated when the system exposes GPU toolkits as standalone modules
  # separable from a vendor PrgEnv (e.g., `rocm/<v>`, `cudatoolkit/<v>`).
  # The committed default Cray-PE GPU lane (Option B) loads the GNU
  # PrgEnv plus the standalone toolkit module from this list.
  rocm:
    version: "6.0.0"
    module: rocm/6.0.0
    prefix: /opt/rocm-6.0.0
  cudatoolkit:                                  # NVIDIA equivalent on NVIDIA systems
    version: "12.4"
    module: cudatoolkit/12.4
    prefix: /opt/cray/pe/cudatoolkit/12.4
  nvhpc:                                        # NVHPC as a standalone toolkit (no PrgEnv switch); rare
    version: "24.5"
    module: nvhpc/24.5
    prefix: /opt/nvidia/hpc_sdk/24.5

filesystem:                                     # R - install-tree and shared-storage candidates
  install_tree_candidates:                      # R - shared filesystems suitable for the install tree
    - path: /shared/stack/spack/opt
      type: lustre
      locks_honored: true                       # R - true if file locks are reliable here
      free_gb: 50000
  source_cache_candidate: /shared/stack/spack/source-cache    # O
  buildcache_candidate:   /shared/stack/buildcache            # O

node_types:                                     # R - one entry per node class on the system
  # System-shared facts (OS, glibc, fabric, modules_system, vendor_cray) are at
  # the top level. node_types holds only the facts that genuinely differ
  # across nodes: CPU target, GPU presence, build-stage paths.

  login:                                        # entry key is the node-type name; referenced by stack.yaml
    role: build_host                            # R - build_host | runtime | both
    description: "Cray login node; shared workspace, no GPU"
    cpu:                                        # R - microarchitecture facts for this node class
      detected: zen2                            # R - what archspec sees on this class
      preferred: zen2                           # R - target this class would compile to
      alternates: []                            # O - other targets reachable on this class
    gpu: null                                   # R - explicit null if this class has no GPU
    build_stage:                                # R - writable fast paths for this class
      - path: $tempdir/$user/spack-stage
        visibility: shared
        writable: true
        throughput_class: medium

  cpu_compute:
    role: runtime                               # build_host only if Spack can run from this class
    description: "CPU compute partition, Zen3"
    cpu:
      detected: zen3
      preferred: zen3
      alternates: [zen2]
    gpu: null
    build_stage:
      - path: /local_scratch/$user/spack-stage
        visibility: compute-only
        writable: true
        free_gb: 800
        free_inodes: 10000000
        mount_opts: [rw]
        throughput_class: fast
      - path: $tempdir/$user/spack-stage
        visibility: compute-only
        writable: true

  gpu_compute_mi250x:
    role: runtime
    description: "GPU compute, MI250X (gfx90a), Zen3 host"
    cpu:
      detected: zen3
      preferred: zen3
    gpu:                                        # R within gpu: present when class has a GPU
      vendor: amd                               # R - amd | nvidia
      driver_version: "6.0"                     # R - kernel driver version on this class
      toolkit_ceiling: "6.0.0"                  # R - max toolkit the driver supports
      arch_target: gfx90a                       # R - arch label: AMD gfx90a/gfx942, NVIDIA sm_80/sm_90/etc.
      cuda_compat_available: false              # O - NVIDIA only; default false
    build_stage:
      - path: /local_scratch/$user/spack-stage
        visibility: compute-only
        writable: true
        throughput_class: fast

  gpu_compute_mi300a:                           # second GPU node class — separate entry, separate facts
    role: runtime
    description: "GPU compute, MI300A (gfx942), Zen4 host"
    cpu:
      detected: zen4
      preferred: zen4
    gpu:
      vendor: amd
      driver_version: "6.1"
      toolkit_ceiling: "6.1.0"
      arch_target: gfx942
    build_stage:
      - path: /local_scratch/$user/spack-stage
        visibility: compute-only
        writable: true
        throughput_class: fast

capabilities:                                   # R - derived flags the stack consults
  lanes_capable:                                # R - which (compiler, lane, runtime_node_type) tuples are valid
    - { compiler: cce,    lane: core,             runtime_node_types: [login, cpu_compute, gpu_compute_mi250x, gpu_compute_mi300a] }
    - { compiler: cce,    lane: serial,           runtime_node_types: [cpu_compute, gpu_compute_mi250x, gpu_compute_mi300a] }
    - { compiler: cce,    lane: mpi-craympich,    runtime_node_types: [cpu_compute, gpu_compute_mi250x, gpu_compute_mi300a] }
    - { compiler: gcc,    lane: core,             runtime_node_types: [login, cpu_compute, gpu_compute_mi250x, gpu_compute_mi300a] }
    - { compiler: gcc,    lane: mpi-craympich,    runtime_node_types: [cpu_compute, gpu_compute_mi250x, gpu_compute_mi300a] }
    # GPU lanes default to GCC host (Cray PE Option B: PrgEnv-gnu + standalone
    # rocm toolkit module). See §Host-Compiler Policy and §Cray PE + GPU.
    - { compiler: gcc,    lane: gpu-craympich-gfx90a,  runtime_node_types: [gpu_compute_mi250x] }
    - { compiler: gcc,    lane: gpu-craympich-gfx942,  runtime_node_types: [gpu_compute_mi300a] }
    # rocmcc/core is available as the precondition for named ROCmCC exception
    # lanes; no general-stack lanes are built under rocmcc by default.
    - { compiler: rocmcc, lane: core,             runtime_node_types: [gpu_compute_mi250x, gpu_compute_mi300a] }
  gpu_lane_supported: true                      # O - true if any node_type carries a gpu: block
  fabric_class: vendor_tuned                    # O - vendor_tuned | open | ethernet_only
```

### Why node_types is one block per system, not one profile per node class

A "system" in this design is one OS image + one admin team + one shared
filesystem + one MODULEPATH base. Login and compute nodes of a single
cluster share all of that, so most of the profile (OS, glibc, fabric
drivers, modules_system, Cray PE, compiler externals, MPI implementations,
shared filesystems) is identical across the cluster and lives at the top
of the file. Putting one profile per node type and duplicating those
top-level blocks in every file would invite drift — three copies of the
glibc version that have to be edited together.

What genuinely differs across node classes is small: the CPU target the
node class detects, whether the class carries a GPU (and which one),
which writable fast paths exist (login does not have `/local_scratch`,
compute does), and whether the class is a build host, a runtime target,
or both. Those things go inside `node_types[*]`, one block per class. A
homogeneous system has exactly one entry under `node_types:`; a system
with login + CPU compute + two GPU partitions has four. The schema
scales without restructuring.

### Node type roles

The `role:` field on each node type tells the rest of the pipeline how
the class participates in a build:

| Role | Meaning |
|---|---|
| `build_host` | Spack can run from this class. Ansible may submit `concretize`/`install` jobs here. Typically the login node. |
| `runtime` | The class hosts the running stack. Lane targets (CPU, GPU arch) are taken from runtime classes. |
| `both` | The class is suitable as both a build host and a runtime target. Some systems have compute nodes that login nodes can submit to *and* that can run Spack directly. |

A lane's `runtime_node_type` (declared in `stack.yaml`, see below) must
name a class with `role: runtime` or `role: both`. The CPU target and GPU
block the render step uses for the lane come from that node type.

The `capabilities.lanes_capable` list takes the cross-product into
account: it says which lanes can run on which node types. A `core` lane
is broad (any class) because Core is portable; an `mpi-craympich` lane
runs on compute classes (not login); a `gpu-craympich-gfx90a` lane runs
only on the gfx90a class. This list is what `stack-validate` checks
`stack.yaml`'s lane declarations against.

Profile rules:

- It is platform reality, not package intent.
- It must not require Ansible.
- It must not require ClusterInspector at build time.
- It should be reviewable and hand-editable. A profile written by hand against
  this schema is just as valid as one emitted by an inspector.
- It must not contain the stack package list, lane policy, or build cadence.
  Those are stack intent (`stack.yaml`), not platform reality.
- Versions are exact strings as Spack would resolve them. Backporting distros
  do not get a renamed version; the version string is what Spack will trust.
- Externals never carry a `%compiler` annotation. Cray PE per-flavor cray-mpich
  is the sanctioned exception (HPE genuinely ships per-compiler builds at
  distinct prefixes), and it is expressed by separate `flavors:` keys rather
  than by attaching a compiler to one spec.

The render step treats absent optional keys as defaults. A profile whose
`node_types` entries all have `gpu: null` produces a workspace with no GPU
lanes; a profile with no `vendor_cray:` block produces a workspace with no
Cray scope includes.
Required keys missing is a render-time failure, not a silent default.

For validation, render first constructs a normalized compiler inventory from
`vendor_cray.*` compiler entries plus `compilers_external.*`. Later checks refer
to this normalized inventory, not to `compilers_external` alone; otherwise Cray
compilers such as CCE and PE GCC would incorrectly fail validation.

### `stack.yaml`

`stack.yaml` declares desired stack behavior. It is the durable stack
contract, and it is **platform-portable** — one stack file can drive
multiple platforms because the render step picks which lanes apply based
on what the profile declares.

Lane entries may name provider-specific lanes. Profile-backed providers such as
`mpi-craympich` and `mpi-site` require matching facts in the profile.
Stack-built providers such as `mpi-openmpi` are satisfiable from stack templates
and package policy; they do **not** require an entry in `profile.mpi[]`. Lanes
whose profile-backed providers are not declared in the profile are **skipped**
at render time with an info-level log entry — not an error. So a stack file can
list both `mpi-craympich` and `mpi-openmpi` lanes; on a generic Linux HPC system
the craympich lane is skipped, while the Spack-built OpenMPI lane can still
render.
A skipped lane becomes an error only if the lane carries `required: true`, which
a stack maintainer sets when the lane's absence on a given system should fail
the render rather than be silently dropped.

Top-level stanzas (`externals.*`, `targets.*`, `modules.*`) stay
genuinely platform-agnostic: they express policy in terms of categories
(`compilers: prefer_platform`) that the render step resolves against the
profile.

It should answer questions like:

- What lanes should be built?
- What package sets should each lane use?
- What targets should each lane prefer?
- What module naming and exposure policy should users see?
- What externals policy should convert profile facts into Spack config?
- What build-cache lanes and release artifacts should be saved?

The full reference schema follows. Required keys are marked **R**; optional
keys are marked **O**.

```yaml
schema_version: 1                               # R - stack schema version
name: cse                                       # R - stack name; appears in paths and modules

profile_contract:                               # R - which profile schema this stack consumes
  schema_version: 1                             # R - render rejects mismatched profile schema

templates:                                      # R - which template set to render against
  set: v6                                       # R - template set name; matches templates/ on disk

modules:                                        # R - user-visible module strategy
  format: tcl                                   # R - mandatory baseline; always `tcl` (only valid value)
  additional_formats: []                        # O - optional add-ons; e.g. [lmod] to also emit Lua tree
  init_module: cse-init                         # R - bootstrap/init module users may load first
  module_root: CSE                              # R - user-facing lane-module root, e.g. CSE/GCC/mpi-openmpi
  hierarchy_style: collapsed                    # O - collapsed (default) | granular (Lmod-only)
  expose_provenance: true                       # O - default true; emits STACK_PACKAGE_PROVENANCE

targets:                                        # R - target policy by class
  foundation: x86_64_v3                         # R - portable baseline for Core
  science_default: runtime_preferred            # R - symbolic optimized target; resolves from lane.runtime_node_type cpu.preferred
  hard_require: false                           # O - false (preference) | true (require: target=...); default false

lanes:                                          # R - the matrix the render step expands
  - name: gcc-core                              # R - identifier; used in env paths and module names
    compiler: gcc                               # R - must match a compiler the profile can satisfy
    lane: core                                  # R - provider-qualified lane identifier
    kind: core                                  # R - strict enum: core | serial | mpi | gpu
    package_set: core-foundation                # R - which package-set file to expand into specs
    target: foundation                          # R - foundation | science_default | <named target>
    runtime_node_type: cpu_compute              # R - which profile.node_types entry the lane runs on
    publish: true                               # O - default true; false skips view/module regeneration
    required: false                             # O - default false; true → render errors if the lane cannot be satisfied

  - name: cce-mpi-craympich
    compiler: cce
    lane: mpi-craympich
    kind: mpi
    package_set: science-full
    target: science_default
    runtime_node_type: cpu_compute              # MPI lane targets a CPU compute class
    publish: true

  # GPU lanes default to GCC host (Cray PE Option B). One lane per GPU class.
  - name: gcc-gpu-craympich-gfx90a               # one lane per GPU class — names are explicit
    compiler: gcc
    lane: gpu-craympich-gfx90a
    kind: gpu
    package_set: science-gpu
    target: science_default
    runtime_node_type: gpu_compute_mi250x        # GPU lane targets the matching GPU class
    publish: true

  - name: gcc-gpu-craympich-gfx942
    compiler: gcc
    lane: gpu-craympich-gfx942
    kind: gpu
    package_set: science-gpu
    target: science_default
    runtime_node_type: gpu_compute_mi300a        # second GPU class gets its own lane
    publish: true

externals:                                      # R - platform-agnostic externals policy
  compilers: prefer_platform                    # R - prefer_platform | build_all | mixed
  mpi: prefer_platform                          # R - prefer_platform | build_all | mixed
  openssl: system                               # R - system (force external) | stack_built
  curl: system                                  # R - system | stack_built
  fabric_userspace: prefer_platform             # O - default prefer_platform
  gpu_toolkit: prefer_platform                  # O - default prefer_platform

foundation_pins:                                # O - libs the common scope must require: single-version
  zlib:  "1.3.1"
  xz:    "5.4.6"
  zstd:  "1.5.6"

buildcache:                                     # O - build-cache lane policy
  spack_generation: "spack-{spack_version}/repo-{package_repo_generation}"
  foundation_lane: "foundation/{os_id}/glibc-{glibc}/{spack_generation}/{baseline_target}"
  science_lane:    "science/{os_id}/glibc-{glibc}/{spack_generation}/{system}/{compiler}-{lane}/{target}"
  signed: false                                 # O - default false; true requires key configuration
  push_after_every_step: true                   # O - default true

release:                                        # R - what to save per release
  save_lockfiles: true                          # R - keep spack.lock per lane
  save_manifest: true                           # R - emit release-manifest.yaml
  retain_previous: 2                            # O - default 2; previous releases kept loadable
  promotion: gated_manual                       # O - gated_manual (default) | auto

helpers:                                        # O - maintainer recommendations on helper use
  # Values: preferred | available | disabled. These are recommendations only;
  # the manual workflow remains valid regardless. A stack can never force a
  # helper to be required — the design guarantees the manual path stays open.
  inspector: available                          # O - available (default) | preferred | disabled
  render:    available                          # O - same vocabulary
  ansible:   available                          # O - same vocabulary
```

Every key the render step understands maps to one or more template slots. The
table makes the mapping explicit; anyone tracing how a `stack.yaml` decision
reaches Spack config follows this map.

| stack.yaml key | Influences |
|---|---|
| `name` | rendered workspace path, release path root, view path root |
| `templates.set` | which `templates/` subtree is used |
| `modules.format` | the mandatory baseline format — always `tcl` |
| `modules.additional_formats` | optional extra formats to also emit (e.g. `[lmod]` on Lmod sites) |
| `modules.init_module` | bootstrap/init module name users may load first, e.g. `cse-init` |
| `modules.module_root` | user-facing lane-module root, e.g. `CSE` in `CSE/GCC/mpi-openmpi` |
| `modules.expose_provenance` | whether `setenv STACK_PACKAGE_PROVENANCE` is emitted |
| `targets.foundation` | `configs/target/<baseline>/packages.yaml` rendered into core lanes |
| `targets.science_default` | symbolic optimized target resolved per lane from `profile.node_types[lanes[*].runtime_node_type].cpu.preferred` |
| `targets.hard_require` | `target: [...]` vs `require: target=...` in the target scope |
| `lanes[*]` | one `environments/<compiler>/<lane>/spack.yaml` per entry |
| `lanes[*].package_set` | which `package-sets/<name>.yaml` is expanded into the lane's specs |
| `lanes[*].target` | which target scope the lane includes |
| `lanes[*].runtime_node_type` | which `profile.node_types` entry supplies the lane's CPU target and GPU block; render validates the name exists and that `role` is `runtime` or `both` |
| `externals.compilers` | `configs/vendor/<family>/packages.yaml` content for compilers |
| `externals.mpi` | `configs/mpi/<provider>/packages.yaml` content for MPI |
| `externals.openssl` / `externals.curl` | `configs/os/<os>/packages.yaml` system-external declarations |
| `externals.fabric_userspace` | UCX/libfabric `buildable` posture in fabric scope |
| `externals.gpu_toolkit` | CUDA/ROCm `buildable` posture in GPU scope |
| `foundation_pins.<lib>` | `require:` lines in the common scope |
| `buildcache.spack_generation` | path token separating incompatible Spack/package-repo generations |
| `buildcache.foundation_lane` | mirror path key for foundation cache |
| `buildcache.science_lane` | mirror path key for science cache |
| `release.save_lockfiles` | whether `spack.lock` is copied into `releases/<date>/` |
| `release.save_manifest` | whether `release-manifest.yaml` is emitted |
| `release.promotion` | whether Ansible swaps the `current` symlink automatically or waits for approval |

Stack rules:

- It is stack intent, not detected system state.
- It is platform-portable. Top-level policy stanzas (`externals.*`,
  `targets.*`, `modules.*`) carry no platform-specific blocks; the
  render step resolves them against the profile. Lane entries may name
  platform-specific providers; lanes whose providers are absent from
  the profile are skipped at render (or flagged as errors if marked
  `required: true`).
- It should be sufficient to explain the generated stack layout. Anything that
  shows up in the rendered workspace must be traceable to a key here, to a
  template, to a package set, or to the profile.
- It should remain valid if a human renders the files manually.
- It should avoid hidden policy in scripts or playbooks.

`modules.init_module` and `modules.module_root` are deliberately separate. The
init module is the optional bootstrap surface (`module load cse-init`) that can
set `MODULEPATH` to the current release. The module root is the user-facing lane
namespace (`CSE/GCC/mpi-openmpi`) exposed after initialization. Keeping them
separate prevents `cse-init` from being confused with the lane-module prefix.

### Package Set Files

A package set is a named list of root specs. Sets live under
`package-sets/<name>.yaml` and are referenced by `stack.yaml.lanes[*].package_set`.
A lane gets its spec list from exactly one set. Pulling the spec list out of
`stack.yaml` keeps the stack file focused on policy and lets multiple lanes
share the same set when their intent is the same.

Package sets are the **only** source of versioned root specs. If the stack ships
three HDF5 versions, those `hdf5@...` roots live in the package set, not in
`stack.yaml`. `stack.yaml.foundation_pins` is separate: it pins common-scope
dependency policy such as `zlib`, `xz`, or `zstd`; it does not define science
root versions.

Sets fall into three tiers, declared in the file itself:

| Tier | Meaning |
|---|---|
| `canonical` | A user-facing set the stack promises to ship. Changes go through normal review. |
| `smoke` | A small set used for CI/smoke tests. Never used by a production lane. |
| `experimental` | A set being tried out. May change or be deleted without notice. |

The tier guards against accidental promotion of test sets to production —
a `stack.yaml` lane that references a `smoke` set should fail render-time
validation unless the stack file explicitly opts in.

Schema:

```yaml
schema_version: 1
name: science-full                              # R - matches the filename stem
tier: canonical                                 # R - canonical | smoke | experimental
description: |                                  # R - human-readable purpose
  Full curated science library set: HDF5/NetCDF/PnetCDF (multi-version),
  TAU, and the common build tools needed at build time.

kinds: [serial, mpi]                            # R - which lane kinds this set is valid for

specs:                                          # R - root specs by lane-kind constraint
  any:                                          # specs identical across every kind in `kinds`
    - gsl@2.8
  serial:                                       # specs only for serial-kind lanes
    - hdf5@1.14.5~mpi+fortran
    - hdf5@1.14.4~mpi+fortran
    - hdf5@1.12.3~mpi+fortran
    - netcdf-c@4.9.2~mpi
    - netcdf-c@4.9.0~mpi
  mpi:                                          # specs only for mpi-kind lanes
    - hdf5@1.14.5+mpi+fortran
    - hdf5@1.14.4+mpi+fortran
    - hdf5@1.12.3+mpi+fortran
    - netcdf-c@4.9.2+mpi
    - netcdf-c@4.9.0+mpi
    - parallel-netcdf@1.13.0
    - tau+mpi

provenance_hints:                               # O - override the render-step provenance derivation
  cray-mpich: Platform-backed                   #     (otherwise derived from packages.yaml)
  openssl:    Site-external

notes: |                                        # O - free-form notes for maintainers
  Multi-version HDF5/NetCDF is the working target. PnetCDF stays single-version
  until the next refresh; revisit when 1.14.x lands.
```

The render step expands the set by selecting `specs.any` plus the
lane-kind-specific block (`specs.serial` for a serial lane, `specs.mpi` for
an MPI lane) and emits the result into the lane's `spack.yaml` `specs:`
list. `specs.any` is only for roots that are literally identical for every kind
the set supports. Dual-build packages such as HDF5 and NetCDF belong only in
the kind-specific blocks. After expansion, duplicate root specs by package name
and major variant class are a render-time validation error unless the package
set marks an explicit override. The toolchain decoration (`%cce_craympich`
etc.) is applied by the render step from the lane's compiler-and-MPI pairing,
not from the package set; sets stay compiler-agnostic so the same set is usable
across lanes.

Three canonical sets ship with the stack out of the gate:

- **`core-foundation`** — build tools and foundation libraries: `cmake`,
  `ninja`, `pkgconf`, `git`, `zlib-ng+compat`, `xz`, `zstd`, and the
  `miniforge` user environment. Used by every `<compiler>/core` lane.
- **`science-full`** — multi-version HDF5/NetCDF/PnetCDF, plus TAU and the
  performance-portability layers (`kokkos`, `raja`) without GPU variants.
  Used by serial and MPI lanes.
- **`science-gpu`** — GPU-flavored Kokkos/RAJA with backend and arch
  variants applied by the GPU scope, plus the MPI-aware HDF5/NetCDF the GPU
  lane needs. Used by GPU lanes.

Smoke sets used for CI live alongside (`smoke-hdf5-mpi`, `smoke-cuda-only`,
etc.) but are never referenced by a `stack.yaml` lane in production.

## Rendered Release Workspace

A rendered release workspace is the environment tree Spack actually reads. It is
generated or manually constructed from durable inputs.

Example shape:

```text
<render-dir>/<system>/<stack>/<release>/
  configs/
    common/
    os/rhel8/
    target/zen3/
    vendor/cray/
    mpi/cray-mpich/
    gpu/amd-rocm/
  environments/
    gcc/core/spack.yaml
    gcc/serial/spack.yaml
    cce/mpi-craympich/spack.yaml
    gcc/gpu-craympich-gfx90a/spack.yaml
  release-manifest.yaml
```

This workspace is not the highest-order source of truth. It is the runnable
Spack input. It may live in a temporary controller directory, on the target
shared filesystem, or in a release directory.

The generated workspace should be reproducible from:

```text
profile.yaml + stack.yaml + package-sets + templates + release vars
```

## What Goes Where

| File | Belongs here | Does not belong here |
|---|---|---|
| `spack.yaml` | Root specs, include list, lane views, lane-local settings | Platform-wide external definitions duplicated everywhere |
| `packages.yaml` | Externals, providers, buildable policy, targets, default variants | The full stack package list |
| `toolchains.yaml` | Named compiler/MPI policies | Filesystem paths unless part of external definitions |
| `config.yaml` | Install tree, caches, build stage, build jobs | Package list or module UX policy |
| `concretizer.yaml` | `unify: when_possible`, reuse policy | Per-lane root specs |
| `modules.yaml` | Spack-generated package-module behavior | Front-door lane-module policy; those modules are stack-owned |
| `mirrors.yaml` | Source mirror and build-cache mirror definitions | Stack software list |
| `env_vars.yaml` | Explicit stack environment variables | Implicit shell/module state |

## Config Layering Details

The environment manifest should include only the config scopes needed for that
lane. Each scope remains a separate directory on disk; Spack reads and merges
the scopes at solve time. The render step should place files, not flatten all
scope content into a single `spack.yaml`.

Example isolated lane manifest:

```yaml
spack:
  include::
    - ../../../configs/common
    - ../../../configs/mpi/cray-mpich
    - ../../../configs/target/zen3
    - ../../../configs/vendor/cray
    - ../../../configs/os/rhel8
  specs:
    - hdf5+mpi+fortran %cce_craympich
    - netcdf-c+mpi %cce_craympich
    - netcdf-fortran %cce_craympich
  view:
    default:
      root: /shared/stack/views/example-cray/cse/cce/mpi-craympich
      projections:
        all: "{name}/{version}"
      link: roots
      link_type: symlink
```

`concretizer.yaml` belongs in `configs/common` so every lane inherits the same
base solve policy:

```yaml
concretizer:
  unify: when_possible
  reuse: true
```

Two additional concretizer controls may be useful, but they are not committed
template defaults until validated against the deployed Spack release. If a solve
runs on a login/build host while the lane targets compute-only CPUs, validate
the deployed syntax for disabling host-compatible target filtering before adding
that knob to `configs/common/concretizer.yaml`. If a site sees unwanted mixed-
compiler link/run dependencies, validate the deployed syntax for disabling
compiler mixing before adding it. Do not put either key into the generated
templates just because it appears in this design note; prove it with
`spack config get concretizer` and a representative concretization first.

### Multi-Version Policy and the Foundation Single-Version Rule

The stack carries **multiple versions** of important science libraries so users
are not forced onto a single version. As a working target, science lanes carry
at least the latest three versions of HDF5, NetCDF, and the other libraries
users pin to. This is what makes `unify: when_possible` necessary rather than
strict `unify: true`: strict unification forces one coherent assignment across
the environment, which collapses or fails when an environment legitimately
wants three HDF5 versions. `when_possible` deduplicates shared deps where they
agree and permits independent version sub-DAGs where they do not, which is the
behavior the multi-version policy needs.

Multi-version is a **science-lane concern only**. Core stays single-version
because there is no user reason to expose multiple CMakes, and the foundation
stable-ABI libraries (zlib, xz, zstd, and any others a deployed-system DAG
inspection adds) are pinned **single-version** with explicit `require:` lines
in the common scope. The reason is direct: this is a build environment for
users, and users will compile their own code against the libraries the stack
exposes. For a science library that is fine because the user makes an explicit
`module load hdf5/1.14.5` choice and only that version is exposed. The
foundation stable-ABI libraries are **ambient** — the user's compiler picks
them up without an explicit choice — and their soname is major-version-only
(zlib presents `libz.so.1` across many versions), so two versions on the same
path are indistinguishable to the user's link step. RPATH protects the stack's
own builds (each stack binary records the absolute path of the exact library
it linked) but does not protect the user's fresh compile, where RPATH has not
happened yet. The `require:` line on each foundation pinned library is what
keeps the user-link path unambiguous.

The `require:` pins the *version*, not the compiler, so each compiler's Core
builds the same version under its own compiler — one version per lane, which
is all that matters because a user is only ever in one lane at a time.

```yaml
# configs/common/packages.yaml (excerpt)
packages:
  zlib:
    require: "@1.3.1"
  xz:
    require: "@5.4.6"
  zstd:
    require: "@1.5.6"
```

The single-version rule applies only to libraries **exposed in the user-facing
view for direct compilation**. The discriminator is "does a user `-l` this
directly," not "is it a low-level library." A library can be multi-version in
the install tree and at runtime without any problem, because RPATH isolates
each consumer to the exact version it linked. Two tools in one lane that
privately link two different versions of a transitive dependency coexist
fine. The ambiguity arises only when two versions are both projected into the
user-facing view for the user to link against. OpenSSL, for example, is
generally a private transitive dependency — the tools that need it RPATH it
internally and it is not view-projected because most user codes do not
`-l ssl` directly — so it does not need foundation single-version enforcement.
Reserve the rule for libraries users actually link directly (zlib being the
common case); leave the rest as private transitive deps that RPATH isolates.

The set of libraries that belong on the pinned list is derived per-system, not
hard-coded. The procedure is a once-per-build-cycle dry run: concretize a lane
(`spack -e <lane> spec --json`), read the low-level link deps at the bottom of
the DAG, filter by dependency type to keep only link-time candidates a user
could compile against, then check soname stability per library (zlib qualifies;
OpenSSL does not, and is also not view-exposed anyway). Externals — for
example cray-mpich — do not expand their internal library closure into the
DAG, so anything they drag at runtime is invisible to spec-based discovery;
note that as a known blind spot. The hard part of this work (which libraries
are ABI-safe to pin) is stable and carries forward across cycles; the
discovery itself gets cheaper each cycle.

The multi-version stack lives inside **one environment per lane**, not one
environment per version. Splitting each version into its own environment was
considered and rejected: it multiplies lockfiles, views, and module roots
without buying isolation that `when_possible` does not already provide. The
exception would be a version whose dependency requirements are so divergent
that they pollute the lane's solve; such a case can be broken out into its
own environment, but it is the exception, not the rule.

Versions interact with the rest of the design as follows: each version is a
distinct spec in the lane's `spack.yaml`; the projected view exposes versions
under `{name}/{version}` so users select with `module load netcdf-c/4.9.2`;
releases are versioned and rolled back as a unit through the `current`
symlink. Note that *versioning* here means multiple versions of a package
within a lane; it is distinct from the serial-versus-MPI split, which is
handled by separate lanes, not by version suffixes.

### Scope Blame

Every production lane should pass a scope provenance check. Example:

```text
$ spack -e environments/cce/mpi-craympich config blame packages
---
packages:
  mpi:
    require:
    - cray-mpich              # configs/mpi/cray-mpich/packages.yaml:3
  cray-mpich:
    buildable: false          # configs/mpi/cray-mpich/packages.yaml:6
    externals:
    - spec: cray-mpich@8.1.29 %cce
      prefix: /opt/cray/pe/mpich/8.1.29/ofi/cray/17.0
                               # configs/mpi/cray-mpich/packages.yaml:9
  all:
    target:
    - zen3                    # configs/target/zen3/packages.yaml:4
```

Every setting should trace to the rendered workspace plus Spack defaults. If a
user, site, or system config scope appears unexpectedly, fix the `include::`
list before building.

### Concretizer Posture Per Environment Kind

`concretizer.yaml` belongs in `configs/common`, but two settings — `reuse:`
and `unify:` — interact with the environment's purpose in ways worth making
explicit. The wrong posture in the wrong environment is silently incorrect:
the lockfile looks fine; the build proceeds; the failure is that *the work
you intended to happen does not happen.*

| Environment kind | `reuse:` | `unify:` | Rationale |
|---|---|---|---|
| Science lane (serial / MPI / GPU) | `true` | `when_possible` | Pull finished binaries from the foundation cache (no rebuild of CMake/Ninja/zlib per lane); allow multi-version science libs to coexist. |
| Core / foundation lane | `true` | `when_possible` | Same reuse posture; `when_possible` is harmless here because Core is single-version by policy. |
| Pipeline-driving env (input to `spack ci generate`) | `false` | `when_possible` | With `reuse: true`, `spack ci generate` will not emit rebuild jobs for specs whose hashes changed but whose old hashes still appear in the cache — the intended rebuilds silently do not happen. Pipeline envs *must* set `reuse: false` so changed definitions produce rebuild jobs. |
| Bootstrap / compiler-build env | `true` | `when_possible` | The compiler is the only meaningful spec here; reuse is still useful for the build-time deps (Autotools chain, perl, etc.). |
| Diagnostic / experimentation env | `false` | `when_possible` | When investigating "why did the solver pick X," `reuse: false` forces a fresh solve uninfluenced by cached binaries. |

The two `reuse:` postures are not in conflict. **Build-time `reuse: true`**
pulls finished binaries from the cache to avoid recompiling unchanged work.
**Pipeline-generation `reuse: false`** must be off so that changed
definitions produce the rebuild jobs that the pipeline is supposed to
emit. The science lane is the build-time case; the pipeline env is the
generation case; they are separate environments serving different purposes,
and they each set the value appropriate to their purpose.

`unify: when_possible` is the committed default for every kind because the
foundation single-version rule (which strict unification would have
covered) is enforced explicitly via `require:` in the common scope, and the
science lanes carry multi-version stacks that strict unification would
collapse. `when_possible` deduplicates shared deps where they agree without
forcing them where they disagree, which is exactly the posture this design
needs.

Reflecting on whether to ever set `unify: true`: only if the stack ever
abandons multi-version policy entirely, which is not the current direction.
The setting is documented for completeness; the stack ships with
`unify: when_possible` and stays there until the multi-version policy itself
changes.

## Detailed Scenario: Cray RHEL With Cray PE

This scenario represents a RHEL-based Cray system with Cray PE, Cray MPICH, and
AMD GPU nodes. Versions and prefixes are examples; the actual values come from
`profile.yaml`.

Major lanes:

- CCE + Cray MPICH for MPI science packages.
- GCC + Cray MPICH where a GNU lane is desired.
- ROCmCC + Cray MPICH for AMD GPU packages.
- Core/foundation packages at a portable target.

### Cray Core Lane

Core holds build tools and neutral libraries. It uses the portable target, not
the optimized science target.

```yaml
# environments/cce/core/spack.yaml
spack:
  include::
    - ../../../configs/common
    - ../../../configs/target/x86_64_v3
    - ../../../configs/vendor/cray
    - ../../../configs/os/rhel8
  specs:
    - cmake
    - ninja
    - pkgconf
    - git
    - zlib-ng+compat
  view:
    default:
      root: /shared/stack/views/example-cray/cse/cce/core
      projections:
        all: "{name}/{version}"
      link: roots
      link_type: symlink
```

### Cray Serial Lane

The serial lane carries science packages built without MPI. Build tools do not
belong here because they live in Core.

```yaml
# environments/cce/serial/spack.yaml
spack:
  include::
    - ../../../configs/common
    - ../../../configs/target/zen3
    - ../../../configs/vendor/cray
    - ../../../configs/os/rhel8
  specs:
    - hdf5~mpi+fortran %cce_serial
    - netcdf-c~mpi %cce_serial
    - netcdf-fortran %cce_serial
  view:
    default:
      root: /shared/stack/views/example-cray/cse/cce/serial
      projections:
        all: "{name}/{version}"
      link: roots
      link_type: symlink
```

### Cray MPI Lane

The MPI lane carries MPI-enabled science packages. On Cray, the MPI provider is
Cray MPICH external, not a Spack-built MPI.

```yaml
# environments/cce/mpi-craympich/spack.yaml
spack:
  include::
    - ../../../configs/common
    - ../../../configs/mpi/cray-mpich
    - ../../../configs/target/zen3
    - ../../../configs/vendor/cray
    - ../../../configs/os/rhel8
  specs:
    - hdf5@1.14.5+mpi+fortran %cce_craympich
    - hdf5@1.14.4+mpi+fortran %cce_craympich
    - netcdf-c@4.9.2+mpi %cce_craympich
    - netcdf-fortran@4.6.1 %cce_craympich
    - parallel-netcdf@1.13.0 %cce_craympich
  view:
    default:
      root: /shared/stack/views/example-cray/cse/cce/mpi-craympich
      projections:
        all: "{name}/{version}"
      link: roots
      link_type: symlink
```

### Cray GPU Lane

GPU lanes include GPU runtime scopes and carry GPU-sensitive packages. The
committed default is the Option B assembly (GCC host + standalone ROCm
toolkit module + GCC-flavor cray-mpich); the lane shows that. One lane
per GPU class — `gfx90a` here, with a parallel `gfx942` lane added when a
second GPU class is present. Toolchain decoration is `%gcc_craympich`,
not `%rocmcc_craympich`, because the host compiler is GCC.

```yaml
# environments/gcc/gpu-craympich-gfx90a/spack.yaml
spack:
  include::
    - ../../../configs/common
    - ../../../configs/gpu/amd-rocm
    - ../../../configs/mpi/cray-mpich
    - ../../../configs/target/zen3
    - ../../../configs/vendor/cray
    - ../../../configs/os/rhel8
  specs:
    # GPU-arch-pinned performance-portability layer and applications
    - kokkos+rocm amdgpu_target=gfx90a %gcc_craympich
    - raja+rocm   amdgpu_target=gfx90a %gcc_craympich
    # MPI-aware sciences — the GPU lane is itself an MPI lane (carries the
    # same MPI-aware libraries as the plain CCE/GCC MPI lane, plus the
    # GPU-pinned packages above).
    - hdf5+mpi+fortran      %gcc_craympich
    - netcdf-c+mpi          %gcc_craympich
    - netcdf-fortran        %gcc_craympich
    - parallel-netcdf       %gcc_craympich
  view:
    default:
      root: /shared/stack/views/example-cray/cse/gcc/gpu-craympich-gfx90a
      projections:
        all: "{name}/{version}"
      link: roots
      link_type: symlink
```

The lane's front-door module loads `PrgEnv-gnu` + `gcc-native/13` +
`rocm/<v>` + `cray-mpich/<v>` at runtime (Option B), not `PrgEnv-amd`.
A second GPU class (MI300A) gets its own parallel lane:
`environments/gcc/gpu-craympich-gfx942/spack.yaml` with the same shape and
`amdgpu_target=gfx942`, targeting `runtime_node_type: gpu_compute_mi300a`.

**Option A as an exception lane.** When a code specifically needs NVHPC's
compiler driver or ROCmCC's amdclang (OpenACC code, CUDA Fortran, AMD-
vendor codes), an exception lane with `PrgEnv-amd` / `PrgEnv-nvidia` and
`%rocmcc_craympich` / `%nvhpc_craympich` is rendered alongside the default
lane. It is named explicitly (`environments/rocmcc/gpu-craympich-gfx90a/`)
and carries only the codes that justify it, not the general science
stack.

Kokkos and RAJA do not belong in Core. Their GPU backend and architecture are
build-time choices, and their C++ template interfaces are compiler-sensitive.

**The GPU lane composes with its own compiler's Core, not with a separate
"gpu-core" view.** Under the committed Option B default, the GPU lane is
`gcc/gpu-craympich-<arch>` and it composes with `gcc/core`. The Option A
exception lane uses the vendor host compiler, so a `rocmcc/gpu-...` lane
would compose with `rocmcc/core`; a `nvhpc/gpu-...` lane would compose with
`nvhpc/core`. The lane's front-door module prepends both the compiler's
Core MODULEPATH and the GPU lane's MODULEPATH, the same way the serial and
MPI lanes work. There is no separate Core layer for GPU lanes because
there is no need for one — the host compiler is the compiler, and the
Core built for that compiler is the Core the GPU lane reuses.

This composition rule means a system with a GPU lane has, for that compiler, a
core environment plus a `gpu-<provider>` lane environment. A system with both
serial/MPI lanes *and* a GPU lane under the same compiler has serial, MPI, and
GPU lane environments all composing with the one `<compiler>/core` for that
compiler. The user picks exactly one of the three at a time (the lane conflict
rule); Core is always present.

### Cray Compiler Externals

Cray PE compiler externals use both `prefix` and `modules`. The module list is
part of the external contract because Cray compiler behavior depends on the PE
module environment, especially for Fortran and Cray runtime/library paths.

```yaml
# configs/vendor/cray/packages.yaml
packages:
  cce:
    buildable: false
    externals:
      - spec: cce@17.0.1 languages='c,c++,fortran'
        prefix: /opt/cray/pe/cce/17.0.1
        modules: [PrgEnv-cray, cce/17.0.1]
        extra_attributes:
          compilers:
            c: /opt/cray/pe/cce/17.0.1/bin/craycc
            cxx: /opt/cray/pe/cce/17.0.1/bin/craycxx
            fortran: /opt/cray/pe/cce/17.0.1/bin/crayftn
  gcc:
    buildable: false
    externals:
      - spec: gcc@13.3.0 languages='c,c++,fortran'
        prefix: /opt/cray/pe/gcc-native/13
        modules: [PrgEnv-gnu, gcc-native/13]
  rocmcc:
    buildable: false
    externals:
      - spec: rocmcc@6.0.0 languages='c,c++,fortran'
        prefix: /opt/rocm-6.0.0
        modules: [PrgEnv-amd, rocm/6.0.0]
```

### Cray MPICH Externals

Cray MPICH is compiler-flavored. The same version can have distinct prefixes for
CCE, GNU, and ROCmCC PrgEnv families.

```yaml
# configs/mpi/cray-mpich/packages.yaml
packages:
  mpi:
    buildable: false
    require:
      - cray-mpich
  cray-mpich:
    buildable: false
    variants: +wrappers
    externals:
      - spec: cray-mpich@8.1.29 %cce
        prefix: /opt/cray/pe/mpich/8.1.29/ofi/cray/17.0
        modules: [cray-mpich/8.1.29]
      - spec: cray-mpich@8.1.29 %gcc
        prefix: /opt/cray/pe/mpich/8.1.29/ofi/gnu/13.3
        modules: [cray-mpich/8.1.29]
      - spec: cray-mpich@8.1.29 %rocmcc
        prefix: /opt/cray/pe/mpich/8.1.29/ofi/amd/6.0
        modules: [cray-mpich/8.1.29]
```

The `modules:` entry is the same name for every flavor because the PE resolves
the flavor from whichever `PrgEnv-*` is loaded: the compiler external's
`PrgEnv-*` module plus `cray-mpich/8.1.29` lands on the matching `ofi/<flavor>`
build. The explicit per-flavor `prefix:` keeps the declaration honest about
which build each spec refers to. Cray MPICH is the sanctioned exception to the
"externals carry no `%compiler` attachment" rule: HPE genuinely ships
compiler-matched builds at distinct prefixes, so the compiler annotation here
is real, not cosmetic.

The toolchains scope binds each compiler to its matching cray-mpich flavor so
the concretizer cannot pick the wrong pairing even when more than one external
could satisfy:

```yaml
# configs/mpi/cray-mpich/toolchains.yaml
# The `when: "%c"` conditional form is the newest part of the toolchains
# feature; validate the exact syntax against the deployed Spack version.
toolchains:
  cce_serial:
    - { spec: "%c=cce@17.0.1",       when: "%c" }
    - { spec: "%cxx=cce@17.0.1",     when: "%cxx" }
    - { spec: "%fortran=cce@17.0.1", when: "%fortran" }
  cce_craympich:
    - { spec: "%c=cce@17.0.1",       when: "%c" }
    - { spec: "%cxx=cce@17.0.1",     when: "%cxx" }
    - { spec: "%fortran=cce@17.0.1", when: "%fortran" }
    - { spec: "%mpi=cray-mpich@8.1.29", when: "%mpi" }
  gcc_craympich:
    - { spec: "%c=gcc@13.3.0",       when: "%c" }
    - { spec: "%cxx=gcc@13.3.0",     when: "%cxx" }
    - { spec: "%fortran=gcc@13.3.0", when: "%fortran" }
    - { spec: "%mpi=cray-mpich@8.1.29", when: "%mpi" }
  rocmcc_craympich:
    - { spec: "%c=rocmcc@6.0.0",       when: "%c" }
    - { spec: "%cxx=rocmcc@6.0.0",     when: "%cxx" }
    - { spec: "%fortran=rocmcc@6.0.0", when: "%fortran" }
    - { spec: "%mpi=cray-mpich@8.1.29", when: "%mpi" }
```

A spec written `hdf5+mpi+fortran %cce_craympich` then carries the CCE-plus-cray-mpich
constraint atomically. The pairing is what makes ABI matching guaranteed
rather than inferred; without the toolchain, the concretizer might pick a
different (compiler-mismatched) flavor when the externals are ambiguous.

On Cray, do not replace Cray MPICH with Spack-built OpenMPI or MPICH for the
main MPI lanes. Cray MPICH is tuned for the PE and fabric. The compiler split is
the stack's choice; the MPI provider is platform-owned.

## Detailed Scenario: Generic Linux HPC With Site MPI

This scenario represents a Linux system with a vendor/site compiler, optional
site MPI, and the possibility of a Spack-built MPI lane.

Major lanes:

- GCC or site compiler + serial.
- Site compiler + site MPI.
- Site compiler or GCC + Spack-built OpenMPI.
- Optional GPU lanes when GPUs exist.

### Site Compiler External

```yaml
# configs/vendor/linux/packages.yaml
packages:
  aocc:
    buildable: false
    externals:
      - spec: aocc@4.2.0 languages='c,c++,fortran'
        prefix: /opt/AMD/aocc-compiler-4.2.0
        modules: [aocc/4.2.0]
```

### Site MPI External

Prefer stable prefixes over modules when possible. Use modules only when the MPI
environment cannot be reconstructed from prefix and standard paths.

```yaml
# configs/mpi/site-mpi/packages.yaml
packages:
  mpi:
    buildable: false
    require:
      - openmpi
  openmpi:
    buildable: false
    externals:
      - spec: openmpi@4.1.6 %aocc@4.2.0
        prefix: /opt/site/openmpi/4.1.6-aocc-4.2.0
```

The `%aocc@4.2.0` annotation on the site MPI external is acceptable here only
because the site MPI is genuinely compiler-matched to AOCC at the named prefix
(the site built it with AOCC). When a site MPI is built once and works against
any consumer compiler, drop the annotation — externals carry no compiler tag
unless the underlying binary really is per-compiler.

```yaml
# configs/mpi/site-mpi/toolchains.yaml
toolchains:
  aocc_site_mpi:
    - { spec: "%c=aocc@4.2.0",       when: "%c" }
    - { spec: "%cxx=aocc@4.2.0",     when: "%cxx" }
    - { spec: "%fortran=aocc@4.2.0", when: "%fortran" }
    - { spec: "%mpi=openmpi@4.1.6",  when: "%mpi" }
```

### Spack-Built OpenMPI Lane

When site MPI is unsuitable or the stack should own the full MPI stack, use a
separate Spack-built MPI lane.

```yaml
# configs/mpi/spack-openmpi/packages.yaml
packages:
  mpi:
    require:
      - openmpi
  openmpi:
    buildable: true
    require:
      - '@5:'
      - fabrics=ucx
```

The `require:` on the `mpi` virtual keeps the lane's MPI provider singular: a
multi-version science library inside the lane cannot float a second OpenMPI
underneath itself. This is the lane-coherence protection the Cray lane gets
for free (because cray-mpich is a single `buildable: false` external) and a
Linux Spack-built lane has to assert explicitly.

```yaml
# configs/mpi/spack-openmpi/toolchains.yaml
toolchains:
  aocc_spack_openmpi:
    - { spec: "%c=aocc@4.2.0",       when: "%c" }
    - { spec: "%cxx=aocc@4.2.0",     when: "%cxx" }
    - { spec: "%fortran=aocc@4.2.0", when: "%fortran" }
    - { spec: "%mpi=openmpi",        when: "%mpi" }
  gcc_spack_openmpi:
    - { spec: "%c=gcc@13.3.0",       when: "%c" }
    - { spec: "%cxx=gcc@13.3.0",     when: "%cxx" }
    - { spec: "%fortran=gcc@13.3.0", when: "%fortran" }
    - { spec: "%mpi=openmpi",        when: "%mpi" }
```

The toolchain pins the *provider* (`openmpi`) but not the version, because the
science libraries in the lane stay MPI-version-agnostic and bind whatever
single OpenMPI the lane resolves. Tight library-to-MPI-version pins are a
per-version exception (used only when a specific old library has a known
incompatibility with the current MPI), not policy.

Keep site-MPI and Spack-MPI lanes separate. Do not let one lane accidentally
resolve multiple MPI providers.

## Manual Workflow

The manual workflow is the reference model. Automation must be a wrapper around
this process, not a replacement for it.

```text
1. Write or review systems/<system>/profile.yaml.
2. Write or review stacks/<stack>/stack.yaml.
3. Materialize the rendered release workspace.
4. Inspect the selected `include::` scopes.
5. Run `spack -e <env> config scopes -vp` and `spack -e <env> config blame`.
6. Run `spack -e <env> concretize`.
7. Run `spack -e <env> fetch -D` when preparing a source cache.
8. Run `spack -e <env> install` on the target build host or allocation.
9. Refresh views/modules.
10. Push build caches if configured.
11. Save `spack.lock` and `release-manifest.yaml`.
12. Promote only after verification passes.
```

Any step that cannot be explained by `profile.yaml`, `stack.yaml`, templates,
package sets, or release vars is hidden policy and should be moved into one of
those artifacts.

## Render Step — Specification

The render step is the seam between source-of-truth (`profile.yaml`,
`stack.yaml`, package sets, templates) and runnable Spack input (the
rendered workspace). It is mechanical and deterministic. A render helper is
the typical implementation, but the step itself is a *contract*: anything
that satisfies the contract — a Python helper, a Make target, a human with
a text editor — produces a valid workspace.

### Inputs

| Input | Source | Role |
|---|---|---|
| `profile.yaml` | `systems/<system>/profile.yaml` | Platform facts. |
| `stack.yaml` | `stacks/<stack>/stack.yaml` | Stack intent. |
| Package sets | `package-sets/<name>.yaml`, all referenced by `stack.yaml.lanes[*].package_set` | Root specs. |
| Templates | `templates/<set>/configs/...` and `templates/<set>/environments/...` | Jinja-style templates the step expands. |
| Release vars | Command-line or environment | `release_tag`, `output_dir`, build-cache mirror URLs, optional overrides. |

### Outputs

| Output | Location | Purpose |
|---|---|---|
| Workspace tree | `<output>/<system>/<stack>/<release>/` | What Spack reads. |
| `configs/<scope>/...` | inside the workspace | Rendered config scopes. |
| `environments/<compiler>/<lane>/spack.yaml` | inside the workspace | Rendered lane environments. |
| `release-manifest.yaml` | inside the workspace | Provenance for the release (schema specified in Release Artifacts). |
| Render log | stderr or a log file | Human-readable record of which lanes were rendered and why anything was skipped. |

### Invariants

The render step is bound by a small number of rules. Violating any of them
breaks the *helpers are optional* property, which is load-bearing for the
whole design.

| Invariant | Why |
|---|---|
| **Determinism.** Same inputs → byte-identical workspace. | A re-render must not introduce diffs from ambient state. |
| **Read-only on the host.** No probing `$HOME`, `$PATH`, `module list`, loaded shell state, or live system files. | The render step does not depend on the host being the target system. A laptop can render a Cray release. |
| **No Spack calls.** The step does not run `spack concretize`, `spack spec`, or anything else that requires a Spack installation. | Render and concretize are separate steps that may run on different machines. |
| **No SSH and no remote copy.** The step writes only inside `--output`. | Distribution to target systems is Ansible's job (or a human's `rsync`); not the render step's. |
| **No `--install`, no promotion.** The step never invokes Spack and never swaps the `current` symlink. | Render produces inputs; build and promotion are separate stages. |
| **No partial output on failure.** If validation fails or any template fails to render, the step deletes its partial output and exits non-zero with a useful error. | A half-rendered workspace is worse than none; the next step would consume invalid input. |
| **Render-time validation.** Schema-validate `profile.yaml` and `stack.yaml`; cross-check `stack.yaml.profile_contract.schema_version` against the profile; check that every `stack.yaml.lanes[*].package_set` exists; check that every `package_set` lane-kind is compatible with the lane that references it; check that the platform externals the stack requests (`prefer_platform`) are actually present in the profile. | Catch errors at the cheapest moment. |
| **Renderer identity.** The render step records its own name and version in `release-manifest.yaml.templates.render_tool`. | A reader can identify the exact tool that produced a workspace. |

Manual rendering uses the same manifest field: `render_tool.name: manual` and
`render_tool.version: null`. A helper records its command name and version.
Timestamp fields in a draft manifest are explicit release variables supplied to
the render step. A render helper may default them for operator convenience, but
the render contract itself never calls the wall clock. If `rendered_at` changes,
that is a changed input, not ambient state.

### Helper-style example invocations

The reference helper name is `stack-render`. Helper names are working names for
the design and examples until a naming review, but the render contract survives a
rename.

The helper writes the workspace under
`<output-root>/<system>/<stack>/<release>/`. Pass the root; the helper
derives the rest from the profile and release vars. This matches the
determinism guarantee (same inputs → same output path).

```bash
# Render a release workspace
stack-render \
  --profile systems/example-cray/profile.yaml \
  --stack stacks/cse/stack.yaml \
  --release 2026.06 \
  --output-root /tmp/rendered
# → workspace written to /tmp/rendered/example-cray/cse/2026.06/

# Validate without rendering
stack-validate \
  --profile systems/example-cray/profile.yaml \
  --stack stacks/cse/stack.yaml

# Explain: print the planned render context without writing files
stack-explain \
  --profile systems/example-cray/profile.yaml \
  --stack stacks/cse/stack.yaml \
  --release 2026.06
```

### Render step pseudo-code

Language-neutral; the implementation may be Python, Make, Bash, or
something else. The shape is what matters.

```text
function render(profile_path, stack_path, package_sets_dir, templates_dir,
                release_vars, output_dir):

    # ── Inputs ────────────────────────────────────────────────────────────
    profile = load_yaml(profile_path)
    stack   = load_yaml(stack_path)

    validate_schema(profile, "profile.v1")
    validate_schema(stack,   "stack.v1")

    require(stack.profile_contract.schema_version == profile.schema_version,
            "profile schema does not match stack.profile_contract")

    require(profile.system.name == release_vars.system_name_or(profile.system.name),
            "system name override mismatch")

    sets = {}
    for lane in stack.lanes:
        set_file = package_sets_dir / (lane.package_set + ".yaml")
        require(set_file.exists, "missing package set: " + lane.package_set)
        s = load_yaml(set_file)
        validate_schema(s, "package_set.v1")
        require(lane.kind in s.kinds,
                "package set " + s.name + " is not valid for kind " + lane.kind)
        if s.tier != "canonical":
            require(release_vars.allow_noncanonical,
                    "lane " + lane.name + " uses non-canonical set " + s.name)
        sets[s.name] = s

    rendered_lanes = []
    skipped_lanes = []
    for lane in stack.lanes:
        reason = unsatisfied_lane_reason(lane, profile)
        if reason is None:
            rendered_lanes.append(lane)
        elif lane.required:
            fail("required lane " + lane.name + " cannot render: " + reason)
        else:
            skipped_lanes.append({"lane": lane.name, "reason": reason})

    require(rendered_lanes, "no stack lanes can render for profile " + profile.system.name)

    # ── Context ───────────────────────────────────────────────────────────
    ctx = build_render_context(profile, stack, sets, rendered_lanes,
                               skipped_lanes, release_vars)
    # ctx is a frozen dict. Nothing in it reads ambient state, $HOME, $PATH,
    # or `module list`. Two renders with the same ctx produce the same bytes.

    # ── Workspace skeleton ────────────────────────────────────────────────
    workspace = output_dir / profile.system.name / stack.name / release_vars.release
    if workspace.exists and not release_vars.overwrite:
        fail("workspace already exists: " + workspace)
    pending = workspace + ".rendering"   # write to side path, rename atomically
    if pending.exists:
        fail("stale render side path exists: " + pending)
    mkdir_clean(pending)

    # ── Config scopes ─────────────────────────────────────────────────────
    for scope_name in required_scopes(profile, rendered_lanes):
        # scope_name examples: common, os/rhel8, target/zen3, target/x86_64_v3,
        # vendor/cray, mpi/cray-mpich, gpu/amd-rocm
        src = templates_dir / "configs" / scope_name
        dst = pending / "configs" / scope_name
        render_template_tree(src, dst, ctx)

    # ── Lane environments ────────────────────────────────────────────────
    for lane in rendered_lanes:
        lane_ctx = ctx | {
            "lane":     lane,
            "specs":    expand_package_set(sets[lane.package_set], lane),
            "scopes":   scopes_for_lane(lane, stack, profile),
            "toolchain": toolchain_for_lane(lane),
            "view_root": view_root(profile, stack, lane, release_vars),
            "runtime_modules": runtime_modules_for_lane(lane, profile),
        }
        src = templates_dir / "environments" / lane.kind / "spack.yaml.j2"
        dst = pending / "environments" / lane.compiler / lane.lane / "spack.yaml"
        render_template(src, dst, lane_ctx)

    # ── Release manifest ─────────────────────────────────────────────────
    write_yaml(pending / "release-manifest.yaml",
               build_manifest(ctx, pending, rendered_lanes, skipped_lanes))

    # ── Commit ──────────────────────────────────────────────────────────
    atomic_rename(pending, workspace, replace=release_vars.overwrite)
    return workspace


# Invariants the implementation must honor:
#   - render() reads only its arguments and the named files. No $HOME,
#     no env probing, no `module list`, no /etc/* lookups.
#   - render() never calls spack, never SSHes, never writes outside output_dir.
#   - On any failure, the side path is deleted before render() returns.
#   - Same inputs → byte-identical workspace.
#   - The render tool's name and version are written into release-manifest.yaml
#     so a reader can identify what produced the workspace.
```

The functions called by `render` (`unsatisfied_lane_reason`, `required_scopes`,
`scopes_for_lane`, `toolchain_for_lane`, `runtime_modules_for_lane`,
`view_root`, `expand_package_set`, `build_manifest`) are pure transformations
of the frozen context. None of them touches the host.

### Failure modes the render step catches

These should fail *at render time*, not at Spack-build time, because they
are cheaper to fix here:

- Missing required profile key.
- Profile schema mismatch with `stack.yaml.profile_contract`.
- `stack.yaml.lanes[*].package_set` references a nonexistent file.
- A lane's `kind` is not in the package set's `kinds` list.
- A required lane references a compiler the normalized compiler inventory does not declare.
- A required GPU lane is requested but no matching `profile.node_types[*].gpu` block exists.
- A required Cray lane is requested but the profile has no `vendor_cray:` block.
- A site-external lane's runtime modules cannot be resolved (the named
  modules are not declared on any external in the profile).

## ClusterInspector — Specification

ClusterInspector is the read-only system inspector that produces a
`profile.yaml`. It is *optional* by design: any human or other tool can
produce a valid profile, and the rest of the stack does not call into
ClusterInspector at build time.

### Goals

- Probe the system for every fact the profile schema requires (and the
  optional facts that improve later decisions).
- Emit a single `profile.yaml` that the stack repository can commit, review,
  and edit by hand.
- Make the inspection repeatable: running it twice on the same system
  produces the same output (modulo timestamps).

### Explicit non-goals

These belong to other stages and are *not* ClusterInspector's job:

- **No render.** ClusterInspector does not produce `spack.yaml`, scopes, or
  modulefiles. Those are the render step's outputs.
- **No Spack calls.** ClusterInspector does not run `spack concretize`,
  `spack install`, or any other Spack command. Spack may be installed on the
  same host, but the inspector does not depend on it.
- **No deploy.** ClusterInspector does not copy files anywhere, does not
  modify the system, and does not interact with Ansible.
- **No package decisions.** Anything that depends on "what the stack wants
  to build" is stack intent and lives in `stack.yaml`, not the profile.

### What ClusterInspector probes

The probes correspond directly to keys in the profile schema. For each
probe, the inspector emits a result, a confidence (`probed` / `inferred` /
`unknown`), and the underlying evidence (the command run, the file read).

Probes are split between **system-wide** (run once per system, typically
on the login node) and **per-node-type** (run once per node class, then
merged into the per-class entries of `profile.node_types`).

| Scope | Probe | Profile keys | Source |
|---|---|---|---|
| System | System identity | `system.name`, `system.family` | `/etc/os-release`, `uname`, `hostname` |
| System | OS and glibc | `os.name`, `os.major`, `os.minor`, `os.glibc` | `/etc/os-release`, `ldd --version` |
| System | Fabric | `fabric.*` | `ibstat`, `fi_info`, `ucx_info -d`, `/sys/class/infiniband`, module enumeration |
| System | Module system | `modules_system.tool`, `modules_system.version` | which `lmod`/`modulecmd`, `module --version` |
| System | Cray PE | `vendor_cray.*` | `module avail`, `/opt/cray/pe/*` enumeration |
| System | Other compilers | `compilers_external[*]` | module enumeration, `/opt/*/bin/*` probing |
| System | MPI implementations | `mpi[*]` | module enumeration, `mpicc -show` decode, vendor-stack identification |
| System | Filesystem candidates | `filesystem.*` | `mount`, `stat -f`, lock test on shared install-tree path |
| Per node type | CPU targets | `node_types[<n>].cpu.detected`, `cpu.preferred`, `cpu.alternates` | `archspec cpu`, `/proc/cpuinfo` on the node class |
| Per node type | GPU | `node_types[<n>].gpu.*` (or `null`) | `nvidia-smi`, `rocm-smi`, `lspci` on the node class; vendor table lookup |
| Per node type | Build-stage candidates | `node_types[<n>].build_stage[*]` | writable-path scan with quick I/O probe on the node class |
| Per node type | Role classification | `node_types[<n>].role` | observed plus operator hint (login vs compute vs both) |
| Derived | Capabilities | `capabilities.lanes_capable` | post-merge derivation from the system + per-node facts |

### Multi-node probing and merge

A login node alone cannot probe a compute node's CPU target or GPU
presence — it has to ask the compute node itself. ClusterInspector
handles this in two phases: a per-node probe that runs on each node class
and emits a single-node fragment, and a merge step that consolidates
fragments plus a system-wide probe into one `profile.yaml`.

```bash
# Phase 1 — per-node probe, on the login node itself
cluster-inspector probe-node \
    --node-type login --role build_host \
    --output probes/login.yaml

# Phase 1 — per-node probe, on each compute node class (one srun each)
srun -N1 -n1 --partition=cpu_compute \
    cluster-inspector probe-node \
        --node-type cpu_compute --role runtime \
        --output probes/cpu_compute.yaml

srun -N1 -n1 --partition=gpu --constraint=mi250x \
    cluster-inspector probe-node \
        --node-type gpu_compute_mi250x --role runtime \
        --output probes/gpu_compute_mi250x.yaml

srun -N1 -n1 --partition=gpu --constraint=mi300a \
    cluster-inspector probe-node \
        --node-type gpu_compute_mi300a --role runtime \
        --output probes/gpu_compute_mi300a.yaml

# Phase 2 — merge: system-wide probe + per-node fragments → one profile.yaml
cluster-inspector merge \
    --system example-cray \
    --system-probe-on-this-host \
    --node probes/login.yaml \
    --node probes/cpu_compute.yaml \
    --node probes/gpu_compute_mi250x.yaml \
    --node probes/gpu_compute_mi300a.yaml \
    --output systems/example-cray/profile.yaml
```

Phase-1 fragments are small (one `node_types[*]` entry plus a handful of
verification fields each). Phase 2 runs on the login node, performs the
system-wide probe directly, attaches the per-node fragments under
`node_types:`, and derives `capabilities.lanes_capable` from the union.
The merge step is deterministic — given the same fragments, it produces
the same output — so it is safe to re-run.

There is an all-in-one convenience for the common case where the operator
already has scheduler access from the login node:

```bash
# All-in-one: log in, name the node types, let the inspector submit srun jobs.
cluster-inspector profile \
    --system example-cray \
    --node-type login=this:role=build_host \
    --node-type cpu_compute=srun:partition=cpu_compute:role=runtime \
    --node-type gpu_compute_mi250x=srun:partition=gpu,constraint=mi250x:role=runtime \
    --node-type gpu_compute_mi300a=srun:partition=gpu,constraint=mi300a:role=runtime \
    --output systems/example-cray/profile.yaml
```

The `this:` keyword runs the per-node probe in the current shell (for
classes the login is itself an instance of), and `srun:...` submits a
short scheduler job (one node, a few seconds) for each compute class.
The same syntax with `pbsdsh:...` covers PBS systems.

**Manual override path.** Operators who want full control can also write
the per-node fragments by hand — they are small files — and call only
`cluster-inspector merge`. This is the fallback path when the scheduler
is not reachable from the login node or when a node class is being
brought online manually.

### Module Enumeration: Auto-Discovery Plus Hints

Most platform externals on the systems this stack targets are exposed as
**system modules** — Cray PE compilers and cray-mpich, site compilers
like AOCC, GPU toolkits like ROCm and CUDA, fabric userspace like
libfabric. Detecting them is what ClusterInspector spends most of its
work on, and the question of how it iterates through modules is worth
making explicit. The committed model is **hybrid**: auto-discovery first,
operator hints to narrow and override, then load-and-probe verification.

Three phases, in order:

**Phase 1 — auto-discovery (heuristic enumeration).** The inspector
enumerates available modules via `module avail` and `MODULEPATH`
directory walks, then classifies each candidate by name pattern:

| Category | Patterns matched |
|---|---|
| Compilers | `gcc`, `gcc-native`, `cce`, `aocc`, `intel`, `oneapi`, `nvhpc`, `rocmcc`, `PrgEnv-*` |
| MPI | `cray-mpich`, `openmpi`, `mpich`, `mvapich`, `intel-mpi`, `mpt` |
| GPU toolkits | `rocm`, `cudatoolkit`, `cuda`, `nvhpc`, `cuda-compat` |
| Fabric userspace | `libfabric`, `ucx` |

Each match is recorded as a *candidate*, not a confirmed fact. Auto-
discovery alone is brittle — a site might have `gcc-data/9.3`,
`gcc-toolset/12`, and `gcc-native/13`, only one of which is a real
compiler choice; or five CUDA versions where the stack should only see
one. The next phase narrows the candidate list.

**Phase 2 — operator hints (the committed override mechanism).** The
operator writes a hints file alongside the profile to make the
inspector's behavior reproducible across runs. The hints file lives in
the stack repo at `systems/<system>/inspector-hints.yaml` and is the
operator's persistent policy about how to interpret modules on this
system:

```yaml
# systems/example-cray/inspector-hints.yaml
schema_version: 1

compilers:
  include:                           # only these modules count as compiler externals
    - cce/17.0.1
    - gcc-native/13
    - rocmcc/6.0.0
  exclude_patterns:                  # never treat these as compilers, even if name matches
    - "gcc-data/*"
    - "gcc-toolset/*"

mpi:
  include:
    - cray-mpich/8.1.29

gpu_toolkits:
  include:
    - rocm/6.0.0
    - cudatoolkit/12.4

fabric_userspace:
  include:
    - libfabric/1.20
    - ucx/1.15

extras:                              # declare an external the heuristic missed
  compilers:
    - module: mycompiler/1.0
      name:    mycompiler
      version: "1.0"
      prefix:  /opt/site/mycompiler/1.0
      languages: [c, c++, fortran]
```

Rules the inspector applies:

| Hint | Effect |
|---|---|
| `<category>.include` is a non-empty list | Only those modules are kept in that category; other auto-discovered matches are dropped. |
| `<category>.include` is empty or absent | All auto-discovered matches in that category are kept. |
| `<category>.exclude_patterns` | Anything matching is dropped, even if it would have passed `include`. |
| `extras.<category>[*]` | Added to the category even if auto-discovery missed it. |

**Phase 3 — load-and-probe verification.** For every surviving candidate
the inspector spawns a clean shell, runs `module load <candidate>`, and
probes what the module actually exposes:

| Probe | What it confirms |
|---|---|
| `which cc gcc g++ gfortran craycc` | Compiler driver paths under the resolved prefix |
| `mpicc -show`, `mpicxx -show` | MPI compiler wrappers point at a real underlying compiler |
| `$ROCM_PATH`, `$CUDA_HOME`, `$NVHPC_ROOT` | GPU toolkit prefix variables set by the module |
| `ls $prefix/lib`, `ls $prefix/bin` | The resolved prefix actually contains a build artifact |
| `ldconfig -p \| grep libfabric` | Fabric userspace libraries are loadable |

The shell exits after each candidate; nothing persists. Each result is
recorded with `probed: true` and the evidence (commands run, what they
returned). A candidate that fails verification gets `probed: false` and
a reason — the operator decides whether to fix or exclude via the hints
file.

**Why a hints file instead of CLI flags.** CLI flags work for one-off
probes (`cluster-inspector profile --compiler-modules ...`), but the
hints file is the **committed override policy** and lives in source
control next to the profile. Without it, every operator re-discovers the
same site-specific quirks on their first run; with it, the answer is
already in the repo and reproducible. The hints file converges quickly
and only changes when the system genuinely changes (PE upgrade, new GPU
partition added). It is *additive* to the profile, not a substitute —
the profile is what the stack consumes; the hints file is how the
inspector decides what to put in the profile.

**Iterative discovery in practice.** Bringing up a new system follows a
short loop:

1. Run `cluster-inspector profile --system <name> ...` with default
   heuristics (no hints file yet).
2. Review the emitted profile. Anything wrong? Anything missing? A
   `gcc-toolset/12` that got classified as a compiler but isn't a real
   choice for the stack? A `cudatoolkit/12.4` that should be the only
   CUDA included?
3. Write `systems/<name>/inspector-hints.yaml` to fix those cases.
4. Re-run. Iterate until the profile is clean.
5. Commit profile + hints together; both are durable artifacts.

The iteration converges in two or three rounds on a typical system. PE
upgrades and driver bumps later require a hints touch-up only if the
upgrade introduces a new module-naming convention; otherwise re-running
the inspector against the same hints just refreshes the versions in
place.

**Multi-node-type interaction.** Hints apply per-category but not
per-node-type — the compiler set, MPI set, and GPU toolkit set are
system-wide facts, declared once in the hints file and reused across
every node-type probe. Node-type-specific facts (CPU target, GPU arch,
build-stage paths) come from the per-node probe and are not affected by
the hints file.

### Operational rules

- The inspector is **read-only** on the system. It runs commands that read
  state; it never modifies state. (One exception: it may write a tiny test
  file in candidate build-stage paths to confirm `writable: true`, and it
  removes that file before reporting.)
- The inspector emits **one artifact**: `profile.yaml` on stdout (or a
  named file). No log files, no caches, no side outputs.
- The inspector **does not need to be the only profile producer.** A
  hand-written profile that follows the schema is just as valid. The
  inspector exists to reduce error and to capture facts a human would have
  to look up by hand (Cray PE flavor prefixes, GPU driver-to-toolkit ceiling
  tables).

### Helper-style example invocations

```bash
# Probe the current host and print the profile to stdout
cluster-inspector profile

# Probe and write to a file, with a system identifier override
cluster-inspector profile --system example-cray > systems/example-cray/profile.yaml

# Print only the GPU block (useful for partial updates)
cluster-inspector profile --section gpu

# Validate an existing profile against the current host
cluster-inspector verify systems/example-cray/profile.yaml
```

### ClusterInspector pseudo-code

The inspector has three entry points: `probe_system` (system-wide facts;
runs on the login node), `probe_node` (one node-type's facts; runs on
each node class), and `merge_profile` (consolidate fragments into
`profile.yaml`).

```text
function probe_system(args) -> system_fragment:
    s = empty_system_fragment(schema_version=1)
    s.system           = detect_system_identity(args.system_name_override)
    s.os               = read_os_release() + read_glibc_version()
    s.modules_system   = detect_module_tool()           # tcl | lmod
    s.fabric           = probe_fabric()
    s.vendor_cray      = probe_cray_pe()                # may be None
    s.filesystem       = probe_install_tree_candidates()

    # Module enumeration follows the three-phase model:
    #   1) auto-discover candidates via `module avail` + MODULEPATH walk
    #   2) apply operator hints (include / exclude / extras) per category
    #   3) load-and-probe verify each surviving candidate in a clean shell
    hints = load_hints(args.hints_file)                 # may be empty

    candidates_compilers = enumerate_module_candidates(category="compilers")
    candidates_mpi       = enumerate_module_candidates(category="mpi")
    candidates_gpu_tk    = enumerate_module_candidates(category="gpu_toolkits")
    candidates_fabric_us = enumerate_module_candidates(category="fabric_userspace")

    s.compilers_external = verify_modules(
        apply_hints(candidates_compilers, hints.compilers))
    s.mpi                = verify_modules(
        apply_hints(candidates_mpi, hints.mpi))
    s.gpu_toolkit_modules = verify_modules(
        apply_hints(candidates_gpu_tk, hints.gpu_toolkits))
    s.fabric.userspace   = verify_modules(
        apply_hints(candidates_fabric_us, hints.fabric_userspace))

    return s


function enumerate_module_candidates(category) -> list:
    # Run `module avail` and walk MODULEPATH directories, then classify each
    # entry by name pattern against the category's pattern list. Returns a
    # list of {module_name, classified_category, pattern_matched} records.
    # No module loads yet — this is name-pattern matching only.
    candidates = []
    for module_name in enumerate_all_modules():
        for pattern in patterns_for(category):
            if module_name.matches(pattern):
                candidates.append({
                    module: module_name,
                    category: category,
                    pattern: pattern,
                })
                break
    return candidates


function apply_hints(candidates, hints) -> list:
    out = candidates
    if hints.include is not empty:
        out = [c for c in out if c.module in hints.include]
    for pat in hints.exclude_patterns:
        out = [c for c in out if not c.module.matches(pat)]
    for extra in hints.extras:
        out.append({module: extra.module, category: extra.category,
                    declared: extra})
    return out


function verify_modules(candidates) -> list:
    # For each candidate, spawn a clean shell, load the module, probe what
    # it exposes (compiler driver paths, MPI wrapper, toolkit prefix vars),
    # unload, exit. Record probed: true plus evidence, or probed: false
    # plus the reason.
    results = []
    for c in candidates:
        evidence = run_in_clean_shell(steps=[
            "module load " + c.module,
            probe_commands_for(c.category),   # which, mpicc -show, etc.
        ])
        if evidence.ok:
            results.append({
                name:      derived_name(c, evidence),
                version:   derived_version(c, evidence),
                prefix:    derived_prefix(c, evidence),
                modules:   [c.module] + extra_modules_needed(c, evidence),
                probed:    true,
                evidence:  evidence.summary,
            })
        else:
            results.append({
                module:   c.module,
                probed:   false,
                reason:   evidence.failure_reason,
            })
    return results


function probe_node(args) -> node_fragment:
    n = empty_node_fragment()
    n.name        = args.node_type_name              # e.g. "gpu_compute_mi250x"
    n.role        = args.role                        # build_host | runtime | both
    n.description = args.description or ""
    n.cpu         = run("archspec cpu") + detect_alternates()
    n.gpu         = probe_gpu()                      # None if no GPU
    n.build_stage = probe_writable_executable_fast_paths()
    return n


function merge_profile(system_frag, node_frags, output_path) -> profile:
    p = empty_profile(schema_version=1)
    p ← system_frag                                  # all system-wide keys

    p.node_types = {}
    for nf in node_frags:
        require(nf.name not in p.node_types, "duplicate node type: " + nf.name)
        p.node_types[nf.name] = {
            role:        nf.role,
            description: nf.description,
            cpu:         nf.cpu,
            gpu:         nf.gpu,
            build_stage: reject_noexec(nf.build_stage),
        }

    p.capabilities = derive_capabilities(p)
    require(at_least_one_role_in(p.node_types, "build_host", "both"),
            "no node type can serve as a build host")

    write_yaml(output_path, p)
    return p


function inspect_system_all_in_one(args) -> profile:
    # Convenience: probe system + node types in one invocation when the
    # operator has scheduler access from the current shell.
    system_frag = probe_system(args)
    node_frags  = []
    for spec in args.node_type_specs:
        # spec.name, spec.runner ("this" | "srun" | "pbsdsh"), spec.opts, spec.role
        if spec.runner == "this":
            node_frags.append(probe_node(spec))
        else:
            node_frags.append(submit_remote_probe(spec))   # short scheduler job
    return merge_profile(system_frag, node_frags, args.output_path)


function probe_fabric() -> fabric_block:
    drivers  = enumerate_kernel_drivers()
            # rdma-core, CXI, OFED — names, versions, prefixes
    userlibs = detect_userspace(["ucx", "libfabric"])
            # version + prefix per library; empty list if absent
    mpis = []
    for m in enumerate_mpi_modules_and_prefixes():
        mpis.append({
            name:       m.name,
            version:    m.version,
            prefix:     m.prefix,
            provenance: classify(m),    # site | system | vendor_bundled
        })
    return {
        type:       classify_fabric_type(),     # slingshot | infiniband | ...
        generation: detect_generation(),
        drivers:    drivers,
        userspace:  userlibs,
        mpis:       mpis,
    }


function probe_gpu() -> gpu_block_or_None:
    if has_nvidia_smi():
        driver  = read_nvidia_driver_version()
        ceiling = lookup_cuda_max_for_driver(driver)   # vendor table
        arch    = "sm_" + detect_compute_capability()  # profile label: sm_80, sm_90, ...
        return {
            vendor: "nvidia",
            driver_version:    driver,
            toolkit_ceiling:   ceiling,
            arch_target:       arch,
            cuda_compat_available: has_cuda_compat(),
        }
    if has_rocm_smi() or has_amdgpu():
        driver  = read_amdgpu_kfd_version()
        ceiling = lookup_rocm_max_for_driver(driver)
        arch    = detect_gfx_target()                  # gfx90a, gfx942
        return {
            vendor: "amd",
            driver_version:  driver,
            toolkit_ceiling: ceiling,
            arch_target:     arch,
        }
    return None


function probe_writable_fast_paths() -> list:
    candidates = ["/local_scratch/$user/spack-stage",
                  "/scratch/$user/spack-stage",
                  "$tempdir/$user/spack-stage",
                  "/shared/stack/spack/stage/$user"]
    out = []
    for raw in candidates:
        path = expand(raw)
        if not path.exists or not is_writable(path):
            continue
        t = quick_write_throughput(path)        # small fio or dd
        out.append({
            path:             raw,
            visibility:       classify_visibility(path),    # login-only | compute-only | shared
            writable:         true,
            free_gb:          free_capacity_gb(path),
            free_inodes:      free_inodes(path),
            mount_opts:       mount_options(path),
            throughput_class: classify_throughput(t),
        })
    return out


# Invariants the implementation must honor:
#   - Read-only on every host the inspector touches. Any temp file used
#     for a writability test is removed before the function returns.
#   - probe_system, probe_node, and merge_profile are all idempotent:
#     given the same inputs they produce the same outputs.
#   - merge_profile is the only writer of the final profile.yaml.
#     probe_system and probe_node emit fragments; merging is a separate
#     deterministic step.
#   - The inspector is optional; anyone may write profile.yaml (or any
#     fragment) by hand against the schema.
#   - The inspector does not call Spack and does not render anything.
#   - Per-node probes are short, side-effect-free scheduler jobs (no
#     compilation, no module manipulation, no allocation beyond a few
#     seconds). They never modify shared state on the compute node.
#   - Vendor-table lookups (driver-to-toolkit ceilings) are part of the
#     inspector; the rest of the stack does not need that table.
```

## Ansible — Specification

Ansible is the orchestration layer. Like ClusterInspector and the render
step, it is optional: a human with `rsync`, `srun`, and `spack` can do
everything Ansible does. The value of Ansible is consistency across
deploys, not capability.

### Goals

- Move a rendered workspace onto target hosts.
- Drive Spack through the build sequence with the host-specific arguments
  (parallelism, scheduler submission, mirror credentials).
- Verify, push to the build cache, and gate promotion.
- Apply the same playbook to Cray and generic Linux HPC systems by varying per-host
  data, not by branching playbook logic.

### Goals it does not have

- Owning package decisions. Specs come from the rendered workspace, which
  came from the stack and package set. Ansible never edits specs.
- Interpreting profile facts deeply. The profile has been consumed already
  by the render step; Ansible just passes the workspace through.
- Rendering many Spack files directly with Ansible templates. The render
  step is the rendering authority. Ansible may call the render helper, but
  it does not duplicate its work.
- Replacing Spack. Spack is the build engine; Ansible drives it, does not
  substitute for it.

### Role decomposition

| Role | Responsibility |
|---|---|
| `preflight` | Validate profile, stack, and release inputs exist; check Spack version on the host; refuse to proceed on schema mismatch. |
| `render-if-needed` | If a pre-rendered workspace was supplied, skip. Otherwise call the render helper locally. |
| `provision` | Create shared directories (`install_tree`, `source_cache`, executable `build_stage`, `buildcache`, release dirs); set permissions; place the rendered workspace at the release dir before any Spack command runs. |
| `concretize-fetch` | On the build host, run `spack -e <env> concretize` and `fetch -D` per rendered lane; save `spack.lock`. |
| `install-core` | Build each compiler's Core lane first and push successful Core specs to the foundation cache. |
| `install-lanes` | After Core is cached, submit per-lane scheduler jobs (Slurm/PBS) for non-core `spack install -j N`. Track outcomes; collect logs. |
| `publish` | Regenerate views, generate stack lane/package modules, push each lane to its configured buildcache destination, and write the final manifest. |
| `verify-user` | From clean shells, load the candidate release's module root, run package compile smoke tests, and run scheduler-backed MPI/GPU runtime tests. |
| `promote` | Gated atomic symlink swap (temporary symlink plus rename). Refuses to delete a previous release tree if `current` points at it. |

### Operational rules

- Ansible **operates on an already-rendered workspace.** The render step
  may run on Ansible's controller (the `render-if-needed` role) or have
  been run earlier by hand; either way, by the time `provision` runs, the
  workspace exists on disk.
- Ansible **never edits scopes or specs in flight.** If a fix is needed,
  the fix is in the source repo, re-render, re-deploy.
- **Promotion is gated.** No green build automatically swaps `current`.
  The default `release.promotion: gated_manual` requires a person to set
  `promote=true` on the play; `auto` is available but discouraged for
  production.
- **Per-system data is in inventory, not in playbooks.** The lane matrix,
  runtime module lists, scheduler args, and mirror URLs live in
  `inventory/host_vars/<host>.yml` (or equivalent group vars). One
  playbook serves every system; the playbook reads its data.

### Ansible deploy pseudo-code

Pseudocode for the deploy playbook. Variable shape uses Ansible conventions
but the *logic* is portable.

```text
play: deploy-stack
hosts: build_targets
vars_files:
  - "inventory/host_vars/{{ inventory_hostname }}.yml"
vars:
  profile:     "{{ source_repo }}/systems/{{ system }}/profile.yaml"
  stack:       "{{ source_repo }}/stacks/{{ stack_name }}/stack.yaml"
  release:     "{{ release_tag }}"
  workspace:   "/shared/stack/work/{{ system }}/{{ stack_name }}/{{ release }}"
  release_dir: "/shared/stack/releases/{{ release }}/{{ system }}/{{ stack_name }}"

roles:

  - role: preflight
    tasks:
      - assert: profile and stack both exist
      - assert: schema_validate(profile, "profile.v1")
      - assert: schema_validate(stack,   "stack.v1")
      - assert: spack_version_on_host >= stack.minimum_spack
      - assert: build_target hosts are reachable
      - assert: selected install_tree has reliable locks, or serialize installs
      - assert: selected build_stage paths are writable and not mounted noexec

  - role: render-if-needed
    tasks:
      - if workspace_already_supplied:
          set_fact: skip_render = true
        else:
          run_locally: stack-render
            --profile     {{ profile }}
            --stack       {{ stack }}
            --release     {{ release }}
            --output-root {{ workspace_root }}
          # → workspace written to {{ workspace_root }}/{{ system }}/{{ stack_name }}/{{ release }}/
      - read_yaml:
          path: "{{ workspace }}/release-manifest.yaml"
          register: release_manifest
      - set_fact:
          rendered_lanes: "{{ release_manifest.lanes }}"
          core_lanes: "{{ release_manifest.lanes | selectattr('kind', 'equalto', 'core') }}"
          non_core_lanes: "{{ release_manifest.lanes | rejectattr('kind', 'equalto', 'core') }}"

  - role: provision
    tasks:
      - ensure_dirs: [install_tree, source_cache, executable_build_stage, buildcache, release_dir]
      - rsync:
          src:  "{{ workspace }}/"
          dest: "{{ release_dir }}/"
      - set_permissions: as policy

  - role: concretize-fetch
    # Pick any node_type with role build_host or both. By convention this
    # is the login node, but the playbook does not hard-code that — it
    # selects from profile.node_types where role in [build_host, both].
    delegate_to: "{{ select_build_host(profile.node_types) }}"
    tasks:
      - for lane in rendered_lanes:
          run: spack -e {{ release_dir }}/environments/{{ lane.compiler }}/{{ lane.lane }} concretize
          run: spack -e {{ release_dir }}/environments/{{ lane.compiler }}/{{ lane.lane }} fetch -D
          collect_artifact: spack.lock
              → "{{ release_dir }}/{{ lane.compiler }}/{{ lane.lane }}/spack.lock"

  - role: install-core
    tasks:
      - for lane in core_lanes:
          # The lane's runtime_node_type drives scheduler placement: install
          # runs on a node of the matching class so the build sees the same
          # CPU target (and GPU, when relevant) the lane was concretized for.
          set_fact:
            target_class: "{{ lane.runtime_node_type }}"
            scheduler_args: "{{ scheduler_args_for(target_class) }}"
          submit_scheduler:
            env: "{{ release_dir }}/environments/{{ lane.compiler }}/{{ lane.lane }}"
            args: "{{ scheduler_args }}"     # e.g. --partition=gpu --constraint=mi250x
            command: |
              spack -e <env> install -j {{ build_jobs }} \
                                     --show-log-on-error
          collect: logs, exit code
      - wait_all
      - for lane in core_lanes:
          assert: install exit code == 0
          run: spack -e <env> buildcache push --update-index --unsigned {{ lane.buildcache_push_url }}

  - role: install-lanes
    tasks:
      - for lane in non_core_lanes:
          set_fact:
            target_class: "{{ lane.runtime_node_type }}"
            scheduler_args: "{{ scheduler_args_for(target_class) }}"
          submit_scheduler:
            env: "{{ release_dir }}/environments/{{ lane.compiler }}/{{ lane.lane }}"
            args: "{{ scheduler_args }}"
            command: |
              spack -e <env> install -j {{ build_jobs }} \
                                     --show-log-on-error
          collect: logs, exit code
      - wait_all
      - for lane in non_core_lanes:
          assert: install exit code == 0

  - role: publish
    tasks:
      - for lane in rendered_lanes:
          run: spack -e <env> verify libraries
          run: spack -e <env> verify manifest -a
          run: spack -e <env> env view regenerate
          run: spack -e <env> module tcl refresh -y
          run: generate front-door modules from the stack-owned template for {{ lane.name }}
          run: spack -e <env> buildcache push --update-index --unsigned {{ lane.buildcache_push_url }}
      - write_yaml:
          dest: "{{ release_dir }}/release-manifest.yaml"
          content: "{{ build_manifest(stack, profile, release, lane_results) }}"

  - role: verify-user
    tasks:
      - for lane in rendered_lanes:
          run_clean_shell: |
            module use {{ release_dir }}/modules
            module load {{ stack.modules.module_root }}/{{ lane.compiler }}/{{ lane.lane }}
            {{ site_smoke_test_command }} {{ lane.name }}
      - assert: all user and runtime checks passed

  - role: promote
    gate: promote == true                  # required, default false
    tasks:
      - assert: stack.release.promotion in [gated_manual, auto]
      - if release.promotion == "gated_manual" and not approved:
          fail: "release {{ release }} requires manual approval before promotion"
      - atomic_symlink_swap:
          target: "/shared/stack/releases/{{ release }}"
          link:   "/shared/stack/current"
      - cleanup: per stack.release.retain_previous policy
          (refuse to delete a previous release tree if `current` points at it)


# Invariants the implementation must honor:
#   - The playbook operates on a rendered workspace. If workspace is
#     supplied, render-if-needed is a no-op.
#   - The playbook never edits package decisions, scope contents, or
#     templates. Fixes go to the source repo and re-render.
#   - Promotion is gated by default; never automatic without
#     stack.yaml.release.promotion: auto AND an explicit promote=true.
#   - Per-system data (lane matrix, runtime modules, scheduler args, mirror
#     URLs) lives in inventory/host_vars, not in the playbook.
#   - Failures of one lane do not silently skip subsequent lanes; the
#     play either fails-fast or collects-and-reports per stack policy.
```

### Inventory shape

The lane matrix, runtime module lists, and scheduler arguments are per-host
data. The playbook above reads `inventory/host_vars/<host>.yml`; a Cray
host's file looks like:

```yaml
# inventory/host_vars/cray01.yml
system:        example-cray
stack_name:    cse
build_jobs:    64
modules_tool:  tcl

buildcache_mirror:        file:///shared/stack/buildcache/science/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/example-cray
foundation_mirror:        file:///shared/stack/buildcache/foundation/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/x86_64_v3
site_smoke_test_command:  /shared/stack/tests/smoke.sh

scheduler:
  kind:   slurm
  default_args: "--time=02:00:00"

# Per-node-type scheduler arguments. The playbook looks up the lane's
# runtime_node_type and joins these args with scheduler.default_args.
node_type_scheduler_args:
  login:                   ""                                  # build-host only; no scheduler
  cpu_compute:             "--partition=build"
  gpu_compute_mi250x:      "--partition=gpu --constraint=mi250x --gpus=1"
  gpu_compute_mi300a:      "--partition=gpu --constraint=mi300a --gpus=1"
```

A Linux host's file has the same shape with different values; the playbook
does not branch on the system family. `node_type_scheduler_args` makes the
mapping from a lane's `runtime_node_type` to the right scheduler placement
explicit in per-system data, so the playbook itself never needs to know
about partition names or constraint syntax.

## Config Scope Model

The same config-scope grammar should work for Cray and generic Linux HPC systems.
The difference is which scopes a lane includes.

Common scope examples:

```text
configs/common/config.yaml
configs/common/concretizer.yaml
configs/common/modules.yaml
configs/common/env_vars.yaml
```

System family scope examples:

```text
configs/os/rhel8/packages.yaml
configs/os/sles15/packages.yaml
configs/vendor/cray/packages.yaml
configs/vendor/linux/packages.yaml
```

MPI scope examples:

```text
configs/mpi/cray-mpich/packages.yaml
configs/mpi/site-mpi/packages.yaml
configs/mpi/spack-openmpi/packages.yaml
```

GPU scope examples:

```text
configs/gpu/amd-rocm/packages.yaml
configs/gpu/nvidia-cuda/packages.yaml
```

Lane environments choose scopes with `include::`; they do not duplicate all
platform policy inline.

## Lane Model

Recommended lane kinds:

| Lane kind | Purpose |
|---|---|
| Core | Shared build tools and user tools that are not compiler/MPI/GPU sensitive. |
| Serial | User-facing serial libraries and tools. |
| MPI | User-facing MPI-enabled libraries and MPI provider policy. |
| GPU | GPU-enabled packages and performance portability layers. |

Core packages can include build tools and stable tools such as CMake, Ninja,
pkgconf, Git, and selected Python tools. Packages that are ABI-sensitive,
compiler-sensitive, MPI-linked, or GPU-runtime-sensitive should stay in lanes.

### Per-Compiler Core, Not Shared Core

**The committed model is per-compiler Core.** Every compiler on a system owns its
own Core environment, view, and module root: `gcc/core`, `cce/core`,
`rocmcc/core`, and so on. The CCE Core builds CMake, Ninja, pkgconf, Git, and
the foundation stable-ABI libraries under CCE; the GCC Core builds the same
packages under GCC; there is no cross-compiler Core sharing. Each compiler's
Core view sits at its own path:

```text
/shared/stack/releases/<release>/<system>/<stack>/views/gcc/core/
/shared/stack/releases/<release>/<system>/<stack>/views/cce/core/
/shared/stack/releases/<release>/<system>/<stack>/views/rocmcc/core/
```

A single shared Core view across compilers does not work under per-lane
builds, because each compiler's CMake projects to `cmake/3.30.5` and the two
projections collide in the same view root. Two compilers' `cmake/3.30.5` are
real disjoint binaries, but the projected view has only one path for that
name and version. Per-compiler view roots remove the collision without any
projection cleverness: the CCE and GCC view roots are different paths, so
both can hold `cmake/3.30.5` honestly.

This is the explicit, intentional cost of the per-compiler Core model: build
tools and stable-ABI libraries are duplicated across compilers within a system.
The benefits make the duplication worthwhile:

- **Clean view model.** Each compiler's view is a self-contained universe
  matching the lane's compiler; no cross-compiler ABI guessing.
- **No `include_concrete` plumbing.** A shared-Core scheme requires deriving
  a Core spec set, pinning it to a single common compiler, locking it once,
  and wiring every lane to consume that locked Core via `include_concrete` or
  `reuse: from:`. Per-compiler Core needs none of that — every lane is a normal
  environment that does its own concretize-and-build.
- **No ABI guessing.** "Is GCC-built zlib safe for a CCE consumer?" is a
  legitimate-but-fragile call for plain-C stable-ABI libraries and not safe
  at all for ABI-coupled ones. Per-compiler Core does not need to make that call;
  every library is built under the compiler that consumes it.
- **Independent rebuilds.** A change to one compiler's Core rebuilds only
  that compiler's Core; the other compilers' lanes are unaffected.

The cost — disk space and some compile time for duplicated build tools and
plain-C libs — is acceptable on the systems this stack targets, where storage
is not a binding constraint and the duplicated packages are cheap to compile.

**Future-condensation note.** If overlap measurement later shows the
duplication is large and expensive (a substantial set of costly shared
libraries genuinely rebuilt per compiler, or measured cache size pressure), an
explicit shared-Core extraction can be layered on later without restructuring
the rest of the stack: derive a shared subset, pin it to a single common GCC,
publish to a foundation cache lane, and wire each lane via `reuse: true` plus
a foundation-cache read source. This is an evidence-gated optimization, not a
fallback the per-compiler Core model depends on. Until the evidence appears,
the per-compiler default is the model, and the rest of the design does not
assume shared-Core extraction has happened.

The procedure to measure the overlap cheaply: concretize each lane
(`spack -e <lane> concretize`, then `spack -e <lane> spec --json`), intersect
the concretized DAGs by package name, and look at the size and expense of the
intersection. If it is dozens of expensive shared packages, extraction may pay
off; if it is a handful of build tools, the ceremony does not earn back its
cost.

Examples that usually belong outside Core:

- MPI implementations.
- HDF5 built with MPI.
- NetCDF linked to MPI HDF5.
- Kokkos and RAJA with GPU backends.
- Fortran module producers.
- C++ template-heavy libraries tied to compiler ABI.

### Layer Composition And Dual-Build Packages

Compilers and Core compose with lanes; serial and MPI lanes conflict with each
other.

| Layer | Membership test | Conflicts with siblings? |
|---|---|---|
| Compiler | The package is a compiler or compiler runtime view. | Precondition, selected first. |
| Core | The package has no meaningful serial/MPI/GPU split. | No, always composable. |
| Serial lane | Serial build of a dual-variant package. | Yes, with MPI/GPU siblings. |
| MPI lane | MPI build of a dual-variant package. | Yes, with serial/GPU siblings. |
| GPU lane | GPU-runtime-specific build. | Yes, with incompatible GPU/runtime siblings. |

A package belongs in both serial and MPI lanes if it has both serial and MPI
build variants. HDF5 and NetCDF-C are the canonical examples. Do not rename the
packages globally to `hdf5-serial` or `hdf5-mpi`. The loaded lane decides which
build is visible.

Example user intent:

```bash
module load CSE/GCC/serial
module load hdf5        # serial HDF5

module swap CSE/GCC/serial CSE/GCC/mpi-openmpi
module load hdf5        # MPI HDF5
```

This is why lane conflicts matter. RPATHs help runtime linking, but they do not
prevent compile-time contamination through `PATH`, `CPATH`, `LIBRARY_PATH`,
`PKG_CONFIG_PATH`, or `CMAKE_PREFIX_PATH`.

### Why GPU Is A Separate Lane Kind, Not An MPI Sub-Type

A natural question: most GPU codes also use MPI, so why is "GPU" a
separate lane kind from "MPI" instead of an add-on to it? The answer
starts with restating what a GPU lane actually contains, because the
mental model that confuses things is "user loads MPI, then adds GPU on
top," and that is not how the design works.

**The GPU lane *is* an MPI lane.** A GPU lane carries the same MPI-aware
science libraries as a plain MPI lane on the same system — `hdf5+mpi`,
`netcdf-c+mpi`, `parallel-netcdf`, and the rest — built against the same
cray-mpich (GNU flavor by default). On top of that, the GPU lane includes
the GPU-arch-pinned packages — `kokkos+rocm amdgpu_target=gfx90a`,
`raja+rocm amdgpu_target=gfx90a`, GPU-aware MPI applications — that the
plain MPI lane does not have. So a GPU lane is a *superset* of the
matching MPI lane, scoped to one GPU class.

A user on an MI250X partition loads `CSE/GCC/gpu-craympich-gfx90a` and
gets MPI HDF5, MPI NetCDF, *and* GPU-pinned Kokkos in one lane. They do
not load the plain MPI lane and then add a GPU layer on top — there is no
GPU layer to add. The lanes conflict; the user picks one.

**Four reasons GPU does not collapse into a single MPI-or-GPU lane kind.**

1. **Runtime targeting differs.** A plain MPI lane runs on a CPU compute
   partition; a GPU lane runs on a specific GPU partition. Their
   `runtime_node_type` values differ, their `runtime_modules` differ (the
   GPU lane loads `rocm/<v>` or `cudatoolkit/<v>` at runtime; the MPI lane
   does not), and Ansible places each lane's install job on the matching
   node class. Folding them into one lane breaks this targeting.

2. **GPU architecture is a build-time pin, not a runtime switch.**
   `kokkos+rocm amdgpu_target=gfx90a` is a different artifact from
   `kokkos+rocm amdgpu_target=gfx942`. Two GPU partitions on the same
   system require two lanes, one per arch, because the spec hashes
   differ. Trying to put both arches in one lane would either collapse
   them (losing one of the builds) or force per-spec projections like
   `kokkos/{version}-{amdgpu_target}` — a richer projection just to
   compensate for not separating the lanes. The design's projection
   policy keeps `{name}/{version}` as the default by separating the
   lanes.

3. **Cleaner front-door composition.** One module per partition target is
   easy to explain: "I'm on MI250X → load `CSE/GCC/gpu-craympich-gfx90a`."
   Folding GPU into MPI as a sub-load would require *either* a layered
   load (`module load gpu-gfx90a` after the MPI lane — the extra layer
   nobody wants), or a wider MPI lane front-door that conditionally
   exposes GPU paths based on an additional variable. Both reintroduce
   the cross-contamination problem the lane-conflict mechanism exists to
   prevent.

4. **Lane-conflict semantics stay simple.** "Pick exactly one lane" is
   the entire user mental model. A GPU sub-add on top of an MPI lane
   would force a new rule: "the MPI sub-add and the GPU sub-add conflict
   with each other but compose with the MPI base." That is the kind of
   rule that breaks when a user thinks about it for the first time.
   One-lane-at-a-time is robust.

**On user-visible layer count.** The concern that "more lanes means
more for users to learn" is reasonable to raise; the actual user surface
under this design is:

```bash
module load CSE/GCC/gpu-craympich-gfx90a   # one front-door module load
module load hdf5                            # MPI HDF5, from the GPU lane's view
module load kokkos                          # GPU-pinned, from the GPU lane's view
```

Two module loads. The same shape as a plain MPI user. The lane *choice*
is wider on a system with multiple GPU classes (six lanes instead of
four), but the *user actions* are unchanged. The front-door module is
the single point that hides the per-lane runtime module fan-out
(`PrgEnv-gnu` + `rocm/<v>` + `cray-mpich/<v>` for a GPU lane vs. just
`PrgEnv-gnu` + `cray-mpich/<v>` for an MPI lane).

**Edge case: a GPU-only code with no MPI use.** A code like NCCL- or
RCCL-only deep-learning workloads that never call MPI still loads the
GPU lane; the MPI sciences in the lane are simply unloaded by the user
or not referenced. The cost is some unused symlinks in the lane's view,
which is cheap. The alternative — a GPU-only-no-MPI lane kind — would
double the lane matrix to keep "GPU-no-MPI" separate from "GPU-with-MPI"
for the rare case where the difference matters, which is not worth it.
GPU lanes include MPI sciences uniformly; a code that does not need them
ignores them.

**Edge case: pure CPU MPI on a node that happens to have GPUs.** If a
user runs a CPU-only MPI code on a GPU partition (sometimes happens — the
GPU node is just the available allocation), they load the GPU lane's
front-door module and the MPI sciences work. They are paying a runtime
ROCm-module load they do not use, which is harmless. The alternative —
making them load the plain CPU MPI lane on a GPU partition — would
require them to know the partition does not match the lane, and the
design avoids forcing that knowledge.

### Lane Matrix Sizing

Realistic lane counts per system. The matrix grows linearly with
compilers and node classes, not multiplicatively, because Core is
per-compiler-not-per-class and serial/MPI scale with compilers (not GPU
classes):

| System shape | Compilers exposed | Lane kinds | Total lanes | Examples |
|---|---|---|---|---|
| Homogeneous CPU (one node class, GCC only) | 1 (GCC) | core, serial, mpi | **3** | `gcc/core`, `gcc/serial`, `gcc/mpi-openmpi` |
| Homogeneous CPU, two compilers | 2 (GCC, AOCC) | core, serial, mpi | **6** | the above × 2 compilers |
| Cray, one CPU partition, no GPU | 2 (GCC, CCE) | core, serial, mpi | **6** | `gcc/core`, `gcc/serial`, `gcc/mpi-craympich`, `cce/core`, `cce/serial`, `cce/mpi-craympich` |
| Cray, one CPU partition + one GPU class (MI250X) | 2 (GCC, CCE) | core, serial, mpi, gpu | **7** | the 6 above plus `gcc/gpu-craympich-gfx90a` |
| Cray, one CPU + two GPU classes (MI250X + MI300A) | 2 (GCC, CCE) | core, serial, mpi, gpu | **8** | the 7 above plus `gcc/gpu-craympich-gfx942` |
| Cray, full Option A NVHPC exception lane added | 2 + 1 (NVHPC narrow) | core, serial, mpi, gpu | **9** | the 8 above plus one `gpu` exception lane: `nvhpc/gpu-craympich-sm90` |

The growth shape:

- **+1 lane per new compiler exposed** (a compiler adds core + serial +
  mpi, but serial and mpi may be skipped on compilers used only for
  GPU work).
- **+1 lane per new GPU class** (one GPU lane per arch).
- **+0 lanes for adding a CPU partition** — a second CPU partition with
  the same architecture reuses the existing MPI lane (the lane is keyed
  to compiler + lane-kind + GPU class, not to CPU partition identity).

Eight lanes on a fully-populated Cray is the realistic ceiling for the
first deployments. Six is the typical case (Cray with one CPU partition
and one GPU class). The user sees these as a flat menu of front-door
module names; they pick the one that matches their partition and
compiler preference.

### Deriving Core Membership

User-facing package exposure is a stack decision. Dependency placement can often
be derived from the concretized DAG:

- Build-only dependencies are Core candidates because they produce no linked ABI.
- Plain-C stable-ABI link dependencies may be Core candidates.
- MPI-linked packages stay in the MPI lane.
- Fortran module producers stay in the compiler/MPI lane.
- C++ ABI-sensitive libraries stay in the compiler-specific lane.
- GPU-backend packages stay in the GPU lane.

This keeps Core from becoming a catch-all. Core means "safe to compose across
lanes on this system," not "small utility package."

### Lane Composition At Module Load

The lane model only delivers its promise when it lands cleanly at module
load. A user's session is the place where Core composes with a lane and the
lane conflict prevents cross-contamination. Walking through the load steps
explicitly is the simplest way to see what the design guarantees.

**The user makes two real choices.** First, which lane (compiler + serial
or MPI or GPU). Second, which package and version within that lane.
Everything else is handled by the front-door module.

```bash
# Step 1: pick a lane.
$ module load CSE/GCC/mpi-openmpi

# What that single module load did:
#  - Prepended /shared/stack/.../modules/gcc/core to MODULEPATH
#    (composes the GCC Core with the lane)
#  - Prepended /shared/stack/.../modules/gcc/mpi-openmpi to MODULEPATH
#    (exposes the MPI-lane package modules)
#  - Declared conflict with every other CSE/<compiler>/<lane>
#  - Set STACK_RELEASE, STACK_NAME=CSE, STACK_COMPILER=GCC,
#    STACK_MODE=mpi, STACK_MPI=openmpi, STACK_VIEW=/shared/stack/.../views/gcc/mpi-openmpi
#  - On a site-external lane, also: module load aocc/4.2.0; module load openmpi/4.1.6
#    (skipped here because this is a Spack-built OpenMPI lane)

# Step 2: pick packages.
$ module load cmake          # from gcc/core (composes, no conflict)
$ module load hdf5           # from gcc/mpi-openmpi (the MPI build)
$ module load netcdf-c       # from gcc/mpi-openmpi (the MPI build)
```

**Which `hdf5` resolves?** The MPI-lane `hdf5`, because
`gcc/mpi-openmpi/modules/` was prepended onto MODULEPATH ahead of any other
hdf5 the user might have on PATH. The serial-lane `hdf5` is not on
MODULEPATH at all, because no serial lane was loaded. The Cray PE's HDF5
module (if any) is shadowed by the higher-precedence stack lane. The
package name stays a clean `hdf5` — no `hdf5-mpi-openmpi` suffix — because
the lane already disambiguated.

**Switching lanes.** A user moves between serial and MPI builds by swapping
the front-door module:

```bash
$ module swap CSE/GCC/mpi-openmpi CSE/GCC/serial
$ module load hdf5           # now the serial build, same name
```

The conflict mechanism ensures this is *swap, not load-on-top*: the
front-door module declares `conflict CSE/GCC/mpi-openmpi`, so loading the
serial lane forces the MPI lane to unload first. The user cannot
accidentally end up with both lanes active and pick whichever `hdf5` the
PATH order happens to favor.

**Which layers conflict, which compose.** This is the table the rest of the
design relies on:

| Layer | Membership test | Conflicts with siblings? | Composes with? |
|---|---|---|---|
| Compiler precondition | The user picks one compiler. | Implicit — selected first via the front-door. | Anything in that compiler's column. |
| `<compiler>/core` view | The package has no meaningful serial/MPI/GPU split (CMake, Ninja, pkgconf, Git, foundation libs). | No — Core composes with every lane in the same compiler column. | Any lane in the same compiler. |
| Serial lane | The serial build of a dual-variant package, or a serial-only science library. | Yes — with the MPI and GPU lanes in the same compiler column. | The compiler's Core. |
| MPI lane | The MPI build of a dual-variant package, or an MPI-linked science library. | Yes — with serial and GPU lanes in the same compiler column. | The compiler's Core. |
| GPU lane | A GPU-runtime-specific build (Kokkos/RAJA with backend, GPU-aware MPI sciences). | Yes — with serial and (non-GPU) MPI lanes in the same compiler column; with GPU lanes for incompatible toolkits. | The compiler's Core. |

**Why the lane conflict blocks nothing real.** The serial-versus-MPI
conflict can look restrictive, but it does not block any legitimate
combination. A build is either wholly serial or wholly MPI: the moment any
component is parallel, the application is an MPI program, and every parallel
library it links comes from the MPI lane. There is no real workflow that
wants one serial parallel-library mixed with one parallel parallel-library —
the moment two parallel libraries enter the picture, they must share an MPI,
which puts the whole build in the MPI lane. The apparent counterexample —
an MPI application using a serial FFT independently on each rank — is still
wholly an MPI application; the FFT being single-threaded is an internal
detail, and the build still belongs to the MPI lane.

The conflict therefore only ever prevents *mistakes* (cross-variant header
contamination, pkg-config and CMake search-path bleed, accidentally linking
a serial library into an MPI binary), not any combination anyone actually
wants.

**Dual-build packages.** A package that has both a serial and an MPI build
variant (HDF5, NetCDF-C, NetCDF-Fortran, PnetCDF, Dakota) lives in *both*
lane views under the same clean name. The user has loaded exactly one lane,
so within their session there is exactly one `hdf5`; it is whichever build
the lane exposes. The lane has become the prefix, expressed as a MODULEPATH
position rather than a decoration on the package name:

```bash
$ module load CSE/GCC/serial && module load hdf5   # → serial hdf5
$ module swap CSE/GCC/serial CSE/GCC/mpi-openmpi && module load hdf5   # → MPI hdf5
```

This is the rule that replaces the version-suffix trick. You do not decide
globally whether HDF5 is "serial" or "MPI." You build both, and the loaded
lane chooses.

## Compiler, MPI, GPU, And Fabric Modeling

Compiler and MPI modeling should be explicit.

Cray example:

- CCE is an external compiler from the Cray PE.
- Cray MPICH is an external MPI provider.
- Cray MPICH may have compiler-flavored prefixes.
- Module lists for Cray PE externals are part of the external contract.

Generic Linux example:

- GCC may be Spack-built or system-provided depending on stack policy.
- AOCC, NVHPC, oneAPI, or site compilers may be externals.
- Site MPI may be external by stable prefix.
- OpenMPI or MPICH may be Spack-built when that is stack policy.

GPU modeling rules:

- The kernel driver is a platform fact and runtime ceiling, not a Spack package to build.
- The toolkit/runtime version must be compatible with that ceiling.
- GPU architecture target is a build axis. Profile fields use arch labels such as `sm_90`, `gfx90a`, or `gfx942`; rendered Spack specs use variants such as `cuda_arch=90` or `amdgpu_target=gfx90a`.
- GPU lanes should carry GPU-sensitive packages, not Core.

Fabric modeling rules:

- Kernel and driver layers are platform facts.
- Userspace libfabric or UCX may be system external or Spack-built depending on policy.
- MPI provider policy must be compatible with fabric reality.

### What Toolchains Are For

A toolchain is a named compiler/MPI constraint set attached to a spec with a
toolchain name. Its strongest use is enforcing compiler-matched MPI pairings.

Cray MPICH example:

```text
cray-mpich@8.1.29 %cce     -> /opt/cray/pe/mpich/8.1.29/ofi/cray/17.0
cray-mpich@8.1.29 %gcc     -> /opt/cray/pe/mpich/8.1.29/ofi/gnu/13.3
cray-mpich@8.1.29 %rocmcc  -> /opt/cray/pe/mpich/8.1.29/ofi/amd/6.0
```

The `cce_craympich` toolchain means CCE plus the `%cce` Cray MPICH external.
The `gcc_craympich` toolchain means GCC plus the `%gcc` Cray MPICH external.
That is ABI correctness, not just documentation.

Toolchains are less critical in a single-compiler lane with exactly one MPI
provider, where the isolated `packages.yaml` already forces the choice. They are
still useful as a readable catalog of valid compiler/MPI pairings.

Toolchains do not control variants. Fabric choices, CUDA/ROCm variants, Lustre
support, and provider build options belong in `spack.yaml` specs and
`packages.yaml` requirements.

### Toolchain Propagation And Foundation Reuse

Compiler propagation should be scoped to lane roots and science subtrees, not to
the whole foundation. The committed model is **per-compiler Core** (see
§Per-Compiler Core, Not Shared Core): each compiler builds its own Core, including its own
build tools (CMake, Ninja) and its own foundation stable-ABI libraries (zlib,
xz, zstd). Binary reuse happens *within* a compiler — a CCE science lane
reuses CCE's Core build of CMake — not *across* compilers. The hash carries
the compiler, so cross-compiler reuse is not what the foundation cache is
doing.

The desired behavior is:

```text
Each compiler's Core builds at the baseline (x86_64_v3) target.
Each science lane reuses its own compiler's Core from the foundation cache.
Compiler/MPI-sensitive packages build in the lane.
```

The foundation cache is keyed by OS/glibc, not by compiler. Both compilers'
Core builds land in the same cache lane (for example,
`foundation/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/x86_64_v3/`);
the per-spec hash decides which binary a given lane pulls. See
§Build-Cache Keying for why the cache directory must not be per-compiler-
keyed even though binaries inside it are compiler-specific.

Validate the reuse path with `spack spec -l` and `spack.lock` inspection
before relying on it for production.

### Externalization Mechanics

The `buildable` setting has three practical postures:

| Posture | Meaning |
|---|---|
| `buildable: false` | Force external or fail. Use for vendor MPI, compilers, and system-coupled pieces. |
| `buildable: true` with no requirement | External is available, but Spack may build a newer/different one. |
| `buildable: true` with `require` or `prefer` | Steer toward the external while allowing a build when necessary. |

Force-external candidates:

- Vendor compilers.
- Cray MPICH and other fabric-coupled vendor MPI.
- Kernel/fabric-coupled userspace pieces when the system owns them.
- System Python used to run Spack itself, distinct from user-facing Python.

Stack-built candidates:

- User-facing science libraries.
- Build tools when the system versions are too old.
- User-facing Python/Miniforge.

### Externals Carry No `%compiler` Attachment

An external is a pre-existing system binary. The stack did not build it, so
no compiler choice applies to it, and attaching `%compiler` to an external
spec is wrong — meaningless at best, a concretization obstacle at worst.
System OpenSSL was distro-built (typically with GCC), but the stack does not
get to claim that as its constraint. The same rule applies to every external
in the system: compilers, fabric userspace libraries, system Python, and any
other registered prefix.

The **named exception** is Cray PE per-flavor cray-mpich, because HPE
genuinely ships compiler-matched builds at distinct prefixes (`ofi/cray/`,
`ofi/gnu/`, `ofi/amd/`). There the `%compiler` is real — it names which of
several real binaries the spec refers to — and the per-flavor `prefix:` makes
the distinction observable on disk. Outside the Cray PE cray-mpich case, do
not attach `%compiler` to external specs. A site MPI built once and reused
across consumer compilers also has no `%compiler` tag; only when the site
genuinely built per-compiler variants at separate prefixes does the
annotation apply.

This rule was a real practice mistake on earlier stacks and is recorded so
it does not recur.

### `modules:` External Semantics

A `packages.yaml` external can be declared with `prefix:` (a static path the
stack asserts), with `modules:` (a list of environment modules), or with
both. Behavior differs in a way that matters:

- **`prefix:` only.** The stack asserts the external lives at the named
  path. Spack uses the prefix to find headers, libraries, and executables.
  Nothing about the live module state of the build host affects the
  external; the prefix is the contract.

- **`modules:` present.** Spack `module load`s every entry in the list at
  build time and inherits the environment those modules set — PATH,
  LD_LIBRARY_PATH, CPATH, PKG_CONFIG_PATH, and any other variables the
  modulefile manipulates. Spack is not parsing the modulefile for a prefix;
  it is running the module and taking the resulting environment, then
  injecting that environment into the build of every dependent. This is the
  module-path dependence the design warns about: the external's environment
  is established dynamically by module state rather than fixed on disk.

The rule:

- **Prefer `prefix:`** wherever a stable on-disk location exists. It is
  deterministic, does not drag in whatever else the modulefile touches, and
  does not couple build correctness to the live module state of the host.
- **Use `modules:`** only for the sanctioned vendor case (Cray PE compilers
  and cray-mpich), where the modulefile establishes runtime environment a
  bare prefix cannot — Fortran module paths for `crayftn`, libsci runtime
  locations, PE configuration variables. These modules are stable,
  vendor-managed, and explicitly registered, which is the controlled case.
- **Site MPI on a non-vendor system** stays `prefix:`-only unless there is
  a concrete reason the prefix cannot reconstruct the build environment.
  Adding `modules:` to a site MPI external creates the same module-path
  fragility the Cray PE case justifies and the rest of the stack avoids.

Which variables Spack captures from a loaded module — and how it reconciles
them against RPATH — is version-sensitive across the 1.x line. Confirm on
the deployed Spack with a `spack spec` dry-run on a module-based external
before committing to it.

### OpenSSL And Curl

OpenSSL and curl should generally be system externals because the site
administrators patch them. If the stack builds its own OpenSSL or curl, the
stack owns the CVE rebuild treadmill for those packages and their consumers.

Rules:

- Declare the true system version (run `spack external find openssl curl` on
  the target to get it).
- **Do not attach a compiler to system externals** — `openssl %gcc` on an
  external is wrong. See the *Externals Carry No `%compiler` Attachment* rule
  above; OpenSSL and curl are pure system externals and have no compiler tag.
- Do not falsely relabel a patched distro OpenSSL as a newer API version. A
  distro that backports security fixes into 1.1.1 keeps the version string
  1.1.1; renaming it to 3.x lies to the solver and breaks at build or runtime.
- Do not set `buildable: false` naively. If no matching external is found,
  `buildable: false` hard-fails concretization. Leave OpenSSL/curl
  `buildable: true` and steer with `require:`/`prefer` toward the external —
  a consumer requiring a genuinely newer API can then build it as a
  documented, per-consumer exception.
- If a stack-built OpenSSL is needed for that exception, link it against the
  system CA certificate bundle so cert updates cost nothing.

**Vendored library copies inside tools are acceptable.** Some tools bundle
private copies of libraries (CMake's internal curl, Python's bundled pieces).
A vendored copy is private — nothing else links against it — so the blast
radius of a security update is the rebuild of that one tool, and for a build
tool that vendored copy only matters at the tool's own runtime, not in
anything it builds. The rule: vendored-inside-a-tool is fine; a *library
users link against* must never be a vendored copy — users link the real
system external or the stack-built library, never something bundled inside
another package.

### Fabric Two-Layer Model

Fabric support has two layers:

- Kernel/hardware driver layer: owned by the OS/vendor, never built by Spack.
- Userspace communication layer: libfabric, UCX, PMIx, MPI provider pieces.

The userspace layer may be external or built, but it must match the real driver
and fabric underneath it. A Spack-built UCX or libfabric that cannot talk to the
site driver stack is not useful.

### GPU Driver Ceiling

The GPU kernel driver is an unbuildable floor. Spack can build or use CUDA/ROCm
toolkits, but the installed driver determines the maximum compatible runtime.

Profile facts should report:

- GPU vendor.
- GPU architecture target.
- Kernel driver version.
- Toolkit/runtime ceiling.
- Whether CUDA compatibility packages are present when relevant.

Stack policy decides whether to build or expose a GPU lane and which toolkit
version sits at or below that ceiling.

### Host-Compiler Policy For GPU Lanes

When the lane targets a GPU, **device-code performance is controlled by
the GPU toolchain** (nvcc/CUDA on NVIDIA, hipcc/ROCm on AMD), not by the
host compiler. The host compiler only compiles the CPU-side scaffolding,
which is rarely the bottleneck in a GPU-bound application. That observation
sets the host-compiler default for GPU lanes:

- **GNU + CUDA on NVIDIA systems** is the committed default.
- **GNU + ROCm on AMD systems** is the committed default (including on
  Cray, where GNU + ROCm works well in practice).

The vendor host compilers (NVHPC, ROCmCC, AOCC) are not the GPU-lane
default. They appear as **narrow exception lanes** for codes that
specifically need them:

| Vendor host compiler | When the exception applies | Why it is narrow |
|---|---|---|
| **NVHPC** | OpenACC code, CUDA Fortran, `-stdpar` GPU offload, codes written against the NVIDIA HPC SDK | A whole-stack trial of NVHPC on generic Linux went poorly; many general-stack packages do not build cleanly under it. NVHPC is the right tool for the codes it is the right tool for, and not the right tool for building the stack. |
| **ROCmCC** | AMD-vendor codes that specifically need amdclang/amdflang features | Same caveat: not validated as a general stack compiler in the design. |
| **AOCC** | Genuinely CPU-bound host code on Zen where measured improvement vs. GCC justifies the lane | GPU-bound applications get nearly no benefit from AOCC on the host side; it is justified only when CPU performance is the bottleneck. |

The committed default keeps the matrix small: GPU lanes are GNU-hosted by
default, and vendor host compilers appear only where a specific code's
programming model or CPU profile demands them.

### Cray PE + GPU: How To Express The Lane

On a Cray PE system with GPUs, there are three valid ways to assemble the
compiler + GPU toolkit + cray-mpich environment. Each is a real choice in
the PE, not a quirk of this design. State them once so the lane definition
is unambiguous about which one is in use.

**Option A: PrgEnv-`<gpu-vendor>` all-in-one.**

```bash
module load PrgEnv-amd          # AMD GPU
# - host compiler: amdclang / amdflang (ROCmCC)
# - GPU toolkit:    ROCm (HIP, ROCBLAS, ...)
# - cray-mpich:     ofi/amd flavor (compiler-matched)

module load PrgEnv-nvidia       # NVIDIA GPU (or PrgEnv-nvhpc on some PE releases)
# - host compiler: nvc / nvfortran (NVHPC)
# - GPU toolkit:    CUDA + NVHPC SDK
# - cray-mpich:     ofi/nvidia flavor
```

One module load gives the whole vendor-blessed environment. The trade-off
is that the host compiler is forced to the vendor's compiler (ROCmCC or
NVHPC), which the design's host-compiler policy explicitly *does not*
default to.

**Option B: PrgEnv-gnu + GPU toolkit module (the committed default).**

```bash
module load PrgEnv-gnu          # GNU host (gcc/g++/gfortran) + cray-mpich ofi/gnu flavor
module load rocm/6.0.0          # GPU toolkit only, no host-compiler override
# (or `cudatoolkit/12.4`, `nvhpc/24.5`, etc. for NVIDIA — depends on the PE release)
```

Two module loads give: GNU host compiler, the GPU toolkit's headers and
libraries, and the GNU-matched cray-mpich flavor. The host compiler is
GCC (matching the host-compiler policy); the GPU toolkit provides HIP,
nvcc, the device libraries, and the GPU runtime. This is the
**recommended way** to assemble Cray PE + GPU lanes.

**Option C: PrgEnv-cray + GPU toolkit module.**

```bash
module load PrgEnv-cray         # CCE host + cray-mpich ofi/cray flavor
module load rocm/6.0.0          # or cudatoolkit/...
```

Valid; rare in practice. Use only when a specific code requires CCE on
the host side (Cray-specific OpenMP offload work, Fortran codes that
depend on CCE-specific features) and the GPU build still needs the
toolkit module separately.

**The committed choice: Option B.** GPU lanes on Cray use GNU + GPU
toolkit module. This follows from the host-compiler policy: GNU is the
default host for GPU work, and on Cray the GNU host comes from
`PrgEnv-gnu`. Option A appears only as the **NVHPC exception lane** (when
a code needs NVHPC's compiler and SDK as a whole), and Option C appears
only as the **CCE-host GPU lane** (when CCE-specific host features are
required). Both exceptions are narrow lanes with a documented user need;
neither is a default.

**How this shows up in the profile and the rendered lane.**

The profile declares every PE module that exists so the render step can
emit any of the three options. The `gcc` and `rocmcc`/`nvhpc` externals
each declare their own PrgEnv + version modules, and the GPU toolkit
appears either bundled inside the vendor PrgEnv or as a separately loadable
module (or both, depending on the PE release):

```yaml
# profile.yaml excerpt — declare every PE compiler external the system exposes
vendor_cray:
  pe_version: "8.1.29"
  cce:
    version: "17.0.1"
    prefix: /opt/cray/pe/cce/17.0.1
    modules: [PrgEnv-cray, cce/17.0.1]
  gcc:
    version: "13.3.0"
    prefix: /opt/cray/pe/gcc-native/13
    modules: [PrgEnv-gnu, gcc-native/13]
  rocmcc:                                      # for the NVHPC-style "all-in-one" exception lane
    version: "6.0.0"
    prefix: /opt/rocm-6.0.0
    modules: [PrgEnv-amd, rocm/6.0.0]
  cray_mpich:
    version: "8.1.29"
    flavors:
      cce:    { prefix: /opt/cray/pe/mpich/8.1.29/ofi/cray/17.0,  modules: [cray-mpich/8.1.29] }
      gcc:    { prefix: /opt/cray/pe/mpich/8.1.29/ofi/gnu/13.3,   modules: [cray-mpich/8.1.29] }
      rocmcc: { prefix: /opt/cray/pe/mpich/8.1.29/ofi/amd/6.0,    modules: [cray-mpich/8.1.29] }

gpu_toolkit_modules:                           # standalone toolkit modules (Option B path)
  rocm:
    version: "6.0.0"
    module: rocm/6.0.0
    prefix: /opt/rocm-6.0.0
  cudatoolkit:                                 # on NVIDIA systems
    version: "12.4"
    module: cudatoolkit/12.4
    prefix: /opt/cray/pe/cudatoolkit/12.4
  nvhpc:                                       # NVHPC as a toolkit (no PrgEnv switch); rare
    version: "24.5"
    module: nvhpc/24.5
    prefix: /opt/nvidia/hpc_sdk/24.5
```

The rendered GPU lane under the committed Option B path then looks like:

```yaml
# environments/gcc/gpu-craympich-gfx90a/spack.yaml
spack:
  include::
    - ../../../configs/common
    - ../../../configs/gpu/amd-rocm
    - ../../../configs/mpi/cray-mpich
    - ../../../configs/target/zen3
    - ../../../configs/vendor/cray
    - ../../../configs/os/rhel8
  specs:
    - kokkos+rocm amdgpu_target=gfx90a %gcc_craympich
    - raja+rocm amdgpu_target=gfx90a %gcc_craympich
    - hdf5+mpi+fortran %gcc_craympich
  view: { ... clean projection ... }
```

— compiler is `%gcc_craympich` (Option B's GNU host), not `%rocmcc_craympich`
(which would be Option A). The ROCm toolkit comes from `configs/gpu/amd-rocm`
(the externals declared there for `hip`, `hsa-rocr-dev`, etc.), and the lane's
front-door module loads `PrgEnv-gnu` + `rocm/<version>` + `cray-mpich/<version>`
at runtime:

```tcl
# Front-door module for the gfx90a lane under Option B
if { ![is-loaded PrgEnv-gnu] }    { module load PrgEnv-gnu }
if { ![is-loaded gcc-native/13] } { module load gcc-native/13 }
if { ![is-loaded rocm/6.0.0] }    { module load rocm/6.0.0 }
if { ![is-loaded cray-mpich/8.1.29] } { module load cray-mpich/8.1.29 }
```

The exception-lane equivalents would substitute `PrgEnv-amd` + `rocm/...`
(Option A — used only for an NVHPC- or ROCmCC-specific code) or
`PrgEnv-cray` + `rocm/...` (Option C — used only for a CCE-host GPU code).
The lane name, the spec compiler, the `runtime_node_type`, and the
front-door module loads all move together — the render step keeps them
consistent because they all come from the same lane entry in `stack.yaml`.

**NVIDIA on Cray: same shape, different modules.** Where the PE exposes
NVIDIA support (`PrgEnv-nvidia`/`PrgEnv-nvhpc` on releases that ship it,
`cudatoolkit` as a separately loadable module), the same three-option
choice applies and the same default (Option B: GNU + CUDA toolkit module)
holds. The NVHPC exception lane uses `PrgEnv-nvidia` directly because the
code wants NVHPC's compiler driver, not just its libraries.

| Option | Committed use | Lane compiler | Lane front-door modules |
|---|---|---|---|
| A — PrgEnv-vendor all-in-one | Narrow exception lanes (NVHPC for OpenACC/CUDA Fortran; ROCmCC for AMD-vendor codes) | `%rocmcc_craympich` / `%nvhpc_craympich` | PrgEnv-amd or PrgEnv-nvidia + cray-mpich |
| B — PrgEnv-gnu + GPU toolkit module | **Default GPU lane** | `%gcc_craympich` | PrgEnv-gnu + GPU toolkit module + cray-mpich |
| C — PrgEnv-cray + GPU toolkit module | Narrow lane for CCE-host GPU codes | `%cce_craympich` | PrgEnv-cray + GPU toolkit module + cray-mpich |

On Cray PE specifically, the "GNU + GPU toolkit" pattern is realized by
**PrgEnv-gnu + standalone toolkit module** (Option B), not by PrgEnv-amd or
PrgEnv-nvidia. The exception lanes are named, scoped, and renderable, but never
the default.

## Compiler Bootstrap And Build Order

Compilers are dependency providers for language virtuals in modern Spack, but a
compiler still needs an already-working compiler beneath it. There is always a
bootstrap floor: OS compiler, vendor compiler, site module, or prebuilt compiler
from a build cache.

Recommended staged order:

```text
1. Register or use a bottom compiler supplied by OS/vendor/site/cache.
2. Build the common stack GCC if the stack provides one.
3. Push that compiler to the foundation build cache.
4. Build Core/foundation at the portable baseline target.
5. Push Core/foundation to the foundation cache.
6. Fan out independent serial, MPI, and GPU lanes.
7. Generate views/modules and save lockfiles.
```

The foundation neck is serial. Once Core is available in the cache, lane builds
are independent and can proceed in parallel.

Parallelism tiers:

| Tier | Meaning |
|---|---|
| Foundation neck | Base compiler and Core must be available first. |
| Across lanes | Independent Spack environments can build in parallel. |
| Within a lane | Spack can build multiple independent packages concurrently. |
| Within a package | Make/Ninja/CMake `-j` parallelism. |

Shared filesystem caveat: confirm that the install filesystem supports reliable
file locking before running multiple concurrent writers against the same install
tree. If locking is unreliable, serialize installs or build locally and publish
through a build cache.

### Build Order In Practice

The staged order above is the design intent; turning it into an actual
build campaign has a few rules that are not visible from the order alone.
These are the things that bite on the first run if they are not stated.

**The foundation neck is sequential on purpose.** The bottom compiler
(external or vendor) must be available before any stack-built compiler
(typically a common GCC) can be built. Each stack-built compiler must be
in the foundation cache before that compiler's Core can be built against
it. Each compiler's Core must be in the foundation cache before its
science lanes can reuse it. These checkpoints are sequential per
compiler chain; do not try to parallelize within a chain. The neck is
cheap (a compiler plus a handful of tools); the cost of parallelizing it
is far higher than the time saved. Different compiler chains *can* run
in parallel once their bottom compiler is in place — GCC's Core build
and CCE's Core build are independent and the foundation cache absorbs
both.

**Per-prefix locks are a safety net, not a coordination primitive.** Spack
holds a file lock on each install prefix during the build, so two
processes that try to build the same prefix at the same time will not
corrupt each other — one builds, the other waits. This is what makes
multi-node concurrent installs *safe* on a shared install tree. It is
*not* what makes the fan-out efficient: the lock keeps two processes from
corrupting one prefix; it does not stop them from racing to build the same
spec under two different hashes.

**The cold-cache race trap.** Launching every lane in parallel on a cold
cache is tempting and loses. On a cold cache, nothing is pinning what
compiler builds CMake (for example): each lane is free to concretize CMake
under its own compiler, and you end up building CMake several times in
parallel — once under each compiler — while the per-prefix lock never
engages because the prefixes are different. Build the foundation Core
first as an explicit checkpoint, push it to the cache, and *then* fan out
the lanes. Now every lane finds its CMake in the cache and pulls it
instead of racing to build it.

**Push to cache after every successful step, first run included.** Do not
wait until everything works to start pushing. Caching each successful step
means a later pass pulls finished work from the cache instead of
rebuilding it; the cache *is* the cross-run progress checkpoint. A small
DAG change then rebuilds only the changed spec and its dependents, never
the whole stack. The discipline is: every time a spec finishes,
`buildcache push --update-index --unsigned <mirror> <spec>` it. Ansible's `install`
role can do this automatically per lane.

**First run is for correctness, second run is for speed.** On the very
first pass against a new system or a new lane definition, expect to shake
out concretization and packaging issues. It is often saner to build one
lane fully first — prove the path end to end — then enable the multi-node
fan-out for the remaining lanes once Core is cached and the pattern is
known good. The fan-out is a steady-state speed optimization; the first
run is about correctness, and a serial-ish first pass is fine.

**The fan-out pattern.** Once Core is cached, the lanes run as independent
`srun`/`sbatch` (or `pbsdsh`) invocations, one Spack process per lane,
each writing to disjoint compiler subtrees of the install tree. Because
the subtrees do not overlap, there is no contention to coordinate; the
per-prefix lock only fires on the incidental shared spec, where the
fastest builder wins and the others reuse.

```bash
# After Core is in the foundation cache, fan out lanes one per node.
srun -N1 -n1 -w node01 spack -e environments/cce/mpi-craympich  install -j64 &
srun -N1 -n1 -w node02 spack -e environments/gcc/mpi-craympich  install -j64 &
srun -N1 -n1 -w node03 spack -e environments/gcc/gpu-craympich-gfx90a install -j64 &
wait
```

**Build-stage placement.** The build stage should live on the fastest writable
and executable path the inspector found (typically `/local_scratch/$user/...` on
a compute node, `$TMPDIR/...` inside an allocation). Reject `noexec` candidates:
Spack stages run build scripts, tests, and helper executables. Keep
`source_cache` and `install_tree` on shared storage so every node sees the same
artifact set, but never put `build_stage` on shared storage if a local fast path
exists — Make/Ninja are I/O-heavy and shared filesystems multiply the write
latency through every dependent. If concretize/fetch runs on a login node and
install runs on compute nodes, configure a login-visible fetch stage separately
from the compute-node build stage; do not assume a compute-only path exists on
the login host.

**Spack 1.2 jobserver collapses `-j` and `-p`.** On Spack 1.1 the
concurrency knobs are `-j` (build jobs inside one package) and
`-p`/`--concurrent-packages` (independent packages in one Spack process).
On Spack 1.2, the POSIX jobserver makes `-j` the single knob — `-j64`
means at most 64 build jobs across all packages combined — and `-p` is a
secondary limit on queue depth rather than the primary parallelism
control. When the deployed Spack is 1.2, prefer `-j` alone. When it is
1.1, use both.

**Tuning recommendation, first build:**

| Setup | Suggested per-process command |
|---|---|
| Single 64-core node, Spack 1.1 | `spack install -j48 -p1` |
| Single 64-core node, Spack 1.2 | `spack install -j48` |
| Four 64-core nodes, Spack 1.1, one process per node | `spack install -j32 -p1` |
| Four 64-core nodes, Spack 1.2, one process per node | `spack install -j32` |

Increase gradually only after checking memory pressure, shared filesystem
load, build-stage location, and lock-wait behavior. The initial under-tuned
number is intentional — finish the first build, then optimize.

Walkthrough commands below use `spack install -j N` for readability. On a Spack
1.1 deployment, apply the table above and add `-p1` (or the measured
site-approved value) to avoid accidental oversubscription. On Spack 1.2, prefer
`-j` alone.

## Tcl Module Baseline

Tcl modulefiles should be the portable baseline.

Rationale:

- Tcl modulefiles work with traditional Environment Modules.
- Tcl modulefiles are also readable by Lmod.
- Lua/Lmod-only modulefiles do not work on Tcl-only systems.
- The stack should not require bootstrapping a second module system.

The stack can still support Lmod-specific behavior later, but the minimum common
output should be Tcl.

Front-door lane modules should:

- Set stack identity variables such as release, stack name, compiler, and lane.
- Prepend the lane package module root to `MODULEPATH`.
- Prepend the compiler's Core module root to `MODULEPATH` (per-compiler Core, so
  every lane composes with its own compiler's Core).
- Prepend clean view paths when needed.
- Declare conflicts with other mutually exclusive lane modules.
- Load required platform modules for module-provided externals (see Lane
  Runtime Module Requirements below).

Package modules should:

- Expose package-specific roots from clean views.
- Avoid broad implicit dependency pollution.
- Make provenance visible (see Provenance In Modulefiles below).

Module generation has two explicit outputs: lane front-door modules and package
modules. `spack -e <env> module tcl refresh -y` may generate the package modules
only if `modules.yaml` templates/projections emit the documented roots-only,
view-based, provenance-bearing behavior. Otherwise a stack module generator owns
package modules too. Front-door modules are stack-owned in either case; Spack's
stock module refresh does not know the lane conflict/runtime-module policy by
itself. The publish step must verify both outputs exist before user workflow
verification runs.

### Lane Runtime Module Requirements

A lane's runtime dependency on system modules follows from what kind of
external the lane was built on. The rule is structural, not platform-specific:

- **Module-provided external lane → runtime modules required.** A lane built on
  module-provided externals — the canonical case is Cray PE compilers and
  cray-mpich — carries a runtime dependency on those same modules. Without them
  loaded, user-fresh compiles fail to find the compiler driver and MPI programs
  may fail to find `mpirun` or the vendor runtime libraries. RPATH covers the
  stack's own binaries' linkage but not the user's fresh compile path or a
  module-provided MPI launcher's search.
- **Prefix-only site external → no automatic module load.** A site MPI declared
  only by stable `prefix:` is exposed through the lane's view and package
  modules. The front-door module loads an MPI module only when the consumed
  profile external declares one in `modules:`.
- **Spack-built lane → self-contained.** A lane where the compiler is
  Spack-built and the MPI is Spack-built is fully RPATH'd, the compiler
  driver is on the lane's view PATH, and no system modules need to be
  loaded for users to compile or run. The front-door module declares no
  platform module prereqs.

The front-door module for a site-external lane must either `module load` the
external's declared modules or declare them as prerequisites so a user without
them loaded sees a clear error rather than a missing-library failure. The
runtime module list is per-lane data: the render step takes it from
`profile.yaml` (the `modules:` lists on the externals the lane consumes) and
emits the corresponding `module load` or `prereq` lines into the rendered
front-door module template.

The Cray case is the canonical worked example: a CCE + cray-mpich lane's
front-door module must establish `PrgEnv-cray` and `cray-mpich/<version>` at
load time, because (1) the CCE compiler driver is found through the PrgEnv,
(2) cray-mpich's `mpirun` and shared libraries are exposed through its
module, and (3) the matched PrgEnv guarantees a user fresh compile with the
PE wrappers resolves to the same `ofi/<flavor>` cray-mpich the lane was built
against. The same rule applies to a generic Linux HPC AOCC + site-OpenMPI lane:
the front-door module loads `aocc/4.2.0` if AOCC is module-provided; it loads an
OpenMPI module only if the site-OpenMPI external declares one. A prefix-only site
OpenMPI is exposed through the stack's view/package-module paths instead.

Verify per lane with `ldd` on a built binary whether PE/site runtime
libraries resolve via RPATH (front-door module can be light) or require the
external's `LD_LIBRARY_PATH` (front-door module must load the external's
modules). The answer is per-system and worth recording on the first build
of a new lane.

### Provenance In Modulefiles

The stack uses four provenance classes — `Stack-built`, `Platform-backed`,
`Site-external`, `Spack-built`. The classification is unobservable unless it
surfaces in the user-visible modulefile. Every package module emits a
provenance line:

```tcl
setenv STACK_PACKAGE_PROVENANCE Platform-backed
```

and the `module-whatis` line carries a class suffix:

```tcl
module-whatis "netcdf-c 4.9.2 (Platform-backed via Cray PE)"
```

`module avail` and `module help` then show the class to users without
extra commands, and any user script can switch on
`$STACK_PACKAGE_PROVENANCE` to decide whether a dependency was built by the
stack, supplied by the platform, registered as a site external, or pulled
from an upstream Spack recipe without special stack ownership policy.

The render step derives the class per package from the `packages.yaml`
declaration: `buildable: false` with a Cray PE prefix is Platform-backed;
`buildable: false` with a non-PE prefix is Site-external; everything else
the stack actually built is Stack-built (when the package has an explicit
stack policy or fork) or Spack-built (when it is an unmodified upstream
recipe).

### Front-Door Module Anatomy

Every line in the front-door module is there for a reason. Walking through
the template line by line is the easiest way to see what the lane
guarantees and where each guarantee comes from. This is the rendered Tcl
template for a Cray CCE + cray-mpich lane; site-external Linux lanes have
the same shape with different module names.

```tcl
#%Module1.0
##
## CSE/CCE/mpi-craympich — Cray CCE + cray-mpich MPI lane
##
module-whatis "CSE lane: CCE 17.0.1 + cray-mpich 8.1.29 (Platform-backed MPI)"

# ── Conflicts: prevent loading more than one lane at a time ───────────────
conflict CSE/CCE/serial
conflict CSE/CCE/gpu-craympich-gfx90a
conflict CSE/GCC/serial
conflict CSE/GCC/mpi-craympich
conflict CSE/GCC/gpu-craympich-gfx90a
conflict CSE/GCC/gpu-craympich-gfx942
conflict CSE/ROCmCC/core
conflict CSE/ROCmCC/gpu-craympich-gfx90a

# ── Runtime modules (site-external lane): load the PE the lane was built on
# Lane Runtime Module Requirements section: cray-mpich and CCE are module-
# provided externals, so users of this lane need their modules loaded.
if { ![is-loaded PrgEnv-cray] } {
    module load PrgEnv-cray
}
if { ![is-loaded cce/17.0.1] } {
    module load cce/17.0.1
}
if { ![is-loaded cray-mpich/8.1.29] } {
    module load cray-mpich/8.1.29
}

# ── Stack identity: discoverable env vars ─────────────────────────────────
setenv STACK_RELEASE   "2026.06"
setenv STACK_NAME      "CSE"
setenv STACK_COMPILER  "CCE"
setenv STACK_COMPILER_VERSION "17.0.1"
setenv STACK_MODE      "mpi"
setenv STACK_MPI       "cray-mpich"
setenv STACK_MPI_VERSION "8.1.29"
setenv STACK_VIEW      "/shared/stack/releases/2026.06/example-cray/cse/views/cce/mpi-craympich"

# ── MODULEPATH: compose Core + lane (per-compiler Core, same compiler) ───
prepend-path MODULEPATH "/shared/stack/releases/2026.06/example-cray/cse/modules/cce/core"
prepend-path MODULEPATH "/shared/stack/releases/2026.06/example-cray/cse/modules/cce/mpi-craympich"

# Front-door does NOT prepend view paths to PATH/CPATH/LD_LIBRARY_PATH.
# Each package module does that for its own package only.
```

**Why each block exists.**

- **`module-whatis`.** Visible in `module help` and `module avail`.
  Includes the provenance class for the lane's MPI in parentheses
  (`Platform-backed`, `Site-external`, or `Stack-built`) so the class is
  visible without loading the module.
- **Conflict block.** Lists every other front-door module on the system.
  The render step generates this list from `stack.yaml.lanes` so it stays
  in sync; do not hand-maintain it. Conflicts give the lane-switch
  semantics — `module swap` works, `module load` of a second lane fails
  loudly — without relying on Lmod's `family` directive (which is
  Lmod-only and not available in the Tcl baseline).
- **Runtime module loads.** Present on site-external lanes only. The
  `is-loaded` guard makes the load idempotent for the common case where a
  user already has the PE loaded. On a Spack-built lane (Spack-built
  compiler + Spack-built MPI) this block is empty — the lane is
  self-contained.
- **Stack identity env vars.** A user script or build system can inspect
  `STACK_*` to know the active lane, view path, compiler version, and MPI
  provider without parsing `module list` output. `STACK_VIEW` is
  particularly useful for CMake (`-DCMAKE_PREFIX_PATH=$STACK_VIEW`).
- **MODULEPATH prepends.** Two prepends: the per-compiler Core module
  root, then the lane module root. The Core root goes first so that if a
  package name exists in both Core and the lane, the lane's wins (which is
  the right answer — a science-lane HDF5 should not be shadowed by a Core
  HDF5; the lane-membership rule keeps HDF5 out of Core in the first place,
  but the ordering is defense in depth).
- **No global PATH/CPATH/CMAKE_PREFIX_PATH prepends.** The lane module
  does *not* dump the entire view into the user's environment. Per-package
  modules do that for their own package, on demand. This keeps the active
  shell minimal and avoids the "everything is on PATH" mess that breaks
  user builds.

Lane switching has one additional rule: a front-door `module swap` only changes
the active lane roots. It cannot safely rewrite environment variables from
package modules that are already loaded from the old lane on every Tcl module
implementation. The supported safe switch is either a clean shell/module purge,
or unloading lane package modules before swapping lanes. Verification must test
both the clean-shell path and the documented lane-switch path.

### Per-Package Module Anatomy

A per-package module is much simpler. Every package gets one; the render
step generates them from the lane's projected view.

```tcl
#%Module1.0
##
## hdf5 1.14.5 — built by CSE/CCE/mpi-craympich
##
module-whatis "hdf5 1.14.5 (Stack-built, +mpi+fortran)"

# Provenance: discoverable to user scripts.
setenv STACK_PACKAGE_PROVENANCE "Stack-built"

# Conflict on the unversioned name so only one version is active at a time.
conflict hdf5

# Root of the projected view entry for this package. Generated modules use
# release-tagged paths; only the init/bootstrap module follows `current`.
set root "/shared/stack/releases/2026.06/example-cray/cse/views/cce/mpi-craympich/hdf5/1.14.5"

# Prepend the package's view paths only — not the lane's entire view.
prepend-path PATH                 "$root/bin"
prepend-path CPATH                "$root/include"
prepend-path LD_LIBRARY_PATH      "$root/lib"
prepend-path LD_LIBRARY_PATH      "$root/lib64"
prepend-path LIBRARY_PATH         "$root/lib"
prepend-path LIBRARY_PATH         "$root/lib64"
prepend-path CMAKE_PREFIX_PATH    "$root"
prepend-path PKG_CONFIG_PATH      "$root/lib/pkgconfig"
prepend-path PKG_CONFIG_PATH      "$root/lib64/pkgconfig"
```

**Why per-package, not whole-view.** The user's environment ends up with
exactly the libraries they loaded plus their transitive RPATH closure.
Nothing else. Their `cmake --find-package` sees only what they asked for;
their `pkg-config --list-all` shows only their stack. This is the
discipline that keeps user builds reproducible across release rolls.

**Variants in `module-whatis`.** The variants that produced the build go
in the whatis line so users can see whether they have the `+mpi+fortran`
build or the `~mpi~fortran` one. The render step pulls these from the
spec the view exposes.

**Conflict on unversioned name.** `conflict hdf5` means loading
`hdf5/1.14.4` after `hdf5/1.14.5` swaps; loading both at once fails
loudly. This is exactly the multi-version selection behavior the design
wants.

**No `setenv HDF5_DIR`.** Some sites set per-package environment variables
like `HDF5_DIR`, `NETCDF_ROOT`. The design does not, because CMake-style
package discovery via `CMAKE_PREFIX_PATH` and `PKG_CONFIG_PATH` is the
modern convention and works without per-package env vars. If a specific
user community needs the legacy variables, they can be added as render-step
overrides per package; the default omits them to keep the user shell
clean.

## Views And User-Facing Paths

Users should see stable paths, not raw Spack install prefixes.

Example view roots:

```text
/shared/stack/releases/2026.06/example-cray/cse/views/gcc/core
/shared/stack/releases/2026.06/example-cray/cse/views/gcc/serial
/shared/stack/releases/2026.06/example-cray/cse/views/cce/mpi-craympich
```

Projection examples:

```yaml
view:
  mpi:
    root: /shared/stack/releases/2026.06/example-cray/cse/views/cce/mpi-craympich
    projections:
      all: "{name}/{version}"
    link: roots
    link_type: symlink
```

The stack uses `link: roots` everywhere. Roots-only keeps the view tree to
exactly the user-loadable package set: each `module load` resolves to a clean
`{name}/{version}` symlink, and transitive dependencies reach consumers through
RPATH rather than appearing as clutter in the view namespace. Spack's default is
`link: all` (which would also link every transitive link/run dependency into the
view); the stack does not use that default because it muddies the per-package
module surface and forces non-default projection tricks to disambiguate
transitive collisions.

Use richer projections — `{compiler.name}`, `{^mpi.name}`, `{hash:7}` — only
when a single view must hold otherwise-colliding builds (the same name and
version produced by two different concretizations). Lane separation removes
most such collisions in practice, so the `{name}/{version}` default should
suffice for production lanes; reach for the richer projections only when lane
separation cannot reach the case.

### View Projections In Detail

A view is a symlink tree, and its `projections` setting controls how each
package is named within that tree. This is the mechanism that gives users
the clean paths the design promises — `module load hdf5` resolving to
`/shared/.../views/cce/mpi-craympich/hdf5/1.14.5/` instead of
`/shared/.../spack/opt/linux-rhel8-zen3/cce-17.0.1/hdf5-1.14.5-k7h2qe4f...`.
The hashed prefix still exists underneath; it is never the thing the user
sees.

**The default projection: `{name}/{version}`.** Within a single lane, the
compiler and MPI are fixed, so there is normally one build of each name
and version. `{name}/{version}` is sufficient and is the projection every
production lane uses.

**Projection tokens.** Spack projection strings accept several tokens. The
ones the design uses are:

| Token | Expands to | When to use |
|---|---|---|
| `{name}` | Package name | Always (the default projection). |
| `{version}` | Package version | Always (the default projection). |
| `{compiler.name}` | Compiler name | When a single view holds builds from more than one compiler. |
| `{compiler.version}` | Compiler version | Rare; only when two builds of one package differ only in compiler version. |
| `{^mpi.name}` | MPI provider name | When a single view holds builds against more than one MPI. |
| `{^mpi.version}` | MPI provider version | Rare; per-MPI-version disambiguation. |
| `{hash:7}` | First 7 hex chars of the spec hash | Last-resort disambiguator when nothing else makes the path unique. |

**Per-spec keys.** Projections accept an ordered map of per-spec keys
evaluated before the `all` fallback. This is the mechanism for handling
specific collisions without making every path noisier:

```yaml
projections:
  ^mpi:        "{name}/{version}-{^mpi.name}-{^mpi.version}"    # parallel builds tagged with MPI
  +cuda:       "{name}/{version}-cuda-{cuda_arch}"              # CUDA builds tagged with arch
  +rocm:       "{name}/{version}-rocm-{amdgpu_target}"          # ROCm builds tagged with target
  all:         "{name}/{version}"                               # everything else, clean
```

The first matching key wins. Order from most-specific to least-specific.

**Lane separation removes most of the need.** The design's choice to put
serial, MPI, and GPU lanes in separate views is what keeps the default
projection sufficient in practice. The CCE serial view holds the serial
`hdf5/1.14.5`; the CCE MPI view holds the MPI `hdf5/1.14.5`; they are
different view roots, so they do not collide, and neither needs a richer
projection. Per-compiler Core views remove the cross-compiler collision in
the same way: `gcc/core/cmake/3.30.5` and `cce/core/cmake/3.30.5` are
different view roots and so do not need disambiguation.

**Reach for richer projections only when a single view must genuinely hold
otherwise-colliding builds.** The case this typically arises is a science
lane that exposes multiple builds of the same package and version under
different `cuda_arch` values or different `^mpi` choices. If you find yourself
adding per-spec projection keys, ask first whether the underlying problem
is "this should be two lanes." Often it is.

**`link: roots` is committed.** Every production view sets `link: roots`,
which links only the root specs the lane requested. Transitive
dependencies are reachable through RPATH at runtime and through
CMake/pkg-config search paths exposed by the root packages; they do not
each need a top-level clean path. The Spack default `link: all` would link
every transitive link/run dependency into the view, which both inflates
the namespace and creates collisions that would force richer projections.
The design chooses to keep the view tight and the projections clean.

**The view is generated, not edited.** Treat the view as build output.
Regenerate with `spack -e <env> env view regenerate` after every install
or version change. If a user reports a stale symlink in the view, the
answer is regenerate, not hand-fix.

**View paths under a release.** The full path structure is:

```text
/shared/stack/releases/<release>/<system>/<stack>/views/<compiler>/<lane>/
```

so the same package and version coexist across releases by living under
different release directories. Generated lane and package modules embed
release-tagged absolute paths, not `/shared/stack/current`, so a candidate
release can be verified before promotion and older releases remain loadable
after a later promotion. The `current` symlink belongs only to the init/bootstrap
surface: `module load cse-init` exposes the module root for the currently
promoted release. Users normally enter through `current`; operators and rollback
tests may load release-tagged module roots directly.

## Build Cache Policy

Source cache, source mirror, and build cache are separate tools:

| Term | Meaning | Best use |
|---|---|---|
| Source cache | Spack instance cache populated by `spack fetch -D`. | Login-node prefetch before compute-node build. |
| Source mirror | Curated source repository created with Spack mirror commands. | Restricted or air-gapped source supply. |
| Build cache | Binary cache of installed package prefixes and metadata. | Avoid rebuilding packages inside a compatible lane. |

Recommended fetch/build flow:

```bash
# Login node or internet-capable host
spack -e <env> concretize
spack -e <env> fetch -D

# Compute node or build allocation
spack -e <env> install -j 64
```

Do not re-concretize on the compute node unless the goal is to allow the DAG to
change. Concretize once, fetch against that lockfile, then install from the same
lockfile.

Do not treat the build cache as one universal bucket. Use compatibility lanes.

### Unsigned Buildcache: Why The Default Is Correct

The committed default is `buildcache.signed: false`. This is a deliberate
position based on the trust boundary, not an oversight. The reasoning:

- **The mirror sits inside the team's own trust boundary.** It lives at
  `file:///shared/stack/buildcache/...` on a shared filesystem with
  team-controlled write access. Only Ansible (running on behalf of the
  stack maintainers) writes to it; only the stack's own systems read
  from it.
- **Anyone who can tamper with the mirror has already crossed the trust
  boundary.** Write access to the mirror implies write access to the
  install tree, the modulefiles, and the source repo. Signing within
  the same boundary adds key-management overhead (key creation,
  distribution, rotation, loss recovery) without adding security.
- **Airgap does not change this.** GPG signature verification is
  offline — signed caches work in airgap with the public key shipped
  alongside the cache files. The unsigned default is not a concession
  to airgap; both modes work in airgap.
- **Signing becomes worth it only when the trust boundary changes.**
  Cross-org publishing, vendor-hosted artifact stores, public mirrors,
  or audit-required per-binary provenance are the triggers. None apply
  to the current shape; the Committed Decisions row flags when to
  revisit.

Operational consequence: `spack buildcache push` requires the
`--unsigned` flag when the mirror is configured `signed: false`. Every
push example in this document includes it. If signing is later turned
on (mirror `signed: true`), drop the flag and add the key-distribution
step.

### Build-Cache Keying: OS/glibc And Generation, Not Compiler

ABI correctness for binary reuse is enforced by **Spack's hash**, not by the
cache layout. Every concrete spec encodes the compiler, MPI, target, variants,
dependencies, and OS in a hash; a `%cce`-built consumer concretizes to a spec
whose hash demands a `%cce`-built dependency, and the cache lookup matches
only that hash. A `%gcc`-built binary sitting next to it in the same bucket
has a different hash and is never picked. Mixing compilers in one cache is
hash-safe.

Bucketing decisions are therefore about **reuse reach**, not about safety.
The rule:

- **Key the cache by OS/glibc.** A SLES15 binary will not run on RHEL8;
  the dynamic linker resolves against an incompatible glibc and fails before
  any Spack logic engages. Separate RHEL and SLES caches make the
  incompatibility structural — a RHEL lane only ever reads the RHEL cache.
- **Key the cache by Spack/package-repo generation.** Spack hashes and package
  metadata change across tool upgrades. A generation token keeps old and new
  binary namespaces readable without pretending they are the same cache.
- **Compiler, MPI, target, GPU runtime are directory labels for human
  readability**, not reuse boundaries. They go in the path because
  `science/cray-rhel/cce-mpi-craympich/zen3` is easier for a human to scan
  than a hash, but the hash is what the solver matches against.
- **Within one OS/glibc, register every compatible cache lane as a read
  source.** A CCE MPI lane reads the foundation cache lane, which holds
  both CCE-built and GCC-built Core binaries (each compiler builds its
  own Core under per-compiler Core). The CCE lane pulls the `%cce`-hashed
  CMake; the GCC lane pulls the `%gcc`-hashed CMake. They share the
  cache *lane* but not the *binaries*. The hash decides what gets
  pulled; the bucket placement only affects whether the lane can *see*
  the binary at all.

The wrong-way example is the trap to avoid. If the cache is keyed by
compiler — `cache/gcc/foundation/...`, `cache/cce/foundation/...` — then
each compiler's foundation cache sits in its own silo where the *other*
compilers' lanes cannot read it. That seems fine at first glance because
each compiler reuses its own Core anyway. But it breaks the model in two
ways. First, when a second compiler is added later, its Core builds land
in a *new* per-compiler bucket; existing lanes never gain access to it,
and registering N buckets per lane scales poorly. Second, it implies
"per-compiler reuse" is the rule when actually the reuse rule is
"per-hash reuse" — the bucketing reads as a safety mechanism it is not.
Spack's hash already prevents unsafe picks; the bucketing does not add
safety, it only removes the operational simplicity of one cache lane per
OS.

Recommended axes for the cache directory label (humans), in order:

| Axis | Cache role | Why |
|---|---|---|
| OS / glibc | **Reuse boundary** | Real runtime incompatibility; structural separation. |
| Spack version / package repo | **Reuse boundary** | Hashes change across Spack/package-repo bumps; mixing produces miss-after-miss. |
| External ABI digest | Optional reuse boundary | Use only when one mirror serves same-OS systems with incompatible external compiler/MPI/fabric/GPU-toolkit surfaces. |
| Lane class (foundation / science) | Organizational label | Helps humans see what the cache holds. |
| System name | Organizational label | Distinguishes caches when one mirror serves many systems. |
| Compiler / MPI / target / GPU arch | Organizational label | Readability only; the hash, not the path, decides selection. |

Example lane naming, with the labels read accordingly:

```text
buildcache/foundation/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/x86_64_v3
buildcache/foundation/sles15/glibc-2.31/spack-1.1.1/repo-2026.06/x86_64_v3
buildcache/science/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/example-cray/cce-mpi-craympich/zen3
buildcache/science/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/example-cray/gcc-mpi-craympich/zen3
buildcache/science/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/example-cray/gcc-gpu-craympich/gfx90a
```

The lane on a Cray RHEL8/glibc-2.28 system registers the matching foundation
bucket and every matching science lane under the same OS/glibc and
Spack/package-repo generation, regardless of which compiler appears in the
directory label, so any compatible binary is reachable. If `profile_abi` is
configured, the lane also requires that token to match.

The optional `profile_abi` path segment is a digest of the external ABI surface
the profile exposes: external compiler/MPI/fabric/GPU-toolkit names, versions,
prefixes, modules, OS, and glibc. Use it when one physical mirror serves two
same-OS systems whose vendor or site external stacks should not share a bucket.
Do not add it by default for a single-system mirror. The `spack_generation` path
segment is an operator-chosen release token, not a solver input. It must change
whenever the deployed Spack version or active package repositories change enough
that old binary hashes should not share a mirror namespace with new ones. A
simple first implementation is `spack-<spack-version>/repo-<stack-release>`.

Reuse should come from Spack concretizer reuse plus compatible build caches,
not from forcing unrelated systems into the same binary bucket — and not from
siloing the same system into per-compiler buckets that prevent foundation
reuse.

### Target Microarchitecture And Reuse

Build performance-neutral foundation packages at a portable baseline target.
Reserve microarchitecture tuning for science libraries that actually benefit.

Recommended baseline:

```yaml
# configs/target/x86_64_v3/packages.yaml
packages:
  all:
    target: [x86_64_v3]
```

Optimized target examples:

| System class | Suggested Spack target |
|---|---|
| AMD Zen 3 CPU or MI250X host | `zen3` |
| AMD Zen 4 / MI300A host | `zen4` |
| Intel Sapphire Rapids | `sapphirerapids` |
| Intel Ice Lake SP | `icelake` |
| NVIDIA GPU host | detect CPU target separately from GPU arch |

Use target preferences, not hard global requirements, unless the lane truly
cannot accept a fallback. A hard `require: target=zen3` on `all` can prevent
reuse of baseline build tools and defeat the Core/foundation cache.

Performance tiering:

| Class | Examples | Microarch payoff | Default placement |
|---|---|---|---|
| SIMD / compute-bound | FFTW, BLAS/LAPACK, dense kernels | High | Optimized science lane |
| I/O-bound | HDF5, NetCDF, PnetCDF | Usually modest | Start in optimized science lane for simplicity |
| Neutral tooling | CMake, Ninja, pkgconf, Git | None | Core / baseline |

Start with a single optimized science lane per system target. Split I/O
libraries back to baseline only if rebuild time or cache duplication becomes a
measured problem.

## Release Artifacts

Rendered files are reproducible from source inputs (`profile.yaml`,
`stack.yaml`, package sets, templates, release vars). Lockfiles and the
release manifest are the **saved artifacts** — the workspace can be
regenerated from sources, but the lockfile records what Spack actually
concretized, and that fact is not derivable from sources alone once the
package repository or external versions move.

Example source-controlled artifact layout, matching the relative path used by
the runtime release tree under `/shared/stack/releases`:

```text
releases/2026.06/example-cray/cse/
  release-manifest.yaml
  gcc/core/spack.lock
  gcc/serial/spack.lock
  cce/core/spack.lock
  cce/mpi-craympich/spack.lock
  gcc/gpu-craympich-gfx90a/spack.lock
  gcc/gpu-craympich-gfx942/spack.lock
```

### Manifest Phases (Draft And Final)

The release manifest is written **twice**: once by the render step (as a
draft, with only source-derived fields populated) and again by the
publish step (as final, with build-host, lockfile, buildcache, and
verification fields added). One file, two states. A `phase:` top-level
key distinguishes them.

Why two writes rather than two files: a reader who asks "what was in
release 2026.06?" goes to one filename in one place. Splitting into
`render-manifest.yaml` + `release-manifest.yaml` would force the reader
to know which manifest carries which fact and what to do when the two
disagree (after a re-render, for example). Two phases of one file makes
the lifecycle explicit without doubling the lookup surface.

| Phase | Written by | Fields populated |
|---|---|---|
| `draft` | render step | source-derived: profile/stack/package-set digests, render-tool identity, explicit `rendered_at` release var, lane definitions (env path, kind, compiler, target, package_set, runtime_node_type), planned install/view/module paths, planned buildcache destinations |
| `final` | publish step | adds: build host, lockfile digests per lane, provenance summary per lane, runtime modules per lane, actual buildcache push destinations + lanes pushed, verification results, promoted_at / promoted_by, previous_release |

A draft manifest is valid input to Ansible's deploy roles; the publish
role overwrites it with the final phase when the build completes
successfully. A re-render replaces a final manifest with a fresh draft
(losing the publish-time fields for that file — they live in the
previous release directory until that release is reproved).

### Release Manifest Schema

The release manifest is the single file that ties a release to its source
inputs, its build context, and its build-cache destinations. It is the file
to read first when answering "what was in release 2026.06?" The schema:

```yaml
schema_version: 1
phase: final                                   # draft (after render) | final (after publish)

release:
  name:         "2026.06"                      # release tag (draft + final)
  rendered_at:  "2026-06-14T18:42:00Z"         # explicit release var, UTC (draft + final)
  promoted_at:  "2026-06-15T10:15:00Z"         # filled at publish; null in draft
  promoted_by:  "rventers"                     # filled at publish; null in draft

# ── Source-derived (filled at render, present in both draft and final) ──
stack:
  name:       cse                              # from stack.yaml.name
  source_repo: "git@gitlab:stacks/cse-stack"   # repo URL
  source_commit: "0375b16f..."                 # exact commit the render used
  source_dirty: false                          # true if the working tree had uncommitted changes

profile:
  path: "systems/example-cray/profile.yaml"    # path within the source repo
  digest: "sha256:b13c2e..."                   # sha256 of the profile file as rendered
  system_name: "example-cray"                  # cross-check against profile.system.name

stack_file:
  path: "stacks/cse/stack.yaml"
  digest: "sha256:f421a7..."

package_sets:                                  # one entry per set referenced by stack.yaml
  - name: core-foundation
    path: "package-sets/core-foundation.yaml"
    digest: "sha256:5510dc..."
  - name: science-full
    path: "package-sets/science-full.yaml"
    digest: "sha256:99a1be..."
  - name: science-gpu
    path: "package-sets/science-gpu.yaml"
    digest: "sha256:c734e1..."

templates:
  set: v6                                      # from stack.yaml.templates.set
  digest: "sha256:e2a5e0..."                   # sha256 of the rendered template tree, sorted
  render_tool:                                 # which render step produced this workspace
    name:    stack-render                      # or manual
    version: "0.4.2"                           # null when name is manual

# ── Build-context (filled at publish; null in draft) ────────────────────
spack:
  version: "1.1.1"                             # `spack --version` on the build host
  commit:  "ba9d6a01..."                       # exact commit, if Spack is a git checkout
  package_repos:                               # custom repos registered for this build
    - name: stack-overlay
      path: "configs/repo"
      commit: "0375b16f..."

build_host:
  hostname:  "cray01-login03"
  os:        "rhel"
  os_major:  8
  glibc:     "2.28"
  cpu:       "zen3"

# ── Lanes (rendered lanes only; skeleton at render; lockfile/install/provenance/runtime_modules at publish) ──
lanes:                                         # one entry per environment in the release
  - name: gcc-core
    env_path: "environments/gcc/core"          # render-filled
    kind: core                                 # render-filled
    compiler: gcc                              # render-filled
    target: x86_64_v3                          # render-filled
    runtime_node_type: cpu_compute             # render-filled
    package_set: core-foundation               # render-filled
    view_root: "/shared/stack/releases/2026.06/example-cray/cse/views/gcc/core"    # render-filled (planned path)
    package_module_root: "/shared/stack/releases/2026.06/example-cray/cse/modules/gcc/core" # render-filled (planned path)
    # publish-filled fields below
    lockfile: "gcc/core/spack.lock"
    lockfile_digest: "sha256:09abee..."
    install_root: "/shared/stack/spack/opt/linux-rhel8-x86_64_v3/gcc-13.3.0"
    provenance_summary:
      stack_built: 7                           # count of packages by provenance class
      platform_backed: 0
      site_external: 0
      spack_built: 0
    runtime_modules: []                        # platform modules the front-door must load

  - name: cce-mpi-craympich
    env_path: "environments/cce/mpi-craympich"
    kind: mpi
    compiler: cce
    target: zen3
    runtime_node_type: cpu_compute             # MPI lane runs on the CPU compute class
    lockfile: "cce/mpi-craympich/spack.lock"
    lockfile_digest: "sha256:71f4c5..."
    install_root: "/shared/stack/spack/opt/linux-rhel8-zen3/cce-17.0.1"
    view_root: "/shared/stack/releases/2026.06/example-cray/cse/views/cce/mpi-craympich"
    package_module_root: "/shared/stack/releases/2026.06/example-cray/cse/modules/cce/mpi-craympich"
    package_set: science-full
    provenance_summary:
      stack_built: 18
      platform_backed: 1                       # cray-mpich
      site_external: 0
      spack_built: 0
    runtime_modules:                           # platform modules the front-door loads
      - PrgEnv-cray
      - cce/17.0.1
      - cray-mpich/8.1.29

  - name: gcc-gpu-craympich-gfx90a              # Cray PE + GPU lane assembly Option B:
    env_path: "environments/gcc/gpu-craympich-gfx90a"   #   GNU host + ROCm toolkit module
    kind: gpu
    compiler: gcc                              # GNU host per the host-compiler policy
    target: zen3
    runtime_node_type: gpu_compute_mi250x       # GPU lane runs on the matching GPU class
    lockfile: "gcc/gpu-craympich-gfx90a/spack.lock"
    lockfile_digest: "sha256:b8c401..."
    install_root: "/shared/stack/spack/opt/linux-rhel8-zen3/gcc-13.3.0"
    view_root: "/shared/stack/releases/2026.06/example-cray/cse/views/gcc/gpu-craympich-gfx90a"
    package_module_root: "/shared/stack/releases/2026.06/example-cray/cse/modules/gcc/gpu-craympich-gfx90a"
    package_set: science-gpu
    provenance_summary:
      stack_built: 12
      platform_backed: 2                       # cray-mpich + ROCm toolkit externals
      site_external: 0
      spack_built: 0
    runtime_modules:                           # Option B: PrgEnv-gnu + standalone rocm + cray-mpich
      - PrgEnv-gnu
      - gcc-native/13
      - rocm/6.0.0
      - cray-mpich/8.1.29

skipped_lanes:                                 # render-filled; empty if every stack lane rendered
  - name: cce-gpu-craympich-gfx90a
    reason: "lane not declared in profile capabilities"

# ── Buildcache + verification (filled at publish; planned destinations may
#    appear in draft as `planned_destinations:` for Ansible to consult) ──
buildcache:
  push_destinations:                           # mirrors this release was pushed to
    - name: foundation
      url:  "file:///shared/stack/buildcache/foundation/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/x86_64_v3"
      lanes_pushed: ["gcc-core", "cce-core", "rocmcc-core"]
    - name: science
      url:  "file:///shared/stack/buildcache/science/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/example-cray"
      lanes_pushed: ["cce-mpi-craympich", "gcc-gpu-craympich-gfx90a"]
  signed: false

verification:
  spack_verify_libraries: passed               # passed | failed | skipped
  spack_verify_manifest:  passed
  site_smoke_tests:       passed
  notes: "All lanes verified on cray01-login03 2026-06-15."

previous_release: "2026.05"                    # for rollback; null on first release
```

### Final Manifest Without A Helper

`stack-publish-manifest` is an optional helper, not a required release engine.
A fully manual publish step writes the same `phase: final` manifest by filling
the publish-time fields from files and commands already produced by the manual
workflow:

```text
1. Set `phase: final`.
2. Keep all draft source-derived fields unchanged.
3. Fill `spack.version` and `spack.commit` from the build host.
4. Fill `build_host.*` from the host that performed the builds.
5. For each rendered lane, copy the final `spack.lock` path and sha256 digest.
6. For each rendered lane, record `install_root`, `view_root`,
   `package_module_root`, provenance counts, and runtime modules loaded by the
   front-door module.
7. Record actual buildcache push destinations and lanes pushed.
8. Record verification results from `spack verify ...` and site smoke tests.
9. Fill `promoted_at` and `promoted_by` only when promotion actually happens;
   leave them null if the final manifest is written before promotion approval.
10. Record `previous_release` from the `current` symlink before promotion.
```

The helper only automates this checklist. It must not infer policy beyond what
the rendered workspace, lockfiles, verification logs, and operator-supplied
promotion metadata contain.

Promotion is an atomic symlink swap and the `current` symlink reaches the
release manifest first. Use a temporary symlink and rename it over `current`;
plain `ln -sfn` is only a simplified sketch and should not be the production
primitive.

```bash
ln -s releases/2026.06 /shared/stack/.current.2026.06.tmp
mv -Tf /shared/stack/.current.2026.06.tmp /shared/stack/current
```

Keep previous releases loadable until they are intentionally retired. The
`release.retain_previous` policy in `stack.yaml` (default 2) determines the
default cleanup horizon; Ansible's promotion task refuses to delete a
release tree if `current` still points at it.

## Validation And Verification

Validation runs at every layer of the pipeline. Each layer catches its own
class of failure at the cheapest moment.

| Layer | Catches | Example checks |
|---|---|---|
| Source contract | Schema errors, typos, missing files | YAML syntax, schema versions, profile/stack compatibility, package-set existence |
| Rendered workspace | Bad rendering, broken include paths | expected files exist, no unresolved Jinja placeholders, `include::` paths point at existing scopes |
| Spack config | Scope leakage, missing externals | `spack config scopes -vp`, `spack config blame`, `spack spec` |
| Concrete solve | Bad concretization choices | `spack -e <env> concretize`, inspect `spack.lock` diffs |
| Build | Build-recipe failures | `spack -e <env> install --fail-fast` |
| Integrity | Broken install / missing libraries | `spack verify manifest`, `spack verify libraries` |
| User workflow | Lane composition / view exposure | clean shell, load front-door, load package modules, compile smoke tests |
| Runtime | Real MPI/GPU/scheduler interaction | scheduler launch, MPI hello-world, GPU device-query, multi-node smoke test |

Verification runs in the same context users will see, not in a dirty build
shell. For each lane:

```text
1. Start a clean shell with no stack lane loaded.
2. Prepend the candidate release's physical module directory directly, or load a
   release-tagged init module; do not use the global `current` symlink for
   pre-promotion verification.
3. Load the lane front-door module (`<modules.module_root>/<compiler>/<lane>`,
   for example `CSE/GCC/gpu-craympich-gfx90a`).
4. Confirm the front-door loaded required platform modules for consumed externals.
5. Run `spack -e <env> verify libraries` and `verify manifest -a`.
6. Load representative package modules from that lane and run compile/smoke tests.
7. For MPI/GPU lanes, run scheduler-backed runtime smoke tests on the lane's
   `runtime_node_type`.
```

### Validation Commands Reference

The full set of Spack commands the render step, Ansible, and a debugger
call into. Pass/fail signatures are noted where they are not obvious.

**Config and scope provenance:**

```bash
spack -e <env> config scopes -vp
#   Pass: every line resolves to a path inside the rendered workspace
#         (plus Spack's own defaults).
#   Fail: any line points at ~/.spack/, /etc/spack/, or a user-config path.

spack -e <env> config blame packages
spack -e <env> config blame config
spack -e <env> config blame modules
#   Pass: every setting traces to a stack-controlled scope file or to
#         Spack defaults.
#   Fail: a setting traces to a user or site scope.
```

**Spec inspection (pre-concretize):**

```bash
spack -e <env> spec <spec>
#   Shows the concretization plan for one spec. Use to verify toolchain
#   and external selection before running install.

spack -e <env> spec -l <spec>
#   Same, with hashes. Use to compare against an existing lockfile.

spack -e <env> spec -I <spec>
#   Show only the parts of the DAG that would be installed (skipping
#   what is already present). Useful for change-impact analysis.
```

**Concretize and fetch:**

```bash
spack -e <env> concretize
#   Concretize the environment. Writes spack.lock.
#   Pass: solver succeeds; lockfile produced.
#   Fail: "concretization failed" — typically a missing or conflicting
#         external, or a toolchain pinning that cannot be satisfied.

spack -e <env> concretize -f
#   Force re-concretization. Treats existing lockfile as advisory only.
#   Use intentionally; can change hashes unrelated to the targeted update.

spack -e <env> fetch -D
#   Fetch sources for the whole DAG into source_cache.
#   Should be run on a host with internet access.
```

**Build:**

```bash
spack -e <env> install -j <N>
#   The production build command. -j sets parallelism.

spack -e <env> install --fail-fast --show-log-on-error -v <spec>
#   The diagnostic build command. Fail fast and show the build log on
#   the first error.

spack -e <env> install --fail-fast --show-log-on-error -v \
                       --keep-stage --keep-prefix <spec>
#   Same with the stage and partial prefix preserved for post-mortem.
```

**Build-env inspection:**

```bash
spack -e <env> build-env <spec> -- env | sort
#   Dump every environment variable Spack would set during this spec's
#   build. Diff against a failing manual build to find what's different.

spack -e <env> build-env <spec> -- /bin/bash
#   Drop into an interactive shell inside the spec's build environment.
#   Reproduce the failing configure/cmake/make manually here.
```

**Find and reuse inspection:**

```bash
spack -e <env> find -lv
#   List installed specs in the environment with hashes and variants.
#   The 'I' flag indicates installed-and-current; absence means missing.

spack -e <env> find -c -lv
#   List concretized specs (everything in the lockfile), including
#   those not yet installed.
```

**Verify (post-install):**

```bash
spack -e <env> verify manifest -a
#   Cross-check every installed file against the manifest.
#   Pass: clean. Fail: a file was changed after install (or missing).

spack -e <env> verify libraries
#   Check that every installed binary's shared-library dependencies
#   resolve under the RPATH and the system loader.
#   Pass: clean. Fail: a missing or wrong-version library — typically
#   a Cray PE module not loaded at runtime, or a broken RPATH.
```

**Views and modules:**

```bash
spack -e <env> env view regenerate
#   Regenerate the projected view. Run after every install or version
#   change.

spack -e <env> module tcl refresh -y
#   Regenerate Tcl modulefiles for everything in the environment.
#   The committed module format.

# Optional on Lmod-enabled sites:
spack -e <env> module lmod refresh -y
```

**Build cache:**

```bash
spack -e <env> buildcache push --update-index --unsigned <mirror> [<spec> ...]
#   Push specs to the named mirror. Omitting specs (inside an active
#   environment) pushes the environment's specs.

spack buildcache list
#   List available binaries in registered mirrors.
```

**Cluster Inspector and render helpers (optional):**

```bash
cluster-inspector profile [--system <name>]
cluster-inspector verify <profile.yaml>

stack-validate         --profile <profile> --stack <stack>
stack-render           --profile <profile> --stack <stack> --release <tag> --output-root <dir>
stack-explain          --profile <profile> --stack <stack> [--release <tag>]
stack-publish-manifest --release-dir <release-dir> [--verification-results <file>]
```

## Debug And Triage Policy

Production fixes should go into stack inputs, Spack config, Spack recipes,
patches, or module/view policy. Avoid shipping production fixes that depend on a
dirty interactive shell.

Debug bundle contents:

- command line used
- `profile.yaml`
- `stack.yaml`
- rendered `spack.yaml`
- rendered config scopes
- `spack.lock`
- `spack config scopes -vp`
- `spack config blame packages/config/modules`
- `spack-build.log`
- build environment dump (`spack -e <env> build-env <spec> -- env | sort`)
- preserved stage path if available
- loaded modules if platform externals require modules

Triage order:

```text
1. What did Spack concretize?         spack spec -l, spack find -lv
2. Which config scopes were read?     spack config scopes -vp, config blame
3. Which external or toolchain was selected?   inspect concretization
4. Is the failure a package recipe issue, a stack policy issue, or a platform issue?
5. Where should the durable fix live?
```

### Failure Modes Catalog

Long table mapping symptom to likely cause to durable fix location. This
is the doc's debugging map; the categories cover the failures the design
actually generates. When an unfamiliar failure appears, add it to this
table — it is the single place the team's failure knowledge accumulates.

| Symptom | Likely cause | Where to fix |
|---|---|---|
| `config blame` shows `~/.spack/...` or `/etc/spack/...` | `include::` is `include:` (single colon), or no `include::` at all | `templates/environments/*/spack.yaml.j2` — switch to `include::` |
| `config blame` shows expected scope but a setting is wrong | Render step copied the wrong scope, or the scope file in `templates/configs/...` has the wrong value | `templates/configs/<scope>/<file>` |
| `spack concretize` fails with "no satisfying spec for compiler" | Profile declared the compiler but stack's `externals.compilers` policy did not honor it; or the toolchain pins a compiler the lane cannot reach | Cross-check the normalized compiler inventory (`vendor_cray.*` plus `compilers_external.*`) against `stack.externals.compilers`; check `toolchains.yaml` versions match the profile |
| `spack concretize` fails with "no satisfying spec for mpi" | The MPI scope is missing from the lane's `include::` list, or `mpi: require:` points at a provider that is not present | Lane environment template's `include::` order; `configs/mpi/<provider>/packages.yaml` `require:` line |
| Concretization picks the wrong cray-mpich flavor | The lane's `%toolchain` does not specify `%mpi`, or the per-flavor external `%cce` / `%gcc` / `%rocmcc` tags are absent in `configs/mpi/cray-mpich/packages.yaml` | `configs/mpi/cray-mpich/toolchains.yaml`, `configs/mpi/cray-mpich/packages.yaml` |
| Build fails with "OpenSSL not found" | `openssl: buildable: false` and no external was detected, OR the external version pin is too narrow | `configs/os/<os>/packages.yaml` — use `buildable: true` with `prefer:` |
| Build fails with linker errors against zlib | Foundation `require:` pin missing in common scope, allowing two zlib versions | `configs/common/packages.yaml` — add `require:` on zlib |
| `spack verify libraries` fails for a Cray build | The lane's front-door module does not load the PE modules at runtime; CSE binaries depend on PE runtime components | Front-door module template — add `module load PrgEnv-...` + `cray-mpich/...` |
| `ldd` on a built binary shows "not found" for `libpgmath.so` or similar | Site compiler runtime not loaded; the lane is built on a module-provided external but the front-door does not load its modules | Front-door module template — add `module load <compiler-module>` |
| GPU runtime fails with "CUDA driver version is insufficient for CUDA runtime version" | Toolkit version exceeds the GPU driver ceiling | Check the lane's `profile.node_types[<runtime_node_type>].gpu.toolkit_ceiling`; pin CUDA in `configs/gpu/nvidia-cuda/packages.yaml` at or under it |
| GPU build fails with "no kernel image available for execution" | Rendered Spack GPU variant (`cuda_arch=90` or `amdgpu_target=gfx90a`) does not match the lane's profile arch label (`sm_90` or `gfx90a`) from `profile.node_types[<runtime_node_type>].gpu.arch_target` | `configs/gpu/<vendor>/packages.yaml` — map the profile label to the correct Spack variant |
| User compile finds the wrong `hdf5` headers | Two `hdf5` versions on `CPATH` — typically a stale module not unloaded, or the wrong lane loaded | Verify with `module list`; lane conflict should prevent this |
| `module load` of two lanes simultaneously succeeds | Conflict block in front-door module is missing or stale | Front-door module template — `conflict CSE/...` for every other lane |
| User script picks `mpirun` from system PATH instead of the lane | Site MPI's `mpirun` is not exposed by the lane (Spack-built lanes put it in the view PATH; site-external lanes rely on the site module) | Confirm the lane's runtime module loads include the MPI module |
| Cache miss on a binary the foundation already built | Cache keyed by compiler; CCE lane is reading the wrong bucket; or the foundation mirror is not registered in the lane's `mirrors.yaml` | Re-key the cache by OS/glibc (label compiler in the path, not the key); register foundation mirror in `configs/common/mirrors.yaml` |
| `spack ci generate` produces no rebuild jobs after a stack change | Pipeline env has `reuse: true` (the default); `spack ci` must run on `reuse: false` | Pipeline env's `concretizer.yaml` — set `reuse: false` |
| Re-render produces a diff from the last release | The render step is consulting ambient state (shell vars, `module list`, etc.) | Render step implementation — remove the ambient lookup; renders must be deterministic from `(profile, stack, sets, templates, release_vars)` |
| Render rejects a lane with "runtime_node_type not found" | `stack.yaml.lanes[*].runtime_node_type` names a class that is not in `profile.node_types`, or names one whose `role` is `build_host` only | Add the node type to the profile (re-run inspector or hand-edit), or change the lane to point at a class with `role: runtime` / `both` |
| GPU lane builds for the wrong arch (e.g., `gfx90a` when the node is `gfx942`) | `lanes[*].runtime_node_type` names the wrong GPU class — the render took the GPU block from the wrong `node_types` entry | Fix the lane's `runtime_node_type:` in `stack.yaml`; one lane per GPU class is the committed model, do not try to make one lane serve two GPU archs |
| Different OS lanes share one cache and hashes seem to overlap | Cache lane is not keyed by OS/glibc; SLES and RHEL builds collided | Re-key cache by OS/glibc — `buildcache/foundation/<os-id>/glibc-<glibc>/<spack-generation>/<baseline>/` |
| Two compilers' Core CMake collide in one view | One shared Core view across compilers — per-compiler Core needs per-compiler view roots | View root template — split into `views/<compiler>/core/` |
| `module load` of a package finds a stale path that no longer exists | View was not regenerated after install | Run `spack -e <env> env view regenerate` — Ansible's `publish` role should do this automatically |
| Site smoke test passes but `verify libraries` fails | Soft RPATH; runtime library happens to be available at test time but not via RPATH | Inspect with `readelf -d`; rebuild with explicit RPATH or fix the package recipe |

## Example Cray Flow (Helper-Assisted End-To-End Walkthrough)

A worked example of bringing up `release 2026.06` of the CSE stack on a
Cray-class system named `example-cray` (RHEL8, Slingshot/CXI fabric, AMD
GPU compute partitions for MI250X and MI300A). Every command shown is
runnable; the values mirror the schema examples in §Durable Inputs.

> **Helper-assisted.** This walkthrough uses ClusterInspector and the
> render helper to reduce labor. The §Manual Workflow remains valid:
> write `profile.yaml` and `environments/*/spack.yaml` by hand against
> the schemas in §Durable Inputs and §Lane Model, skip the inspector
> and render steps, and run `spack -e <env> install` directly. The
> helpers are convenience; the model does not require them.

### Phase 1 — Author the profile

Run ClusterInspector for the first time on the login node, no hints file
yet. Use the all-in-one invocation to probe the login + each compute
class in a single command:

```bash
$ cluster-inspector profile \
    --system example-cray \
    --node-type login=this:role=build_host \
    --node-type cpu_compute=srun:partition=cpu_compute:role=runtime \
    --node-type gpu_compute_mi250x=srun:partition=gpu,constraint=mi250x:role=runtime \
    --node-type gpu_compute_mi300a=srun:partition=gpu,constraint=mi300a:role=runtime \
    --output systems/example-cray/profile.yaml
```

The inspector enumerates `module avail`, classifies candidates, submits
short scheduler jobs for each compute class to probe CPU/GPU/build-stage
facts, and writes a first draft of `profile.yaml`.

Review the output. On a typical first run the auto-discovery picked up
some modules that are not real CSE compiler choices:

```
$ grep -A1 "name:" systems/example-cray/profile.yaml | head
    name: cce         version: "17.0.1"
    name: gcc-native  version: "13"
    name: gcc-toolset version: "12"      # ← not a real CSE compiler
    name: gcc-data    version: "9.3"     # ← not a real CSE compiler
    name: rocmcc      version: "6.0.0"
```

Author the hints file to narrow the discovery to the real CSE compiler
set on this system, then re-run:

```bash
$ cat > systems/example-cray/inspector-hints.yaml <<'EOF'
schema_version: 1

compilers:
  include:
    - cce/17.0.1
    - gcc-native/13
    - rocmcc/6.0.0
  exclude_patterns:
    - "gcc-data/*"
    - "gcc-toolset/*"

mpi:
  include:
    - cray-mpich/8.1.29

gpu_toolkits:
  include:
    - rocm/6.0.0
EOF

$ cluster-inspector profile \
    --system example-cray \
    --hints systems/example-cray/inspector-hints.yaml \
    --node-type login=this:role=build_host \
    --node-type cpu_compute=srun:partition=cpu_compute:role=runtime \
    --node-type gpu_compute_mi250x=srun:partition=gpu,constraint=mi250x:role=runtime \
    --node-type gpu_compute_mi300a=srun:partition=gpu,constraint=mi300a:role=runtime \
    --output systems/example-cray/profile.yaml
```

The second pass produces a clean profile. Verify it parses and the
node-types are reachable:

```bash
$ cluster-inspector verify systems/example-cray/profile.yaml
PASS  schema.v1
PASS  4 node_types, 1 build_host
PASS  PE: cce@17.0.1, gcc-native@13.3.0, rocmcc@6.0.0, cray-mpich@8.1.29
PASS  GPU classes: gpu_compute_mi250x (gfx90a), gpu_compute_mi300a (gfx942)
PASS  fabric: slingshot/cxi; drivers: rdma-core@29.0, cxi-userlibs@1.0
```

Commit `systems/example-cray/profile.yaml` and
`systems/example-cray/inspector-hints.yaml` together.

### Phase 2 — Author the stack file

Edit `stacks/cse/stack.yaml` to declare the lanes this release will
build. The committed lane choices for this system: two compilers (GCC +
CCE) × two non-GPU kinds (core, mpi) + two GPU lanes (gfx90a, gfx942 —
Option B with GCC host). Plus core lanes for each compiler so the
compiler's Core view exists.

```yaml
# stacks/cse/stack.yaml (excerpt — the schema in §Durable Inputs has the rest)
lanes:
  - { name: gcc-core,                   compiler: gcc,  lane: core,                kind: core,   package_set: core-foundation, target: foundation,        runtime_node_type: cpu_compute,           publish: true }
  - { name: gcc-mpi-craympich,          compiler: gcc,  lane: mpi-craympich,       kind: mpi,    package_set: science-full,    target: science_default,   runtime_node_type: cpu_compute,           publish: true }
  - { name: gcc-gpu-craympich-gfx90a,   compiler: gcc,  lane: gpu-craympich-gfx90a, kind: gpu,   package_set: science-gpu,     target: science_default,   runtime_node_type: gpu_compute_mi250x,    publish: true }
  - { name: gcc-gpu-craympich-gfx942,   compiler: gcc,  lane: gpu-craympich-gfx942, kind: gpu,   package_set: science-gpu,     target: science_default,   runtime_node_type: gpu_compute_mi300a,    publish: true }
  - { name: cce-core,                   compiler: cce,  lane: core,                kind: core,   package_set: core-foundation, target: foundation,        runtime_node_type: cpu_compute,           publish: true }
  - { name: cce-mpi-craympich,          compiler: cce,  lane: mpi-craympich,       kind: mpi,    package_set: science-full,    target: science_default,   runtime_node_type: cpu_compute,           publish: true }
```

Six lanes — the realistic count from §Lane Matrix Sizing for this system
shape. Validate:

```bash
$ stack-validate \
    --profile systems/example-cray/profile.yaml \
    --stack stacks/cse/stack.yaml
PASS  profile schema matches stack.profile_contract
PASS  every lane.runtime_node_type resolves in profile.node_types
PASS  every lane.compiler resolves in normalized compiler inventory
PASS  every lane.package_set exists with kind compatible
PASS  no profile capability missing for declared lanes
```

### Phase 3 — Render

Materialize the rendered workspace:

```bash
$ stack-render \
    --profile     systems/example-cray/profile.yaml \
    --stack       stacks/cse/stack.yaml \
    --release     2026.06 \
    --output-root /shared/stack/work
# → workspace written to /shared/stack/work/example-cray/cse/2026.06/

$ rsync -a /shared/stack/work/example-cray/cse/2026.06/ \
        /shared/stack/releases/2026.06/example-cray/cse/

$ tree -L 3 /shared/stack/releases/2026.06/example-cray/cse/
/shared/stack/releases/2026.06/example-cray/cse/
├── configs
│   ├── common
│   ├── gpu/amd-rocm
│   ├── mpi/cray-mpich
│   ├── os/rhel8
│   ├── target/x86_64_v3
│   ├── target/zen3
│   ├── target/zen4
│   └── vendor/cray
├── environments
│   ├── cce/core/spack.yaml
│   ├── cce/mpi-craympich/spack.yaml
│   ├── gcc/core/spack.yaml
│   ├── gcc/gpu-craympich-gfx90a/spack.yaml
│   ├── gcc/gpu-craympich-gfx942/spack.yaml
│   └── gcc/mpi-craympich/spack.yaml
└── release-manifest.yaml
```

Verify scope isolation on one lane before the build:

```bash
$ cd /shared/stack/releases/2026.06/example-cray/cse
$ spack -e environments/gcc/gpu-craympich-gfx90a config blame packages | head
configs/mpi/cray-mpich/packages.yaml:3      mpi.require: cray-mpich
configs/mpi/cray-mpich/packages.yaml:6      cray-mpich.buildable: false
configs/mpi/cray-mpich/packages.yaml:9      cray-mpich.externals[0].prefix: /opt/cray/pe/mpich/8.1.29/ofi/gnu/13.3
configs/gpu/amd-rocm/packages.yaml:4        all.variants: amdgpu_target=gfx90a
configs/target/zen3/packages.yaml:4         all.target: [zen3]
configs/common/packages.yaml:4              zlib.require: "@1.3.1"
```

Every line traces to the rendered workspace — no `~/.spack`, no
`/etc/spack/`. Isolation works.

### Phase 4 — Build the foundation neck

Build the bootstrap compiler externals, then GCC Core, then CCE Core.
These are the serial neck:

```bash
# On the login node (build_host):
$ cd /shared/stack/releases/2026.06/example-cray/cse

# GCC Core: build tools + foundation libs at x86_64_v3 baseline
$ spack -e environments/gcc/core concretize
$ spack -e environments/gcc/core fetch -D
$ spack -e environments/gcc/core install -j 48
$ spack -e environments/gcc/core buildcache push --update-index --unsigned \
       file:///shared/stack/buildcache/foundation/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/x86_64_v3

# CCE Core: same package set, built under CCE — per-compiler Core means
# this duplicates the build tools, intentionally
$ spack -e environments/cce/core concretize
$ spack -e environments/cce/core fetch -D
$ spack -e environments/cce/core install -j 48
$ spack -e environments/cce/core buildcache push --update-index --unsigned \
       file:///shared/stack/buildcache/foundation/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/x86_64_v3
```

### Phase 5 — Fan out the science and GPU lanes

Now that both Cores are cached, the four remaining lanes run independently.
Submit one Spack process per node, each lane pinned to its
`runtime_node_type`:

```bash
# On the login/build host, concretize and fetch every non-core lane first.
$ for env in gcc/mpi-craympich cce/mpi-craympich \
             gcc/gpu-craympich-gfx90a gcc/gpu-craympich-gfx942; do
    spack -e environments/$env concretize
    spack -e environments/$env fetch -D
done

# CPU MPI lanes on the CPU compute partition
$ srun -N1 -n1 --partition=cpu_compute \
    spack -e environments/gcc/mpi-craympich install -j 64 &
$ srun -N1 -n1 --partition=cpu_compute \
    spack -e environments/cce/mpi-craympich install -j 64 &

# GPU lanes on their matching GPU partitions
$ srun -N1 -n1 --partition=gpu --constraint=mi250x --gpus=1 \
    spack -e environments/gcc/gpu-craympich-gfx90a install -j 64 &
$ srun -N1 -n1 --partition=gpu --constraint=mi300a --gpus=1 \
    spack -e environments/gcc/gpu-craympich-gfx942 install -j 64 &

$ wait
```

The lanes write disjoint compiler subtrees of the install tree; per-prefix
locks act as the safety net for the rare incidentally-shared spec. Each
lane reads the foundation cache for CMake/Ninja/zlib instead of rebuilding
them, because the foundation lane was pushed first.

### Phase 6 — Verify, push, publish

Per lane, run Spack integrity checks, regenerate candidate views/modules, and
push the science cache:

```bash
$ for env in gcc/mpi-craympich cce/mpi-craympich \
             gcc/gpu-craympich-gfx90a gcc/gpu-craympich-gfx942; do
    spack -e environments/$env verify libraries
    spack -e environments/$env verify manifest -a
    /shared/stack/tests/smoke.sh environments/$env

    spack -e environments/$env env view regenerate
    spack -e environments/$env module tcl refresh -y
    spack -e environments/$env buildcache push --update-index --unsigned \
         file:///shared/stack/buildcache/science/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/example-cray
done
```

After candidate views and modules exist, run clean-shell user verification from
the release-tagged module root before promotion. This is where package-module
loads, compile smoke tests, MPI launch tests, and GPU device-query tests run.

Write the final manifest in the release directory:

```bash
# The publish step rewrites the manifest with phase: final, adding
# build-host, lockfile digests, provenance summaries, runtime modules,
# buildcache push destinations, and verification results:
$ stack-publish-manifest \
    --release-dir /shared/stack/releases/2026.06/example-cray/cse \
    --build-host  $(hostname) \
    --buildcache  foundation=file:///shared/stack/buildcache/foundation/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/x86_64_v3 \
    --buildcache  science=file:///shared/stack/buildcache/science/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/example-cray \
    --verification-results /tmp/verify-results.yaml
# → overwrites release-manifest.yaml with phase: final
```

### Phase 7 — Promote (gated)

The release is built and verified but not yet visible to users. Promotion
is an explicit, gated step:

```bash
$ ls -la /shared/stack/current
lrwxrwxrwx ... /shared/stack/current -> releases/2026.05    # previous release

# After human approval:
$ ln -s releases/2026.06 /shared/stack/.current.2026.06.tmp
$ mv -Tf /shared/stack/.current.2026.06.tmp /shared/stack/current
```

A user on a GPU partition now loads:

```bash
$ module load CSE/GCC/gpu-craympich-gfx90a
$ module load hdf5 kokkos
$ echo $STACK_PACKAGE_PROVENANCE                  # → Stack-built
```

The previous release (`releases/2026.05`) remains intact and loadable
via the release-tagged paths (`/shared/stack/releases/2026.05/...`) for
two cycles per the retention policy.

## Example Generic Linux HPC Flow (Helper-Assisted End-To-End Walkthrough)

A worked example for a generic Linux HPC system named `example-linux`
(SLES15, InfiniBand HDR fabric, AOCC site compiler, OpenMPI from the
site). Differences from the Cray flow: no PE, the site MPI is registered
as a `prefix:`-only external, no GPU.

> **Helper-assisted.** Same caveat as the Cray flow above — the helpers
> reduce labor but are not required. The manual workflow remains valid.

### Phase 1 — Author the profile

```bash
$ cluster-inspector profile \
    --system example-linux \
    --node-type login=this:role=build_host \
    --node-type cpu_compute=srun:partition=compute:role=runtime \
    --output systems/example-linux/profile.yaml

# Review; the heuristic likely picked up extra compiler modules
$ cat > systems/example-linux/inspector-hints.yaml <<'EOF'
schema_version: 1
compilers:
  include:
    - aocc/4.2.0
    - gcc/11.4.0
  exclude_patterns:
    - "gcc-data/*"
mpi:
  include:
    - openmpi/4.1.6
EOF

$ cluster-inspector profile \
    --system example-linux \
    --hints systems/example-linux/inspector-hints.yaml \
    --node-type login=this:role=build_host \
    --node-type cpu_compute=srun:partition=compute:role=runtime \
    --output systems/example-linux/profile.yaml

$ cluster-inspector verify systems/example-linux/profile.yaml
```

The resulting profile has no `vendor_cray:` block (the system is not
Cray), no `gpu:` block on any node_type (no GPUs), and an `mpi:` array
listing the site OpenMPI with its `prefix:` (no `modules:` — the site MPI
is a stable on-disk install).

### Phase 2 — Author the stack file

Three lanes per compiler. No GPU lanes. Two MPI options: the site MPI lane
(for users who want the site-tuned MPI) and a Spack-built OpenMPI lane
(for users who want a stack-owned MPI):

```yaml
# stacks/cse/stack.yaml (Linux excerpt)
lanes:
  - { name: aocc-core,             compiler: aocc, lane: core,         kind: core,   package_set: core-foundation, target: foundation,      runtime_node_type: cpu_compute, publish: true }
  - { name: aocc-serial,           compiler: aocc, lane: serial,       kind: serial, package_set: science-full,    target: science_default, runtime_node_type: cpu_compute, publish: true }
  - { name: aocc-mpi-site,         compiler: aocc, lane: mpi-site,     kind: mpi,    package_set: science-full,    target: science_default, runtime_node_type: cpu_compute, publish: true }
  - { name: aocc-mpi-openmpi,      compiler: aocc, lane: mpi-openmpi,  kind: mpi,    package_set: science-full,    target: science_default, runtime_node_type: cpu_compute, publish: true }
  - { name: gcc-core,              compiler: gcc,  lane: core,         kind: core,   package_set: core-foundation, target: foundation,      runtime_node_type: cpu_compute, publish: true }
  - { name: gcc-mpi-openmpi,       compiler: gcc,  lane: mpi-openmpi,  kind: mpi,    package_set: science-full,    target: science_default, runtime_node_type: cpu_compute, publish: true }
```

```bash
$ stack-validate \
    --profile systems/example-linux/profile.yaml \
    --stack stacks/cse/stack.yaml
```

### Phase 3 — Render

```bash
$ stack-render \
    --profile     systems/example-linux/profile.yaml \
    --stack       stacks/cse/stack.yaml \
    --release     2026.06 \
    --output-root /shared/stack/work
# → workspace written to /shared/stack/work/example-linux/cse/2026.06/

$ rsync -a /shared/stack/work/example-linux/cse/2026.06/ \
        /shared/stack/releases/2026.06/example-linux/cse/

$ cd /shared/stack/releases/2026.06/example-linux/cse
$ ls environments/
aocc/core  aocc/serial  aocc/mpi-site  aocc/mpi-openmpi
gcc/core   gcc/mpi-openmpi
```

The rendered Spack-built OpenMPI lane includes `configs/mpi/spack-openmpi`
(which builds OpenMPI as part of the lane); the site-MPI lane includes
`configs/mpi/site-mpi` (which registers the prefix as a `buildable: false`
external).

### Phase 4 — Build

Build each compiler's Core first; the site MPI lane reads its MPI as an
external so no MPI build happens there. The Spack-built OpenMPI lane
builds OpenMPI from source as part of the lane.

```bash
$ spack -e environments/aocc/core concretize
$ spack -e environments/aocc/core fetch -D
$ spack -e environments/aocc/core install -j 64
$ spack -e environments/aocc/core buildcache push --update-index --unsigned \
       file:///shared/stack/buildcache/foundation/sles15/glibc-2.31/spack-1.1.1/repo-2026.06/x86_64_v3

$ spack -e environments/gcc/core concretize
$ spack -e environments/gcc/core fetch -D
$ spack -e environments/gcc/core install -j 64
$ spack -e environments/gcc/core buildcache push --update-index --unsigned \
       file:///shared/stack/buildcache/foundation/sles15/glibc-2.31/spack-1.1.1/repo-2026.06/x86_64_v3

# On the login/build host, concretize and fetch every non-core lane first.
$ for env in aocc/serial aocc/mpi-site aocc/mpi-openmpi gcc/mpi-openmpi; do
    spack -e environments/$env concretize
    spack -e environments/$env fetch -D
done

# Fan out the four remaining lanes
$ srun -N1 -n1 --partition=compute \
    spack -e environments/aocc/serial         install -j 64 &
$ srun -N1 -n1 --partition=compute \
    spack -e environments/aocc/mpi-site       install -j 64 &
$ srun -N1 -n1 --partition=compute \
    spack -e environments/aocc/mpi-openmpi    install -j 64 &
$ srun -N1 -n1 --partition=compute \
    spack -e environments/gcc/mpi-openmpi     install -j 64 &
$ wait
```

### Phase 5 — Verify, push, publish, promote

Same shape as the Cray flow. Per lane: verify, regenerate view+modules,
push science cache. Copy workspace + manifest to the release directory.
Swap `current` after approval.

The two AOCC MPI lanes differ in their front-door modules. Both load the AOCC
compiler module if AOCC is a module-provided external. The site-MPI lane exposes
the prefix-only site OpenMPI path declared in the profile (no OpenMPI module is
loaded unless the profile external declares one). The Spack-built OpenMPI lane
does not load an OpenMPI module because OpenMPI is stack-built inside the lane.

```bash
# A user picks the MPI flavor they want
$ module load CSE/AOCC/mpi-site            # site-tuned, AOCC module + OpenMPI prefix
$ module list | grep -E "aocc|openmpi|CSE"
1) aocc/4.2.0    2) CSE/AOCC/mpi-site
$ which mpirun
/opt/site/openmpi/4.1.6-aocc-4.2.0/bin/mpirun

# vs.
$ module swap CSE/AOCC/mpi-site CSE/AOCC/mpi-openmpi   # stack-owned, self-contained
$ module list | grep -E "aocc|openmpi|CSE"
1) aocc/4.2.0    2) CSE/AOCC/mpi-openmpi      # no site OpenMPI module needed
```

Both produce a working user surface. The choice is one of provenance
(`Site-external` vs `Stack-built`) and is recorded per-package via the
`STACK_PACKAGE_PROVENANCE` module env var.

## Committed Decisions And Genuinely Open Questions

The design avoids unanswered questions where it can. Decisions that have a
practical answer right now are recorded here as **committed** — the answer
may evolve, but the design has a position and ships with it. The
genuinely-open list at the end is short and limited to questions that need
real-world evidence (a deployed system, a measured workload) to settle.

### Committed Decisions

| Question | Committed answer | May change when |
|---|---|---|
| Helper command names | `cluster-inspector` (the read-only system probe), `stack-render` (the render helper), `stack-validate` (validate-only mode), `stack-explain` (dry-run mode), and `stack-publish-manifest` (optional final-manifest writer). Ansible playbook names follow `deploy-stack`. | A naming review happens before the helpers are user-installable; until then these names are committed. The architectural rules in §Render Step would survive a rename. |
| Location of `stack.yaml` | `stacks/<name>/stack.yaml` (one file per stack, top-level `stacks/` directory). No system-specific overlays — system facts live in `profile.yaml` and the render step composes them. | Never, unless the design ever lets one stack be defined as a composition of two stacks; that case would need overlay syntax, but it is not on the horizon. |
| Multiple node types per system | **One `profile.yaml` per system with a `node_types:` block** containing one entry per node class (login, CPU compute, GPU compute per GPU model, etc.). System-shared facts (OS, glibc, fabric drivers, Cray PE, modules system, shared filesystem) live at the top level; per-class facts (CPU target, GPU presence, build-stage paths, role) live inside `node_types[*]`. ClusterInspector populates this with a two-phase probe + merge model. A `stack.yaml` lane names its `runtime_node_type` explicitly — no defaulting — and the render step pulls the lane's CPU target and GPU block from that entry. | Never — one profile per system is the correct level of grouping; node-class facts scale inside it. |
| Package-set expansion granularity | All specs live in `package-sets/<name>.yaml`. `stack.yaml.lanes[*].package_set` references one set by name; the render step expands the set into the lane's `spack.yaml`. The stack file lists *which* sets to use, never the specs themselves. | Never — this is the platform/intent split applied to specs. |
| Minimum Spack version | **1.1.1** is the committed floor. Newer Spack (including 1.2) is supported and benefits from the jobserver and spec groups; older Spack lacks `include::` semantics and is not supported. | Spack 1.2 stabilizes and the team adopts it as the new floor; revisit the table in §Spack Version Floor. |
| Lmod beyond the Tcl baseline | The committed module format is **Tcl** because Lmod reads Tcl and Tcl-only systems cannot read Lua. On Lmod-equipped systems, the same install tree can additionally produce an Lmod tree via `spack -e <env> module lmod refresh -y` and serve both module roots in parallel. Lmod's `family` directive and hierarchy features are *not* relied on; the design's conflict mechanism and front-door modules give the same behavior portably. | Never for the Tcl baseline; the optional Lmod tree is per-site choice and does not affect the core design. |
| Release artifact storage | Lockfiles (`spack.lock` per lane) and the release manifest are committed to the source repository under `releases/<tag>/<system>/<stack>/`. The runtime release tree under `/shared/stack/releases/<tag>/<system>/<stack>/` uses the same relative shape but also contains rendered Spack inputs, views, and modulefiles. Build-cache contents are *not* committed — they live on the buildcache mirror (file URL or S3-compatible). Build logs are CI/Ansible artifacts, attached to the release record but not committed. | Build-cache contents grow past the source repo's practical size for some other reason; revisit per-system. |
| Repo layout split | `cray-*` vs `linux-*` at the top level is **not** the split. The repository is system-agnostic; per-system reality lives in `profile.yaml` and per-platform behavior lives in the scopes the render step selects. | Never — this is the generic-repo decision. |
| Core sharing across compilers | **Per-compiler Core** is the committed model — each compiler builds its own Core view at its own path. Cross-compiler shared Core is a future, evidence-gated optimization (see §Per-Compiler Core, Not Shared Core). | Measured overlap across compiler Cores is large and expensive enough to justify the `include_concrete`/foundation-cache extraction work. Until then, per-compiler Core stays. |
| GPU lane Core composition | The GPU lane uses its own compiler's Core. Under the committed Option B default the GPU lane is GCC-hosted, so `gcc/gpu-craympich-<arch>` ↔ `gcc/core`. Named exception lanes follow the same rule with their own host compiler: a ROCmCC exception lane uses `rocmcc/core`, an NVHPC exception lane uses `nvhpc/core`. No separate "gpu-core" layer in any case. | Never — this falls out of the per-compiler Core model. |
| GPU vs. MPI as lane kinds | **GPU is its own lane kind, not an MPI sub-type.** A GPU lane is a *superset* of the matching MPI lane (it contains the same MPI-aware science libraries plus GPU-arch-pinned packages) and is pinned to one GPU class via `runtime_node_type`. One GPU lane per GPU class on a system. GPU lanes are not "MPI + a GPU add-on layer" — there is no GPU sub-load; users pick exactly one lane, and the GPU lane has everything that lane needs. See §Why GPU Is A Separate Lane Kind. | A real workload pattern materially benefits from a GPU-no-MPI sub-kind, which has not been observed yet. |
| ClusterInspector module enumeration | **Three-phase hybrid: auto-discover by name pattern, narrow with operator hints, verify by load-and-probe.** The hints file lives in source control at `systems/<system>/inspector-hints.yaml` and is the committed override mechanism (CLI flags exist for one-off probes but the hints file is what persists). See §Module Enumeration: Auto-Discovery Plus Hints. | A site exposes externals through something other than modules (rare); add the appropriate discovery mechanism. The hints + verify model still applies. |
| Host compiler for GPU lanes | **GNU host by default.** GNU + CUDA on NVIDIA, GNU + ROCm on AMD. NVHPC, ROCmCC, and AOCC appear only as narrow exception lanes scoped to codes that specifically need them (OpenACC/CUDA Fortran/`-stdpar` for NVHPC; AMD-vendor codes for ROCmCC; CPU-bound host code for AOCC). See §Host-Compiler Policy For GPU Lanes. | A specific code's programming model demands the vendor compiler; that lane is added without changing the default. |
| Cray PE + GPU lane assembly | **Option B: `PrgEnv-gnu` + standalone GPU toolkit module** (`rocm/<v>`, `cudatoolkit/<v>`) + the GCC-flavor cray-mpich. The lane compiler is `%gcc_craympich`; the GPU toolkit comes from the `configs/gpu/<vendor>` scope; the front-door module loads PrgEnv-gnu + GPU toolkit module + cray-mpich at runtime. Option A (`PrgEnv-amd` / `PrgEnv-nvidia` all-in-one) appears only as the NVHPC or ROCmCC exception lane; Option C (`PrgEnv-cray` + GPU toolkit) only as the CCE-host GPU lane. | A vendor-PrgEnv-required code appears; the exception lane is added without changing the default. |
| Concretizer `unify:` | **`unify: when_possible`** in every environment, because science lanes carry multi-version stacks and the foundation single-version rule is enforced explicitly with `require:` in the common scope. | Multi-version policy is abandoned entirely. |
| Concretizer `reuse:` | Build-time environments (science lanes, core, foundation) → `reuse: true`. Pipeline-driving environments (input to `spack ci generate`) → `reuse: false`. See §Concretizer Posture Per Environment Kind. | Never — this is structural. |
| Build-cache keying | **OS/glibc + Spack/package-repo generation**, with an optional profile external-ABI token when one mirror spans incompatible same-OS site/vendor external surfaces. Compiler/MPI/target are directory labels for human readability, not reuse boundaries. See §Build-Cache Keying. | Never — the hash already enforces spec correctness, but the bucket still needs clear reuse boundaries; per-compiler keying actively strands the foundation. |
| OpenSSL / curl provenance | **System externals** with `buildable: true` and `prefer:`/`require:` steering. The system admins patch them; the stack does not own that treadmill. Stack-built OpenSSL is a per-consumer documented exception (e.g., a consumer needs a newer API than the system ships). | The system OpenSSL falls out of vendor support entirely; revisit per-system. |
| Cray MPICH provenance | **Platform-backed external** with per-flavor `prefix:` and `modules:`. Spack-built MPI on Cray is forbidden for production lanes; the fabric tuning lives in cray-mpich. | Never on Cray. |
| Cray PE version pinning | The initial build-out pins to **one** PE version (the latest the profile reports), and older point releases are out of support. PE version becomes a future lane dimension when a second version needs support. | A second PE version becomes required and is added as a parallel lane. |
| `modules:` external usage | Reserved for the **Cray PE** case (compilers + cray-mpich). Site MPI on non-vendor systems uses `prefix:` unless a concrete reason forces `modules:`. | Never as a default; case-by-case for new vendor stacks that genuinely require modules. |
| Lane-runtime-module rule | A lane built on module-provided externals → front-door module loads them at runtime. A fully Spack-built lane → self-contained, no platform module prereqs. See §Lane Runtime Module Requirements. | Never — this is structural. |
| Provenance taxonomy | Four classes: `Stack-built`, `Platform-backed`, `Site-external`, `Spack-built`. Emitted on every package module via `STACK_PACKAGE_PROVENANCE` and a `module-whatis` suffix. | Never; the four classes cover every real source. |
| `link:` policy on views | **`link: roots`** everywhere. Spack's default `link: all` is not used. | Never — the per-package module model depends on roots-only. |
| Default projection | **`{name}/{version}`** in every production view. Richer projections only for collisions a single view must actually hold. | Never as the default. |
| Promotion model | **Gated manual symlink swap.** A green build does not auto-promote. `release.promotion: gated_manual` is the committed default; `auto` is available per-stack but discouraged for production. | Never for production stacks. |
| Previous release retention | Default **2 previous releases** kept loadable. Ansible's promote role refuses to delete a release tree if `current` points at it. | Per-stack override is fine; the default stays 2. |
| Naming on user-facing modules | `<modules.module_root>/<compiler>/<lane>` — e.g., `CSE/CCE/mpi-craympich`. `modules.init_module` (for example `cse-init`) is only the bootstrap module that exposes the release's module root. The system name is not in the user-facing module path; it shows up in internal release directories and in `STACK_RELEASE`. | Never. |
| Serial/MPI naming on packages | No suffixes — `hdf5`, not `hdf5-mpi`. The loaded lane disambiguates via MODULEPATH. | The same MODULEPATH is forced to expose both lanes simultaneously; until then, no suffixes. |
| Module hierarchy style | **Collapsed** front-door (one module per lane) as the committed default. Lmod-native granular cascade is an optional add-on per site, not the primary surface. | Never as the default. |

### Genuinely Open Questions

These are the questions left, narrowed to ones that need real evidence
before settling. Each has a working assumption written next to it so the
stack ships with a position; the position can be revisited when evidence
arrives.

| Question | Working assumption | What would settle it |
|---|---|---|
| First two systems to prove the design end-to-end | One Cray + one generic Linux HPC system. The Cray slot is whichever Cray-PE system has compute time available first; the Linux slot is a generic Linux HPC node with site OpenMPI. | When two specific candidate systems are named, lock them in §Example Cray Flow / §Example Generic Linux HPC Flow. |
| Whether `cluster-inspector verify` should additionally drift-detect against the installed lockfile | Not in v1. Profile verification is read-only against the live system; comparing against an installed release is the release-manifest's job. | A real drift incident on a production release. |
| Whether to ship per-package legacy env vars (`HDF5_DIR`, `NETCDF_ROOT`) | Not by default. Modern CMake/`pkg-config` discovery via `CMAKE_PREFIX_PATH` and `PKG_CONFIG_PATH` is the convention. | A user community whose build chain needs the legacy variables; add as render-step overrides per package. |
| Whether to support `spack ci generate` runners on login nodes in v1 | Not in v1. Use `srun`/scheduler fan-out + shared cache for the first deployments; revisit when the manual fan-out hits a friction point persistent runners would remove. | Concrete operational pain that a login-node GitLab runner would solve. |
| Whether a universal cross-system Core baseline is feasible | Not assumed. Foundation cache is keyed by OS/glibc, so each system maintains its own Core. A genuinely universal Core would require standardizing a common OS/glibc build base across systems. | Two systems with the *same* OS/glibc want to share Core; until then, per-system Core. |
| Whether build-cache contents should be signed | Not by default in v1. The committed setting is `buildcache.signed: false`. Stack-built binaries are pushed unsigned to file-URL mirrors inside the trust boundary. | A multi-tenant mirror that crosses the trust boundary; turn on signing then with `buildcache.signed: true` and a key management section to be written. |
| Where `release-manifest.yaml` history lives | Committed under `releases/<tag>/<system>/<stack>/release-manifest.yaml` in the source repo. CI/release records may *additionally* link to it. | Repo size becomes a practical issue. |

This list is intentionally short. Every previously-open question that
could be answered with a defensible default has been answered above and
moved to Committed Decisions. The remaining questions are the ones where a
wrong-by-default answer would be worse than no answer, and they wait for
the evidence that picks the right one.
