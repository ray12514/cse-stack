# cse-stack — Agent Handoff Brief

**April 2026**

This document is the original handoff brief for the AI coding agent (Claude Code) tasked with scaffolding the `cse-stack` repository. It is preserved here for reference. The full design documents are in `docs/`.

---

## What We Are Building

A GitHub repository named `cse-stack`, public, that holds the configuration, scripts, and module templates needed to deploy the Computational Software Environment (CSE) on a target HPC system using Spack.

Two implementation variants are supported:

- **Variant A (`v1-minimal-externals`)**: minimal externals, Spack-built GCC, Spack-built Open MPI. Targets generic Linux systems.
- **Variant B (`v2-cray-integrated`)**: PrgEnv-gnu and the Cray substrate (cray-mpich, cray-libsci, optionally cray-pals) consumed as externals. Targets Cray systems.

Both variants produce the same user-facing module names under a `cse/<package>` namespace, gated by a `cse-init/<mpi>` activation module. Both Lmod and Tcl Modules are supported; the pipeline picks the modulefile format based on what is available on the host.

---

## Staged Scripts

Each stage script is independently runnable. The orchestrator `deploy.sh` composes them.

| Stage | Script | Purpose |
|-------|--------|---------|
| 1 | `stage1_profile.sh` | Run Cluster Inspector, write `profiles/<hostname>-<timestamp>.yaml` |
| 2 | `stage2_spack.sh` | Clone Spack (v1.1.1), set SPACK_ROOT; Variant A: bootstrap GCC |
| 3 | `stage3_externals.sh` | Render `packages.yaml` from system profile |
| 4 | `stage4_build.sh` | Render remaining templates; `spack concretize --fresh`; `spack install` |
| 5 | `stage5_modules.sh` | `spack module refresh`; install `cse-init` modulefile |

### Cluster Inspector Integration

[Cluster Inspector](../../../clusterinspector) is the maintainer's existing tool that reports system specs as YAML. Stage 1 wraps `clusterinspector profile --local --format yaml --include-modules`. The helper `scripts/lib/profile.py` loads this YAML and exposes typed accessors used by the Jinja2 template renderer (`scripts/lib/render.py`).

---

## Decisions Already Made (Do Not Re-Ask)

- Two variants with the names `v1-minimal-externals` and `v2-cray-integrated`.
- Group `cse`, permissions `read: world`, `write: group`, mode 775.
- `padded_length: 256` on the install tree.
- Both Lmod and Tcl Modules are supported; pipeline auto-detects.
- HDF5 and NetCDF-C are built `+mpi` and `~mpi`; both forms exposed via `-mpi` and `-serial` Spack module suffixes.
- Cray substrate (cray-mpich, cray-libsci, cray-pals) is exposed as `cse/<name>` modules even though they are externals.
- Users on Variant B compile with `mpicc`/`mpif90` from cray-mpich, not the PrgEnv `ftn`/`cc`/`CC` wrappers.
- Two views per variant: `views/mpi` and `views/serial`.
- Python is registered as an external but not pinned `buildable: false`.
- No CI/CD, no Ansible. Manual deploy via `deploy.sh`.

---

## Open Items (Leave as TODO)

- Exact GCC version in Variant A (default `gcc@13.2.0` until a maintainer overrides).
- Exact GCC, cray-mpich, cray-libsci, cray-pals versions for Variant B (from Stage 1 at runtime).
- Whether `parallel-netcdf` (PnetCDF) gets its own `cse/parallel-netcdf` module or stays a transitive dep.
- Pilot system identity.

---

## Definition of Done for the Agent

1. The repository has the layout shown in `README.md` with all template files and scripts in place.
2. `./scripts/deploy.sh --variant v1-minimal-externals --release test --shared-path /tmp/cse-test --dry-run` prints a coherent plan and exits zero on a non-Cray Linux host.
3. `./scripts/deploy.sh --variant v2-cray-integrated --release test --shared-path /tmp/cse-test --dry-run` does the same (use `--mock-profile profiles/mock-cray.yaml` if not on a real Cray).
4. The README clearly states the prerequisites, the two variants, the dry-run workflow, and the user-facing module commands.
5. Both `docs/phase_two_summary.md` and `docs/implementation_plan.md` are present in `docs/`.

The agent should **not** attempt to run a real `spack install` as part of validation. Dry-run plus template rendering is sufficient.
