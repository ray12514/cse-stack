# cse-stack Handoff

This file is preserved as a short handoff note. The current implementation
state is documented in `README.md`, `docs/implementation_plan.md`, and
`docs/phase_two_summary.md`.

## Current Decisions

- Active variants are `v1-openmpi` and `v2-mpich`.
- Both variants bootstrap `gcc@13.3.0` from Spack.
- Both variants use the shared Spack instance at `${SHARED_PATH}/cse/spack-site`.
- Compiler registration for Stage 4 comes only from `gcc-bootstrap.yaml`.
- Deploys now carry an explicit network mode: `online`, `restricted`, or
  `airgapped`.
- Restricted and air-gapped flows can use request/fulfillment/deploy wrappers
  plus authoritative lockfiles and artifact manifests.
- `cse-init/<mpi>` exposes the CSE GCC baseline and the variant module tree.
- Spack-generated package modules use `autoload: direct` so high-level modules
  load their direct dependency modules recursively.
- `v2-mpich` builds upstream MPICH and may consume Cray libfabric/cray-pals as
  externals when detected; it does not currently use external `cray-mpich`.

## Deferred Items

- Phase 2: optional Cray `cray-mpich` runtime splice via `CSE_MPICH_SPLICE=1`.
- Decide whether PnetCDF should become a top-level `cse/parallel-netcdf` module.
- Add Ansible orchestration after the bash proof-of-concept is stable.
