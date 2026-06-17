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
| Helpers | `cluster-inspector`, `spack-composer`, Ansible | Reduce labor, but remain optional |

The stack must remain understandable and buildable without `cluster-inspector`,
without `spack-composer`, and without Ansible. Those tools reduce error and
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
| **Package set** | A named list of root specs grouped by purpose (`core-foundation`, `science-full`, `<stack>-apps`, etc.). One file per set under `package-sets/`. Referenced by name from `stack.yaml.builds[*].package_set`. |
| **Package repository** | A Spack package repository owned by the stack, such as `package-repos/cse/`. Holds internal packages and recipe overrides. It is stack source, not system fact. Render emits `repos.yaml` so Spack sees it. |
| **Template set** | The collection of Jinja-style templates the render step expands. Versioned by name (`v6`) and selected by `stack.yaml.templates.set`. |
| **Template contract** | `templates/<set>/contract.yaml`. The finite vocabulary accepted by a template set for build classes, toolchains, node selectors, and target policies. `stack.yaml` names these values; the contract defines what they mean. |
| **Stack defaults** | `templates/<set>/stack-defaults.yaml`. Template-owned defaults merged under a user's `stack.yaml` so package managers do not repeat module, externals, buildcache, and release boilerplate. |
| **Profile corpus** | The set of committed `systems/*/profile.yaml` files for known systems. Maintainers use it to assess template coverage and scaffold new template support. |
| **`per_system` block** | Optional system-scoped narrowing inside `stack.yaml`. It intersects a generic build request with profile names for one target system without polluting the portable top-level build intent. |
| **Starter stack** | A small copy-and-edit `stack.yaml` under `stacks/_starters/` that shows a common adoption shape such as one package, CPU+GPU app, or CSE-style package-set reuse. |
| **Lane** | A single Spack environment representing one (compiler, kind) pairing within a stack. Examples: `gcc/core`, `cce/serial`, `cce/mpi-craympich`, `gcc/gpu-craympich-gfx90a`. A lane has its own `spack.yaml`, its own lockfile, its own view, and its own module root. |
| **Lane kind** | A template-selected lane category. The default taxonomy is `core` / `serial` / `mpi` / `gpu`, but a simple stack may use only one payload lane and no separate Core. The kind controls which scopes the lane includes and which package-set blocks it expands. |
| **Front-door module** | The single user-facing module that selects a lane. Loading it prepends the lane's package MODULEPATH and records/checks required platform-module prerequisites. It does not silently load platform modules unless a site explicitly enables autoload policy. Example: `CSE/CCE/mpi-craympich`. |
| **Direct application module** | A public package/application module that users load without a separate lane selector. It carries its lane's provenance, conflicts, and platform-module prerequisite checks directly. Example: `fun3d/14.2-gpu-gfx90a`. |
| **Scope** | A directory of Spack config files (`packages.yaml`, `toolchains.yaml`, etc.) that a lane's `include::` list pulls in. Lives under `templates/configs/<scope-name>/` in source and `configs/<scope-name>/` in the rendered workspace. |
| **Common scope** | `configs/common/`. The scope every lane includes. Holds `concretizer.yaml`, `mirrors.yaml`, foundation `require:` pins, and other policy that applies to every lane. |
| **Platform scope** | Any scope whose contents come from platform/system facts (`configs/vendor/cray/`, `configs/os/rhel8/`, `configs/mpi/cray-mpich/`, `configs/gpu/amd-rocm/`). |
| **Render workspace** | The on-disk tree the render step produces — `configs/` + `environments/` + manifest — that Spack reads. Ephemeral by design; regeneratable from sources. |
| **Release** | One concretized, built, verified copy of the stack with a unique tag (e.g. `2026.06`). Source records live under `releases/<tag>/<system>/<stack>/`; runtime trees live under `/shared/stack/releases/<tag>/<system>/<stack>/`. The `current` symlink points at the active runtime release. |
| **Foundation cache** | The build-cache lane that holds Core builds when a stack renders Core lanes. Keyed by OS/glibc + Spack/package-repo generation + baseline target (e.g. `foundation/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/x86_64_v3`). An optional profile-ABI token may be inserted when one mirror spans incompatible site/vendor external surfaces. Read by payload lanes on a matching system when the stack has Core/foundation lanes. |
| **Payload cache** | The build-cache lane that holds non-Core package builds (CSE calls these science serial/MPI/GPU builds). Keyed by the same OS/glibc + generation boundary; compiler/MPI/target appear in lane names and manifests for human readability, not as reuse boundaries. |
| **Projected view** | A symlink tree generated by Spack that exposes installed packages at clean `{name}/{version}` paths instead of raw hashed install prefixes. The user-facing surface of a lane. |
| **`include::`** | The double-colon Spack directive that *replaces* the built-in include list. The committed isolation mechanism for production lanes. |
| **Toolchain** | A named bundle of compiler-and-MPI-provider constraints declared in `toolchains.yaml` and applied to a spec as `%toolchain_name`. The mechanism that pins compiler-matched MPI flavors (the canonical case: Cray cray-mpich's per-PrgEnv builds). |
| **Provenance class** | One of `Stack-built` / `Platform-backed` / `Site-external` / `Spack-built`. Emitted into every package module via `STACK_PACKAGE_PROVENANCE` so users can see where a binary came from. |
| **Helper** | An optional automation tool — `cluster-inspector`, `spack-composer`, Ansible — that reduces operator labor but is not load-bearing for correctness. The manual workflow always remains executable. |
| **Manual workflow** | The reference end-to-end procedure that uses no helpers — hand-written profile and stack files, hand-rendered (or hand-edited) workspace, hand-run `spack` commands. Every helper must be replaceable by this without changing the model. |

## Guiding Principles

| Principle | Practical meaning |
|---|---|
| Spack is the build source of truth | Spack environments, lockfiles, install trees, modules, views, and build caches define what was built. |
| The stack is the user interface | Users load stack modules and clean package modules. They should not need to know Spack internals. |
| Separate intent from platform reality | `profile.yaml` describes the system. `stack.yaml` describes the desired stack. |
| Keep config isolation explicit | Production environments use `include::` to read only selected stack scopes plus Spack defaults. |
| Keep helper tools optional | `cluster-inspector`, `spack-composer`, and Ansible automate steps but do not define the model. |
| Prefer lane separation where useful | Variant-rich stacks should separate Core, serial, MPI, GPU, or site-specific payload lanes. Simple stacks can use one lane and direct package modules. |
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
   install     projected     public        spack.lock   build cache
    tree         views        entry        per lane     foundation
   (hashed)    {name}/        modules                   + payload
              {version}       + package                  lanes
                              modules
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

**One generated tree in this picture is deterministic but ephemeral**: the
rendered workspace should be byte-identical for the same inputs, but it is not
committed source. It can be deleted and re-rendered at any time. Treat the
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

## End-To-End Operating Model

The framework exists so a package manager can bring ordinary Spack specs and get
a correct stack on several different systems. The extra machinery is there to
hide repeated system work, not to make package managers learn another Spack.

| Step | Owner / tool | Artifact | Purpose |
|---|---|---|---|
| Probe one system | `cluster-inspector` or system owner | `systems/<system>/profile.yaml` | Record observed system facts: OS, compilers, MPI, GPU, fabric, filesystem, modules. |
| Assess the profile corpus | `spack-composer assess-profiles` | coverage report | Compare all known profiles against existing contracts/templates and identify missing OS, MPI, GPU, compiler, or package-repo support. |
| Scaffold new support | `spack-composer scaffold-templates` plus maintainer review | proposed template/contract stubs | Generate draft files for new observed patterns. The maintainer decides what becomes supported. |
| Curate support policy | framework/template maintainer | `templates/<set>/contract.yaml`, config templates, defaults | Define the finite vocabulary and supported compiler/MPI/GPU combinations. |
| Write package intent | package manager | `stacks/<stack>/stack.yaml`, optional package sets | List normal Spack specs and select build classes such as CPU, MPI, or GPU. |
| Explain valid choices | `spack-composer explain` | human-readable menu | Show valid compiler, MPI, GPU, and node selector names for one stack/template/system. |
| Render | `spack-composer render` or manual equivalent | `configs/`, `environments/*/spack.yaml`, manifest | Instantiate Spack input for one stack, system, and release. |
| Build | Spack and orchestration | install tree, lockfiles, buildcache | Concretize, fetch, install, test, and cache. |
| Publish | release tooling | views, modules, final manifest, `current` symlink | Expose the release to users after verification. |

The profile can list more than the stack uses. For example, a Cray profile may
report GCC, CCE, AOCC, NVHPC, Intel, Cray MPICH, CUDA, and ROCm. The contract
defines which combinations the template set supports. The stack narrows that
menu to the builds requested for a release. The render step then emits only the
concrete lanes selected by this intersection.

The maintainer-facing loop for a new or upgraded system is:

```text
profile.yaml added or updated
        │
        ▼
spack-composer assess-profiles
        │
        ├── covered by current templates → render/build normally
        │
        └── gap found → scaffold templates → maintainer review → commit support
```

This keeps system onboarding explicit. A version change that follows an existing
pattern should require only a profile update. A new OS family, MPI family, GPU
toolkit layout, or supported compiler/GPU combination requires template or
contract work.

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
concretizer policy, mirror declarations), followed by the selected
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
| `concretizer.yaml` | Shared concretization policy such as `unify: false`, `unify: when_possible`, and `reuse:`. |
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
| `concretizer: reuse: false` for pipeline-driving environments | 1.1 | Distinct from the build-time `reuse: true` used in payload lanes. |
| `concretizer: unify: when_possible` | 1.1 | Optional deduplication posture for narrow application lanes; CSE-style cross-product stack lanes normally use `unify: false`. |
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

### Three-Layer Version Model

The version constraint is split across three owners so each layer keeps its
own concern:

| Layer | Owner | Says what | Where it lives |
|---|---|---|---|
| **Floor** | Template maintainer | Minimum Spack version the template set's features require (e.g. `include::`, `toolchains.yaml when:`). | `templates/<set>/stack-defaults.yaml` → `spack.floor` (required when the template set is published). |
| **Pin** (optional) | Package manager | A tighter version constraint for one stack — useful when a stack has only been tested against a specific Spack version. May tighten the floor; never widens it. | `stack.yaml` → `spack.version` (optional). |
| **Root** (operational) | Site operator / CI | Where on disk Spack actually lives. Pure operator concern; the stack source never names a path. | `spack-build --spack-root <path>`. |

A stack expresses *which Spack versions are acceptable*. The site expresses
*where to find them*. Multiple Spack installs may coexist on disk;
`--spack-root` picks the one to use, and `spack-build` refuses to run if
that install's `spack --version` does not satisfy floor + pin.

### Acquiring And Installing Spack

`spack-composer` and v6 are silent on Spack acquisition by design — it is
an operational decision per site. The supported patterns are:

**Pattern 1 — Site module.** Spack is exposed as a module on the system
(`module load spack/1.1.3`). Common on Cray sites. After load,
`spack --version` reports the version and `which spack` reports the prefix.
`spack-build` uses `$PATH` (no `--spack-root` needed).

**Pattern 2 — Per-version clone (recommended for sites that want multiple
versions side-by-side).** One git clone per pinned tag, kept under a
shared directory under operator control:

```text
/shared/stack/spack/
  1.1.1/        # git clone https://github.com/spack/spack.git . && git checkout v1.1.1
  1.1.3/        # git clone https://github.com/spack/spack.git . && git checkout v1.1.3
  1.2.0/        # ...
  current -> 1.1.3        # optional convenience symlink; never the version-of-record
```

Each clone is immutable once installed: a version bump means a new
directory, not a `git pull` in place. The convenience symlink is for human
convenience only — `spack-build --spack-root` always points at the
explicit pinned directory, never the symlink, so the manifest records
what was actually used.

To install one version:

```bash
mkdir -p /shared/stack/spack/1.1.3
git clone https://github.com/spack/spack.git /shared/stack/spack/1.1.3
cd /shared/stack/spack/1.1.3
git checkout v1.1.3
# verify
./bin/spack --version
```

**Pattern 3 — Ansible-managed clone.** Same on-disk layout as Pattern 2,
but the clone-and-checkout is automated in an Ansible role. Recommended
when many build hosts need the same set of versions.

### Pointing Tools At A Specific Install

- **`spack-build`** (the committed default driver for stacks not on Ansible):
  pass `--spack-root /shared/stack/spack/<version>`. The script sources
  `<spack-root>/share/spack/setup-env.sh` and then runs `spack --version`,
  compares against `templates/<set>/stack-defaults.yaml.spack.floor` and
  `stack.yaml.spack.version`, and refuses to run on a mismatch. The version
  used is captured into `verify-results.yaml`; `publish-manifest` lifts it
  into `release-manifest.yaml.build_context.spack_version`.
- **Ansible**: either calls `spack-build` per host (delegating the check),
  or replicates the same floor+pin check using the same two source fields
  before invoking Spack directly.
- **Manual workflow**: an operator running bare Spack commands by hand is
  responsible for running `spack --version` themselves and confirming
  against the floor and any pin. The manual path remains executable but
  carries the version-mismatch risk that the helpers eliminate.

**Buildcache signing keys** are unrelated to Spack acquisition and stay
deferred per the §Committed Decisions row (`buildcache.signed: false` is
the v1 default). Key bootstrap is the topic to write when the first
multi-tenant mirror appears.

## Repository Layout

The repository layout should be generic enough to cover Cray systems and generic
Linux HPC systems without creating unrelated structures for each platform.

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
    <other-stack-set>.yaml
  package-repos/
    cse/
      repo.yaml
      packages/
  templates/
    <set>/
      contract.yaml
      stack-defaults.yaml
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

Package managers should not have to learn every repository concept before their
first successful build. The design has an adoption ladder; each tier or optional
extension is a valid workflow, not a throwaway tutorial.

| Tier | Files the package manager writes | Use when |
|---|---|---|
| Tier 0 — manual Spack | One `spack.yaml` environment | First proof, debugging, or a maintainer who wants no renderer yet. |
| Tier 1 — starter stack | One `stack.yaml` with inline `specs:` | One package or a small application stack. This is the normal starting point. |
| Tier 2 — narrowed stack | Same `stack.yaml`, plus optional `per_system:` | Same stack intent across systems, but one deployment needs fewer compilers, MPI providers, or GPU arches. |
| Optional — package-set reuse | `stack.yaml` plus optional `package-sets/<name>.yaml` | Large stacks where the same root spec list is shared by multiple build requests, such as CSE using `science-full` for serial, MPI, and GPU lanes. |

Most package managers should start from `stacks/_starters/`, edit `name:` and
`builds[*].specs`, then render. Template contracts and stack defaults are
framework-maintainer files; package managers select the names they define but do
not normally edit them.

### `profile.yaml`

`profile.yaml` describes observed system facts. It can be emitted by
`cluster-inspector` or written by hand. It is the cross-repo contract between
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
  # The committed default Cray-PE GPU lane (Option B) requires the GNU
  # PrgEnv plus the standalone toolkit module from this list. Public entry
  # modules check/prereq those modules by default. For ROCm, this module is
  # also the source for the Spack component externals below.
  rocm:
    version: "6.0.0"
    module: rocm/6.0.0
    prefix: /opt/rocm-6.0.0
    spack_components:                           # representative ROCm 5/6 component externals
      - { package: hip,          prefix: /opt/rocm-6.0.0/hip }
      - { package: hsa-rocr-dev, prefix: /opt/rocm-6.0.0 }
      - { package: comgr,        prefix: /opt/rocm-6.0.0 }
      - { package: rocblas,      prefix: /opt/rocm-6.0.0 }
      - { package: hipblas,      prefix: /opt/rocm-6.0.0 }
      - { package: hipsparse,    prefix: /opt/rocm-6.0.0 }
      - { package: rocprim,      prefix: /opt/rocm-6.0.0/rocprim }
      - { package: llvm-amdgpu,  prefix: /opt/rocm-6.0.0 }
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
    - { compiler: gcc,    lane: serial,           runtime_node_types: [cpu_compute, gpu_compute_mi250x, gpu_compute_mi300a] }
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
only on the gfx90a class. This list is what `spack-composer validate` checks
`stack.yaml`'s lane declarations against.

Profile rules:

- It is platform reality, not package intent.
- It must not require Ansible.
- It must not require `cluster-inspector` at build time.
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
- ROCm component externals are platform facts about the installed ROCm tree, not
  stack root specs. They may be listed explicitly in
  `gpu_toolkit_modules.rocm.spack_components`, or supplied by a checked-in
  versioned component template keyed by the profile's ROCm version and prefix.
  If neither source can produce a coherent component set, AMD GPU lanes fail
  validation rather than pretending `rocm` is a single Spack external.

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

`stack.yaml` declares desired stack behavior. It is the durable stack contract,
and it is **platform-portable** — one stack file can drive multiple platforms
because the render step resolves generic build requests against the selected
`profile.yaml`.

The source stack file should not normally list concrete lane names such as
`gcc-gpu-craympich-gfx90a`. Those names are target-system consequences: they
come from the compiler inventory, MPI/provider policy, node types, CPU targets,
and GPU architecture facts in the profile. The source file says "build this
payload as CPU and GPU," "use direct modules," or "expand one build per GPU
architecture." The render step turns those requests into concrete lanes.

Do not confuse package sets with Spack `packages.yaml`. Package sets are source
inputs that list root packages and supported versions. Rendered `packages.yaml`
files are target-system Spack config: externals, providers, target preferences,
GPU toolkit components, and buildable policy derived from `profile.yaml` plus
the policies in this stack file.

Top-level stanzas (`externals.*`, `modules.*`) stay genuinely
platform-agnostic: they express policy in terms of categories
(`compilers: prefer_platform`) that the render step resolves against the
profile. Build requests use only names accepted by the selected template
contract.

It should answer questions like:

- What build requests should be expanded?
- What inline specs or package sets should each request use?
- Which target classes should each request run on?
- How should ambiguous target matches expand?
- What module naming and exposure policy should users see?
- What externals policy should convert profile facts into Spack config?
- What build-cache lanes and release artifacts should be saved?

The minimum Tier 1 stack file is intentionally small. It uses normal Spack root
spec strings under `specs:` and relies on the selected template set's defaults
for modules, externals, buildcache, and release policy.

```yaml
# stacks/my-app/stack.yaml — minimum renderable stack
schema_version: 1
name: my-app

templates:
  set: v6

builds:
  - name: payload
    class: cpu
    toolchain: app-default
    nodes: cpu
    expand: one
    specs:
      - hdf5@1.14.5
      - netcdf-c@4.9.2
```

That is the normal adoption path: copy a starter, edit `name` and Spack `specs`,
adjust `class`, `toolchain`, `nodes`, or `expand` only when the starter's default
shape is not the one you want, then render. The selected template contract must
define those names. The full reference schema follows for stack owners and
CSE-scale stacks. Required keys in source `stack.yaml` are marked **R**; optional
keys are marked **O**. Optional keys may still be required after merging with
`templates/<set>/stack-defaults.yaml`; if neither the source stack nor the
defaults supplies a required value, render fails.

LAMMPS-like packages do not need a second stack language. Package managers keep
normal Spack variants in the root specs; `spack-composer` supplies the lane's
compiler, MPI, target, GPU arch, externals, module policy, and config scopes:

```yaml
# stacks/lammps/stack.yaml — compact multi-lane example
schema_version: 1
name: lammps

templates:
  set: v6

modules:
  exposure: direct
  module_root: lammps

builds:
  - name: cpu-mpi
    class: mpi
    toolchain: cse-mpi-default       # contract expands to GCC/CCE + Cray MPICH on Cray
    nodes: cpu
    expand: one
    specs:
      - lammps@2024.06.27 +mpi +manybody +molecule

  - name: gpu-a100
    class: gpu
    toolchain: cse-craympich-cuda    # contract allows AOCC host + Cray MPICH + CUDA
    nodes: gpu
    expand: per_gpu_arch
    specs:
      - lammps@2024.06.27 +mpi +kokkos +cuda

per_system:
  example-nvidia-cray:
    builds:
      cpu-mpi:
        compilers: [gcc, cce]
        mpi: [cray-mpich]
      gpu-a100:
        compilers: [aocc]
        mpi: [cray-mpich]
        gpu_arch: [a100]
```

The rendered CPU lanes decorate the same `lammps` spec with `%gcc_craympich` and
`%cce_craympich` as appropriate. The rendered GPU lane decorates it with the
AOCC/Cray-MPICH toolchain and the selected NVIDIA toolkit scope. A friendly
selector such as `a100` belongs in the template contract; render maps it to the
profile fact (`sm_80`) and Spack variant (`cuda_arch=80`).

```yaml
schema_version: 1                               # R - stack schema version
name: cse                                       # R - stack name; appears in paths and modules

profile_contract:                               # O - defaulted by template set when omitted
  schema_version: 1                             # R - render rejects mismatched profile schema

templates:                                      # R - which template set to render against
  set: v6                                       # R - template set name; matches templates/ on disk

spack:                                          # O - Spack version constraint for this stack
  version: ">=1.1.1,<1.2"                       # O - PEP-440-style constraint or exact version
                                                #     tightens the template set's floor; never widens it
                                                #     enforced by spack-build before any lane runs

modules:                                        # O - user-visible module strategy; normally from stack-defaults.yaml
  format: tcl                                   # R - mandatory baseline; always `tcl` (only valid value)
  additional_formats: []                        # O - optional add-ons; e.g. [lmod] to also emit Lua tree
  exposure: front_door                          # O - front_door (default) | direct
  init_module: cse-init                         # O - bootstrap/init module; null if module_root is already on MODULEPATH
  module_root: CSE                              # R - user-facing lane-module root, e.g. CSE/GCC/mpi-openmpi
  publish_root: null                            # O - existing site MODULEPATH root for direct publication
  hierarchy_style: collapsed                    # O - collapsed (default) | granular (Lmod-only)
  expose_provenance: true                       # O - default true; emits STACK_PACKAGE_PROVENANCE
  platform_module_policy: prereq                # O - prereq (default) | autoload

builds:                                         # R - generic build requests, not resolved lanes
  - name: core                                  # R - request name; appears as source_build in generated lanes
    class: core                                 # R - key in templates/<set>/contract.yaml build_classes
    package_set: core-foundation                # O - mutually exclusive with specs; package-set file stem
    specs: null                                 # O - mutually exclusive with package_set; inline Spack root specs
    toolchain: cse-core                         # R - key in template contract toolchains
    nodes: cpu                                  # R - key in template contract node_selectors
    expand: one                                 # R - one | per_node_type | per_cpu_target | per_gpu_arch
    publish: true                               # O - default true; false skips public module/view publication
    required: false                             # O - default false; true → render errors if unsatisfied

  - name: serial                                # CSE serial payload request
    class: serial
    package_set: science-full
    specs: null
    toolchain: cse-serial-default
    nodes: cpu
    expand: one
    publish: true

  - name: mpi                                   # CSE-style payload request
    class: mpi
    package_set: science-full
    specs: null
    toolchain: cse-mpi-default
    nodes: cpu
    expand: one
    publish: true

  - name: gpu                                   # CSE-style GPU payload request
    class: gpu
    package_set: science-full
    specs: null
    toolchain: cse-gpu-default
    nodes: gpu
    expand: per_gpu_arch
    publish: true

per_system:                                     # O - system-scoped narrowing; ignored for other profile.system.name values
  example-cray:
    builds:
      mpi:
        compilers: [gcc, cce]                   # subsets of profile/contract-resolved candidates only
        mpi: [cray-mpich]
      gpu:
        compilers: [gcc]
        mpi: [cray-mpich]
        gpu_arch: [gfx90a]

externals:                                      # O - platform-agnostic externals policy; normally from stack-defaults.yaml
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

buildcache:                                     # O - build-cache lane policy; normally from stack-defaults.yaml
  spack_generation: "spack-{spack_version}/repo-{package_repo_generation}" # R when buildcache is set
  foundation_lane: "foundation/{os_id}/glibc-{glibc}/{spack_generation}/{baseline_target}" # O - only when Core/foundation lanes exist
  payload_lane:    "payload/{os_id}/glibc-{glibc}/{spack_generation}/{system}" # R when buildcache is set
  signed: false                                 # O - default false; true requires key configuration
  push_after_every_step: true                   # O - default true

release:                                        # O - what to save per release; normally from stack-defaults.yaml
  save_lockfiles: true                          # R - keep spack.lock per lane
  save_manifest: true                           # R - emit release-manifest.yaml
  retain_previous: 2                            # O - default 2; previous releases kept loadable
  promotion: gated_manual                       # O - gated_manual (default) | auto

package_repositories:                           # O - internal Spack package repos to register for this stack;
                                                #     normally inherited from stack-defaults.yaml. The user
                                                #     stack may add new entries or replace the defaults list
                                                #     (lists replace, per the merge rules). Render emits
                                                #     repos.yaml from the resolved selection.
  - name:      cse                              # R - repository name
    namespace: cse                              # R - Spack package namespace
    path:      package-repos/cse                # R - path under the stack source tree
    priority:  before_builtin                   # O - before_builtin (default) | after_builtin

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
| `modules.exposure` | whether users enter through stack-owned front-door lane modules (`front_door`) or direct package/application modules (`direct`) |
| `modules.init_module` | optional bootstrap/init module name users may load first, e.g. `cse-init`; null when the public module root is already in MODULEPATH |
| `modules.module_root` | user-facing module namespace, e.g. `CSE` in `CSE/GCC/mpi-openmpi` or `fun3d` in `fun3d/14.2-gpu-gfx90a` |
| `modules.publish_root` | optional existing site MODULEPATH root where public modules are published or symlinked |
| `modules.expose_provenance` | whether `setenv STACK_PACKAGE_PROVENANCE` is emitted |
| `modules.platform_module_policy` | whether public entry modules check/prereq platform modules (`prereq`) or actively load them (`autoload`) |
| `builds[*]` | source build requests expanded into one or more resolved lanes |
| `builds[*].specs` | inline Spack root specs expanded into each generated lane; mutually exclusive with `package_set` |
| `builds[*].package_set` | optional reusable `package-sets/<name>.yaml` expanded into each generated lane; mutually exclusive with `specs` |
| `builds[*].class` | key into the template contract's `build_classes`; determines lane kind, spec kind (`package_set_kind`), default target policy, and required capabilities |
| `builds[*].toolchain` | key into the template contract's `toolchains`; determines compiler/MPI/GPU-toolkit resolution policy |
| `builds[*].nodes` | key into the template contract's `node_selectors`; determines which `profile.node_types` entries are eligible |
| `builds[*].expand` | global expansion rule for multiple eligible node matches |
| `per_system.<system>.builds.<name>` | optional subset-only narrowing after the contract resolves eligible compilers, MPI providers, and GPU arches |
| `externals.compilers` | `configs/vendor/<family>/packages.yaml` content for compilers |
| `externals.mpi` | `configs/mpi/<provider>/packages.yaml` content for MPI |
| `externals.openssl` / `externals.curl` | `configs/os/<os>/packages.yaml` system-external declarations |
| `externals.fabric_userspace` | UCX/libfabric `buildable` posture in fabric scope |
| `externals.gpu_toolkit` | CUDA external posture and ROCm component-external posture in GPU scope |
| `foundation_pins.<lib>` | `require:` lines in the common scope |
| `buildcache.spack_generation` | path token separating incompatible Spack/package-repo generations |
| `buildcache.foundation_lane` | mirror path key for foundation cache; required only when the stack builds Core/foundation lanes |
| `buildcache.payload_lane` | mirror path key for payload cache |
| `release.save_lockfiles` | whether `spack.lock` is copied into `releases/<date>/` |
| `release.save_manifest` | whether `release-manifest.yaml` is emitted |
| `release.promotion` | whether Ansible swaps the `current` symlink automatically or waits for approval |
| `package_repositories[*]` | internal Spack package repositories registered for this stack; rendered into `repos.yaml`. Normally inherited from `stack-defaults.yaml`; user entries replace the defaults list. |

Source Contract Rubric:

| Field | Allowed values | Meaning |
|---|---|---|
| `modules.format` | `tcl` | Tcl modulefiles are the mandatory baseline. |
| `modules.exposure` | `front_door`, `direct` | Whether users load a lane selector first or load public package/application modules directly. |
| `modules.publish_root` | `null` or absolute path | Existing site MODULEPATH root used for direct publication or site-managed symlinks. |
| `builds[*].specs` | List of Spack root spec strings, or a map keyed by spec kind (`any`, `serial`, `mpi`, `gpu`, etc.) | Inline package roots and versions for this build request. Recommended for small stacks. |
| `builds[*].package_set` | Filename stem under `package-sets/` | Optional reuse mechanism for root specs. Use when the same spec list is shared across multiple build requests. Mutually exclusive with `specs`. |
| `builds[*].class` | Any key in `templates/<set>/contract.yaml.build_classes` | Named build class such as `core`, `cpu`, `gpu`, `mpi`, or another template-defined class. |
| `builds[*].toolchain` | Any key in `templates/<set>/contract.yaml.toolchains` | Named toolchain policy. The contract, not `stack.yaml`, defines compiler/MPI/GPU-toolkit behavior. |
| `builds[*].nodes` | Any key in `templates/<set>/contract.yaml.node_selectors` | Named node-selection policy. The contract defines how it matches `profile.node_types`. |
| `builds[*].expand` | `one`, `per_node_type`, `per_cpu_target`, `per_gpu_arch` | Global expansion rule for multiple matched node types. |
| `builds[*].publish` | `true`, `false` | Whether public modules/views are generated for lanes from this request. |
| `builds[*].required` | `true`, `false` | Whether an unsatisfied request fails render instead of being skipped with an explanation. |
| `per_system.<system>.builds.<name>.compilers` | List of normalized compiler IDs from the matching profile | Optional subset of compilers after contract resolution. Unknown values are errors for the matching system. |
| `per_system.<system>.builds.<name>.mpi` | List of MPI provider names from the matching profile or template contract | Optional subset of MPI providers after contract resolution. Unknown values are errors for the matching system. Note: this is a list of provider names (subset semantics), distinct from `externals.mpi` at the top level, which is a single posture scalar (`prefer_platform` / `build_all` / `mixed`). |
| `per_system.<system>.builds.<name>.gpu_arch` | List of GPU architecture labels from `profile.node_types[*].gpu.arch_target` | Optional subset of GPU architectures after contract resolution. Unknown values are errors for the matching system. |

`one` expansion means "exactly one match is expected." If the selector matches
zero entries, the request is skipped unless `required: true`. If it matches more
than one node type, render fails and asks the maintainer to choose a more
explicit expansion rule. `per_gpu_arch` means one lane per distinct GPU
architecture label in the matched node types; `per_cpu_target` means one lane per
distinct CPU target; `per_node_type` means one lane per matching node type.
Toolchain fan-out is separate: a template contract may define a toolchain that
expands across multiple compilers or MPI providers. That behavior is named in the
contract and then selected from `stack.yaml` by `builds[*].toolchain`.

The key rule is that `stack.yaml` contains names, not resolver expressions. A
value such as `cse-gpu-default` or `fun3d-default` is allowed only because the
selected template contract defines it. Raw implementation strings such as
`prefer_gnu`, `provider:cray-mpich`, or `node_type:gpu_compute_mi250x` belong in
the template contract or profile, not in the normal stack file.

Every build request must provide exactly one source of root specs: either inline
`specs:` or `package_set:`. Inline specs are ordinary Spack root specs; users
should write package versions and semantic variants such as `+mpi`, `~mpi`,
`+rocm`, or `+cuda` exactly as the package recipe defines them. System-specific
target details such as `target=zen3`, `cuda_arch=90`, or
`amdgpu_target=gfx90a` should normally come from the profile and rendered GPU or
target scopes, not from inline specs.

System-specific names are forbidden in the generic build request fields. The
`per_system:` block is the one explicit exception. A `per_system` entry is
applied only when its key matches `profile.system.name`; all other entries are
ignored for that render. It can only narrow candidates already produced by the
template contract and profile. It never widens the contract, never invents a
compiler/MPI/GPU arch, and never changes package roots.

`per_system:` narrows only `builds:`. `externals.*`, `foundation_pins.*`,
`buildcache.*`, and `release.*` stay platform-portable policy and cannot be
overridden per system. A deployment that needs different policy on different
systems has three options depending on what differs: use profile-derived path
tokens (when the policy can be expressed as a profile fact such as `{os_id}` or
`{system}` in a buildcache path), adopt a different template set (when several
deployments share the same alternative policy and it belongs in
`stack-defaults.yaml`), or maintain a separate `stack.yaml` (when only one
deployment differs and the policy is genuinely stack-level intent).

### Template Authoring Lifecycle

Template sets are not written from guesswork. They are bootstrapped from the
profile corpus and then curated by maintainers.

```text
systems/*/profile.yaml
        │
        ▼
spack-composer assess-profiles
        │
        ▼
coverage report: OS families, compilers, MPIs, GPU toolkits, node classes
        │
        ▼
spack-composer scaffold-templates  # optional, advisory
        │
        ▼
maintainer review and support decision
        │
        ▼
templates/<set>/contract.yaml + config templates + stack-defaults.yaml
```

The scaffolder may propose missing OS scopes, GPU selectors, MPI provider scopes,
or contract additions, but it does not decide support policy. The maintainer owns
the contract. A profile says what exists; the contract says which observed
combinations this template set supports; `stack.yaml` says which supported
combinations to build.

A template author writes three kinds of file inside a template set:
`contract.yaml` (see §Template Contract Files for the schema),
`stack-defaults.yaml` (see §Stack Defaults Merge Rules for the schema), and
Jinja templates for scopes and lane environments (see §Template Render Context
for the variables those templates can reference). The render engine treats
the Jinja template tree as authoritative output text; it does not permit
templates to read host state or import files outside the template set.

**Extend vs. fork a template set.** Add to an existing template set when the
change is additive and at least two real deployments will use it (a new
resolver-policy name, a new GPU selector, a new MPI provider scope). Create a
new template set (`templates/<new>/`) only when the change is removing or
contradicting something the existing set guarantees, or when one deployment
needs a substantially different shape that would clutter the shared contract.
The cost of a new set is real (every stack pinned to it tracks its own
release cadence), so the default is to extend.

This distinction matters for systems with many programming environments. A Cray
profile may report GCC, CCE, AOCC, NVHPC, Intel, Cray MPICH, CUDA, and ROCm.
That does not mean every compiler/GPU/toolkit combination is supported. The
contract records the support matrix. The effective build menu is:

```text
profile facts ∩ template contract ∩ stack request
```

When a system changes, run the profile corpus assessment before changing
templates. A new compiler version with the same module/prefix pattern may be a
profile-only update. A new OS family, new MPI family, new ROCm component layout,
or newly supported compiler/GPU combination requires contract or template work.

### Template Contract Files

Every template set ships a contract file:

```text
templates/<set>/contract.yaml
```

The contract is source-controlled and reviewed with the templates. It is the
rubric for accepted `stack.yaml` values. A stack file that names a class,
toolchain, or node selector not present in the selected contract fails validation
before any Spack files are rendered.

Reference schema. Required keys are marked **R**; optional keys are marked **O**.

```yaml
schema_version: 1                              # R - contract schema version

build_classes:                                 # R - map of class name → class shape
  <name>:                                      # R - referenced from stack.yaml.builds[*].class
    lane_kind:        <string>                 # R - matches templates/<set>/environments/<lane_kind>/
    package_set_kind: <string>                 # R - must appear in spec source's `kinds:` list
    default_target:   <string>                 # R - names a target_policies entry
    requires:         [<capability>, ...]      # O - capability names; checked against profile
                                               #     known capabilities: runtime_cpu, runtime_gpu,
                                               #     mpi, gpu_toolkit, build_host

toolchains:                                    # R - map of toolchain name → resolver policy
  <name>:                                      # R - referenced from stack.yaml.builds[*].toolchain
    compiler:        <resolver_policy>         # R - template-set vocabulary; see resolver-policy note below
    mpi:             <resolver_policy>         # R - template-set vocabulary
    gpu_toolkit:     <resolver_policy>         # R - template-set vocabulary
    allowed_compilers: [<id>, ...]             # O - if set, narrows the compiler resolver's output

node_selectors:                                # R - map of selector name → match predicate
  <name>:                                      # R - referenced from stack.yaml.builds[*].nodes
    match: <predicate>                         # R - template-set vocabulary; resolves against
                                               #     profile.node_types[*] role/gpu state

gpu_selectors:                                 # O - map of GPU friendly name → arch + spack vars
  <name>:                                      # O - referenced from per_system narrowing or stack
    vendor:      <nvidia|amd>                  # R
    arch_target: <string>                      # R - e.g. sm_80, sm_90, gfx90a, gfx942
    spack:                                     # O - Spack variant key/value pairs the renderer emits
      <variant>: <string>                      # O - e.g. cuda_arch: "80", amdgpu_target: gfx90a

target_policies:                               # R - map of policy name → target resolution rule
  <name>:                                      # R - referenced from build_classes[*].default_target
    resolve:       <resolver_policy>           # R - template-set vocabulary; resolves against
                                               #     profile.node_types[*].cpu
    hard_require:  <bool>                      # O - default false; true rejects target mismatches
```

**Resolver-policy names** (`each_cse_mpi_compiler`, `platform_then_stack_mpi`,
`gnu_host_default`, `runtime_preferred`, `baseline_x86_64_v3`, etc.) are reviewed
template-set vocabulary. The schema does not enumerate them — every template
set declares its own — but the renderer treats any name referenced in `toolchains:`,
`node_selectors:`, or `target_policies:` as a required vocabulary entry the
renderer must know how to resolve. Adding a new resolver policy name means
adding the matching resolver implementation in the same change.

Example app contract:

```yaml
# templates/app-direct-v1/contract.yaml
schema_version: 1

build_classes:
  cpu:
    lane_kind: cpu                              # rendered environment template kind
    package_set_kind: cpu                       # spec-source `kinds:` entry required
    default_target: payload_default             # target_policies key below
    requires: [runtime_cpu]

  gpu:
    lane_kind: gpu
    package_set_kind: gpu
    default_target: payload_default
    requires: [runtime_gpu, gpu_toolkit]

toolchains:
  app-default:
    compiler: prefer_gnu                        # generic starter-stack default
    mpi: prefer_platform
    gpu_toolkit: when_required_by_class

  fun3d-default:
    compiler: prefer_gnu                        # contract-owned resolver policy
    mpi: prefer_platform
    gpu_toolkit: when_required_by_class

node_selectors:
  cpu:
    match: runtime_without_gpu

  gpu:
    match: runtime_with_gpu

gpu_selectors:
  a100:
    vendor: nvidia
    arch_target: sm_80
    spack:
      cuda_arch: "80"

target_policies:
  payload_default:
    resolve: runtime_preferred                  # profile.node_types[*].cpu.preferred
    hard_require: false
```

Example CSE contract:

```yaml
# templates/v6/contract.yaml (CSE excerpt)
schema_version: 1

build_classes:
  core:
    lane_kind: core
    package_set_kind: core
    default_target: foundation
    requires: [runtime_cpu]

  serial:
    lane_kind: serial
    package_set_kind: serial
    default_target: payload_default
    requires: [runtime_cpu]

  mpi:
    lane_kind: mpi
    package_set_kind: mpi
    default_target: payload_default
    requires: [runtime_cpu, mpi]

  gpu:
    lane_kind: gpu
    package_set_kind: gpu
    default_target: payload_default
    requires: [runtime_gpu, mpi, gpu_toolkit]

toolchains:
  cse-core:
    compiler: each_cse_core_compiler
    mpi: none
    gpu_toolkit: none

  cse-serial-default:
    compiler: each_cse_serial_compiler
    mpi: none
    gpu_toolkit: none

  cse-mpi-default:
    compiler: each_cse_mpi_compiler
    mpi: platform_then_stack_mpi
    gpu_toolkit: none

  cse-gpu-default:
    compiler: gnu_host_default
    mpi: platform_mpi_required
    gpu_toolkit: prefer_platform

  cse-craympich-cuda:
    mpi: cray-mpich
    gpu_toolkit: cudatoolkit
    allowed_compilers: [gcc, aocc, nvhpc]

node_selectors:
  cpu: { match: runtime_without_gpu }
  gpu: { match: runtime_with_gpu }

gpu_selectors:
  mi250x:
    vendor: amd
    arch_target: gfx90a
    spack:
      amdgpu_target: gfx90a
  a100:
    vendor: nvidia
    arch_target: sm_80
    spack:
      cuda_arch: "80"

target_policies:
  foundation:
    resolve: baseline_x86_64_v3
    hard_require: false

  payload_default:
    resolve: runtime_preferred
    hard_require: false
```

The resolver policy names inside the contract (`each_cse_mpi_compiler`,
`platform_then_stack_mpi`, `gnu_host_default`) are reviewed implementation
vocabulary for this template set. Top-level portable build requests in
`stack.yaml` name contract terms such as `class: gpu`, `toolchain:
cse-gpu-default`, and `nodes: gpu`. The optional `per_system` block may narrow
those requests with friendly names exposed by `spack-composer explain`, such as
`gcc`, `cce`, `cray-mpich`, `a100`, or `mi250x`. Raw Spack target details such as
`cuda_arch=80`, `amdgpu_target=gfx90a`, or `target=zen3` stay in the contract and
rendered scopes, not in ordinary package specs.

Template contracts may be generic across many stacks, but they are still finite:
the renderer validates names, spec-kind compatibility, required
capabilities, and expansion behavior against this file before looking at Spack.
If a new workflow needs a new word, add it to the template contract with a clear
meaning; do not smuggle it into `stack.yaml` as an ad hoc value.

### Stack Defaults Merge Rules

Every template set also ships defaults:

```text
templates/<set>/stack-defaults.yaml
```

The source `stack.yaml` must name `templates.set` so the renderer knows which
contract and defaults to load. Render then merges
`templates/<set>/stack-defaults.yaml` underneath the user's `stack.yaml` before
validation. User keys always win.

Merge rules:

- Maps merge recursively.
- Lists replace; they do not concatenate.
- Scalars replace.
- `builds:` is a list and therefore comes from the user stack unless a starter
  intentionally omits it for documentation purposes.
- `per_system:` maps merge by system name and build name.

Template defaults carry the boilerplate most package managers should not repeat:
`profile_contract`, `modules`, `externals`, `foundation_pins`, `buildcache`,
`release`, helper recommendations, and any template-specific default values. The
defaults file is versioned and reviewed with the template set. It is not a
per-stack customization file; if many stacks need a different default, create a
new template set or update the template set deliberately.

The release manifest records the user `stack.yaml` digest plus the selected
`stack-defaults.yaml` and `contract.yaml` digests so a rendered release can be
reproduced exactly.

Reference schema. `stack-defaults.yaml` uses the same shape as `stack.yaml`
(see §Durable Inputs / `stack.yaml`), with these constraints:

- `name:` is **forbidden** in defaults. The stack name lives in the user
  `stack.yaml` only.
- `builds:` should be **omitted** in defaults. Build requests are user
  intent. A starter may include an inline `builds:` for documentation, but a
  shared defaults file should leave this empty so the user list always wins.
- `templates.set:` is **forbidden** in defaults. The user `stack.yaml` selects
  the template set; a defaults file cannot point at itself.
- `profile_contract.schema_version:` **should** be set in defaults so a user
  `stack.yaml` does not need to repeat the version. User keys still win.
- Every other top-level key (`modules`, `externals`, `foundation_pins`,
  `buildcache`, `release`, `package_repositories`, `per_system`,
  `helper_recommendations`) is allowed and is the *boilerplate the package
  manager should not have to repeat*.

```yaml
# templates/<set>/stack-defaults.yaml — reference shape
schema_version: 1                              # R - defaults schema version (same as stack)

profile_contract:                              # O - inherited by user stack unless overridden
  schema_version: 1                            # O - profile schema version this template set targets

spack:                                         # R - Spack version floor for this template set
  floor: "1.1.1"                               # R - minimum Spack version the templates' features require
                                               #     stack.yaml.spack.version may tighten this; never widen

modules: { ... }                               # O - module system defaults (init_module, root, exposure)
externals: { ... }                             # O - mpi posture, openssl/curl externalization, etc.
foundation_pins: { ... }                       # O - common-scope dep pins (zlib, xz, zstd, ...)
buildcache: { ... }                            # O - mirror URLs, policy, key handling
release: { ... }                               # O - promotion policy, release tag rules
package_repositories: [ ... ]                  # O - default selection; user may add/replace
per_system: { ... }                            # O - defaults for narrowing; user keys merge by system
                                               #     and build name (per §Stack Defaults Merge Rules)
helper_recommendations: { ... }                # O - free-form hints displayed by spack-composer explain
```

A defaults file with only `schema_version:` is valid but useless. A defaults
file that names a template-set-specific resolver policy in `per_system:` must
match the contract's vocabulary; the renderer will reject unknown names from
either layer.

During render, `builds:` becomes a resolved release plan. The plan is generated
output, not source policy:

```yaml
resolved_lanes:
  - name: gcc-gpu-craympich-gfx90a
    source_build: gpu
    compiler: gcc
    lane: gpu-craympich-gfx90a
    kind: gpu
    package_set: science-full
    target: zen3
    runtime_node_type: gpu_compute_mi250x
    gpu_arch: gfx90a
```

The rendered `environments/<compiler>/<lane>/spack.yaml`, target scopes, GPU
scopes, modulefiles, views, lockfiles, and build-cache paths are all derived from
that resolved plan plus package sets, templates, and the profile.

### Starter Stacks

The repository should ship starter stack files under `stacks/_starters/`. A
package manager copies the closest starter to `stacks/<name>/stack.yaml`, edits
the stack name and specs, and renders. Starters are documentation and examples,
not a new schema.

| Starter | Shape | When to pick |
|---|---|---|
| `single-package.yaml` | One build, inline specs, no Core | One or two packages, direct modules, fastest Tier 1 path. |
| `cpu-gpu-app.yaml` | CPU and GPU builds, inline specs | One application with CPU and GPU variants. |
| `multi-system-narrowed.yaml` | Inline specs plus `per_system:` | Same stack across multiple systems with per-deployment narrowing. |
| `cse-style-reuse.yaml` | Multiple builds sharing package sets | Large stacks where the same spec list drives several build classes. |

The starter files should stay short. If a starter needs pages of boilerplate,
that boilerplate belongs in `templates/<set>/stack-defaults.yaml` instead.

Stack rules:

- It is stack intent, not detected system state.
- It is platform-portable. Top-level policy stanzas (`externals.*`,
  `modules.*`) and build requests carry no detected system facts;
  the render step resolves them against the profile through the selected template
  contract. The contract may encode provider-specific behavior, but unsupported
  profile-backed providers are skipped at render (or flagged as errors if marked
  `required: true`).
- It should be sufficient to explain the generated stack layout. Anything that
  shows up in the rendered workspace must be traceable to a key here, to a
  template, to a package set, or to the profile.
- It should remain valid if a human renders the files manually.
- It should avoid hidden policy in scripts or playbooks.

`modules.init_module`, `modules.module_root`, and `modules.exposure` are
deliberately separate. For a CSE-style multi-lane stack, the init module is the
optional bootstrap surface (`module load cse-init`) that can set `MODULEPATH` to
the current release, and `modules.module_root` is the user-facing lane namespace
(`CSE/GCC/mpi-openmpi`) exposed after initialization. For a direct application
stack, `modules.init_module` can be null because the site already has
`modules.publish_root` in MODULEPATH; users load modules such as
`fun3d/14.2-gpu-gfx90a` directly. Keeping these separate prevents bootstrap
modules, lane namespaces, and direct application module names from being
conflated.

### Package Sets — Optional Spec Reuse

A package set is a named list of root specs. Sets live under
`package-sets/<name>.yaml` and are referenced by
`stack.yaml.builds[*].package_set`. Package sets are optional. A small stack
should usually inline `builds[*].specs` directly in `stack.yaml`; that keeps the
maintainer at one YAML file. Use a package set when the same root spec list is
shared across multiple build requests, such as CSE using `science-full` for
serial, MPI, and GPU lanes.

Root specs come from exactly one source per build request: inline
`builds[*].specs` or a referenced package set. If the stack ships three HDF5
versions inline, those `hdf5@...` roots live under that build's `specs:`. If the
same list is reused across several build requests, move it to a package set and
reference it by name. `stack.yaml.foundation_pins` is separate: it pins
common-scope dependency policy such as `zlib`, `xz`, or `zstd`; it does not
define payload root versions.

Inline specs can be a flat list:

```yaml
builds:
  - name: payload
    class: serial
    specs:
      - hdf5@1.14.5
      - netcdf-c@4.9.2
```

or a package-set-kind map when one build class needs `any` plus a specific block:

```yaml
builds:
  - name: mpi
    class: mpi
    specs:
      any:
        - gsl@2.8
      mpi:
        - hdf5@1.14.5+mpi+fortran
        - parallel-netcdf@1.13.0
```

Sets fall into three tiers, declared in the file itself:

| Tier | Meaning |
|---|---|
| `canonical` | A user-facing set the stack promises to ship. Changes go through normal review. |
| `smoke` | A small set used for CI/smoke tests. Never used by a production lane. |
| `experimental` | A set being tried out. May change or be deleted without notice. |

The tier guards against accidental promotion of test sets to production —
a `stack.yaml` build request that references a `smoke` set should fail render-time
validation unless the render invocation or release variables explicitly opt in.

Schema:

```yaml
schema_version: 1
name: science-full                              # R - matches the filename stem
tier: canonical                                 # R - canonical | smoke | experimental
description: |                                  # R - human-readable purpose
  Full curated science library set: HDF5/NetCDF/PnetCDF (multi-version),
  TAU, and performance-portability roots used by CSE payload lanes.

kinds: [serial, mpi, gpu]                       # R - package-set kinds this set can satisfy

specs:                                          # R - root specs by package-set kind constraint
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
  gpu:                                          # GPU lanes are MPI-capable plus GPU-sensitive roots
    - hdf5@1.14.5+mpi+fortran
    - hdf5@1.14.4+mpi+fortran
    - hdf5@1.12.3+mpi+fortran
    - netcdf-c@4.9.2+mpi
    - netcdf-c@4.9.0+mpi
    - parallel-netcdf@1.13.0
    - tau+mpi
    - kokkos+rocm
    - raja+rocm

provenance_hints:                               # O - override the render-step provenance derivation
  cray-mpich: Platform-backed                   #     (otherwise derived from packages.yaml)
  openssl:    Site-external

notes: |                                        # O - free-form notes for maintainers
  Multi-version HDF5/NetCDF is the working target. PnetCDF stays single-version
  until the next refresh; revisit when 1.14.x lands.
```

The render step expands inline specs and package sets the same way. A flat list
is emitted as-is. A map selects `specs.any` plus the block named by the build
class's `package_set_kind` in the template contract (`specs.serial` for a serial
class, `specs.mpi` for an MPI class, `specs.gpu` for a GPU class) and emits the
result into the generated lane's `spack.yaml` `specs:` list. `specs.any` is only
for roots that are literally identical for every kind the set supports.
Dual-build packages such as HDF5 and NetCDF belong only in the
package-set-kind-specific blocks. After expansion, duplicate root specs by
package name and major variant class are a render-time validation error unless
the spec source marks an explicit override. The toolchain decoration
(`%cce_craympich` etc.) is applied by the render step from the resolved lane's
compiler-and-MPI pairing, not from the inline spec or package set; spec sources
stay compiler-agnostic so the same list is usable across lanes.

CSE ships these canonical sets out of the gate:

- **`core-foundation`** — build tools and foundation libraries: `cmake`,
  `ninja`, `pkgconf`, `git`, `zlib-ng+compat`, `xz`, `zstd`, and the
  `miniforge` user environment. Used by every `<compiler>/core` lane.
- **`science-full`** — multi-version HDF5/NetCDF/PnetCDF, plus TAU and the
  performance-portability layers (`kokkos`, `raja`). It contains serial, MPI,
  and GPU-specific root blocks; GPU backend and architecture variants are
  applied by the GPU scope. Used by CSE serial, MPI, and GPU lanes.

Other stacks may define much smaller sets and may use only one payload lane. A
curated application stack with no compiler/MPI/GPU variants does not need a
separate Core lane or serial/MPI/GPU taxonomy just to use this framework.

Smoke sets used for CI live alongside (`smoke-hdf5-mpi`, `smoke-cuda-only`,
etc.) but are never referenced by a production `stack.yaml` build request.

### Internal Package Repositories

Some stack packages are site-owned, and some upstream Spack packages need local
recipe changes before upstream accepts them. Those recipes belong in stack-owned
Spack package repositories, not in `profile.yaml`.

Example source layout:

```text
package-repos/
  cse/
    repo.yaml
    packages/
      cse-foo/
        package.py
      lammps/
        package.py      # local override of a builtin package, if needed
```

Package repositories are source inputs. A template set may enable a common repo
by default in `stack-defaults.yaml`, or a stack may request one explicitly:

```yaml
package_repositories:
  - name: cse
    namespace: cse
    path: package-repos/cse
    priority: before_builtin
```

Package managers still write normal Spack specs. For an internal package, that
might be `cse-foo@1.2.0 +mpi`. For a local override of an upstream package,
prefer an explicit namespace when the deployed Spack syntax supports it, such as
`cse.lammps@2024.06.27 +mpi +kokkos`, so review makes clear that the stack-owned
recipe is in use. If unqualified names are used, repository priority must be
recorded in the release manifest so the source of the recipe is not hidden.

The render step emits a `repos.yaml` scope from the selected package
repositories:

```yaml
repos:
  - /rendered/workspace/package-repos/cse
```

The release manifest records each selected package repository's path, namespace,
digest, and source commit. Build-cache keys include the Spack/package-repository
generation because changing recipes changes concretized hashes. `cluster-inspector`
does not probe or generate package repositories; they are stack source controlled
by maintainers.

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
             + selected package repositories
```

## What Goes Where

| File | Belongs here | Does not belong here |
|---|---|---|
| `spack.yaml` | Root specs, include list, lane views, lane-local settings | Platform-wide external definitions duplicated everywhere |
| `packages.yaml` | Externals, providers, buildable policy, targets, default variants | The full stack package list |
| `toolchains.yaml` | Named compiler/MPI policies | Filesystem paths unless part of external definitions |
| `config.yaml` | Install tree, caches, build stage, build jobs | Package list or module UX policy |
| `concretizer.yaml` | `unify` and `reuse` policy selected by environment shape | Per-lane root specs |
| `modules.yaml` | Spack-generated package-module behavior | Front-door lane-module policy; those modules are stack-owned |
| `mirrors.yaml` | Source mirror and build-cache mirror definitions | Stack software list |
| `env_vars.yaml` | Explicit stack environment variables | Implicit shell/module state |

## Config Layering Details

The environment manifest should include only the config scopes needed for that
lane. Each scope remains a separate directory on disk; Spack reads and merges
the scopes at solve time. The render step should place files, not flatten all
scope content into a single `spack.yaml`.

Config scopes are rendered from curated template files, not assembled by probing
the live host during build. Source files live under `templates/<set>/configs/`
as ordinary Spack config fragments, usually with `.yaml.j2` only where a profile
or stack value must be substituted. Render writes the selected scopes to
`configs/<scope-name>/` in the workspace, including `packages.yaml`,
`toolchains.yaml`, `config.yaml`, `concretizer.yaml`, `modules.yaml`,
`mirrors.yaml`, or `repos.yaml` as needed. Lane `spack.yaml` files then point at
those rendered directories with one `include::` list. The include list, not
ambient Spack config under `$HOME` or `/etc`, is the production isolation
boundary.

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

`concretizer.yaml` belongs in `configs/common` so every lane inherits the
template-selected base solve policy. A CSE-style stack-lane default can be:

```yaml
concretizer:
  unify: false
  reuse: true
```

The value is not universal. See §Concretizer Posture Per Environment Kind for
the committed selection rules.

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
are not forced onto a single version. As a working target, payload lanes carry
at least the latest three versions of HDF5, NetCDF, and the other libraries
users pin to. This rules out strict `unify: true`: strict unification forces one
coherent assignment across the environment, which collapses or fails when an
environment legitimately wants three HDF5 versions or multiple variant builds of
the same package. CSE-style stack lanes with deliberate cross-products should use
`unify: false`, matching Spack's stacks tutorial. Narrow application lanes that
do not intentionally carry duplicate package configurations may choose
`when_possible` to deduplicate shared dependencies while still allowing the few
duplicates that are unavoidable.

Multi-version is a **payload-lane concern only**. Core stays single-version
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

The set of libraries that belong on the pinned list is curated by stack
maintainers and should be small. DAG inspection is an audit tool for changing
that list or onboarding a substantially different system, not a task every
package manager performs for every package update. The audit procedure is:
concretize representative lanes (`spack -e <lane> spec --json`), read the
low-level link deps at the bottom of the DAG, filter by dependency type to keep
only link-time candidates a user could compile against, then check soname
stability per library (zlib qualifies; OpenSSL does not, and is also not
view-exposed anyway). Externals — for example cray-mpich — do not expand their
internal library closure into the DAG, so anything they drag at runtime is
invisible to spec-based discovery; note that as a known blind spot. The hard
part of this work (which libraries are ABI-safe to pin) is stable and should not
change often.

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
| CSE-style payload lane with deliberate cross-products (serial / MPI / GPU) | `true` | `false` | Pull finished binaries from the foundation cache when a Core/foundation lane exists; allow intentionally duplicated package versions and variants to coexist without solver pressure to unify them. |
| Narrow application lane with only occasional duplicates | `true` | `when_possible` | Reuse binaries and deduplicate shared deps where they agree, while still allowing unavoidable duplicate nodes. |
| Core / foundation lane | `true` | `false` | Same reuse posture; Core is single-version by policy, so strict deduplication is unnecessary and cross-product safety matters more. |
| Pipeline-driving env (input to `spack ci generate`) | `false` | `false` | With `reuse: true`, `spack ci generate` will not emit rebuild jobs for specs whose hashes changed but whose old hashes still appear in the cache. Pipeline envs *must* set `reuse: false`; `unify: false` keeps CI generation aligned with stack-lane cross-products. |
| Bootstrap / compiler-build env | `true` | `false` | The compiler is the only meaningful root spec here; reuse is still useful for the build-time deps (Autotools chain, perl, etc.). |
| Diagnostic / experimentation env | `false` | `false` or `when_possible` | When investigating "why did the solver pick X," `reuse: false` forces a fresh solve uninfluenced by cached binaries. Pick the `unify:` posture that matches the environment being reproduced. |

The two `reuse:` postures are not in conflict. **Build-time `reuse: true`**
pulls finished binaries from the cache to avoid recompiling unchanged work.
**Pipeline-generation `reuse: false`** must be off so that changed
definitions produce the rebuild jobs that the pipeline is supposed to
emit. The payload lane is the build-time case; the pipeline env is the
generation case; they are separate environments serving different purposes,
and they each set the value appropriate to their purpose.

`unify: false` is the committed default for CSE-style stack lanes because those
lanes intentionally carry cross-products: multiple package versions, CPU/GPU
variants, and sometimes same-package builds with different feature sets. This is
the posture shown in Spack's stacks tutorial for deliberate stacks. The
foundation single-version rule is enforced explicitly via `require:` in the
common scope, so it does not depend on strict unification.

`unify: when_possible` remains valid for a narrow application environment that
does not intentionally model a broad stack cross-product. `unify: true` is only
appropriate for a lane whose root specs must share one coherent DAG; it is not a
production default for the multi-version policy in this design.

## Detailed Scenario: Cray RHEL With Cray PE

This scenario represents a RHEL-based Cray system with Cray PE, Cray MPICH, and
AMD GPU nodes. Versions and prefixes are examples; the actual values come from
`profile.yaml`.

Major lanes:

- CCE + Cray MPICH for CSE MPI science packages.
- GCC + Cray MPICH where a GNU lane is desired.
- GCC + Cray MPICH + ROCm toolkit/component externals for default AMD GPU packages.
- Core/foundation packages at a portable target.

### Cray Core Lane

Core holds build tools and neutral libraries. It uses the portable target, not
the optimized payload target.

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

The serial lane carries CSE science packages built without MPI. Build tools do
not belong here because they live in Core.

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

The MPI lane carries CSE MPI-enabled science packages. On Cray, the MPI provider
is Cray MPICH external, not a Spack-built MPI.

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
committed default is the Option B assembly (GCC host + standalone ROCm toolkit
module + ROCm component externals in Spack + GCC-flavor cray-mpich); the lane
shows that. One lane per GPU class — `gfx90a` here, with a parallel `gfx942`
lane added when a second GPU class is present. Toolchain decoration is
`%gcc_craympich`, not `%rocmcc_craympich`, because the host compiler is GCC.

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

The lane's front-door module checks/prereqs `PrgEnv-gnu` + `gcc-native/13` +
`rocm/<v>` + `cray-mpich/<v>` at runtime (Option B), not `PrgEnv-amd`, unless
the site explicitly chooses `modules.platform_module_policy: autoload`. The
Spack GPU scope still declares the ROCm component packages individually; the
runtime module is not a stand-in for a single `rocm` Spack external.
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

For a CSE-like multi-lane stack, this composition rule means a system with a GPU
lane has, for that compiler, a core environment plus a `gpu-<provider>` lane
environment. A system with both serial/MPI lanes *and* a GPU lane under the same
compiler has serial, MPI, and GPU lane environments all composing with the one
`<compiler>/core` for that compiler. The user picks exactly one payload lane at a
time (the lane conflict rule); Core is present for that compiler. A simple stack
with one payload lane can choose not to render a separate Core lane at all.

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

### Tier 0 Manual Quickstart

Tier 0 skips `stack.yaml` and the renderer entirely. It is the shortest path to
prove a package on a system and the clearest demonstration that the generated
workspace is just Spack input.

Choose the scopes by hand:

| Scope | Carries | Include when |
|---|---|---|
| `configs/common` | concretizer, mirrors, common pins | Always. |
| `configs/os/<os>` | OS externals such as OpenSSL/curl | Always for production lanes. |
| `configs/target/<target>` | CPU target preference or requirement | Always, using the runtime node's CPU target. |
| `configs/vendor/<family>` | Vendor compiler/platform config | Cray PE or other vendor compiler stacks. |
| `configs/mpi/<provider>` | MPI provider and toolchain policy | MPI-enabled builds. |
| `configs/gpu/<vendor>` | GPU toolkit externals and arch variants | GPU-enabled builds. |

Then write one Spack environment directly:

```yaml
# environments/aocc/mpi-site/spack.yaml — hand-written Tier 0 example
spack:
  include::
    - ../../../configs/common
    - ../../../configs/mpi/site-mpi
    - ../../../configs/target/zen3
    - ../../../configs/os/sles15
  specs:
    - hdf5@1.14.5+mpi+fortran %aocc_site_mpi
    - netcdf-c@4.9.2+mpi %aocc_site_mpi
  view:
    default:
      root: /shared/stack/views/example-linux/manual/aocc/mpi-site
      projections:
        all: "{name}/{version}"
      link: roots
      link_type: symlink
```

The `%aocc_site_mpi` decoration on each spec names a toolchain defined in
`configs/mpi/site-mpi/toolchains.yaml`; toolchains belong to the MPI provider
scope, not to the environment. A Tier 0 author copies that toolchain file in
alongside the other scopes — see §Detailed Scenario: Generic Linux HPC With
Site MPI for the file's contents and the rationale.

Run Spack directly:

```bash
$ spack -e environments/aocc/mpi-site concretize
$ spack -e environments/aocc/mpi-site install -j 64
```

Tier 0 does not produce the full release metadata automatically. When the same
shape needs repeatable releases, move to Tier 1 by copying a starter
`stack.yaml`; the renderer writes the environment above from `profile.yaml`, the
starter stack, template defaults, and the template contract.

### Procedural Checklist

```text
1. Write or review systems/<system>/profile.yaml.
2. If using Tier 1 or above, write or review stacks/<stack>/stack.yaml.
3. Materialize the rendered release workspace, or hand-write the Tier 0 Spack environment.
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

Any step that cannot be explained by `profile.yaml`, `stack.yaml`, package sets,
selected package repositories, templates, or release vars is hidden policy and
should be moved into one of those artifacts.

## Render Step — Specification

The render step is the seam between source-of-truth (`profile.yaml`,
`stack.yaml`, package sets, templates) and runnable Spack input (the
rendered workspace). It is mechanical and deterministic. The normal
implementation is `spack-composer render`, but the step itself is a *contract*: anything
that satisfies the contract — a helper, a Make target, a human with a text
editor — produces a valid workspace.

### Inputs

| Input | Source | Role |
|---|---|---|
| `profile.yaml` | `systems/<system>/profile.yaml` | Platform facts. |
| `stack.yaml` | `stacks/<stack>/stack.yaml` | Stack intent. |
| Stack defaults | `templates/<set>/stack-defaults.yaml` | Template-owned defaults merged under `stack.yaml`. |
| Package sets | `package-sets/<name>.yaml`, only when referenced by `stack.yaml.builds[*].package_set` | Optional reusable root specs. |
| Package repositories | `package-repos/<name>/`, when selected by stack defaults or `stack.yaml.package_repositories` | Internal packages and local recipe overrides. Render emits `repos.yaml`. |
| Template contract | `templates/<set>/contract.yaml` | Accepted names and resolver meanings for `stack.yaml.builds[*].class`, `toolchain`, and `nodes`. |
| Templates | `templates/<set>/configs/...` and `templates/<set>/environments/...` | Jinja-style templates the step expands. |
| Release vars | Command-line, environment, or source-info file | `release_tag`, `output_dir`, build-cache mirror URLs, source repo URL/commit/dirty state, optional overrides. Helper convenience defaults are acceptable only when the resulting values are treated as explicit render inputs. |

### Outputs

| Output | Location | Purpose |
|---|---|---|
| Workspace tree | `<output>/<system>/<stack>/<release>/` | What Spack reads. |
| `configs/<scope>/...` | inside the workspace | Rendered config scopes. |
| `environments/<compiler>/<lane>/spack.yaml` | inside the workspace | Rendered lane environments. |
| `release-manifest.yaml` | inside the workspace | Provenance for the release (schema specified in Release Artifacts). |
| Render log | stderr or a log file | Human-readable record of which lanes were generated and which build requests were skipped. |

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
| **Render-time validation.** Schema-validate `profile.yaml`, merged `stack.yaml`, package sets, stack defaults, and the selected template contract; cross-check `stack.yaml.profile_contract.schema_version` against the profile; check that every build request carries exactly one of `specs` or `package_set`; check that referenced package sets exist; check that every build request names contract-defined `class`, `toolchain`, and `nodes` values; check that every spec source kind is compatible with the contract build class; check that contract resolver policies, node selectors, and matching `per_system` narrowing can resolve against the profile or templates. | Catch errors at the cheapest moment. |
| **`prefer:` not `require:` at the all-packages level.** When the renderer writes any `packages.all:` block, it uses `prefer:` for toolchain/target steering. `require: %<family>@<v>` at the `all:` level rejects untagged externals such as glibc, openssl, curl, ncurses, perl, python, libfabric, slurm, pmix, and pals because system libraries carry no compiler tag. The `%<family>@<v>` stamp belongs on the MPI provider external only, where the ABI claim is real. | Avoids an all-level require trap that breaks otherwise valid system externals. |
| **Render-time provenance derivation.** The renderer derives every package's provenance class (`Stack-built`, `Platform-backed`, `Site-external`, `Spack-built`) from raw facts in `profile.yaml` plus the selected contract and stack rules, not from a pre-labelled field the inspector wrote. | Keeps provenance classification in one revisable place and prevents inspector/renderer disagreement. |
| **Renderer identity.** The render step records its own name and version in `release-manifest.yaml.templates.render_tool`. | A reader can identify the exact tool that produced a workspace. |

Manual rendering uses the same manifest field: `render_tool.name: manual` and
`render_tool.version: null`. `spack-composer render` records its command name and version.
Timestamp fields in a draft manifest are explicit release variables supplied to
the render step. `spack-composer render` may default them for operator convenience, but
the render contract itself never calls the wall clock. If `rendered_at` changes,
that is a changed input, not ambient state.

### `spack-composer` Helper Commands

The `spack-composer` repo owns the stack-side tooling. Unlike
`cluster-inspector` (which is genuinely optional), `spack-composer` is the
supported entry point for the render → validate → publish workflow; the
purely manual path remains executable but is the exception.

The canonical design for `spack-composer` lives in
`docs/spack_composer_design_v1.md`: language choice (Python), repo shape,
packaging plan, per-command algorithm sketches, and implementation phases.
This section covers only the helper-command catalog and the render-step
seam contract; everything else lives in the companion doc.

| Command | Audience | Purpose |
|---|---|---|
| `spack-composer assess-profiles` | maintainer | Read the profile corpus and report template/contract coverage gaps. |
| `spack-composer scaffold-templates` | maintainer | Generate proposed template/contract stubs for review. Never commits policy automatically. |
| `spack-composer validate-template-set` | maintainer / CI | Render smoke stacks across profiles to prove a template set covers known systems. |
| `spack-composer explain` | package manager | Print valid compiler, MPI, GPU, and node names for one stack/template/system. |
| `spack-composer render` | package manager / CI | Instantiate the rendered Spack workspace. |
| `spack-composer validate` | package manager / CI | Validate profile, stack, package sets, package repos, and template contract without writing a workspace. |
| `spack-composer publish-manifest` | CI / package manager | Rewrite the draft `release-manifest.yaml` to `phase: final` after build, verify, and buildcache push. Records build host, lockfile digests, install provenance, platform-module prereqs, buildcache destinations, and verification results. |

The helper writes the workspace under
`<output-root>/<system>/<stack>/<release>/`. Pass the root; the helper
derives the rest from the profile and release vars. This matches the
determinism guarantee (same inputs → same output path).

```bash
# Assess the known systems before changing templates
spack-composer assess-profiles \
  --profiles 'systems/*/profile.yaml' \
  --templates templates

# Show a package manager the valid names for one target
spack-composer explain \
  --profile systems/example-cray/profile.yaml \
  --stack stacks/cse/stack.yaml

# Render a release workspace
spack-composer render \
  --profile systems/example-cray/profile.yaml \
  --stack stacks/cse/stack.yaml \
  --release 2026.06 \
  --output-root /tmp/rendered
# → workspace written to /tmp/rendered/example-cray/cse/2026.06/

# Validate without rendering
spack-composer validate \
  --profile systems/example-cray/profile.yaml \
  --stack stacks/cse/stack.yaml
```

### Render step pseudo-code

Language-neutral; the implementation may be Python, Make, Bash, or
something else. The shape is what matters.

```text
function render(profile_path, stack_path, package_sets_dir, package_repos_dir,
                templates_dir, release_vars, output_dir):

    # ── Inputs ────────────────────────────────────────────────────────────
    profile = load_yaml(profile_path)
    raw_stack = load_yaml(stack_path)
    require(raw_stack.templates.set, "stack.yaml must name templates.set")
    template_dir = templates_dir / raw_stack.templates.set

    defaults = load_yaml(template_dir / "stack-defaults.yaml")
    contract = load_yaml(template_dir / "contract.yaml")
    stack = merge_defaults(defaults, raw_stack)  # recursive maps, list replacement
    package_repos = resolve_package_repositories(stack, defaults, package_repos_dir)

    validate_schema(profile, "profile.v1")
    validate_schema(defaults, "stack_defaults.v1")
    validate_schema(stack,   "stack.v1")
    validate_schema(contract, "template_contract.v1")
    validate_package_repositories(package_repos)

    require(stack.profile_contract.schema_version == profile.schema_version,
            "profile schema does not match stack.profile_contract")

    require(profile.system.name == release_vars.system_name_or(profile.system.name),
            "system name override mismatch")

    spec_sources = {}
    for build in stack.builds:
        require(build.class in contract.build_classes,
                "unknown build class: " + build.class)
        require(build.toolchain in contract.toolchains,
                "unknown toolchain: " + build.toolchain)
        require(build.nodes in contract.node_selectors,
                "unknown node selector: " + build.nodes)

        cls = contract.build_classes[build.class]
        require(exactly_one(build.specs, build.package_set),
                "build " + build.name + " must set exactly one of specs or package_set")

        if build.specs:
            spec_source = make_inline_spec_source(build.name, build.specs, cls.package_set_kind)
        else:
            set_file = package_sets_dir / (build.package_set + ".yaml")
            require(set_file.exists, "missing package set: " + build.package_set)
            spec_source = load_yaml(set_file)
            validate_schema(spec_source, "package_set.v1")
            if spec_source.tier != "canonical":
                require(release_vars.allow_noncanonical,
                        "build " + build.name + " uses non-canonical set " + spec_source.name)

        require(cls.package_set_kind in spec_source.kinds,
                "spec source " + spec_source.name + " is not valid for class " + build.class)
        spec_sources[build.name] = spec_source

    rendered_lanes = []
    skipped_builds = []
    build_names = {build.name for build in stack.builds}
    narrowing = stack.per_system.get(profile.system.name, {})
    narrowing_builds = narrowing.get("builds", {})
    require(set(narrowing_builds.keys()).issubset(build_names),
            "matching per_system block names an unknown build")
    for build in stack.builds:
        lanes, reason_code, reason = resolve_build_request(build, contract, profile, template_dir)
        lanes, narrowing_result = apply_per_system_narrowing(
            lanes, narrowing_builds.get(build.name, {}), profile)
        if narrowing_result.emptied:
            reason_code = "per_system_empty"
            reason = narrowing_result.reason
        if lanes:
            rendered_lanes.extend(lanes)
        elif build.required:
            fail("required build " + build.name + " cannot render: " + reason)
        else:
            skipped_builds.append({"build": build.name,
                                   "reason_code": reason_code,
                                   "reason": reason})

    require(rendered_lanes, "no stack builds can render for profile " + profile.system.name)

    # ── Context ───────────────────────────────────────────────────────────
    ctx = build_render_context(profile, stack, defaults, contract, spec_sources,
                               package_repos, rendered_lanes, skipped_builds, release_vars)
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
        src = template_dir / "configs" / scope_name
        dst = pending / "configs" / scope_name
        render_template_tree(src, dst, ctx)

    # Selected package repositories are copied or symlinked into the workspace,
    # and configs/common/repos.yaml points Spack at those workspace paths.
    materialize_package_repositories(package_repos, pending / "package-repos")

    # ── Lane environments ────────────────────────────────────────────────
    for lane in rendered_lanes:
        lane_ctx = ctx | {
            "lane":     lane,
            "specs":    expand_spec_source(spec_sources[lane.source_build], lane, contract),
            "scopes":   scopes_for_lane(lane, stack, profile),
            "toolchain": toolchain_for_lane(lane),
            "view_root": view_root(profile, stack, lane, release_vars),
            "platform_module_prereqs": platform_module_prereqs_for_lane(lane, profile),
        }
        src = template_dir / "environments" / lane.kind / "spack.yaml.j2"
        dst = pending / "environments" / lane.compiler / lane.lane / "spack.yaml"
        render_template(src, dst, lane_ctx)

    # ── Release manifest ─────────────────────────────────────────────────
    write_yaml(pending / "release-manifest.yaml",
               build_manifest(ctx, pending, rendered_lanes, skipped_builds))

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

The functions called by `render` (`merge_defaults`, `resolve_build_request`,
`apply_per_system_narrowing`, `required_scopes`, `scopes_for_lane`,
`toolchain_for_lane`, `platform_module_prereqs_for_lane`, `view_root`,
`expand_spec_source`, `build_manifest`) are pure transformations of the frozen
context. None of them touches the host.

### Failure modes the render step catches

These should fail *at render time*, not at Spack-build time, because they
are cheaper to fix here:

- Missing required profile key.
- Profile schema mismatch with `stack.yaml.profile_contract`.
- Missing or invalid `templates/<set>/contract.yaml`.
- Missing or invalid `templates/<set>/stack-defaults.yaml`.
- A build request has neither `specs:` nor `package_set:`, or has both.
- `stack.yaml.builds[*].package_set` references a nonexistent file.
- A selected package repository is missing `repo.yaml`, has a duplicate
  namespace, or would shadow builtin packages without an explicit priority.
- A build request names a `class`, `toolchain`, or `nodes` value not present in the selected template contract.
- A build request's contract class requires a spec kind that the inline specs or package set cannot satisfy.
- A required build request resolves through the contract to a compiler/provider the profile or templates cannot satisfy.
- A required GPU build request resolves through the contract but no matching `profile.node_types[*].gpu` block exists.
- A matching `per_system.<profile.system.name>` narrowing block names a compiler, MPI provider, or GPU arch absent from the profile or resolved candidates.
- A matching `per_system.<profile.system.name>.builds` block names a build absent from `stack.yaml.builds[*].name`.
- A matching `per_system` narrowing block empties a required build request.
- A generated site-external lane's platform-module prerequisites cannot be
  resolved (the named modules are not declared on any external in the profile).

When a non-required build is emptied by `per_system` narrowing or by any other
condition above that does not fail render, the render step writes a
`skipped_builds[*]` entry carrying a stable `reason_code` (one of
`per_system_empty`, `nodes_unmatched`, `requires_unsatisfied`,
`template_not_supported`) plus a human-readable `reason`. Downstream tooling
matches on `reason_code`; the `reason` text is free-form. Partial narrowing
that drops some lanes from a build without emptying it is recorded under
`templates.applied_narrowing` in the manifest, not under `skipped_builds`.

### Driving Spack From The Rendered Workspace

The render step ends at the rendered workspace. The build half — concretize,
install, smoke, ldd, manifest-verify, buildcache push — has three supported
paths:

1. **`spack-build`** (the committed default for everything except Ansible-managed
   production): a standalone shell script shipped with `spack-composer` and
   installed onto `$PATH`. Takes `--workspace <dir>` plus optional lane filters,
   runs Spack per lane, writes per-lane reports, and emits the three roll-up
   files (`verify-results.yaml`, `buildcache-destinations.yaml`,
   `platform-module-prereqs.yaml`) that `spack-composer publish-manifest`
   consumes. See `docs/spack_composer_design_v1.md` §Companion Script:
   `spack-build` for the CLI contract and per-lane flow.
2. **Ansible** (the production path on multi-host clusters): see §Ansible —
   Specification. The playbook may call `spack-build` per host or replicate
   its loop; either is supported.
3. **Bare Spack commands by hand** (the manual fallback): the §Example Cray
   Flow and §Example Generic Linux HPC Flow walkthroughs show the exact
   command sequence. This is the path that is always available without any
   helper installed.

The two helpers (`spack-build` and Ansible) own *how* Spack is invoked.
`spack-composer` itself never calls Spack and never reads host state during
render. The split keeps render byte-deterministic and lets each site customize
build orchestration without forking the render engine.

**Version enforcement is owned by `spack-build`** (or by Ansible when it
drives Spack directly). Before any lane runs, the driver compares the
selected Spack install's `spack --version` against `stack-defaults.yaml.spack.floor`
and the optional `stack.yaml.spack.version` pin; mismatches refuse to build.
See §Spack Version Floor for the three-layer model.

### Template Render Context

A template author needs to know what variables `render()` makes available
to scope templates and lane environment templates. The contract below is
authoritative: if a template references a name not listed here, the render
step exits non-zero (Jinja's `StrictUndefined`). Two contexts are passed:

| Context | Used by | Source |
|---|---|---|
| `ctx` | Scope templates under `templates/<set>/configs/<scope>/...` | `build_render_context()` |
| `lane_ctx` | Lane environment templates under `templates/<set>/environments/<lane_kind>/spack.yaml.j2` | `ctx` plus per-lane fields |

Both contexts are *frozen*: templates may read keys but cannot mutate them,
nor can they introduce side effects. Two renders with the same context bytes
produce the same output bytes.

**`ctx` keys.** Available in every template.

| Key | Type | Contents |
|---|---|---|
| `profile` | map | Full validated `profile.yaml` content. Templates address it as `profile.system.family`, `profile.os.name`, `profile.fabric.type`, `profile.vendor_cray` (may be null), `profile.node_types`, etc. |
| `stack` | map | Merged `stack.yaml` — template defaults underneath, user keys on top. Same shape as the user `stack.yaml`. |
| `defaults` | map | The raw `stack-defaults.yaml` content (un-merged). Useful when a template needs to distinguish "the user asked for this" from "the default supplied this". |
| `contract` | map | Parsed `templates/<set>/contract.yaml`. Resolver-policy names and the GPU/node selector menus live here. |
| `package_repos` | list | Resolved package-repository selection: `{name, path, namespace, priority, source_commit}` per entry. |
| `spec_sources` | map | Map of `build.name → resolved spec source`. An inline spec source has `{kind: "inline", kinds: [...], specs: [...]}`; a package-set spec source has the loaded `package_set.v1` content. |
| `rendered_lanes` | list | Resolved release plan — one entry per lane that will render. Each entry carries `{name, source_build, compiler, lane, kind, package_set, target, runtime_node_type, gpu_arch (or null)}`. |
| `skipped_builds` | list | Skip entries `{build, reason_code, reason}` for non-required builds that did not render. Empty when every requested build rendered. |
| `applied_narrowing` | map or null | `{system, builds: {<build>: {dropped_lanes, narrowed_by}}}` when `per_system` narrowing dropped at least one candidate; `null` otherwise. |
| `release_vars` | map | Release-time inputs the operator passed to render: `{release_tag, system_name, output_root, mirror_urls, source_repo: {url, commit, dirty}, rendered_at, overrides}`. |
| `renderer_identity` | map | `{name, version}` of the render tool. Written into the manifest; templates may reference it for self-identification in generated comments. |

**`lane_ctx` keys.** `lane_ctx` is `ctx` plus the following per-lane keys.
Available only in lane environment templates.

| Key | Type | Contents |
|---|---|---|
| `lane` | map | The single `rendered_lanes` entry this render is for. |
| `specs` | list | Expanded root specs for this lane, after spec-source expansion against the build class's `package_set_kind`. |
| `scopes` | list | Ordered list of scope paths this lane's `include::` block should reference, e.g., `["../../../configs/common", "../../../configs/os/rhel8", "../../../configs/target/zen3", "../../../configs/mpi/cray-mpich"]`. |
| `toolchain` | map | Fully resolved toolchain for this lane: `{compiler: {name, version, spec}, mpi: {name, version, provider, spec}, gpu_toolkit: {name, version, prefix, spec or null}}`. The resolver policies named in `contract.toolchains[*]` have already been evaluated against the profile. |
| `view_root` | string | Absolute view-root path for this lane, derived from `profile.filesystem.install_tree_candidates`, `stack.modules`, and `release_vars.release_tag`. |
| `platform_module_prereqs` | list | Modules this lane will need at runtime because it consumes site-external providers (e.g., `["PrgEnv-gnu", "cray-mpich/8.1.29", "rocm/6.0.0"]`). Empty when the lane has no site-external dependencies. The lane's front-door modulefile reads this list to write `prereq` lines. |

**Jinja environment.** The render engine constructs a single Jinja environment
per render with these settings:

- `StrictUndefined` — any reference to a missing key fails render.
- Auto-escape **off** — output is YAML, not HTML.
- No filesystem loader access outside `templates/<set>/`. Templates cannot
  `include` arbitrary host paths.
- No globals beyond what is listed here. Standard Jinja built-in filters are
  available. A small set of safe helpers is also exposed:
  - `to_yaml(value)` — emits a YAML-quoted scalar or block, used for
    embedding context values into the rendered Spack config without quoting
    errors.
  - `spack_spec(parts)` — joins a structured spec dict into a Spack spec
    string (e.g., `{name: "hdf5", version: "1.14.5", variants: ["+mpi"]}`
    → `hdf5@1.14.5 +mpi`).
  - `path_join(*parts)` — POSIX path join; never reads the host filesystem.

**Templates must not.**

- Reference any name not in the tables above (fails at render).
- Call `os.environ`, read `/etc/`, `module list`, or any host state.
- Reference `release_vars.rendered_at` in a way that affects byte-for-byte
  determinism unless the operator passed `rendered_at` as a release variable.
- Import other Jinja files outside `templates/<set>/`.
- Mutate any context value. (Frozen at construction; mutation raises.)

When a template needs information that is not in the context tables, the
answer is to extend the renderer to add the field — not to read it from the
host at render time. Render-step purity is what makes determinism testable.

## cluster-inspector — Seam Contract

`cluster-inspector` is the read-only system inspector that produces
`profile.yaml`. It is *optional* by design: any human or other tool can
produce a valid profile, and the rest of the stack does not call into
`cluster-inspector` at build time.

The **canonical inspector design** lives in two companion documents:

- `cluster_inspector_stack_profile_design_v1.md` — product boundary, CLI
  contract, repo shape, language decision (Go), packaging plan, and
  implementation phases.
- `cluster_inspector_profile_extraction_map_v1.md` — field-by-field probe
  map for every key in `profile.yaml`, with extraction, normalization,
  confidence, and fallback rules.

This section records only what the rest of the stack design depends on:
the contract at the seam between inspector output and renderer input. If
the two documents above ever disagree with this seam, they win for
inspector internals and this section wins for what `profile.yaml` must
contain.

### What the renderer requires from `profile.yaml`

The full reference schema is in §Durable Inputs / `profile.yaml`. The
inspector (or a hand-author) must produce a file matching that schema.
Render-time validation enforces the seam:

- All required top-level blocks present: `schema_version`, `system`,
  `os`, `fabric`, `modules_system`, `vendor_cray` (may be null),
  `compilers_external`, `mpi`, `gpu_toolkit_modules`, `filesystem`,
  `node_types`, `capabilities`.
- Required fields populated with `probed` or `inferred` confidence;
  `unknown` is allowed only for fields the selected stack does not need.
- At least one `node_types[*]` entry with `role: build_host` or `both`.
- Cray MPI lane capability appears only when a matching
  `vendor_cray.cray_mpich.flavors.<compiler>` exists.
- AMD GPU node types have coherent ROCm component externals under
  `gpu_toolkit_modules.rocm.spack_components`.
- Capability entries (`capabilities.lanes_capable[*].runtime_node_types`)
  reference node types that are actually present.

The inspector is **not** the only producer. A hand-written profile that
satisfies the same schema is just as valid; the manual workflow remains
the baseline.

### Explicit non-goals

These belong to other stages and are *not* `cluster-inspector`'s job.
The non-goals are restated here because every one of them is a seam the
renderer relies on:

- **No render.** `cluster-inspector` does not produce `spack.yaml`, scopes, or
  modulefiles. Those are the render step's outputs.
- **No templates or contracts.** `cluster-inspector` does not generate
  `templates/<set>/contract.yaml`, `stack-defaults.yaml`, or template trees.
  Profile corpora may feed `spack-composer assess-profiles` and
  `spack-composer scaffold-templates`, but those advisory maintainer tools live
  on the stack side.
- **No Spack calls.** `cluster-inspector` does not run `spack concretize`,
  `spack install`, or any other Spack command. Spack may be installed on the
  same host, but the inspector does not depend on it.
- **No `packages.yaml` emission.** Externalization is a render-step decision;
  the inspector emits raw facts such as install prefixes, module names, vendor
  strings, and languages present, then stops there.
- **No provenance classification.** The four-class provenance taxonomy
  (`Stack-built`, `Platform-backed`, `Site-external`, `Spack-built`) is derived
  at render time from raw profile facts plus the contract. The inspector does
  not label packages with a provenance class, and the profile schema has no
  `provenance:` field for the inspector to populate.
- **No deploy.** `cluster-inspector` does not copy files anywhere, does not
  modify the system, and does not interact with Ansible.
- **No package decisions.** Anything that depends on "what the stack wants
  to build" is stack intent and lives in `stack.yaml`, not the profile.

### Operational rules visible at the seam

The renderer and downstream tooling rely on these properties of any
profile producer (the inspector or a human):

- **Read-only on the host.** The producer never modifies system state.
  A writability test for a build-stage candidate may create a tiny probe
  file and must remove it before reporting.
- **Deterministic output.** Same inputs and observed facts produce the
  same `profile.yaml` bytes. The producer is safe to re-run; the renderer
  caches and validation rely on stable output.
- **One artifact.** The durable output is `profile.yaml`. Diagnostics,
  evidence reports, and rejected candidates may exist as sibling files
  but are not consumed by the renderer.
- **Inspector is optional.** A hand-authored `profile.yaml` against the
  schema in §Durable Inputs is equally valid input to the renderer.

### CLI shape used in the worked examples

The end-to-end walkthroughs (§Example Cray Flow, §Example Generic Linux
HPC Flow) use the inspector's committed CLI verbs: `cluster-inspector
profile` (all-in-one), `cluster-inspector probe-system`, `cluster-inspector
probe-node`, `cluster-inspector merge`, and `cluster-inspector verify`.
A hints file at `systems/<system>/inspector-hints.yaml` is the committed
override mechanism for module discovery; see the canonical inspector
design for the full hints schema, discovery flow, and shell discipline
rules (non-login shells; controlled module verification).

## Ansible — Specification

Ansible is the orchestration layer. Like `cluster-inspector` and the render
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
  step is the rendering authority. Ansible may call `spack-composer render`, but
  it does not duplicate its work.
- Replacing Spack. Spack is the build engine; Ansible drives it, does not
  substitute for it.

### Role decomposition

| Role | Responsibility |
|---|---|
| `preflight` | Validate profile, stack, and release inputs exist; check Spack version on the host; refuse to proceed on schema mismatch. |
| `render-if-needed` | If a pre-rendered workspace was supplied, skip. Otherwise call `spack-composer render` locally. |
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
  platform-module prerequisite lists, scheduler args, and mirror URLs live in
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
          run_locally: spack-composer render
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
          run: spack -e {{ release_dir }}/{{ lane.env_path }} concretize
          run: spack -e {{ release_dir }}/{{ lane.env_path }} fetch -D
          collect_artifact: spack.lock
              → "{{ release_dir }}/{{ lane.env_path }}/spack.lock"

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
            env: "{{ release_dir }}/{{ lane.env_path }}"
            args: "{{ scheduler_args }}"     # e.g. --partition=gpu --constraint=mi250x
            command: |
              spack -e <env> install -j {{ build_jobs }} \
                                     --show-log-on-error
          collect: logs, exit code
      - wait_all
      - for lane in core_lanes:
          assert: install exit code == 0
          run: spack -e <env> buildcache push --update-index --unsigned {{ buildcache_push_url_for(lane, release_manifest) }}

  - role: install-lanes
    tasks:
      - for lane in non_core_lanes:
          set_fact:
            target_class: "{{ lane.runtime_node_type }}"
            scheduler_args: "{{ scheduler_args_for(target_class) }}"
          submit_scheduler:
            env: "{{ release_dir }}/{{ lane.env_path }}"
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
          run: generate exposure-mode modules from the stack-owned template for {{ lane.name }}
          run: spack -e <env> buildcache push --update-index --unsigned {{ buildcache_push_url_for(lane, release_manifest) }}
      - write_yaml:
          dest: "{{ release_dir }}/release-manifest.yaml"
          content: "{{ build_manifest(stack, profile, release, lane_results) }}"

  - role: verify-user
    tasks:
      - for public_entry in rendered_public_entries:
          run_clean_shell: |
            module use {{ release_dir }}/modules
            module load {{ public_entry.module_name }}
            {{ site_smoke_test_command }} {{ public_entry.lane_name }}
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
#   - Per-system data (lane matrix, platform-module prereqs, scheduler args, mirror
#     URLs) lives in inventory/host_vars, not in the playbook.
#   - Failures of one lane do not silently skip subsequent lanes; the
#     play either fails-fast or collects-and-reports per stack policy.
```

### Inventory shape

The lane matrix, platform-module prerequisite lists, and scheduler arguments are per-host
data. The playbook above reads `inventory/host_vars/<host>.yml`; a Cray
host's file looks like:

```yaml
# inventory/host_vars/cray01.yml
system:        example-cray
stack_name:    cse
build_jobs:    64
modules_tool:  tcl

buildcache_mirror:        file:///shared/stack/buildcache/payload/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/example-cray
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

### GPU Toolkit Scopes: CUDA Versus ROCm

CUDA and ROCm do not have the same Spack external shape.

CUDA can usually be represented by one `cuda` external package plus a
`cuda_arch` default in `packages.yaml`:

```yaml
packages:
  all:
    variants: cuda_arch=90
  cuda:
    buildable: false
    externals:
      - spec: cuda@12.4
        prefix: /opt/cray/pe/cudatoolkit/12.4
```

ROCm is different. Spack decomposes ROCm into component packages, so
`configs/gpu/amd-rocm/packages.yaml` must declare a coherent set of component
externals for the installed ROCm version. A `rocm/<version>` module is useful
for the front-door runtime environment, but it is not a sufficient Spack
external by itself.

Representative ROCm 5/6 shape:

```yaml
packages:
  all:
    variants: amdgpu_target=gfx90a

  hip:
    buildable: false
    externals:
      - spec: hip@6.0.0
        prefix: /opt/rocm-6.0.0/hip

  hsa-rocr-dev:
    buildable: false
    externals:
      - spec: hsa-rocr-dev@6.0.0
        prefix: /opt/rocm-6.0.0

  comgr:
    buildable: false
    externals:
      - spec: comgr@6.0.0
        prefix: /opt/rocm-6.0.0

  rocblas:
    buildable: false
    externals:
      - spec: rocblas@6.0.0
        prefix: /opt/rocm-6.0.0

  hipblas:
    buildable: false
    externals:
      - spec: hipblas@6.0.0
        prefix: /opt/rocm-6.0.0

  hipsparse:
    buildable: false
    externals:
      - spec: hipsparse@6.0.0
        prefix: /opt/rocm-6.0.0

  rocprim:
    buildable: false
    externals:
      - spec: rocprim@6.0.0
        prefix: /opt/rocm-6.0.0/rocprim

  llvm-amdgpu:
    buildable: false
    externals:
      - spec: llvm-amdgpu@=6.0.0
        prefix: /opt/rocm-6.0.0
        extra_attributes:
          compilers:
            c: /opt/rocm-6.0.0/bin/amdclang
            cxx: /opt/rocm-6.0.0/bin/amdclang++
```

That list is representative, not universal. The exact component list is a
versioned template input for the stack and should be copied from Spack's current
ROCm external guidance or from a vetted site configuration, then adjusted to the
installed ROCm version and prefixes. `spack external find` may discover some
ROCm packages, but it is not relied on to produce a complete, internally
consistent ROCm component set. ROCm 7 should be revalidated before reusing the
ROCm 5/6 list.

Lane environments choose scopes with `include::`; they do not duplicate all
platform policy inline.

## Lane Model

Common lane kinds:

| Lane kind | Purpose |
|---|---|
| Core | Shared build tools and user tools that are not compiler/MPI/GPU sensitive. |
| Serial | User-facing serial libraries and tools. |
| MPI | User-facing MPI-enabled libraries and MPI provider policy. |
| GPU | GPU-enabled packages and performance portability layers. |

These are the default template categories used by CSE-like stacks. They are not
a requirement that every stack use all four. A small curated application stack
may have one payload lane, no serial/MPI split, no GPU lane, and no separate Core
lane; users can then load the stack's package modules directly after the site
adds the module root. Variant-rich stacks should use front-door lane modules so
users choose exactly one compiler/MPI/GPU surface before loading packages.

When a stack uses Core, Core packages can include build tools and stable tools
such as CMake, Ninja, pkgconf, Git, and selected Python tools. Packages that are
ABI-sensitive, compiler-sensitive, MPI-linked, or GPU-runtime-sensitive should
stay in payload lanes.

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
   `runtime_node_type` values differ, their `platform_module_prereqs` differ
   (the GPU lane requires `rocm/<v>` or `cudatoolkit/<v>` at runtime; the MPI
   lane does not), and Ansible places each lane's install job on the matching
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

Two user-facing stack module loads. The same shape as a plain MPI user. The lane
*choice* is wider on a system with multiple GPU classes (for example eight CSE
lanes instead of the smaller CPU-only menu), but the stack workflow is unchanged.
The front-door module is the single point that records/checks the per-lane
platform-module requirements (`PrgEnv-gnu` + `rocm/<v>` + `cray-mpich/<v>` for a
GPU lane vs. just `PrgEnv-gnu` + `cray-mpich/<v>` for an MPI lane). A site that
opts into autoload may have the front-door module load those platform modules,
but the default is prerequisite checking.

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

**Lanes are derived, not enumerated.** The renderer computes the lane set by
intersecting profile facts (compilers, MPIs, GPU classes, node types) with
template-contract constraints (which compiler, lane kind, language, and runtime
node combinations are buildable). The result is the full set of viable lanes for
that `(profile, contract, stack)` tuple. There is no separate `lane-sets/`
directory and no hand-maintained lane list; the lane set is a function of the
inputs, not a stored artifact.

The `per_system:` blocks in `stack.yaml` exist only to **prune** entries from the
derived set. They cannot add lanes the derivation would not have produced. If a
lane is missing, the gap is in `profile.yaml` or the template contract, and that
is the right place to fix it.

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

Eight lanes on a fully-populated Cray with two GPU classes is the realistic
ceiling for the first deployments. Seven is the typical one-GPU-class Cray case;
six is the CPU-only Cray case. The user sees these as a flat menu of front-door
module names; they pick the one that matches their partition and compiler
preference.

### Curating Core Membership

User-facing package exposure is a stack decision, and Core membership is a
curated stack-maintainer decision. Package managers should not have to rediscover
Core when they add or update payload packages. They normally edit payload
package sets; the existing `core-foundation` set is part of the stack template
contract.

The reason is the same as the multi-version rule above: payload lanes carry
multiple HDF5/NetCDF/etc. versions, and their dependency closures can pull
different versions of low-level libraries. Exposing those low-level libraries
through Core only works when Core stays unambiguous for a user's fresh compile.
The stack's job is not just to build itself; it is to give users a coherent
environment they can compile against after loading one front-door lane.

Reference stacks and public build-cache inventories are useful evidence, but not
authority. `cache.spack.io`, E4S inventories, `spack-stack`, and lab/site configs
can show which packages appear repeatedly across supported stacks, releases,
targets, variants, and dependency graphs. Use that as seed data for maintainer
review. Do not register those public caches as production reuse sources for this
stack, and do not promote a package to Core merely because it appears in a public
cache. A public cache answers "what was built somewhere"; Core answers "what do
we intentionally expose to users in every lane on this system."

Maintainer audit workflow when changing Core or onboarding a substantially
different system:

1. Start from the existing `core-foundation` set plus reference evidence from
   public stack inventories (`cache.spack.io` stack/dependency views, E4S,
   `spack-stack`, lab configs), not from an arbitrary list of convenient
   utilities.
2. Compare those candidates against the canonical payload package sets.
3. Concretize representative payload lanes with all requested user-facing
   versions.
4. Inspect the concrete dependency closures and identify dependencies shared
   across the payload roots.
5. Promote a dependency to Core only if it is safe to expose with every lane in
   that compiler column: build-only tool, user tool, or stable C/ABI dependency
   that can be pinned to one version without breaking the payload solves.
6. Keep dependencies in the lane, or private behind RPATH, when the payload
   closure genuinely needs multiple versions or when the dependency is MPI-,
   GPU-, Fortran-module-, or C++-ABI-sensitive.
7. If the evidence justifies a Core change, update
   `package-sets/core-foundation.yaml` and the single-version ABI pins in
   `stack.yaml.foundation_pins` / `configs/common` through normal stack review.

The default answer for a new dependency is conservative: leave it in the lane or
private behind RPATH. Promote it to Core only when a concrete solve and
user-compile check prove that exposing it does not create ambiguity.

An installed transitive dependency is not automatically user-facing. If `hdf5`
pulls in `libfoo`, HDF5 can still work because its binaries and exported metadata
point at the concrete dependency. If users need to compile directly against
`libfoo`, then `libfoo` must become an explicit root package in Core or in the
appropriate serial/MPI/GPU lane. That exposure change may reuse the already-built
concrete spec or buildcache entry, but it is still a deliberate package-set
change, not an accident of something being present in the Spack install tree.

Dependency placement can often be classified from the concretized DAG:

- Build-only dependencies are Core candidates because they produce no linked ABI.
- Plain-C stable-ABI link dependencies may be Core candidates.
- MPI-linked packages stay in the MPI lane.
- Fortran module producers stay in the compiler/MPI lane.
- C++ ABI-sensitive libraries stay in the compiler-specific lane.
- GPU-backend packages stay in the GPU lane.

This keeps Core from becoming a catch-all. Core means "safe to compose across
lanes on this system," not "small utility package." A package that is useful but
would put two versions of the same user-linkable dependency on the compile path
does not belong in Core; it belongs in the lane that needs it.

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
- CUDA can usually be one Spack `cuda` external; ROCm must be a coherent set of
  component externals (`hip`, `hsa-rocr-dev`, `comgr`, `rocblas`, etc.).
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

Compiler propagation should be scoped to lane roots and payload subtrees, not to
the whole foundation. The committed model is **per-compiler Core** (see
§Per-Compiler Core, Not Shared Core): each compiler builds its own Core, including its own
build tools (CMake, Ninja) and its own foundation stable-ABI libraries (zlib,
xz, zstd). Binary reuse happens *within* a compiler — a CCE payload lane
reuses CCE's Core build of CMake — not *across* compilers. The hash carries
the compiler, so cross-compiler reuse is not what the foundation cache is
doing.

The desired behavior is:

```text
Each compiler's Core builds at the baseline (x86_64_v3) target.
Each payload lane reuses its own compiler's Core from the foundation cache.
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

**Two-tier rule for inspector-detected externals.** The render step partitions
externals the inspector reports into two tiers:

- **Strict tier (`buildable: false`).** The only general Linux libraries that
  belong here by default are **OpenSSL and curl**. Site administrators patch them
  through the distro package manager; rebuilding them under the stack duplicates
  that CVE treadmill and produces a parallel binary the OS does not know about.
  Vendor compilers, vendor MPI on fabric-coupled systems, Slurm, glibc, and the
  system Python that invokes Spack may also be force-external, but those are
  platform contracts rather than promoted general-library hints.
- **Hint tier (`buildable: true`).** Other system libraries the inspector finds,
  such as PMIx, libfabric, UCX, ncurses, hwloc, libpciaccess, and rdma-core, are
  declared as externals so the solver may reuse them, but `buildable: true` is
  preserved so the solver may build a newer version when a consumer's constraints
  exceed what the site provides. The external is a hint, not a pin.

The render step does not allow new general Linux libraries to migrate into the
strict tier without an explicit design decision. The strict list is intentionally
small.

**Why hints, not pins.** The PMIx failure mode is the canonical case. A system
PMIx 2.2.x external emitted as `buildable: false` can satisfy an
under-constrained `depends_on("pmix")` in the solver even when a consumer such as
MPICH 4.x uses PMIx 4.x symbols. The solve succeeds, but the build fails on
missing symbols. Keeping PMIx as `buildable: true` lets the solver build a newer
PMIx when constraints require it. If an upstream recipe is under-constrained,
carry the version floor in the stack-controlled root spec, such as
`mpich ... ^pmix@4`, not in the external declaration.

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

OpenSSL and curl are the only general Linux libraries that ship as strict-tier
(`buildable: false`) externals by default. Site administrators patch them through
the distro package manager, so the stack should not duplicate that CVE rebuild
treadmill with parallel binaries.

Rules:

- Declare the true system version (run `spack external find openssl curl` on
  the target to get it). The version string is an assertion Spack trusts; do not
  falsely relabel a patched distro OpenSSL 1.1.1 as 3.x to satisfy a newer API
  claim.
- Set `buildable: false` for both in every rendered `packages.yaml`.
- Variant declarations matter. A `buildable: false` external must list every
  relevant variant the recipe expects, or Spack may report that no external
  satisfies concretization. curl in particular needs its TLS and common feature
  variants declared explicitly, such as `+nghttp2 +libidn2 tls=openssl`, when
  those match the system build.
- **Do not attach a compiler to system externals** — `openssl %gcc` on an
  external is wrong. See the *Externals Carry No `%compiler` Attachment* rule
  above; OpenSSL and curl are pure system externals and have no compiler tag.
- Use a per-consumer escape, not a site-wide flip. If a specific consumer
  genuinely needs OpenSSL 3.x APIs that the system does not provide, add
  `^openssl@3` to that consumer's spec and declare a second openssl external, or
  allow a stack-built OpenSSL only for that consumer. Do not relax the site-wide
  system OpenSSL entry to `buildable: true`. If a stack-built OpenSSL is needed
  for that exception, link it against the system CA certificate bundle so cert
  updates cost nothing.

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
sets the host-compiler default for GPU lanes, but the framework's full lane
vocabulary is a three-kind taxonomy.

#### The Three Lane Kinds

| Kind | Shape | Members | Typical spec coverage |
|---|---|---|---|
| **Kind-1 — Pure CPU** | `(compiler, mpi)` | compiler from the general-purpose set such as gcc, aocc, intel, or cce; MPI from the profile inventory | Wide. Any spec that builds under the compiler. |
| **Kind-2 — GPU with general-purpose host compiler** | `(host_compiler, mpi, gpu_toolkit)` | host compiler from the general-purpose set; toolkit is cuda or rocm and is invoked per spec for `+cuda` / `+rocm` variants | Wide: same as kind-1 for non-GPU specs, plus the GPU-toolkit-pinned subset. This is the default GPU lane shape. |
| **Kind-3 — GPU-aware compiler** | `(gpu_aware_compiler, mpi)` | compiler is nvhpc or rocmcc/amdclang; the GPU toolkit is bundled into the compiler family | Restricted. Covers specs that genuinely benefit from the compiler's GPU-side features. |

**Kind-2 is the committed default for GPU deployment.** On NVIDIA systems this
means GCC or another general-purpose host plus CUDA toolkit. On AMD systems it
means GCC or another general-purpose host plus ROCm component externals. The
general-purpose host compiler handles the wide spec graph; the GPU toolkit is
invoked only where a package asks for GPU support.

**Kind-3 is an opt-in specialist lane**, not a deprecated form:

| Kind-3 compiler | When it is the right tool | Coverage shape |
|---|---|---|
| **NVHPC** | OpenACC code, CUDA Fortran, `-stdpar` GPU offload, codes written against the NVIDIA HPC SDK | Drops general-stack specs that do not build under NVHPC. |
| **ROCmCC / amdclang** | HIP single-source compilation, AMD-vendor codes that need amdclang/amdflang features, OpenMP target offload to AMD | Restricted to languages and packages ROCmCC can honestly provide for that ROCm release. |

AOCC is a kind-1 question, not kind-3: it has no GPU relationship, so its
inclusion is governed by whether measured CPU performance versus GCC justifies a
parallel CPU lane on Zen.

**Compiler-family lane purity rule.** When a lane's compiler cannot build a spec
because a language is unsupported, the recipe gates a provider, or the upstream
build is broken under that compiler, drop the spec from the lane and document
why. Do not silently route the unbuildable language to another compiler. Silent
fallback makes the lane name lie about what built the package and can introduce
mixed-compiler ABI risk.

Slug convention:

- Kind-1: `<compiler>-<mpi>`, such as `gcc-openmpi` or `cce-craympich`.
- Kind-2: `<host_compiler>-<mpi>-<gpu_toolkit>`, such as
  `gcc-craympich-rocm` or `gcc-openmpi-cuda`.
- Kind-3: `<gpu_aware_compiler>-<mpi>`, such as `nvhpc-nvompi` or
  `rocmcc-craympich`.

The Cray PE version carve-out in the committed decisions applies when the MPI is
`cray-mpich`: the slug gains a PE-version token, and a rolling window of two PE
versions may coexist.

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
libraries, and the GNU-matched cray-mpich flavor. The host compiler is GCC
(matching the host-compiler policy); the GPU toolkit module provides the runtime
environment. For CUDA, the Spack scope can usually point at one `cuda` external.
For ROCm, the Spack scope must additionally declare the ROCm component externals
that packages depend on. This is the **recommended way** to assemble Cray PE +
GPU lanes.

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
    spack_components:
      - { package: hip,          prefix: /opt/rocm-6.0.0/hip }
      - { package: hsa-rocr-dev, prefix: /opt/rocm-6.0.0 }
      - { package: comgr,        prefix: /opt/rocm-6.0.0 }
      - { package: rocblas,      prefix: /opt/rocm-6.0.0 }
      - { package: hipblas,      prefix: /opt/rocm-6.0.0 }
      - { package: hipsparse,    prefix: /opt/rocm-6.0.0 }
      - { package: rocprim,      prefix: /opt/rocm-6.0.0/rocprim }
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
front-door module requires `PrgEnv-gnu` + `rocm/<version>` +
`cray-mpich/<version>` at runtime:

```tcl
# Front-door module for the gfx90a lane under Option B
prereq PrgEnv-gnu
prereq gcc-native/13
prereq rocm/6.0.0
prereq cray-mpich/8.1.29
```

The exception-lane equivalents would substitute `PrgEnv-amd` + `rocm/...`
(Option A — used only for an NVHPC- or ROCmCC-specific code) or
`PrgEnv-cray` + `rocm/...` (Option C — used only for a CCE-host GPU code).
The lane name, the spec compiler, the `runtime_node_type`, and the
front-door module prerequisites all move together — the render step keeps them
consistent because they all come from the same lane entry in `stack.yaml`.

**NVIDIA on Cray: same shape, different modules.** Where the PE exposes
NVIDIA support (`PrgEnv-nvidia`/`PrgEnv-nvhpc` on releases that ship it,
`cudatoolkit` as a separately loadable module), the same three-option
choice applies and the same default (Option B: GNU + CUDA toolkit module)
holds. The NVHPC exception lane uses `PrgEnv-nvidia` directly because the
code wants NVHPC's compiler driver, not just its libraries.

| Option | Committed use | Lane compiler | Lane platform-module prereqs |
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
payload lanes can reuse it. These checkpoints are sequential per
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

There are two supported exposure modes:

- **`front_door`** for variant-rich stacks. Users first load one lane selector
  such as `CSE/GCC/mpi-craympich`, then load package modules from the lane's
  package module root. This is the CSE default because compiler/MPI/GPU variants
  must conflict cleanly.
- **`direct`** for small application stacks. Public package/application modules
  are published directly under an existing site MODULEPATH root, for example
  `fun3d/14.2-cpu-zen3` or `fun3d/14.2-gpu-gfx90a`. There may still be multiple
  rendered lanes behind those modules, but users do not load a separate stack
  gate first.

Front-door lane modules, when `modules.exposure: front_door`, should:

- Set stack identity variables such as release, stack name, compiler, and lane.
- Prepend the lane package module root to `MODULEPATH`.
- Prepend the compiler's Core module root to `MODULEPATH` (per-compiler Core, so
  every lane composes with its own compiler's Core).
- Set view metadata such as `STACK_VIEW`; package modules, not front-door
  modules, prepend package-specific paths from clean views.
- Declare conflicts with other mutually exclusive lane modules.
- Check or declare required platform-module prerequisites for module-provided
  externals (see Lane Runtime Module Requirements below).

Direct or lane package modules should:

- Expose package-specific roots from clean views.
- Avoid broad implicit dependency pollution.
- Make provenance visible (see Provenance In Modulefiles below).
- In `direct` exposure mode, carry the runtime external module checks and
  conflicts that a front-door lane module would otherwise carry.

Module generation outputs depend on the exposure mode. In `front_door` mode the
release publishes stack-owned lane front-door modules plus package modules. In
`direct` mode the release publishes public package/application modules directly
under `modules.publish_root` or a release-tagged directory that the site symlinks
into `modules.publish_root`. `spack -e <env> module tcl refresh -y` may generate
package modules only if `modules.yaml` templates/projections emit the documented
roots-only, view-based, provenance-bearing behavior. Otherwise a stack module
generator owns package modules too. Front-door modules are stack-owned when
`front_door` exposure is selected. In `direct` mode, stack-owned direct modules
carry the conflict/runtime-module policy because no separate lane selector
exists. The publish step must verify the outputs required by the selected
exposure mode before user workflow verification runs.

### Lane Runtime Module Requirements

A lane's runtime dependency on system modules follows from what kind of
external the lane was built on. The rule is structural, not platform-specific:

- **Module-provided external lane → platform modules required.** A lane built on
  module-provided externals — the canonical case is Cray PE compilers and
  cray-mpich — carries a runtime dependency on those same modules. Without them
  loaded, user-fresh compiles fail to find the compiler driver and MPI programs
  may fail to find `mpirun` or the vendor runtime libraries. RPATH covers the
  stack's own binaries' linkage but not the user's fresh compile path or a
  module-provided MPI launcher's search.
- **Prefix-only site external → no automatic module load.** A site MPI declared
  only by stable `prefix:` is exposed through the lane's view and package
  modules. The lane's public entry module requires an MPI module only when the
  consumed profile external declares one in `modules:`.
- **Spack-built lane → self-contained.** A lane where the compiler is
  Spack-built and the MPI is Spack-built is fully RPATH'd, the compiler
  driver is on the lane's view PATH, and no system modules need to be
  present for users to compile or run. The public entry module declares no
  platform module prereqs.

The public entry module for a site-external lane checks the external's declared
modules by default and fails with a clear message if they are absent. On module
systems that support prerequisites, this can be emitted as `prereq` or
`depends-on`; otherwise the Tcl module can inspect `LOADEDMODULES` and raise an
explicit error. A site may opt into `modules.platform_module_policy: autoload` to
emit `module load` lines instead, but silent autoload is not the default. In
`front_door` exposure mode, that public entry is the lane module. In `direct`
exposure mode, each public application module for that lane carries the same
checks or optional autoloads. The platform-module prerequisite list is per-lane
data: the render step takes it from `profile.yaml` (the `modules:` lists on the
externals the lane consumes) and emits the corresponding checks into the rendered
front-door module template or direct application module template.

The Cray case is the canonical worked example: a CCE + cray-mpich lane's public
entry module must require `PrgEnv-cray` and `cray-mpich/<version>` at load time,
because (1) the CCE compiler driver is found through the PrgEnv, (2) cray-mpich's
`mpirun` and shared libraries are exposed through its module, and (3) the matched
PrgEnv guarantees a user fresh compile with the PE wrappers resolves to the same
`ofi/<flavor>` cray-mpich the lane was built against. The same rule applies to a
generic Linux HPC AOCC + site-OpenMPI lane: the public entry module requires
`aocc/4.2.0` if AOCC is module-provided; it requires an OpenMPI module only if
the site-OpenMPI external declares one. A prefix-only site OpenMPI is exposed
through the stack's view/package-module paths instead.

Verify per lane with `ldd` on a built binary whether PE/site runtime
libraries resolve via RPATH (public entry module can be light) or require the
external's `LD_LIBRARY_PATH` (public entry module must require the external's
modules, or autoload them only when the site opted in). The answer is per-system
and worth recording on the first build of a new lane.

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

# ── Platform module prerequisites (site-external lane) ────────────────────
# cray-mpich and CCE are module-provided externals, so users of this lane
# need the matching platform modules already present. Sites that opt into
# modules.platform_module_policy: autoload can render guarded module load
# lines here instead, but prereq/check is the default.
prereq PrgEnv-cray
prereq cce/17.0.1
prereq cray-mpich/8.1.29

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
  The render step generates this list from the resolved lane plan so it stays
  in sync; do not hand-maintain it. Conflicts give the lane-switch
  semantics — `module swap` works, `module load` of a second lane fails
  loudly — without relying on Lmod's `family` directive (which is
  Lmod-only and not available in the Tcl baseline).
- **Platform module prerequisites.** Present on site-external lanes only. The
  default `prereq`/check behavior gives users a clear missing-module error
  without silently changing their platform environment. On a Spack-built lane
  (Spack-built compiler + Spack-built MPI) this block is empty — the lane is
  self-contained. Sites that choose `modules.platform_module_policy: autoload`
  may render guarded `module load` lines instead.
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

### Source Cold-Start On A New Or Air-Gapped Site

Three supported acquisition patterns, in order of operational simplicity:

**Pattern A — Build host has internet.** `spack-build` (or Ansible, or a
human) runs `spack -e <env> fetch -D` per lane between concretize and
install. Sources land in `source_cache` on shared storage and are reused
across lanes and across releases. This is the default; no extra
configuration.

**Pattern B — Login node has internet, compute nodes do not.** Run
`spack -e <env> concretize` and `fetch -D` on the login node against the
shared `source_cache`. Submit `spack -e <env> install` to the compute
nodes; install reads sources from the shared cache without touching the
network. `spack-build` supports this by running concretize+fetch in its
caller's shell and install per lane through `srun` / the configured
scheduler when the operator passes lane-runner options.

**Pattern C — Fully air-gapped site.** External-facing host fetches once,
then ships a source mirror to the site:

```bash
# On an internet-capable gateway machine, after concretizing a
# representative set of lanes on the same Spack version as the site:
spack mirror create -d /tmp/site-mirror -D -a   # -D = include all deps
tar czf site-mirror.tgz -C /tmp site-mirror

# Transfer site-mirror.tgz to the air-gapped site by approved means.

# At the site, unpack under shared storage and declare the mirror:
tar xzf site-mirror.tgz -C /shared/stack/spack-mirror
# Then add the mirror to the template set's
# configs/common/mirrors.yaml so render emits it into every lane:
#   mirrors:
#     site-source: file:///shared/stack/spack-mirror
```

The renderer treats mirrors as ordinary scope content. The choice
between Patterns A/B/C is operator policy expressed through which
mirrors are declared in the template defaults or per-stack overrides.
`spack-composer` and `spack-build` need no air-gap-specific flags;
Spack's mirror resolution handles the rest.

**Bootstrap order on a brand-new system.** Whichever pattern is chosen,
the first build of a fresh release does:

1. `spack-build` (or Ansible) runs concretize per lane — writes the lock.
2. `spack-build` runs `spack fetch -D` per lane — populates `source_cache`
   from internet (A/B) or from the local mirror (C).
3. `spack-build` runs `spack install -j <n>` per lane — reads sources from
   `source_cache`, builds, installs into `install_tree`.
4. Later releases reuse populated `source_cache` and skip Pattern A/B
   internet hits for already-fetched tarballs.

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
- **Compiler, MPI, target, GPU runtime are lane labels for human readability**,
  not reuse boundaries. They appear in lane names, manifests, logs, and optional
  per-lane mirror layouts. The default payload mirror is the parent
  system/release path; Spack's hash is what the solver matches against.
- **Within one OS/glibc, register every compatible cache mirror as a read
  source.** A CCE MPI lane reads the foundation cache mirror, which holds
  both CCE-built and GCC-built Core binaries (each compiler builds its
  own Core under per-compiler Core). The CCE lane pulls the `%cce`-hashed
  CMake; the GCC lane pulls the `%gcc`-hashed CMake. They share the
  cache mirror but not the *binaries*. The hash decides what gets
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
| Lane class (foundation / payload) | Organizational label | Helps humans see what the cache holds. |
| System name | Organizational label | Distinguishes caches when one mirror serves many systems. |
| Compiler / MPI / target / GPU arch | Optional organizational label | Readability only in lane names and optional per-lane mirror subdirectories; the hash, not the path, decides selection. |

Example mirror roots, with the labels read accordingly:

```text
buildcache/foundation/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/x86_64_v3
buildcache/foundation/sles15/glibc-2.31/spack-1.1.1/repo-2026.06/x86_64_v3
buildcache/payload/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/example-cray
buildcache/payload/sles15/glibc-2.31/spack-1.1.1/repo-2026.06/example-sles
```

The lane on a Cray RHEL8/glibc-2.28 system registers the matching foundation
bucket and the matching payload mirror under the same OS/glibc and
Spack/package-repo generation, so any compatible binary in that parent mirror is
reachable. If `profile_abi` is configured, the lane also requires that token to
match.

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
| SIMD / compute-bound | FFTW, BLAS/LAPACK, dense kernels | High | Optimized payload lane |
| I/O-bound | HDF5, NetCDF, PnetCDF | Usually modest | Start in optimized payload lane for simplicity |
| Neutral tooling | CMake, Ninja, pkgconf, Git | None | Core / baseline |

Start with a single optimized payload lane per system target. Split I/O
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
| `draft` | render step | source-derived: profile/stack/package-set digests, render-tool identity, explicit `rendered_at` release var, lane definitions (env path, kind, compiler, target, spec source, runtime_node_type), planned install/view/module paths, planned buildcache destinations |
| `final` | publish step | adds: build host, lockfile digests per lane, provenance summary per lane, platform-module prereqs per lane, actual buildcache push destinations + lanes pushed, verification results, promoted_at / promoted_by, previous_release |

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
  source_repo: "git@gitlab:stacks/spack-composer"   # repo URL
  source_commit: "0375b16f..."                 # exact commit the render used
  source_dirty: false                          # true if the working tree had uncommitted changes

profile:
  path: "systems/example-cray/profile.yaml"    # path within the source repo
  digest: "sha256:b13c2e..."                   # sha256 of the profile file as rendered
  system_name: "example-cray"                  # cross-check against profile.system.name

stack_file:
  path: "stacks/cse/stack.yaml"
  digest: "sha256:f421a7..."

package_sets:                                  # one entry per unique package_set file; empty if all specs are inline
  - name: core-foundation
    path: "package-sets/core-foundation.yaml"
    digest: "sha256:5510dc..."
  - name: science-full
    path: "package-sets/science-full.yaml"
    digest: "sha256:99a1be..."

templates:
  set: v6                                      # from stack.yaml.templates.set
  digest: "sha256:e2a5e0..."                   # sha256 of renderable templates under templates/<set>, sorted
  defaults_digest: "sha256:6f1b9c..."          # sha256 of templates/<set>/stack-defaults.yaml
  contract_digest: "sha256:58c1a3..."          # sha256 of templates/<set>/contract.yaml
  render_tool:                                 # which render step produced this workspace
    name:    spack-composer render             # or manual
    version: "0.4.2"                           # null when name is manual
  applied_narrowing:                           # null when no per_system block matched profile.system.name
    system: example-cray                       # which per_system.<system> key matched
    builds:                                    # one entry per build whose narrowing dropped at least one candidate
      gpu:
        dropped_lanes: ["gcc-gpu-craympich-gfx942"]
        narrowed_by:                           # one entry per axis that actually dropped a contract-resolved candidate;
                                               # per_system axes whose narrowing was a no-op on this profile are not recorded
          gpu_arch:
            kept:    ["gfx90a"]
            dropped: ["gfx942"]

# ── Build-context (filled at publish; null in draft) ────────────────────
spack:
  version: "1.1.1"                             # `spack --version` on the build host
  commit:  "ba9d6a01..."                       # exact commit, if Spack is a git checkout
  package_repos:                               # selected stack-owned repos registered for this build
    - name: cse
      namespace: cse
      path: "package-repos/cse"
      commit: "0375b16f..."

build_host:
  hostname:  "cray01-login03"
  os:        "rhel"
  os_major:  8
  glibc:     "2.28"
  cpu:       "zen3"

# ── Lanes (rendered lanes only; skeleton at render; lockfile/install/provenance/prereqs at publish) ──
lanes:                                         # one entry per environment in the release
  - name: gcc-core
    source_build: core                          # render-filled; stack.yaml.builds[*].name
    env_path: "environments/gcc/core"          # render-filled
    kind: core                                 # render-filled
    compiler: gcc                              # render-filled
    target: x86_64_v3                          # render-filled
    runtime_node_type: cpu_compute             # render-filled
    spec_source: "package_set:core-foundation" # render-filled; inline stacks use inline:<build>
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
    platform_module_prereqs: []                # platform modules the public entry module checks/prereqs

  - name: cce-mpi-craympich
    source_build: mpi
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
    spec_source: "package_set:science-full"
    provenance_summary:
      stack_built: 18
      platform_backed: 1                       # cray-mpich
      site_external: 0
      spack_built: 0
    platform_module_prereqs:                   # platform modules the public entry module checks/prereqs
      - PrgEnv-cray
      - cce/17.0.1
      - cray-mpich/8.1.29

  - name: gcc-gpu-craympich-gfx90a              # Cray PE + GPU lane assembly Option B:
    source_build: gpu
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
    spec_source: "package_set:science-full"
    provenance_summary:
      stack_built: 12
      platform_backed: 8                       # cray-mpich + ROCm component externals (example count)
      site_external: 0
      spack_built: 0
    platform_module_prereqs:                   # Option B: PrgEnv-gnu + standalone rocm + cray-mpich
      - PrgEnv-gnu
      - gcc-native/13
      - rocm/6.0.0
      - cray-mpich/8.1.29

skipped_builds: []                             # render-filled; empty if every requested build rendered.
                                               # Non-empty entries carry { build, reason_code, reason }
                                               # where reason_code is one of:
                                               #   per_system_empty       — per_system narrowed the build to no eligible lanes
                                               #   nodes_unmatched        — no profile.node_types entry satisfied builds[*].nodes
                                               #   requires_unsatisfied   — contract `requires:` for the build_class cannot be met
                                               #   template_not_supported — contract does not provide the named class/toolchain/nodes
                                               # Downstream tooling matches on reason_code; `reason` is free-form for humans.

# ── Buildcache + verification (filled at publish; planned destinations may
#    appear in draft as `planned_destinations:` for Ansible to consult) ──
buildcache:
  push_destinations:                           # mirrors this release was pushed to
    - name: foundation
      url:  "file:///shared/stack/buildcache/foundation/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/x86_64_v3"
      lanes_pushed: ["gcc-core", "cce-core"]
    - name: payload
      url:  "file:///shared/stack/buildcache/payload/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/example-cray"
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

`spack-composer publish-manifest` is an optional helper, not a required release engine.
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
   `package_module_root`, provenance counts, and platform-module prereqs checked
   by the public entry module (`front_door` lane module or direct application
   module).
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
| Integrity (manifest) | Broken install, post-install tampering, missing files | `spack verify manifest` |
| Integrity (libraries, drift only) | New RPATH/RUNPATH gap since the last clean baseline | `spack verify libraries` compared against baseline |
| User workflow | Lane composition / view exposure | clean shell, load public entry module, load package modules when applicable, compile smoke tests |
| Runtime (load-bearing) | Real MPI/GPU/scheduler interaction | `ldd <spec-binary>` resolves entries, `<tool> --version` runs, scheduler launch, MPI hello-world, GPU device-query, multi-node smoke test |

**`spack verify libraries` is a drift detector, not a deploy gate.** It walks
RPATH/RUNPATH. Spack filters `/usr` from RPATH by safety policy, so specs that
link against `/usr` externals can report missing libraries even when the system
loader resolves them correctly at runtime. Cray PE externals under `/opt/cray/pe`
can produce the same shape of warning. A non-empty baseline is not automatically
breakage.

The correct use is to capture `verify libraries` output as a release baseline,
then diff later rebuilds against that baseline. A new warning is a useful signal
that something moved. The load-bearing runtime gate is the runtime row above:
`ldd <spec-binary>` confirms the real loader path, and `<tool> --version` proves
the binary actually loads and runs.

`spack verify manifest` is different. It cross-checks installed files against
the recorded manifest and catches mid-build crashes, missing files, and
post-install tampering. Treat it as a deploy gate.

Verification runs in the same context users will see, not in a dirty build
shell. For each lane:

```text
1. Start a clean shell with no stack lane loaded.
2. Prepend the candidate release's physical module directory directly, or load a
   release-tagged init module; do not use the global `current` symlink for
   pre-promotion verification.
3. Load the public entry module. In `front_door` mode this is the lane module
   (`<modules.module_root>/<compiler>/<lane>`, for example
   `CSE/GCC/gpu-craympich-gfx90a`). In `direct` mode this is a direct package or
   application module such as `fun3d/14.2-gpu-gfx90a`.
4. Confirm the public entry module checks/prereqs required platform modules for
   consumed externals.
5. Run `spack -e <env> verify manifest -a` and capture
   `spack -e <env> verify libraries` for baseline/drift comparison.
6. Load representative package modules from that lane when the workflow has a
   separate package-module step, then run compile/smoke tests.
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
#   Walk RPATH/RUNPATH on every installed binary. This is a drift detector,
#   not a deploy gate. /usr externals are filtered from RPATH by Spack policy
#   and may report missing even when ld.so resolves them at runtime; on Cray,
#   /opt/cray/pe can behave similarly. The signal is a NEW warning compared
#   with the release baseline. The load-bearing runtime gate is
#   `ldd <spec-binary>` plus `<tool> --version`.
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

**cluster-inspector and spack-composer helpers (optional):**

```bash
cluster-inspector profile [--system <name>]
cluster-inspector verify <profile.yaml>

spack-composer assess-profiles --profiles <dir>
spack-composer scaffold-templates --profiles <dir> --output templates/<set>
spack-composer validate --profile <profile> --stack <stack>
spack-composer explain  --profile <profile> --stack <stack> [--release <tag>]
spack-composer render   --profile <profile> --stack <stack> --release <tag> --output-root <dir>
spack-composer publish-manifest --release-dir <release-dir> [--verification-results <file>]
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
| Build fails with "OpenSSL not found" | `openssl: buildable: false` but the rendered external is missing, incomplete, or falsely versioned | Fix `configs/os/<os>/packages.yaml` to declare the real system external and variants; if one consumer truly needs newer APIs, add a per-consumer `^openssl@3` escape plus a second external or stack-built exception |
| Build fails with linker errors against zlib | Foundation `require:` pin missing in common scope, allowing two zlib versions | `configs/common/packages.yaml` — add `require:` on zlib |
| New `spack verify libraries` warning plus `ldd` reports `not found` for a Cray runtime library | The lane's public entry module does not require the PE modules at runtime; CSE binaries depend on PE runtime components | Module template for the selected exposure mode — add platform-module prereqs/checks for `PrgEnv-...` + `cray-mpich/...` |
| `ldd` on a built binary shows "not found" for `libpgmath.so` or similar | Site compiler runtime not present; the lane is built on a module-provided external but the public entry module does not require its modules | Module template for the selected exposure mode — add a platform-module prereq/check for `<compiler-module>` |
| GPU runtime fails with "CUDA driver version is insufficient for CUDA runtime version" | Toolkit version exceeds the GPU driver ceiling | Check the lane's `profile.node_types[<runtime_node_type>].gpu.toolkit_ceiling`; pin CUDA in `configs/gpu/nvidia-cuda/packages.yaml` at or under it |
| GPU build fails with "no kernel image available for execution" | Rendered Spack GPU variant (`cuda_arch=90` or `amdgpu_target=gfx90a`) does not match the lane's profile arch label (`sm_90` or `gfx90a`) from `profile.node_types[<runtime_node_type>].gpu.arch_target` | `configs/gpu/<vendor>/packages.yaml` — map the profile label to the correct Spack variant |
| User compile finds the wrong `hdf5` headers | Two `hdf5` versions on `CPATH` — typically a stale module not unloaded, or the wrong lane loaded | Verify with `module list`; lane conflict should prevent this |
| `module load` of two lanes simultaneously succeeds | Conflict block in the public entry module is missing or stale | Module template for the selected exposure mode — add conflicts for mutually exclusive lane entries |
| User script picks `mpirun` from system PATH instead of the lane | Site MPI's `mpirun` is not exposed by the lane (Spack-built lanes put it in the view PATH; site-external lanes rely on the site module) | Confirm the lane's platform-module prereqs/checks include the MPI module |
| Cache miss on a binary the foundation already built | Cache keyed by compiler; CCE lane is reading the wrong bucket; or the foundation mirror is not registered in the lane's `mirrors.yaml` | Re-key the cache by OS/glibc (label compiler in the path, not the key); register foundation mirror in `configs/common/mirrors.yaml` |
| `spack ci generate` produces no rebuild jobs after a stack change | Pipeline env has `reuse: true` (the default); `spack ci` must run on `reuse: false` | Pipeline env's `concretizer.yaml` — set `reuse: false` |
| Re-render produces a diff from the last release | The render step is consulting ambient state (shell vars, `module list`, etc.) | Render step implementation — remove the ambient lookup; renders must be deterministic from `(profile, stack, sets, templates, release_vars)` |
| Render rejects a build with "node selector matched no runtime node type" | The contract-defined selector named by `stack.yaml.builds[*].nodes` cannot resolve to a `profile.node_types` entry with `role: runtime` or `both` | Add the node type to the profile (re-run inspector or hand-edit), choose a different contract node selector in `stack.yaml`, or fix the selector definition in `templates/<set>/contract.yaml` |
| GPU lane builds for the wrong arch (e.g., `gfx90a` when the node is `gfx942`) | The contract node selector resolved to the wrong GPU node type, the build used the wrong expansion rule, or the profile's GPU arch label is wrong | Fix `stack.yaml.builds[*].nodes`, the contract selector, or the profile GPU block; use `expand: per_gpu_arch` when one build should produce one lane per GPU arch |
| Different OS lanes share one cache and hashes seem to overlap | Cache lane is not keyed by OS/glibc; SLES and RHEL builds collided | Re-key cache by OS/glibc — `buildcache/foundation/<os-id>/glibc-<glibc>/<spack-generation>/<baseline>/` |
| Two compilers' Core CMake collide in one view | One shared Core view across compilers — per-compiler Core needs per-compiler view roots | View root template — split into `views/<compiler>/core/` |
| `module load` of a package finds a stale path that no longer exists | View was not regenerated after install | Run `spack -e <env> env view regenerate` — Ansible's `publish` role should do this automatically |
| Site smoke test passes but `verify libraries` reports the same `/usr` or `/opt/cray/pe` warnings as the release baseline | Expected RPATH filtering for system/platform externals | Keep the baseline; investigate only new warnings or real runtime loader failures from `ldd` / smoke tests |

## Example Cray Flow (Helper-Assisted End-To-End Walkthrough)

A worked example of bringing up `release 2026.06` of the CSE stack on a
Cray-class system named `example-cray` (RHEL8, Slingshot/CXI fabric, AMD
GPU compute partitions for MI250X and MI300A). Every command shown is
runnable; the values mirror the schema examples in §Durable Inputs.

> **Helper-assisted.** This walkthrough uses `cluster-inspector` and
> `spack-composer render` to reduce labor. The §Manual Workflow remains valid:
> write `profile.yaml` and `environments/*/spack.yaml` by hand against
> the schemas in §Durable Inputs and §Lane Model, skip the inspector
> and render steps, and run `spack -e <env> install` directly. The
> helpers are convenience; the model does not require them.

### Phase 1 — Author the profile

Run `cluster-inspector` for the first time on the login node, no hints file
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

Edit `stacks/cse/stack.yaml` to declare the generic build requests this release
will build:

```yaml
# stacks/cse/stack.yaml (excerpt)
templates:
  set: v6

modules:
  format: tcl
  exposure: front_door
  init_module: cse-init
  module_root: CSE
  publish_root: null

builds:
  - { name: core,   class: core,   package_set: core-foundation, toolchain: cse-core,           nodes: cpu, expand: one,          publish: true }
  - { name: serial, class: serial, package_set: science-full,    toolchain: cse-serial-default, nodes: cpu, expand: one,          publish: true }
  - { name: mpi,    class: mpi,    package_set: science-full,    toolchain: cse-mpi-default,    nodes: cpu, expand: one,          publish: true }
  - { name: gpu,    class: gpu,    package_set: science-full,    toolchain: cse-gpu-default,    nodes: gpu, expand: per_gpu_arch, publish: true }
```

Those names are validated against `templates/v6/contract.yaml`; none of the CPU
targets, GPU architectures, compiler module names, or Cray MPICH prefixes are in
the generic build requests. Without `per_system` narrowing, this example profile
resolves to two compilers (GCC + CCE) × three non-GPU kinds (core, serial, mpi) +
two GPU lanes (gfx90a, gfx942 — Option B with GCC host).

```yaml
# generated release plan excerpt after resolving stacks/cse/stack.yaml
resolved_lanes:
  - { name: gcc-core,                   compiler: gcc,  lane: core,                kind: core,   package_set: core-foundation, target: x86_64_v3, runtime_node_type: cpu_compute,           publish: true }
  - { name: gcc-serial,                 compiler: gcc,  lane: serial,              kind: serial, package_set: science-full,    target: zen3,      runtime_node_type: cpu_compute,           publish: true }
  - { name: gcc-mpi-craympich,          compiler: gcc,  lane: mpi-craympich,       kind: mpi,    package_set: science-full,    target: zen3,      runtime_node_type: cpu_compute,           publish: true }
  - { name: gcc-gpu-craympich-gfx90a,   compiler: gcc,  lane: gpu-craympich-gfx90a, kind: gpu,   package_set: science-full,    target: zen3,      runtime_node_type: gpu_compute_mi250x,    publish: true }
  - { name: gcc-gpu-craympich-gfx942,   compiler: gcc,  lane: gpu-craympich-gfx942, kind: gpu,   package_set: science-full,    target: zen4,      runtime_node_type: gpu_compute_mi300a,    publish: true }
  - { name: cce-core,                   compiler: cce,  lane: core,                kind: core,   package_set: core-foundation, target: x86_64_v3, runtime_node_type: cpu_compute,           publish: true }
  - { name: cce-serial,                 compiler: cce,  lane: serial,              kind: serial, package_set: science-full,    target: zen3,      runtime_node_type: cpu_compute,           publish: true }
  - { name: cce-mpi-craympich,          compiler: cce,  lane: mpi-craympich,       kind: mpi,    package_set: science-full,    target: zen3,      runtime_node_type: cpu_compute,           publish: true }
```

Eight lanes — the fully populated CSE shape from §Lane Matrix Sizing for this
system.

If this release should build only CCE and GNU for CPU lanes, and only GNU host +
Cray MPICH for one AMD GPU architecture, add a system-scoped narrowing block:

```yaml
per_system:
  example-cray:
    builds:
      core:
        compilers: [gcc, cce]
      serial:
        compilers: [gcc, cce]
      mpi:
        compilers: [gcc, cce]
        mpi: [cray-mpich]
      gpu:
        compilers: [gcc]
        mpi: [cray-mpich]
        gpu_arch: [gfx90a]
```

That block is ignored when rendering any profile whose `profile.system.name` is
not `example-cray`. On `example-cray`, it intersects the contract-generated
candidates and drops only the excluded variants. Unknown names in the matching
`per_system` block are render errors, not silent skips. The narrowed plan has
seven lanes instead of eight:

```yaml
# generated release plan excerpt after resolving stacks/cse/stack.yaml with the per_system narrowing above
resolved_lanes:
  - { name: gcc-core,                   compiler: gcc,  lane: core,                kind: core,   package_set: core-foundation, target: x86_64_v3, runtime_node_type: cpu_compute,           publish: true }
  - { name: gcc-serial,                 compiler: gcc,  lane: serial,              kind: serial, package_set: science-full,    target: zen3,      runtime_node_type: cpu_compute,           publish: true }
  - { name: gcc-mpi-craympich,          compiler: gcc,  lane: mpi-craympich,       kind: mpi,    package_set: science-full,    target: zen3,      runtime_node_type: cpu_compute,           publish: true }
  - { name: gcc-gpu-craympich-gfx90a,   compiler: gcc,  lane: gpu-craympich-gfx90a, kind: gpu,   package_set: science-full,    target: zen3,      runtime_node_type: gpu_compute_mi250x,    publish: true }
  - { name: cce-core,                   compiler: cce,  lane: core,                kind: core,   package_set: core-foundation, target: x86_64_v3, runtime_node_type: cpu_compute,           publish: true }
  - { name: cce-serial,                 compiler: cce,  lane: serial,              kind: serial, package_set: science-full,    target: zen3,      runtime_node_type: cpu_compute,           publish: true }
  - { name: cce-mpi-craympich,          compiler: cce,  lane: mpi-craympich,       kind: mpi,    package_set: science-full,    target: zen3,      runtime_node_type: cpu_compute,           publish: true }
```

`gcc-gpu-craympich-gfx942` is the dropped row: the GPU build's `gpu_arch: [gfx90a]`
narrowing intersected the contract-resolved GPU candidates and excluded the
gfx942 lane. The `gpu` build itself remains non-empty (gfx90a survived), so no
`skipped_builds` entry is recorded; the resolved-lanes count and the
`templates.applied_narrowing` block in the manifest are how a reader sees the
narrowing took effect. A `skipped_builds` entry with `reason_code:
per_system_empty` is reserved for the stronger case where narrowing empties an
entire build (see §Release Manifest Schema).

The rest of this walkthrough uses the full 8-lane plan to keep the build/push
examples complete; when applying the `per_system` narrowing above, omit
`gcc/gpu-craympich-gfx942` from the rendered tree listing, the fan-out `srun`
loop, and the verify/push loop.

Validate the full file, including the `per_system` block when present, before
rendering:

```bash
$ spack-composer validate \
    --profile systems/example-cray/profile.yaml \
    --stack stacks/cse/stack.yaml
PASS  profile schema matches stack.profile_contract
PASS  every build request resolves or is explicitly skipped
PASS  every resolved lane.runtime_node_type resolves in profile.node_types
PASS  every resolved lane.compiler resolves in normalized compiler inventory
PASS  every spec source exists and satisfies the contract spec kind
PASS  every per_system narrowing name resolves in the profile or contract
```

### Phase 3 — Render

Materialize the rendered workspace:

```bash
$ spack-composer render \
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
│   ├── cce/serial/spack.yaml
│   ├── gcc/core/spack.yaml
│   ├── gcc/gpu-craympich-gfx90a/spack.yaml
│   ├── gcc/gpu-craympich-gfx942/spack.yaml
│   ├── gcc/mpi-craympich/spack.yaml
│   └── gcc/serial/spack.yaml
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
configs/gpu/amd-rocm/packages.yaml:8        hip.buildable: false
configs/gpu/amd-rocm/packages.yaml:11       hip.externals[0].prefix: /opt/rocm-6.0.0/hip
configs/gpu/amd-rocm/packages.yaml:16       hsa-rocr-dev.externals[0].prefix: /opt/rocm-6.0.0
configs/target/zen3/packages.yaml:4         all.target: [zen3]
configs/common/packages.yaml:4              zlib.require: "@1.3.1"
```

Every line traces to the rendered workspace — no `~/.spack`, no
`/etc/spack/`. Isolation works.

### Phase 4 — Build the foundation neck

Build the bootstrap compiler externals, then GCC Core, then CCE Core.
This is the sequential neck:

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

### Phase 5 — Fan out the payload lanes

Now that both Cores are cached, the six remaining lanes run independently.
Submit one Spack process per node, each lane pinned to its
`runtime_node_type`:

```bash
# On the login/build host, concretize and fetch every non-core lane first.
$ for env in gcc/serial cce/serial gcc/mpi-craympich cce/mpi-craympich \
             gcc/gpu-craympich-gfx90a gcc/gpu-craympich-gfx942; do
    spack -e environments/$env concretize
    spack -e environments/$env fetch -D
done

# CPU serial and MPI lanes on the CPU compute partition
$ srun -N1 -n1 --partition=cpu_compute \
    spack -e environments/gcc/serial install -j 64 &
$ srun -N1 -n1 --partition=cpu_compute \
    spack -e environments/cce/serial install -j 64 &
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
push the payload cache:

```bash
$ for env in gcc/serial cce/serial gcc/mpi-craympich cce/mpi-craympich \
             gcc/gpu-craympich-gfx90a gcc/gpu-craympich-gfx942; do
    spack -e environments/$env verify libraries
    spack -e environments/$env verify manifest -a
    /shared/stack/tests/smoke.sh environments/$env

    spack -e environments/$env env view regenerate
    spack -e environments/$env module tcl refresh -y
    spack -e environments/$env buildcache push --update-index --unsigned \
         file:///shared/stack/buildcache/payload/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/example-cray
done
```

After candidate views and modules exist, run clean-shell user verification from
the release-tagged module root before promotion. This is where package-module
loads, compile smoke tests, MPI launch tests, and GPU device-query tests run.

Write the final manifest in the release directory:

```bash
# The publish step rewrites the manifest with phase: final, adding
# build-host, lockfile digests, provenance summaries, platform-module prereqs,
# buildcache push destinations, and verification results:
$ spack-composer publish-manifest \
    --release-dir /shared/stack/releases/2026.06/example-cray/cse \
    --build-host  $(hostname) \
    --buildcache  foundation=file:///shared/stack/buildcache/foundation/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/x86_64_v3 \
    --buildcache  payload=file:///shared/stack/buildcache/payload/rhel8/glibc-2.28/spack-1.1.1/repo-2026.06/example-cray \
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

The same CSE source build requests resolve differently on this profile. No GPU
lanes render. Two MPI options remain: the site MPI lane (for users who want the
site-tuned MPI) and a Spack-built OpenMPI lane (for users who want a stack-owned
MPI):

```yaml
# generated release plan excerpt after resolving stacks/cse/stack.yaml
resolved_lanes:
  - { name: aocc-core,             compiler: aocc, lane: core,         kind: core,   package_set: core-foundation, target: x86_64_v3, runtime_node_type: cpu_compute, publish: true }
  - { name: aocc-serial,           compiler: aocc, lane: serial,       kind: serial, package_set: science-full,    target: zen3,      runtime_node_type: cpu_compute, publish: true }
  - { name: aocc-mpi-site,         compiler: aocc, lane: mpi-site,     kind: mpi,    package_set: science-full,    target: zen3,      runtime_node_type: cpu_compute, publish: true }
  - { name: aocc-mpi-openmpi,      compiler: aocc, lane: mpi-openmpi,  kind: mpi,    package_set: science-full,    target: zen3,      runtime_node_type: cpu_compute, publish: true }
  - { name: gcc-core,              compiler: gcc,  lane: core,         kind: core,   package_set: core-foundation, target: x86_64_v3, runtime_node_type: cpu_compute, publish: true }
  - { name: gcc-mpi-openmpi,       compiler: gcc,  lane: mpi-openmpi,  kind: mpi,    package_set: science-full,    target: zen3,      runtime_node_type: cpu_compute, publish: true }
```

```bash
$ spack-composer validate \
    --profile systems/example-linux/profile.yaml \
    --stack stacks/cse/stack.yaml
```

### Phase 3 — Render

```bash
$ spack-composer render \
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
push payload cache. Copy workspace + manifest to the release directory.
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

## Example Direct Application Stack: FUN3D

This example is intentionally not a CSE-style library stack. It represents a
package manager who owns one application stack, the site already has a public
modulefile root in users' default `MODULEPATH`, and users expect to load FUN3D
directly. The framework still uses the same durable inputs, render step, lane
validation, lockfiles, and release manifest; it just chooses `modules.exposure:
direct` and publishes application modules instead of front-door lane modules.

Assumptions:

- The system profile is named `example-aero` and declares one CPU compute node
  type plus one AMD GPU node type.
- The site already exposes `/apps/modulefiles` in users' default `MODULEPATH`.
- The local Spack package for FUN3D defines the exact CPU/GPU variants. The
  variant names below are illustrative and should match the real package.
- This stack does not need a separate Core lane. Build tools and dependencies are
  normal concretized dependencies of the FUN3D lanes.

### Phase 1 — Author the stack file

The stack file declares direct exposure and two generic build requests. The
template contract for this stack defines `cpu` and `gpu` as valid build classes;
it does not need the CSE serial/MPI/GPU taxonomy. The concrete lane names are not
written here because they depend on the selected profile.

```yaml
# stacks/fun3d/stack.yaml (excerpt)
schema_version: 1
name: fun3d

profile_contract:
  schema_version: 1

templates:
  set: app-direct-v1

modules:
  format: tcl
  exposure: direct
  init_module: null
  module_root: fun3d
  publish_root: /apps/modulefiles
  expose_provenance: true

builds:
  - name: cpu
    class: cpu
    toolchain: fun3d-default
    nodes: cpu
    expand: one
    specs:
      - fun3d@14.2+mpi~rocm~cuda
      - fun3d@14.1+mpi~rocm~cuda
    publish: true

  - name: gpu
    class: gpu
    toolchain: fun3d-default
    nodes: gpu
    expand: per_gpu_arch
    specs:
      - fun3d@14.2+mpi+rocm
      - fun3d@14.1+mpi+rocm
    publish: true

externals:
  compilers: prefer_platform
  mpi: prefer_platform
  openssl: system
  curl: system
  fabric_userspace: prefer_platform
  gpu_toolkit: prefer_platform

buildcache:
  spack_generation: "spack-{spack_version}/repo-{package_repo_generation}"
  payload_lane: "payload/{os_id}/glibc-{glibc}/{spack_generation}/{system}"
  signed: false
  push_after_every_step: true

release:
  save_lockfiles: true
  save_manifest: true
  retain_previous: 2
  promotion: gated_manual
```

Those `class`, `toolchain`, and `nodes` values are valid because the selected
template contract defines them:

```yaml
# templates/app-direct-v1/contract.yaml (excerpt)
build_classes:
  cpu:
    lane_kind: cpu
    package_set_kind: cpu
    default_target: payload_default
    requires: [runtime_cpu]
  gpu:
    lane_kind: gpu
    package_set_kind: gpu
    default_target: payload_default
    requires: [runtime_gpu, gpu_toolkit]

toolchains:
  fun3d-default:
    compiler: prefer_gnu
    mpi: prefer_platform
    gpu_toolkit: when_required_by_class

node_selectors:
  cpu: { match: runtime_without_gpu }
  gpu: { match: runtime_with_gpu }
```

The `specs:` strings are ordinary Spack root specs. The exact variant names must
match the real FUN3D package recipe; `+rocm` / `~rocm` are illustrative. The GPU
lane's rendered scope supplies the GPU architecture variant (for example
`amdgpu_target=gfx90a`) from `profile.node_types[gpu_compute_mi250x]`, keeping
the source stack independent of a specific system. If FUN3D later shares a long
spec list across several builds, move those specs to a package set; do not start
there by default.

### Phase 2 — Render and build

Render exactly as with CSE. On the example profile, the generic `cpu` and `gpu`
build requests resolve to one CPU lane and one GPU lane:

```bash
$ spack-composer render \
    --profile     systems/example-aero/profile.yaml \
    --stack       stacks/fun3d/stack.yaml \
    --release     2026.06 \
    --output-root /shared/stack/work
# → workspace written to /shared/stack/work/example-aero/fun3d/2026.06/

$ rsync -a /shared/stack/work/example-aero/fun3d/2026.06/ \
        /shared/stack/releases/2026.06/example-aero/fun3d/

$ cd /shared/stack/releases/2026.06/example-aero/fun3d
$ ls environments/gcc
cpu-zen3  gpu-gfx90a
```

The generated release plan records that expansion:

```yaml
resolved_lanes:
  - name: gcc-cpu-zen3
    source_build: cpu
    compiler: gcc
    lane: cpu-zen3
    kind: cpu
    specs_source: inline:cpu
    target: zen3
    runtime_node_type: cpu_compute

  - name: gcc-gpu-gfx90a
    source_build: gpu
    compiler: gcc
    lane: gpu-gfx90a
    kind: gpu
    specs_source: inline:gpu
    target: zen3
    runtime_node_type: gpu_compute_mi250x
    gpu_arch: gfx90a
```

If a different profile exposes two GPU architectures and the stack keeps
`expand: per_gpu_arch`, the same source `stack.yaml` generates two GPU lanes. If
the stack used `expand: one` while the node selector matched multiple GPU
architectures, render would fail and ask the maintainer to choose an explicit
expansion policy.

Build the CPU lane on a CPU compute node and the GPU lane on the matching GPU
node type. There is no mandatory foundation build first because this stack did
not declare a Core lane.

```bash
$ spack -e environments/gcc/cpu-zen3 concretize
$ spack -e environments/gcc/gpu-gfx90a concretize
$ spack -e environments/gcc/cpu-zen3 fetch -D
$ spack -e environments/gcc/gpu-gfx90a fetch -D

$ srun -N1 -n1 --partition=compute \
    spack -e environments/gcc/cpu-zen3 install -j 64 &
$ srun -N1 -n1 --partition=gpu --constraint=mi250x --gpus=1 \
    spack -e environments/gcc/gpu-gfx90a install -j 64 &
$ wait
```

### Phase 3 — Publish direct modules

Candidate module generation emits public modules named by application version and
target, not by a CSE front-door lane:

```text
/shared/stack/releases/2026.06/example-aero/fun3d/modules/public/fun3d/
  14.1-cpu-zen3
  14.2-cpu-zen3
  14.1-gpu-gfx90a
  14.2-gpu-gfx90a
```

The release owner publishes those modulefiles or symlinks into the existing site
root named by `modules.publish_root`. The example assumes
`/apps/modulefiles/fun3d` already exists and is owned by the FUN3D release owner:

```bash
$ ln -sfn /shared/stack/releases/2026.06/example-aero/fun3d/modules/public/fun3d/14.1-cpu-zen3 \
          /apps/modulefiles/fun3d/14.1-cpu-zen3
$ ln -sfn /shared/stack/releases/2026.06/example-aero/fun3d/modules/public/fun3d/14.2-cpu-zen3 \
          /apps/modulefiles/fun3d/14.2-cpu-zen3
$ ln -sfn /shared/stack/releases/2026.06/example-aero/fun3d/modules/public/fun3d/14.1-gpu-gfx90a \
          /apps/modulefiles/fun3d/14.1-gpu-gfx90a
$ ln -sfn /shared/stack/releases/2026.06/example-aero/fun3d/modules/public/fun3d/14.2-gpu-gfx90a \
          /apps/modulefiles/fun3d/14.2-gpu-gfx90a
```

Each direct module is generated from its lane, so it carries the same provenance,
platform-module prerequisite checks, and conflicts that a front-door lane module would
have carried. If the GPU lane consumed a module-provided ROCm external, for
example, `fun3d/14.2-gpu-gfx90a` checks/prereqs the matching ROCm module unless
the site explicitly enabled autoload policy. If the CPU and GPU FUN3D modules
should not be loaded together, they conflict directly with each other.

User workflow stays simple:

```bash
$ module avail fun3d
$ module load fun3d/14.2-cpu-zen3
$ fun3d --version

$ module swap fun3d/14.2-cpu-zen3 fun3d/14.2-gpu-gfx90a
$ echo $STACK_PACKAGE_PROVENANCE
Stack-built
```

This is the same architecture as the CSE examples, but with a different module
surface: direct application modules are the public contract, while lanes remain
the internal mechanism that records target, GPU toolkit, lockfile, provenance,
and build-cache separation.

## Committed Decisions And Genuinely Open Questions

The design avoids unanswered questions where it can. Decisions that have a
practical answer right now are recorded here as **committed** — the answer
may evolve, but the design has a position and ships with it. The
genuinely-open list at the end is short and limited to questions that need
real-world evidence (a deployed system, a measured workload) to settle.

### Committed Decisions

| Question | Committed answer | May change when |
|---|---|---|
| Helper command names | Stack-side helpers ship through **`spack-composer`**: `assess-profiles`, `scaffold-templates`, `validate-template-set`, `validate`, `explain`, `render`, and `publish-manifest`. The read-only system probe ships as **`cluster-inspector`** from its own repo. Ansible playbook names follow `deploy-stack`. | A naming review happens before the helpers are user-installable; until then these names are committed. The architectural rules in §Render Step would survive a rename. |
| Location of `stack.yaml` | `stacks/<name>/stack.yaml` (one file per stack, top-level `stacks/` directory). No system-specific overlays — system facts live in `profile.yaml` and the render step composes them. | Never, unless the design ever lets one stack be defined as a composition of two stacks; that case would need overlay syntax, but it is not on the horizon. |
| Multiple node types per system | **One `profile.yaml` per system with a `node_types:` block** containing one entry per node class (login, CPU compute, GPU compute per GPU model, etc.). System-shared facts (OS, glibc, fabric drivers, Cray PE, modules system, shared filesystem) live at the top level; per-class facts (CPU target, GPU presence, build-stage paths, role) live inside `node_types[*]`. A `stack.yaml` build request names a contract node selector such as `cpu` or `gpu`; the render step resolves that selector against `profile.node_types` and records the concrete `runtime_node_type` in the generated lane plan. | Never — one profile per system is the correct level of grouping; node-class facts scale inside it. |
| Root spec source | Small stacks should put ordinary Spack root specs directly in `stack.yaml.builds[*].specs`. Reused spec lists live in `package-sets/<name>.yaml`, and `stack.yaml.builds[*].package_set` references one set by name. The render step expands either source into each generated lane's `spack.yaml`; toolchain, target, MPI, and GPU-arch decoration still comes from the profile and template contract, not from the reusable spec source. | A second reuse mechanism proves simpler than package sets; the inline-spec starter path and platform/intent split remain. |
| Template authoring lifecycle | Template sets are source-controlled stack source. Maintainers may use profile corpora through `spack-composer assess-profiles` and `spack-composer scaffold-templates`, but scaffold output is advisory and must be reviewed, curated, and committed. `templates/<set>/contract.yaml` is the curated support policy; `profile.yaml` is only observed system fact. | A future implementation proves fully automatic template generation is safer than review, which is not assumed for v1. |
| Minimum Spack version | **1.1.1** is the committed floor. Newer Spack (including 1.2) is supported and benefits from the jobserver and spec groups; older Spack lacks `include::` semantics and is not supported. | Spack 1.2 stabilizes and the team adopts it as the new floor; revisit the table in §Spack Version Floor. |
| Lmod beyond the Tcl baseline | The committed module format is **Tcl** because Lmod reads Tcl and Tcl-only systems cannot read Lua. On Lmod-equipped systems, the same install tree can additionally produce an Lmod tree via `spack -e <env> module lmod refresh -y` and serve both module roots in parallel. Lmod's `family` directive and hierarchy features are *not* relied on; the design's conflict mechanism in front-door or direct modules gives the same behavior portably. | Never for the Tcl baseline; the optional Lmod tree is per-site choice and does not affect the core design. |
| Release artifact storage | Lockfiles (`spack.lock` per lane) and the release manifest are committed to the source repository under `releases/<tag>/<system>/<stack>/`. The runtime release tree under `/shared/stack/releases/<tag>/<system>/<stack>/` uses the same relative shape but also contains rendered Spack inputs, views, and modulefiles. Build-cache contents are *not* committed — they live on the buildcache mirror (file URL or S3-compatible). Build logs are CI/Ansible artifacts, attached to the release record but not committed. | Build-cache contents grow past the source repo's practical size for some other reason; revisit per-system. |
| Repo layout split | `cray-*` vs `linux-*` at the top level is **not** the split. The repository is system-agnostic; per-system reality lives in `profile.yaml` and per-platform behavior lives in the scopes the render step selects. | Never — this is the generic-repo decision. |
| Internal package repositories | Stack-owned package repos live under `package-repos/<name>/` and are selected by template defaults or `stack.yaml.package_repositories`. Render materializes them into the workspace, emits `repos.yaml`, and records namespace, digest, priority, and source commit in the manifest. They are stack source, not `cluster-inspector` facts. | A stack needs to consume an externally versioned package repo directly; the manifest still records the selected repo identity. |
| Core sharing across compilers | **Per-compiler Core** is the committed model — each compiler builds its own Core view at its own path. Cross-compiler shared Core is a future, evidence-gated optimization (see §Per-Compiler Core, Not Shared Core). | Measured overlap across compiler Cores is large and expensive enough to justify the `include_concrete`/foundation-cache extraction work. Until then, per-compiler Core stays. |
| GPU lane Core composition | When a stack renders Core lanes, a GPU lane uses its own compiler's Core. Under the committed Option B default the GPU lane is GCC-hosted, so `gcc/gpu-craympich-<arch>` ↔ `gcc/core`. Named exception lanes follow the same rule with their own host compiler: a ROCmCC exception lane uses `rocmcc/core`, an NVHPC exception lane uses `nvhpc/core`. No separate "gpu-core" layer in any case; small direct application stacks may omit Core entirely. | Never — this falls out of the per-compiler Core model. |
| GPU vs. MPI as lane kinds | **GPU is its own lane kind, not an MPI sub-type.** In CSE-style library stacks, a GPU lane is a *superset* of the matching MPI lane (it contains the same MPI-aware science libraries plus GPU-arch-pinned packages) and is pinned to one GPU class via `runtime_node_type`. One GPU lane per GPU class on a system. GPU lanes are not "MPI + a GPU add-on layer" — there is no GPU sub-load; users pick exactly one lane, and the GPU lane has everything that lane needs. See §Why GPU Is A Separate Lane Kind. | A real workload pattern materially benefits from a GPU-no-MPI sub-kind, which has not been observed yet. |
| `cluster-inspector` module enumeration | **Three-phase hybrid: auto-discover by name pattern, narrow with operator hints, verify by load-and-probe.** The hints file lives in source control at `systems/<system>/inspector-hints.yaml` and is the committed override mechanism (CLI flags exist for one-off probes but the hints file is what persists). See `cluster_inspector_stack_profile_design_v1.md` (CLI/hints schema) and `cluster_inspector_profile_extraction_map_v1.md` (per-field discovery rules). | A site exposes externals through something other than modules (rare); add the appropriate discovery mechanism. The hints + verify model still applies. |
| Host compiler for GPU lanes | **General-purpose host compiler by default, expressed through three lane kinds.** Kind-1 pure CPU `(compiler, mpi)`; Kind-2 GPU with general-purpose host `(host_compiler, mpi, gpu_toolkit)` where the GPU toolkit is CUDA or ROCm and the host compiler is GCC/AOCC/Intel/CCE; Kind-3 GPU-aware compiler `(gpu_aware_compiler, mpi)` for NVHPC or ROCmCC/amdclang specialist lanes. Kind-2 is the default GPU lane shape. All kinds obey the compiler-family lane purity rule: drop unbuildable specs honestly, never silently route a language to another compiler. See §Host-Compiler Policy For GPU Lanes. | A specific code's programming model demands a kind-3 lane that was not previously rendered; the lane is added without changing the kind-2 default. |
| Cray PE + GPU lane assembly | **Option B: `PrgEnv-gnu` + standalone GPU toolkit module** (`rocm/<v>`, `cudatoolkit/<v>`) + the GCC-flavor cray-mpich. The lane compiler is `%gcc_craympich`; CUDA is usually one `cuda` external, while ROCm is rendered as component externals in `configs/gpu/amd-rocm/packages.yaml`; the lane's public entry module checks/prereqs PrgEnv-gnu + GPU toolkit module + cray-mpich at runtime unless `modules.platform_module_policy: autoload` is explicitly enabled. Option A (`PrgEnv-amd` / `PrgEnv-nvidia` all-in-one) appears only as the NVHPC or ROCmCC exception lane; Option C (`PrgEnv-cray` + GPU toolkit) only as the CCE-host GPU lane. | A vendor-PrgEnv-required code appears; the exception lane is added without changing the default. |
| Concretizer `unify:` | CSE-style stack lanes with deliberate multi-version and variant cross-products use **`unify: false`**. Narrow application lanes may use `unify: when_possible` when deduplication is useful and duplicate roots are incidental. `unify: true` is not a production default for this multi-version design. | Multi-version/cross-product policy is abandoned entirely, or a measured narrow application stack proves `when_possible` gives materially better results. |
| Concretizer `reuse:` | Build-time environments (payload lanes, core, foundation) → `reuse: true`. Pipeline-driving environments (input to `spack ci generate`) → `reuse: false`. See §Concretizer Posture Per Environment Kind. | Never — this is structural. |
| Build-cache keying | **OS/glibc + Spack/package-repo generation**, with an optional profile external-ABI token when one mirror spans incompatible same-OS site/vendor external surfaces. Compiler/MPI/target are directory labels for human readability, not reuse boundaries. See §Build-Cache Keying. | Never — the hash already enforces spec correctness, but the bucket still needs clear reuse boundaries; per-compiler keying actively strands the foundation. |
| OpenSSL / curl provenance | **System externals with `buildable: false`**: the strict tier of the two-tier externalization rule. Site admins patch them via `dnf`/`zypper`; the stack does not own that treadmill and does not produce a parallel binary. Variant declarations must be complete. A consumer needing a genuinely newer OpenSSL API gets a per-consumer escape (`^openssl@3` on that one spec plus a second openssl external entry), never a site-wide flip to `buildable: true`. | The system OpenSSL falls out of vendor support entirely; revisit per-system. |
| Linux externals beyond OpenSSL/curl | **Hint tier: `buildable: true`**. PMIx, libfabric, UCX, ncurses, hwloc, libpciaccess, rdma-core, and similar libraries are reuse hints; the solver may build a newer version when a consumer's constraints require it. Under-constrained upstream `depends_on` gaps are closed with consumer-side `^pkg@<floor>` in the spec list, not by promoting the external to `buildable: false`. | A new general Linux external proves it can only ever live at the system-shipped version; promote with a committed decision and explicit evidence. |
| Cray MPICH provenance | **Platform-backed external** with per-flavor `prefix:` and `modules:`. Spack-built MPI on Cray is forbidden for production lanes; the fabric tuning lives in cray-mpich. | Never on Cray. |
| Cray PE version pinning | **Carve-out for Cray PE family MPIs; default for everything else.** Non-Cray MPIs keep the default lane slug `<compiler>-<mpi>` with one MPI version per release. Cray PE family MPIs such as `cray-mpich` carry the PE version in the lane slug (`<compiler>-craympich-<peversion>`) and may keep a rolling window of two PE versions, current plus previous, in the same stack release. | A second non-Cray MPI version becomes required for a real workload; promote that MPI family to the same carve-out with explicit evidence. |
| `modules:` external usage | Reserved for the **Cray PE** case (compilers + cray-mpich). Site MPI on non-vendor systems uses `prefix:` unless a concrete reason forces `modules:`. | Never as a default; case-by-case for new vendor stacks that genuinely require modules. |
| Lane-runtime-module rule | A lane built on module-provided externals → its public entry module checks/prereqs those platform modules at runtime (`front_door` lane module or `direct` application module). Silent autoload is disabled by default and requires explicit `modules.platform_module_policy: autoload`. A fully Spack-built lane → self-contained, no platform module prereqs. See §Lane Runtime Module Requirements. | Never — this is structural. |
| Provenance taxonomy | Four classes: `Stack-built`, `Platform-backed`, `Site-external`, `Spack-built`. Emitted on every package module via `STACK_PACKAGE_PROVENANCE` and a `module-whatis` suffix. | Never; the four classes cover every real source. |
| `link:` policy on views | **`link: roots`** everywhere. Spack's default `link: all` is not used. | Never — the per-package module model depends on roots-only. |
| Default projection | **`{name}/{version}`** in every production view. Richer projections only for collisions a single view must actually hold. | Never as the default. |
| Promotion model | **Gated manual symlink swap.** A green build does not auto-promote. `release.promotion: gated_manual` is the committed default; `auto` is available per-stack but discouraged for production. | Never for production stacks. |
| Previous release retention | Default **2 previous releases** kept loadable. Ansible's promote role refuses to delete a release tree if `current` points at it. | Per-stack override is fine; the default stays 2. |
| Naming on user-facing modules | In `front_door` mode, lane selectors use `<modules.module_root>/<compiler>/<lane>` — e.g., `CSE/CCE/mpi-craympich`. In `direct` mode, public application modules live under `<modules.module_root>/...` with stack-defined projections such as `fun3d/14.2-gpu-gfx90a`. `modules.init_module` is only the optional bootstrap module that exposes the release's module root. The system name is not in the user-facing module path; it shows up in internal release directories and in `STACK_RELEASE`. | Never. |
| Serial/MPI naming on packages | No suffixes — `hdf5`, not `hdf5-mpi`. The loaded lane disambiguates via MODULEPATH. | The same MODULEPATH is forced to expose both lanes simultaneously; until then, no suffixes. |
| Module hierarchy style | **Collapsed** front-door (one module per lane) is the committed default for variant-rich stacks. `direct` exposure is the committed surface for small application stacks whose package modules already belong in a site MODULEPATH root. Lmod-native granular cascade is an optional add-on per site, not the primary surface. | Never as the default for variant-rich stacks. |

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
