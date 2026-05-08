# Spack Platform Strategy

## Purpose

The current `cse-stack` repository proves that a small CSE release can be
built with Spack, published through a stable `cse/*` module namespace, and
recreated in online, restricted, or air-gapped network modes. The platform
roadmap turns that proof-of-concept into an operated service: predictable
catalog intake, repeatable releases, automated validation, and site-specific
deployment through Ansible without moving the build policy out of this repo.

This document is the top-level strategy. The companion roadmap documents cover
the catalog model, Conda/Python integration, release pipeline, and Ansible plus
CI/CD plan.

## Operating Principles

- Spack remains the source of truth for compiled CSE packages, dependency
  resolution, build flags, lockfiles, source mirrors, and binary caches.
- Users consume modules, not Spack commands. The supported interface is the
  `cse-init/<mpi>` entry point plus curated `cse/<package>/<version>` modules.
- Each release is immutable after promotion. Fixes produce a new release or
  rebuild candidate, not an in-place mutation of published modules.
- Site policy is explicit data. Compiler baseline, MPI provider, network mode,
  target microarchitecture, external packages, and public package catalog are
  visible in tracked files or generated release metadata.
- Build automation calls the same staged scripts used by maintainers today.
  Ansible orchestrates and verifies the stages; it does not reimplement Spack
  concretization or module policy.

## Target Architecture

The platform has five layers:

| Layer | Owner | Source Of Truth | Notes |
|---|---|---|---|
| Site substrate | System administration | Cluster profile and vendor docs | OS, filesystems, drivers, scheduler, vendor MPI, vendor libraries |
| CSE policy | CSE maintainers | Git-tracked package sets and docs | Public catalog, MPI policy, OpenSSL policy, build targets |
| Spack release | CSE maintainers | Spack environment plus lockfile | Concretized environment, source mirror, optional buildcache |
| Deployment | CSE maintainers plus sysadmins | Ansible inventory and release manifest | Shared path layout, permissions, module root, promotion |
| User overlay | Users and application teams | User environments | Applications and optional user Spack/Conda overlays |

The current bash stages map directly into this architecture:

1. Capture or consume a system profile.
2. Install or seed the site Spack instance and bootstrap GCC.
3. Render externals from the profile and selected policy.
4. Render Spack configuration, concretize or reuse a lockfile, and install.
5. Refresh modules and install `cse-init`.

## Platform Contract

Every supported site should have a platform contract that can be reviewed
before a release build starts:

- Shared filesystem path for CSE releases and modules.
- Unix group, permissions, and setgid policy for shared installs.
- Network mode: `online`, `restricted`, or `airgapped`.
- Default variant: `v1-openmpi` or `v2-mpich`.
- Default target: portable `x86_64` unless the site proves every consumer node
  supports a more specific target.
- Required externals, including OpenSSL and any scheduler or vendor runtime
  libraries consumed by the chosen variant.
- Public package catalog and any site-specific package additions.
- Buildcache namespace and signing policy when binary caches are enabled.
- Validation commands and module smoke tests that must pass before promotion.

The contract should be machine-readable over time, but the first step can be a
tracked YAML or Markdown profile that mirrors the data already captured by the
deployment scripts.

## Roadmap Phases

### Phase 0: Stabilize Current Proof-Of-Concept

- Keep `deploy.sh` as the canonical local implementation path.
- Preserve the current network-mode behavior and manifest-driven prepared
  deploy workflow.
- Keep OpenSSL external-only and fail before concretization when the selected
  package set is incompatible with the site OpenSSL.
- Continue using root package-set specs as the public module catalog.
- Document the remaining manual release and validation steps.

### Phase 1: Formalize Catalog And Release Inputs

- Define the catalog schema for public packages, package-set membership,
  module naming, MPI flavoring, and compatibility notes.
- Add validation for catalog entries before rendering Spack environments.
- Separate release intent from generated artifacts:
  - release request
  - platform contract
  - package catalog
  - concretized lockfile
  - release manifest
- Define the supported bring-your-own package-set path.

### Phase 2: Automate Release Candidates

- Add CI jobs that validate docs, shell syntax, Python helpers, package-set
  schema, dry-run rendering, and prepared-deploy manifests.
- Produce release candidate artifacts in a connected helper environment:
  lockfile, source mirror, bootstrap bundle, optional buildcache, and manifest.
- Make candidate artifacts addressable by release, variant, target, and git
  commit.
- Record promotion checks in a release manifest.

### Phase 3: Add Ansible Orchestration

- Introduce Ansible roles that call the existing staged scripts.
- Keep generated Spack YAML and module policy owned by this repository.
- Use inventory data to select shared paths, groups, network mode, artifact
  locations, and scheduler-specific smoke tests.
- Support check-mode style preflight where possible: permissions, disk space,
  profile visibility, artifact presence, and module path readiness.

### Phase 4: Operate Multi-Site Releases

- Promote releases through dev, staging, and production paths.
- Publish release notes that include catalog deltas, module names, compiler/MPI
  baseline, known caveats, and rollback instructions.
- Keep old releases available until site policy says they can be retired.
- Add telemetry or lightweight inventory reports for installed releases,
  available modules, and validation status.

## Near-Term Decisions

- Whether the catalog should remain YAML under `package-sets/` or move to a
  dedicated `catalog/` directory with package, module, and site overlays.
- Whether `PnetCDF` should become a top-level public module or remain an
  implementation dependency until a user-facing requirement appears.
- How to name optimized buildcache targets without making users learn target
  details.
- How much Conda/Python workflow belongs in the CSE managed catalog versus a
  documented user overlay.
- Whether Cray vendor MPI integration should be revived through a separate
  experimental variant or deferred until the upstream MPICH path is fully
  operated.
