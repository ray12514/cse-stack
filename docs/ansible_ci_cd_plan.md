# Ansible And CI/CD Plan

## Purpose

The bash deployment scripts are the current implementation contract. Ansible
should orchestrate those scripts across real systems, manage inventory-specific
data, and capture validation results. CI/CD should catch policy and rendering
errors before a maintainer starts an expensive Spack build.

This plan keeps responsibilities separated:

- Bash scripts own Spack operations and generated configuration.
- Ansible owns host orchestration, permissions, artifact placement, and smoke
  test execution.
- CI owns static checks, dry-run rendering, schema validation, and release
  candidate artifact checks.

## Ansible Role Layout

Suggested role structure:

```text
ansible/
  inventories/
    dev/
    prod/
  playbooks/
    preflight.yml
    deploy.yml
    validate.yml
    promote.yml
  roles/
    cse_preflight/
    cse_artifacts/
    cse_deploy/
    cse_validate/
```

### `cse_preflight`

Checks target readiness:

- Shared path exists or can be created.
- Unix group exists.
- Setgid and write permissions match policy.
- Required system commands are available.
- Network mode matches expected artifact inputs.
- External OpenSSL can be detected.
- Module command is available in a login-compatible shell.
- Enough disk space is available for source mirror, Spack store, and modules.

### `cse_artifacts`

Places or verifies release artifacts:

- Spack seed bundle.
- Bootstrap bundle.
- Source mirror.
- Buildcache metadata.
- Lockfile.
- Release manifest.

It should verify checksums before deploy and avoid modifying published release
directories after promotion.

### `cse_deploy`

Calls the repo scripts:

- `scripts/deploy.sh` for online builds.
- `scripts/network_deploy.sh` for prepared restricted or air-gapped builds.

The role passes inventory variables instead of templating Spack YAML directly.
Generated Spack files remain owned by the repository scripts.

### `cse_validate`

Runs smoke tests after deploy:

- `module use` the target module root.
- Load `cse-init/<mpi>`.
- Load representative public modules.
- Confirm compiler variables and wrapper compilers.
- Run catalog smoke commands.
- Optionally compile and run a small MPI program through the site scheduler.

## Inventory Variables

Initial variables:

```yaml
cse_release: "2026_04"
cse_variant: "v1-openmpi"
cse_package_set: "full"
cse_shared_path: "/shared/cse"
cse_group: "cse"
cse_network_mode: "restricted"
cse_target: "x86_64"
cse_manifest: "/shared/cse-artifacts/2026_04/manifest.json"
cse_buildcache_uri: "file:///shared/cse-buildcache/2026_04"
```

Inventory may also carry scheduler-specific validation settings, such as queue
name, account, walltime, and node constraints.

## CI Jobs

### Pull Request Checks

- Whitespace check with `git diff --check`.
- Markdown link check for local documentation links.
- Bash syntax for deployment scripts.
- Python syntax/import checks for `scripts/lib/*.py`.
- Dry-run render for `v1-openmpi`.
- Dry-run render for `v2-mpich` with `profiles/mock-cray.yaml`.
- Package-set and catalog schema validation once the schema exists.

### Release Candidate Checks

- Generate or verify release request metadata.
- Concretize selected package sets in a controlled helper environment.
- Build source mirror.
- Build bootstrap bundle.
- Optionally build and sign buildcache.
- Produce release manifest with checksums.
- Upload artifacts to the configured release candidate location.

### Deployment Checks

These run against target or staging systems, not generic CI runners:

- Ansible preflight.
- Prepared deploy from manifest.
- Module load smoke tests.
- Compile smoke tests.
- Scheduler smoke test when the system supports it.

## CD And Promotion

Promotion should require an explicit maintainer action. The automated pipeline
can prepare and validate candidates, but production publication should verify:

- Candidate commit is approved.
- Manifest checksums are valid.
- Smoke tests passed on the target system.
- Release notes are ready.
- Rollback path is documented.

After promotion, the pipeline should archive:

- Release manifest.
- Module catalog export.
- Validation logs.
- Ansible run summary.
- Release notes.

## First Implementation Slice

1. Add CI for `git diff --check`, shell syntax, Python syntax, and dry-runs.
2. Add a minimal Ansible `preflight.yml` that validates shared path, group,
   module command, and artifact presence.
3. Add `deploy.yml` that calls existing scripts with inventory variables.
4. Add `validate.yml` that loads `cse-init` and one representative package.
5. Add release manifest archival before building any more orchestration.

This sequence keeps the platform useful after each step and avoids replacing
working bash logic before the operating model is proven.
