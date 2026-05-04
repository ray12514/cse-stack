# cse-stack — Agent Handoff Brief

**May 2026**

This document is the original handoff brief for the AI coding agent (Claude Code) tasked with scaffolding the `cse-stack` repository. It is preserved here for reference. The full design documents are in `docs/`.

---

## What We Are Building

A GitHub repository named `cse-stack`, public, that holds the configuration, scripts, and module templates needed to deploy the Computational Software Environment (CSE) on a target HPC system using Spack.

Two implementation variants are supported:

- **Variant A (`v1-openmpi`)**: Spack-built GCC, Spack-built Open MPI. Targets generic Linux systems. UCX/OFI/verbs fabric auto-selected by OpenMPI.
- **Variant B (`v2-mpich`)**: Spack-built GCC, Spack-built MPICH with OFI/libfabric transport. Targets any Linux; on Cray systems libfabric and cray-pals are consumed as externals for Slingshot HSN performance. Positioned for a future cray-mpich ABI splice (Phase 2).

Both variants produce the same user-facing module names under a `cse/<package>` namespace, gated by a `cse-init/<mpi>` activation module. Both Lmod and Tcl Modules are supported; the pipeline picks the modulefile format based on what is available on the host.

---

## Staged Scripts

Each stage script is independently runnable. The orchestrator `deploy.sh` composes them.

| Stage | Script | Purpose |
|-------|--------|---------|
| 1 | `stage1_profile.sh` | Run Cluster Inspector, write `profiles/<hostname>-<timestamp>.yaml` |
| 2 | `stage2_spack.sh` | Clone Spack (v1.1.1), bootstrap GCC@13.2.0 into variant dir |
| 3 | `stage3_externals.sh` | Render `packages.yaml` from system profile |
| 4 | `stage4_build.sh` | Render remaining templates; `spack concretize --fresh`; `spack install`; push build cache |
| 5 | `stage5_modules.sh` | `spack module refresh`; install `cse-init` modulefile |

### Cluster Inspector Integration

[Cluster Inspector](../../../clusterinspector) is the maintainer's existing tool that reports system specs as YAML. Stage 1 wraps `clusterinspector profile --local --format yaml --include-modules`. The helper `scripts/lib/profile.py` loads this YAML and exposes typed accessors used by the Jinja2 template renderer (`scripts/lib/render.py`).

---

## Decisions Already Made (Do Not Re-Ask)

- Two variants with the names `v1-openmpi` and `v2-mpich`.
- Both variants bootstrap GCC from Spack — no dependency on PrgEnv-gnu or any vendor compiler.
- MPICH version auto-detected from cray-mpich series in Cluster Inspector profile:
  - `cray-mpich 8.x` → `mpich@3.4.3`
  - `cray-mpich 9.x` → `mpich@4.2.2`
  - non-Cray / undetected → `mpich@4.2.2`
- `mpich device=ch4 netmod=ofi pmi=pmix` — OFI for Slingshot; PMIx for PBS/PALS and Slurm.
- libfabric external only on Cray (auto-detected from `modules.loaded` in profile).
- cray-pals external only on PBS Cray (detected by `has_cray_pals()`).
- Group defaults to `$(id -gn)`; override with `--group`. Permissions `read: world`, `write: group`.
- `padded_length: 256` on the install tree (makes binaries relocatable for build cache).
- Both Lmod and Tcl Modules are supported; pipeline auto-detects.
- HDF5 and NetCDF-C are built `+mpi` and `~mpi`; both forms exposed via `-mpi` and `-serial` Spack module suffixes.
- Two views per variant: `views/mpi` and `views/serial`.
- Python is registered as an external but not pinned `buildable: false`.
- No CI/CD, no Ansible. Manual deploy via `deploy.sh`.
- Source mirror: `--mirror-path` flag → `spack mirror create`.
- Binary build cache: `--buildcache-uri` flag → `spack buildcache push/pull`.

---

## Open Items (Leave as TODO)

- Phase 2: cray-mpich ABI splice via `LD_LIBRARY_PATH` swap in `cse-init/mpich` module. `CSE_MPICH_SPLICE=1` is reserved for this but not yet implemented.
- Whether `parallel-netcdf` (PnetCDF) gets its own `cse/parallel-netcdf` module or stays a transitive dep.
- Pilot system identity.

---

## Definition of Done for the Agent

1. The repository has the layout shown in `README.md` with all template files and scripts in place.
2. `./scripts/deploy.sh --variant v1-openmpi --release test --shared-path /tmp/cse-test --dry-run` prints a coherent plan and exits zero on a non-Cray Linux host.
3. `./scripts/deploy.sh --variant v2-mpich --release test --shared-path /tmp/cse-test --mock-profile profiles/mock-cray.yaml --dry-run` does the same, showing `mpich@3.4.3`, libfabric external, and cray-pals external.
4. The README clearly states the prerequisites, the two variants, the dry-run workflow, and the user-facing module commands.
5. Both `docs/phase_two_summary.md` and `docs/implementation_plan.md` are present in `docs/`.

The agent should **not** attempt to run a real `spack install` as part of validation. Dry-run plus template rendering is sufficient.
