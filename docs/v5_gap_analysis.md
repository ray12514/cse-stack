# v5 Gap Analysis Roadmap

This is the repo home for the v5/v5.1 modernization roadmap. It is a planning
artifact only; it is not an implementation checklist in progress.

Source planning note:


Source design dump:

- `/Users/ravonventers/Library/Mobile Documents/com~apple~CloudDocs/CSE Spack Stack Modernization Design Notes v5 1.md`

## Current Stance

Keep the current dynamic, rendered layout for now. The durable pieces are the
rendered filesystem shape, module/user experience, package set definitions,
variant/profile contracts, templates, and docs. The bash driver can change later
without invalidating those contracts.

The near-term goal is to try the current implementation and preserve the plan
for review. Do not start the larger Core/foundation layer, target split, static
layout, or orchestration rewrite until there is a production-driver decision.

## Durable Contracts

These should survive even if `deploy.sh` is eventually replaced by Python,
Ansible, GitLab CI, or Spack extension commands:

- `templates/`
- `modules/cse-init/`
- `package-sets/`
- `variants/`
- captured profile schema and rendered profile artifacts
- rendered release/variant directory layout
- module naming and environment variable conventions
- docs and operational runbooks

## Recommended Sequencing

Wave 1 parks docs and adds tiny checks only:

- keep this roadmap in `docs/v5_gap_analysis.md`
- add user-facing docs for naming, stack look and feel, update workflow, package
  set tiers, profile schema, and build triage when ready
- document buildcache lane policy, shared filesystem locking, multi-node install
  recipes, and no production `--dirty` builds
- consider small, durable helper entrypoints such as render-only snapshot tests,
  Spack version preflight, debug bundle collection, and release promotion

Wave 2 is conditional on keeping the current script flow:

- Cluster Inspector build-stage advisor
- `spack config blame` gates around rendered environments
- other checks that live mainly inside the stage scripts

Wave 3 should remain design-only until the production orchestration model is
settled:

- Core/foundation layer
- three-layer module hierarchy
- `x86_64_v3` baseline plus optimized target lanes
- buildcache lane enforcement
- foundation cache machinery

Deferred or consciously not adopted yet:

- static `environments/` plus `configs/` layout migration
- named Spack toolchain migration pending Spack 1.2 maturity
- Spack 1.2 spec groups
- global switch to `concretizer: unify: true`
- stale dry-run profile cleanup

## Implementation Boundary

No implementation work is implied by this file. Before starting any item above,
re-read the source plan and current repo state, then decide whether the change is
still useful after trying the current handoff workflow.

