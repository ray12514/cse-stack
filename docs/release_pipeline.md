# Release Pipeline

## Purpose

The release pipeline turns catalog intent into an immutable CSE release:
lockfile, source mirror, optional buildcache, installed modules, validation
results, and promotion metadata. The current scripts already implement the
core build stages. The roadmap adds repeatable release candidate generation,
artifact promotion, and release records.

## Release Inputs

Each release candidate should declare:

- Git commit.
- Release name, such as `2026_04` or `2026_04_rc1`.
- Variant.
- Package set.
- Platform contract.
- Network mode.
- Target microarchitecture.
- Shared path and module root for the target install.
- Buildcache URI and signing policy, if enabled.
- Source mirror and bootstrap bundle locations for prepared deploys.

## Artifact Model

| Artifact | Required | Producer | Consumer |
|---|---|---|---|
| Release request | Yes | Maintainer | CI and Ansible |
| Platform profile | Yes | Target or inventory | Render and deploy stages |
| Spack lockfile | Yes | Connected or target build | Stage 4 |
| Source mirror | Restricted/air-gapped | Connected helper | Stage 4 |
| Bootstrap bundle | Restricted/air-gapped | Connected helper | Stage 2 |
| Spack seed | Air-gapped | Connected helper | Stage 2 |
| Buildcache | Optional | Builder | Stage 4 and future installs |
| Release manifest | Yes | Pipeline | Promotion and audit |
| Module catalog export | Yes | Stage 5 | Release notes and smoke tests |

The release manifest should bind all artifacts to the git commit and record
checksums for transferable files.

## Candidate Flow

1. Create a release branch or candidate tag from the approved source commit.
2. Validate repository content:
   - `git diff --check`
   - shell syntax
   - Python syntax/import checks
   - package-set and catalog schema checks
   - dry-run rendering for supported variants
3. Concretize the selected package set.
4. Generate the authoritative lockfile.
5. Build source mirror and bootstrap artifacts for restricted or air-gapped
   modes.
6. Optionally build and push a signed buildcache.
7. Run deployment smoke tests in a candidate shared path.
8. Export the module catalog.
9. Produce release notes and promotion manifest.

## Promotion Flow

Promotion should be a metadata and filesystem operation, not a rebuild:

1. Confirm the candidate manifest points at the approved git commit.
2. Verify artifact checksums.
3. Install or sync candidate artifacts to the production shared path.
4. Run module and compile smoke tests from a clean shell.
5. Mark the release as current for the site if the local module policy uses a
   current pointer.
6. Publish release notes.

Old releases should remain installed until a retention policy removes them.
Rollback should mean loading the prior release module tree or moving the site
pointer back to a previously validated release.

## Validation Gates

Minimum gates:

- Repository whitespace check with `git diff --check`.
- Bash syntax for `scripts/*.sh` and `scripts/lib/*.sh`.
- Python helper syntax and import validation.
- Dry-run render for `v1-openmpi`.
- Dry-run render for `v2-mpich` using `profiles/mock-cray.yaml`.
- Prepared deploy manifest validation for restricted or air-gapped releases.
- Module availability check for all public catalog entries.
- Load smoke tests for representative serial and MPI modules.
- Compile smoke test for at least one MPI package chain.

Suggested MPI compile smoke:

```bash
module load cse-init/openmpi
module load cse/netcdf-fortran/4.6.1-mpi
mpifort smoke_netcdf.F90 -lnetcdff -lnetcdf
```

The exact smoke source should be checked in once the pipeline is automated.

## Release Notes

Every promoted release should include:

- Release name, git commit, variant, package set, and target.
- Compiler baseline and MPI provider.
- Public module list and module deltas from the previous release.
- OpenSSL policy and detected external OpenSSL version.
- Known compatibility notes.
- Buildcache and mirror availability.
- Validation summary.
- Rollback instructions.

## Branch And Tag Policy

Suggested branch names:

- `design/*` for roadmap and architecture work.
- `feature/*` for implementation changes.
- `release/<name>` for release candidate hardening.

Suggested tags:

- `cse-<release>-<variant>-rc<N>`
- `cse-<release>-<variant>`

Tags should point to the commit used to generate the lockfile and release
manifest. If any input changes after a candidate build, make a new candidate.
