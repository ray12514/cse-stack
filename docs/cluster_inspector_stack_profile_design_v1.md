# Cluster-Inspector Stack Profile Design v1

## Purpose

`cluster-inspector` is the optional system-facts helper for the Spack stack
generation model described in `docs/spack_stack_generation_design_v6.md`.

Its job is intentionally narrow: produce a reviewed, commit-ready
`systems/<system>/profile.yaml` that the stack renderer can consume. A human may
still write the same file by hand. The renderer, Spack build, deployment, and
release promotion do not call back into `cluster-inspector`.

The tool name for the new version is `cluster-inspector`. There is no
compatibility alias requirement for the older `clusterinspector` command name.

## Document Set

This design is intentionally split into two documents:

| Document | Purpose |
|---|---|
| `cluster_inspector_stack_profile_design_v1.md` | Product boundary, CLI contract, repository shape, packaging constraints, and implementation phases. This is the design/build plan. |
| `cluster_inspector_profile_extraction_map_v1.md` | Field-by-field extraction map for `profile.yaml`: where each fact comes from, how it is normalized, confidence level, and fallback behavior. This is the probe/metric map. |

When deciding what to implement next, use the implementation phases in this
document. When deciding how a profile field is discovered, use the extraction
map.

## Product Boundary

`cluster-inspector` is a profile producer, not a general cluster operations
suite. It may reuse probe ideas from the older `clusterinspector` repository,
but the durable contract is the v6 stack `profile.yaml` shape.

| Boundary | Decision |
|---|---|
| Primary artifact | One `profile.yaml` per system. |
| Primary consumer | The stack render step. |
| Primary command | `cluster-inspector profile ...`. |
| Durable schema | The v6 stack profile schema. |
| Diagnostics | Allowed, but not part of the render contract unless explicitly documented. |
| Old repo role | Source material for reusable probes and execution patterns, not the schema baseline. |

## Non-Goals

- No Spack calls: no `spack spec`, `spack external find`, `spack config`,
  `spack concretize`, or `spack install`.
- No render: it does not write `spack.yaml`, Spack config scopes, modulefiles,
  views, lockfiles, or release manifests.
- No template or contract generation: it does not write `templates/<set>/`,
  `contract.yaml`, or `stack-defaults.yaml`. Profile corpora may feed
  `spack-composer assess-profiles` and `spack-composer scaffold-templates`, but
  those advisory maintainer tools live on the stack side.
- No deploy: it does not copy files to a release tree, change permissions, submit
  production builds, or swap `current` symlinks.
- No package decisions: it does not decide what the stack should build, which
  packages are roots, or what package versions are supported.
- No generated `packages.yaml`: Spack externalization policy belongs to stack
  templates and the render step.
- No benchmark validation in `profile.yaml`: benchmark results and smoke-test
  outcomes belong in release verification artifacts, not durable system facts.
- No broad fleet-health product in the critical path: fabric health reports may
  exist as diagnostics, but the stack design depends only on `profile.yaml`.

## Self-Contained Runtime Requirement

Once built, `cluster-inspector` must be self-contained from the tool-distribution
perspective. Running it on a target system must not require the source checkout,
the `cse-stack` repository, Spack, Ansible, network access, or a language runtime
managed by the target site.

Allowed runtime inputs are explicit operator inputs:

- Command-line arguments.
- An optional `inspector-hints.yaml` file.
- Explicit output paths.
- The target system's observable state, plus explicitly requested build-stage
  writability checks.

Allowed host interactions are read-only probes plus tightly scoped build-stage
tests:

- Standard system commands when present, such as `uname`, `ldd`, `mount`,
  `findmnt`, `df`, `lspci`, `nvidia-smi`, `rocm-smi`, `fi_info`, `ucx_info`, and
  module commands.
- Scheduler launch commands only when the operator requests a node-type probe,
  such as `srun` or PBS equivalents.
- Temporary write/remove tests only for declared build-stage candidate paths, to
  verify writability. These tests must create only tiny probe files, clean up
  after themselves, and never run outside the candidate paths.

Self-contained also means the tool ships its own versioned resources:

- The v6 profile schema validator.
- GPU architecture and toolkit-ceiling mapping tables.
- Module-name classification patterns.
- ROCm component package resource tables used to describe observed installed
  ROCm trees.
- Output renderers for YAML, JSON diagnostics, and human summaries.

Missing host commands must degrade into explicit `unknown` facts with evidence,
not into crashes, unless the missing fact is required for a renderable profile.
When required facts are missing, `cluster-inspector` must fail validation before
writing a profile unless the operator explicitly asks for an incomplete diagnostic
artifact.

## Implementation Language Decision

The preferred implementation language for the new tool is **Go**.

Rationale:

- The tool is optional. Users who do not want to build or modify it can still
  write `profile.yaml` manually from the templates and schema.
- The primary operational requirement is a self-contained artifact that can be
  copied to restricted HPC systems and run without managing a Python environment.
- The tool mostly shells out to read-only host commands, parses text, validates a
  schema, and writes YAML/JSON. Go is well-suited to that shape.
- Go's single-binary distribution model fits Cray/SLES/RHEL sites where Python
  versions and site packages vary.

Python remains useful as source material because the older `clusterinspector`
repo already contains probe ideas and parsing logic. The new repo should treat
that code as a reference implementation to mine, not as the runtime or schema
baseline.

The decision is not a statement that every stack maintainer must know Go. The
manual profile path remains first-class, and `cluster-inspector` remains a helper
rather than a correctness dependency.

## Relationship To The Stack Design

The stack design separates facts from intent:

| File | Owner | Contents |
|---|---|---|
| `profile.yaml` | System owner / inspector | Observed platform facts. |
| `stack.yaml` | Stack owner | Desired stack behavior and root specs. |
| `templates/<set>/contract.yaml` | Framework/template owner | Vocabulary and resolver semantics. |
| `templates/<set>/stack-defaults.yaml` | Framework/template owner | Defaults for modules, externals, buildcache, release policy. |

`cluster-inspector` only helps with the first row. It must not infer stack
intent from system facts. For example, it may report that Cray MPICH exists, but
it does not decide whether a stack should prefer platform MPI. It may report ROCm
component externals, but it does not decide which GPU packages the stack builds.
It also does not scaffold template sets or write template contracts; its profiles
are inputs that `spack-composer` can analyze when maintainers curate stack-side
templates.

## Output Contract

The primary output is YAML matching the v6 profile schema. The profile is a
single system document with one `node_types:` map, not one profile per node.

Required top-level blocks:

```yaml
schema_version: 1
system: {}
os: {}
fabric: {}
modules_system: {}
vendor_cray: null
compilers_external: []
mpi: []
gpu_toolkit_modules: {}
filesystem: {}
node_types: {}
capabilities: {}
```

The generated profile must be deterministic for the same inputs and observed
facts. YAML key ordering should be stable and optimized for review, not for the
implementation's internal data structures.

## Evidence And Confidence

Each probed fact should be traceable to evidence. The durable `profile.yaml`
should stay readable, so evidence can be represented in one of two ways:

- Inline compact fields for facts that benefit from review, such as
  `confidence: probed | inferred | unknown` and a short `source` string.
- A sibling diagnostic report emitted only when requested, such as
  `--evidence profile-evidence.json`.

The profile itself must not hide required uncertainty. If a fact is inferred,
that inference should be visible. If a fact is unknown, render-time validation
should later fail when that fact is required by a selected stack.

## Probe Model

The tool has three conceptual operations:

| Operation | Purpose |
|---|---|
| `probe-system` | Collect system-wide facts from the login/build host. |
| `probe-node` | Collect one node type's CPU, GPU, and build-stage facts. |
| `merge` | Merge system and node fragments into one deterministic `profile.yaml`. |

The all-in-one `profile` command composes those operations for the common case.
The lower-level commands remain useful when scheduler access is restricted or an
operator wants to hand-edit fragments before merge.

### System-Wide Facts

System-wide probes run once per system, usually on the login node.

| Fact | Examples |
|---|---|
| System identity | `system.name`, `system.family`, optional description. |
| OS identity | OS name, major/minor version, glibc version. |
| Module system | Lmod vs Tcl modules, version, MODULEPATH roots. |
| Fabric | Slingshot, InfiniBand, RoCE, Ethernet; driver libraries and userspace. |
| Cray PE | PE version, CCE/GCC/ROCmCC/NVHPC availability, Cray MPICH flavors. |
| Site compilers | AOCC, GCC, Intel, NVHPC, ROCmCC, or other compiler externals. |
| MPI inventory | Cray MPICH, site OpenMPI, MPICH, MVAPICH, Intel MPI, provider prefixes/modules. |
| GPU toolkit modules | ROCm/CUDA toolkit modules and component prefixes. |
| Shared filesystems | install tree, source cache, buildcache candidates. |

### Per-Node-Type Facts

Per-node probes run once for each node class that matters to builds or runtime.

| Fact | Examples |
|---|---|
| Role | `build_host`, `runtime`, or `both`. |
| CPU | detected arch, preferred target, alternates. |
| GPU | vendor, driver version, toolkit ceiling, arch label such as `gfx90a` or `sm_90`. |
| Build stage | writable candidates, visibility, free space, inode data, mount options. |

## CLI Contract

Primary all-in-one command:

```bash
cluster-inspector profile \
  --system example-cray \
  --hints systems/example-cray/inspector-hints.yaml \
  --node-type login=this:role=build_host \
  --node-type cpu_compute=srun:partition=cpu_compute:role=runtime \
  --node-type gpu_compute_mi250x=srun:partition=gpu,constraint=mi250x:role=runtime \
  --node-type gpu_compute_mi300a=srun:partition=gpu,constraint=mi300a:role=runtime \
  --output systems/example-cray/profile.yaml
```

Lower-level commands:

```bash
cluster-inspector probe-system \
  --system example-cray \
  --hints systems/example-cray/inspector-hints.yaml \
  --output probes/system.yaml

cluster-inspector probe-node \
  --node-type gpu_compute_mi250x \
  --role runtime \
  --output probes/gpu_compute_mi250x.yaml

cluster-inspector merge \
  --system-fragment probes/system.yaml \
  --node probes/login.yaml \
  --node probes/cpu_compute.yaml \
  --node probes/gpu_compute_mi250x.yaml \
  --output systems/example-cray/profile.yaml

cluster-inspector verify systems/example-cray/profile.yaml
```

The command should write only to paths explicitly passed by the operator.
Printing to stdout is allowed when no `--output` is provided.

## Module Discovery And Hints

Most relevant externals on target systems are module-backed: Cray PE compilers,
Cray MPICH, ROCm/CUDA toolkits, site MPI, and site compilers. Discovery must be
repeatable, so operator hints are first-class.

Discovery flow:

1. Enumerate module candidates with `module avail`, MODULEPATH walks, and known
   naming patterns.
2. Apply `inspector-hints.yaml` includes, excludes, and explicit extras.
3. Verify surviving candidates in clean shells with `module load <candidate>`.
4. Record verified facts into `profile.yaml`.
5. Record rejected or ambiguous candidates in diagnostics, not in the durable
   profile facts.

### Shell Invocation Discipline

Probes must either preserve the operator-selected environment or deliberately
start from a clean one. They must never accidentally get a third state from
login-shell startup files.

Rules:

- Environment-passthrough probes inspect the current compiler, MPI, or module
  context. Run them with a non-login shell such as `bash -c '<probe>'`, not
  `bash -lc`, `bash --login`, `sh -l`, or any flag that sources login startup
  files.
- Module-verification probes start from a controlled non-login shell, clear or
  purge module state as needed, load exactly the candidate modules, and then
  probe. They should not inherit personal shell startup state either.
- Operators should keep inspector-affecting module loads and environment
  overrides out of personal shell startup files. Use CLI arguments and
  `inspector-hints.yaml` for persistent inspector inputs.

The reason is practical: many HPC sites initialize default programming
environments from login-shell startup files. A probe that uses a login shell can
silently replace the compiler or MPI the operator intended to inspect.

Example hints file:

```yaml
schema_version: 1

compilers:
  include:
    - cce/17.0.1
    - gcc-native/13
  exclude_patterns:
    - "gcc-data/*"
    - "gcc-toolset/*"

mpi:
  include:
    - cray-mpich/8.1.29

gpu_toolkits:
  include:
    - rocm/6.0.0

extras:
  compilers:
    - module: aocc/4.2
      name: aocc
      version: "4.2"
      prefix: /opt/AMD/aocc-compiler-4.2
      languages: [c, c++, fortran]
```

Hints are inputs to the inspector, not replacements for the profile. The stack
renderer consumes only `profile.yaml`.

### Iterative Bring-Up Loop

Bringing up a new system follows a short discover-narrow-verify loop. The
first run almost never produces a final profile — module-name heuristics
will pick up entries that look like compilers or MPIs but are not real
choices for the stack (`gcc-data/9.3`, `gcc-toolset/12`, intermediate
`cudatoolkit/11.x` versions). The hints file converges quickly:

1. **First run, no hints.** Run `cluster-inspector profile --system <name>
   --node-type ...` without `--hints`. The inspector auto-discovers
   candidates, verifies the load-and-probe successes, and writes a draft
   `profile.yaml`. Diagnostics name the rejected candidates and the
   ambiguous ones.
2. **Review.** Read the draft profile and the diagnostics. Decisions to
   make: which compiler modules are real CSE compilers; which MPI
   versions the stack supports; which GPU toolkit module is the one the
   stack should use; which fabric userspace modules matter.
3. **Author hints.** Write `systems/<name>/inspector-hints.yaml` with
   `include:` lists (canonical positive sets) and `exclude_patterns:`
   (categorical drops like `gcc-data/*`). Add `extras:` entries for
   anything auto-discovery missed.
4. **Re-run with hints.** `cluster-inspector profile --system <name>
   --hints systems/<name>/inspector-hints.yaml ...`. The profile narrows
   to the hint-approved set.
5. **Verify and iterate.** Run `cluster-inspector verify <profile.yaml>`
   to confirm schema and capability coverage. Repeat steps 2–4 until the
   profile is clean.
6. **Commit.** `profile.yaml` and `inspector-hints.yaml` go into source
   control together. Both are durable artifacts; the hints file is the
   committed override policy for this system.

The loop typically converges in two or three rounds on a fresh Cray
system, one or two on a generic Linux HPC system. PE upgrades and driver
bumps after that require a hints touch-up only if the upgrade changes a
module-naming convention; otherwise re-running the inspector against the
same hints just refreshes versions in place.

**What does not require iteration.** Node-type-specific facts (CPU
target, GPU arch, build-stage paths) come from per-node probes and are
not affected by the hints file. They typically land correct on the first
run and only re-probe when the node class changes (a new GPU partition,
a kernel/glibc bump).

## What To Extract From The Existing `clusterinspector` Repo

The older repo contains useful implementation material, but its product shape is
too broad for the stack-profile helper. Extract selectively.

| Keep | Why |
|---|---|
| Local and SSH runner abstractions | Useful execution layer for read-only probes. |
| Scheduler-aware host resolution ideas | Useful for node-type probing through Slurm/PBS. |
| Fabric passive probes | Good input for `fabric.*` facts. |
| Evidence model | Good basis for explainability and diagnostics. |
| GPU topology parsing | Useful, but output must become `node_types[*].gpu`. |
| Build-stage path scan | Useful, but output must be observed candidates only. |
| Module-system detection | Useful starting point for full module enumeration. |

| Leave Behind Or Rework | Reason |
|---|---|
| Representative-node profile schema | v6 needs one merged system profile with `node_types`. |
| `vendor_substrate` | Replace with v6-native `vendor_cray`, `compilers_external`, `mpi`, and `gpu_toolkit_modules`. |
| `externals_policy` | Policy belongs to stack defaults and render templates. |
| `generate spack-packages` | Spack config generation belongs to render tooling. |
| `profile --format spack-packages` | Same reason: inspector should not write Spack config. |
| Stack-type/risk classifiers in profile output | Useful diagnostics, not durable platform facts. |
| Benchmark validation merge into profile | Release validation belongs in release artifacts. |
| Fabric as primary product surface | Keep as supporting diagnostics or internal probe library. |

## New Repository Shape

Recommended layout for the new repo:

```text
cluster-inspector/
  go.mod
  go.sum
  README.md
  cmd/
    cluster-inspector/
      main.go
  docs/
    design.md
    profile-schema.md
    probe-reference.md
    packaging.md
  internal/
    commands/
      profile.go
      probe_system.go
      probe_node.go
      merge.go
      verify.go
    model/
      profile.go
      fragments.go
      evidence.go
      validation.go
    probes/
      system.go
      modules.go
      cray.go
      compiler.go
      mpi.go
      gpu.go
      fabric.go
      filesystem.go
      node.go
    hints/
      schema.go
      apply.go
    output/
      yaml.go
      json.go
      human.go
    resources/
      gpu_toolkit_ceilings.yaml
      rocm_components.yaml
      module_patterns.yaml
      profile_schema.yaml
  tests/
    fixtures/
      example-cray/
      example-linux/
```

The `cmd/cluster-inspector` package builds the only supported command. Resource
files should be embedded into the binary with Go's `embed` package so the binary
does not need to locate files relative to a source checkout.

## Packaging Plan

The built tool should be easy to move onto restricted HPC systems.

Recommended distribution targets:

- A single `cluster-inspector` binary per supported OS/architecture.
- Release archives containing the binary, license, and checksum.
- Embedded resource files included in the binary.
- Optional signed checksums if the deployment environment requires provenance.

Runtime rules:

- Do not read schema or resource files from a source checkout.
- Do not read files relative to the current working directory unless the user
  passed those paths explicitly.
- Do not require network access.
- Do not shell out to Spack, Ansible, Git, or package managers.
- Gracefully report missing optional host commands.

## Implementation Plan

### Phase 1: Contract And Skeleton

- Create the new repo and package as `cluster-inspector`.
- Implement CLI skeleton for `profile`, `probe-system`, `probe-node`, `merge`,
  and `verify`.
- Add v6 profile schema models and deterministic YAML output.
- Add validation for required blocks and stable key ordering.

Acceptance:

- A hand-written fixture profile validates.
- The tool can print a minimal homogeneous local profile skeleton.
- The built binary runs without the source checkout.

### Phase 2: System-Wide Probes

- Port or rewrite OS, glibc, module-system, fabric, filesystem, compiler, MPI,
  Cray PE, and GPU toolkit probes.
- Add evidence capture for every probe.
- Add read-only failure handling and `unknown` confidence behavior.

Acceptance:

- A generic Linux login-node system fragment is produced.
- A Cray login-node system fragment includes `vendor_cray` and Cray MPICH flavor
  candidates when modules are available.
- No probe requires Spack.

### Phase 3: Node-Type Probes And Merge

- Implement `probe-node` for CPU target, GPU facts, and build-stage candidates.
- Implement deterministic merge into one `profile.yaml`.
- Support `this:`, `srun:`, and PBS-style node-type runners.

Acceptance:

- Login + CPU compute + one GPU class merge into one valid profile.
- Two GPU node types with different arch labels merge without duplication.
- Re-running merge on the same fragments produces byte-identical YAML.

### Phase 4: Module Hints And Clean-Shell Verification

- Implement module enumeration and classification.
- Implement `inspector-hints.yaml` include/exclude/extras semantics.
- Verify module-backed candidates in clean shells.
- Emit diagnostics for ambiguous, rejected, or failed candidates.

Acceptance:

- Hints can exclude false compiler matches such as `gcc-data/*`.
- Cray PE compiler and Cray MPICH modules are verified and recorded with modules
  and prefixes.
- ROCm toolkit modules produce component external facts, not only `rocm/<v>`.

### Phase 5: Full Stack Fixtures

- Add golden fixtures aligned with the v6 design examples.
- Add `cluster-inspector verify` checks against the schema and semantic rules.
- Add documentation examples for Cray and generic Linux HPC.

Acceptance:

- `example-cray` fixture validates with CPU + MI250X + MI300A node types.
- `example-linux` fixture validates with site MPI and optional Spack-built MPI
  capability inputs.
- Render-time required profile facts are present for the v6 stack examples.

## Acceptance Criteria For v1

- Produces a v6-valid `profile.yaml` for a Cray system with login, CPU compute,
  and at least one GPU node type.
- Produces a v6-valid `profile.yaml` for a generic Linux HPC system with site MPI.
- Supports hand-written profile validation without requiring any probes.
- Supports hints-based module discovery.
- Emits deterministic YAML for the same inputs.
- Runs as a self-contained built artifact without the source checkout.
- Does not call Spack, render stack files, generate Spack config, deploy files, or
  encode package/root-spec decisions.

## Open Questions

- Should evidence live inline in `profile.yaml`, in a sibling diagnostics file,
  or both?
- How much scheduler syntax should v1 support beyond `this:` and `srun:`?
- Should the tool ever support SSH in v1, or should all remote/node-type probing
  go through scheduler launch commands?
- Which OS/architecture build targets should the first binary release publish?
