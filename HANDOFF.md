# cse-stack Handoff

This file is preserved as a short handoff note. The current implementation
state is documented in `README.md`, `docs/implementation_plan.md`, and
`docs/phase_two_summary.md`. Build troubleshooting and lessons learned are
tracked in `docs/build_process_notes.md`.

## Current Decisions

- Active variants are `v1-openmpi` and `v2-mpich`.
- Both variants bootstrap `gcc@13.3.0` from Spack.
- Both variants use the shared Spack instance at `${SHARED_PATH}/cse/spack-site`.
- Compiler registration for Stage 4 comes only from `gcc-bootstrap.yaml`.
- Deploys now carry an explicit network mode: `online`, `restricted`, or
  `airgapped`.
- `science-full` is the expanded two-version science package set. Miniforge is
  latest-only, and `netcdf-cxx4` currently has one available Spack version.
- `science-full-legacy-openssl` keeps that expanded catalog but uses the
  legacy OpenMPI policy for sites with older external OpenSSL.
- Restricted and air-gapped flows can use request/fulfillment/deploy wrappers
  plus authoritative lockfiles and artifact manifests.
- Failed release retries should use `deploy.sh --restart-release`; if
  `--buildcache-uri` is set, deploy exports installed packages to that cache
  before clearing the release-local env/store/views/modules.
- `cse-init/<mpi>` exposes the CSE GCC baseline and the variant module tree.
- Spack-generated package modules use clean view-backed paths and curated
  public dependency loads instead of broad recursive autoload.
- The generated module catalog follows explicit root package-set specs;
  low-level transitive dependencies remain installed but hidden.
- `v2-mpich` builds upstream MPICH and may consume Cray libfabric/cray-pals as
  externals when detected; it does not currently use external `cray-mpich`.

## Deferred Items

- Phase 2: optional Cray `cray-mpich` runtime splice via `CSE_MPICH_SPLICE=1`.
- Decide whether PnetCDF should become a top-level `cse/parallel-netcdf` module.
- Add Ansible orchestration after the bash proof-of-concept is stable.
- Flesh out a first-class custom package-set workflow. The current repo-local
  `--package-set <name>` mechanism works for tracked files under
  `package-sets/`, but follow-up work should define and document a supported
  bring-your-own package-set path such as `--package-set-file`.
