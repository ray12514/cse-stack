# Catalog Model

## Purpose

The catalog defines what CSE publishes to users. Spack may install many
dependencies, but only catalog entries become supported `cse/*` modules unless
the entry is explicitly private or transitional. This keeps the public surface
small enough to support while preserving Spack's ability to solve and build the
complete dependency graph.

The current implementation uses root entries in `package-sets/*.yaml` as the
public module catalog. The roadmap keeps that behavior as the compatibility
baseline and then adds schema, review, and release metadata around it.

## Catalog Objects

### Package Entry

A package entry describes one supported user-facing package:

- Canonical package name.
- Spack spec or spec template.
- Public module name.
- Supported version or version range.
- MPI mode: serial, MPI-specific, or dual.
- Variant policy required for support.
- Compatibility notes such as OpenSSL 3.x requirement or legacy package-set
  fallback.
- Owner or reviewer for catalog changes.
- Smoke test command, if one exists.

Example shape:

```yaml
name: netcdf-fortran
module: cse/netcdf-fortran
spec: netcdf-fortran@4.6.1 ^netcdf-c+mpi ^hdf5+mpi
mpi: required
variants:
  - v1-openmpi
  - v2-mpich
visibility: public
smoke:
  module_load: cse/netcdf-fortran/4.6.1-mpi
  commands:
    - nf-config --version
```

### Package Set

A package set is a release selection, not a complete policy file. It references
catalog entries and may pin versions, variants, or compatibility alternatives.

Supported package-set classes:

- `full`: preferred production catalog.
- `full-legacy-openssl`: production catalog compatible with older external
  OpenSSL.
- `hdf5-mpi-smoke`: reduced MPI validation catalog.
- `hdf5-mpi-smoke-legacy-openssl`: reduced MPI validation catalog for older
  OpenSSL.
- `public-buildcache-smoke`: minimal buildcache and pipeline smoke catalog.

The package set should remain easy to review in diffs. Generated lockfiles and
mirrors prove the full dependency graph; the package set explains intent.

### Module Entry

The module entry is generated from the package entry plus the concretized Spack
spec. It records:

- Final module name and version.
- Release, variant, MPI provider, compiler baseline, and target.
- Public dependency module loads.
- Hidden implementation dependencies that are intentionally not published.
- View-backed installation prefix used by module environment edits.

The module catalog should be exported after Stage 5 so release notes and tests
can compare intended modules to generated modules.

## Naming Policy

- Public modules live under `cse/<package>/<version>`.
- MPI-specific packages add an MPI suffix when the upstream package name alone
  does not communicate ABI compatibility, such as `4.6.1-mpi`.
- Provider modules use their implementation name:
  - `cse/openmpi/<version>`
  - `cse/mpich/<version>`
- `cse-init/<mpi>` activates the selected release and variant module tree.
- Low-level libraries such as zlib and bzip2 remain hidden unless they are
  explicit catalog entries.

The module name should be stable across sites when the ABI contract is stable.
Site-specific details belong in release metadata, not in the user-facing module
name.

## Visibility Policy

| Visibility | Module Published | Support Meaning |
|---|---|---|
| `public` | Yes | Supported user-facing package |
| `hidden` | No | Installed dependency required by public packages |
| `experimental` | Optional | Available for early testing; not a stable interface |
| `deprecated` | Yes, with release note | Supported for migration only |

The default for transitive dependencies is `hidden`.

## Change Workflow

Catalog changes should follow this path:

1. Add or modify the catalog entry.
2. Add the entry to one or more package sets.
3. Run schema validation and dry-run rendering.
4. Concretize in a release candidate environment.
5. Build or reuse the candidate artifacts.
6. Run module smoke tests.
7. Include the module delta in release notes.

Breaking changes require an explicit migration note:

- Module renamed or removed.
- MPI ABI changed.
- Compiler baseline changed.
- Package major version changed.
- Python or Conda environment interface changed.

## Validation Rules

Initial catalog validation should check:

- Every package-set entry resolves to a catalog package or explicit Spack spec.
- Public module names are unique within a release and variant.
- MPI-required entries are compatible with every selected variant.
- Legacy OpenSSL package sets do not select known OpenSSL 3.x-only dependency
  stacks.
- Smoke-test module names match generated module naming policy.
- Visibility is one of `public`, `hidden`, `experimental`, or `deprecated`.

These checks can run before Spack concretization, which makes catalog mistakes
cheaper to catch than build failures.
