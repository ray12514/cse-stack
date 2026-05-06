# cse-stack

`cse-stack` is a Spack-driven scaffold for building the Computational Software
Environment (CSE): a small, reproducible HPC software stack exposed through a
stable `cse/*` module namespace.

The current proof-of-concept supports two variants:

| Variant | MPI | Target |
|---|---|---|
| `v1-openmpi` | Spack-built OpenMPI | Generic Linux test systems and non-Cray clusters |
| `v2-mpich` | Spack-built MPICH with OFI | Generic Linux plus Cray/Slingshot when libfabric is detected |

Both variants bootstrap `gcc@13.3.0` with Spack and use that compiler for the
stack. `gcc@13.2.0` is deprecated upstream and is no longer the default.

## OpenSSL Policy

OpenSSL is always treated as a site external and is never built by Spack in
this stack. That keeps the deploy aligned with the site-managed trust and patch
policy.

The consequence is explicit: if the site OpenSSL is too old for the selected
MPI/PMIx package set, deploy fails before concretization with a recommended
alternate package set.

Current supported package-set names include:

- `full`: preferred default stack, expects external OpenSSL 3.x
- `full-legacy-openssl`: legacy-compatible full stack for older site OpenSSL
- `hdf5-mpi-smoke`: reduced MPI smoke stack, also expects external OpenSSL 3.x
- `hdf5-mpi-smoke-legacy-openssl`: reduced MPI smoke stack for older site OpenSSL
- `public-buildcache-smoke`: minimal single-package smoke set

## Deploy Python Environment

The deploy scripts only require `python3` on the host. Repo Python dependencies
(`Jinja2` and `PyYAML`) are installed into a CSE-managed virtualenv at
`${SHARED_PATH}/cse/cache/python-venv` by default. Set `CSE_PYTHON_VENV` to
override that location.

`clusterinspector` is still expected as a separate command on `PATH`, or you can
provide a pre-captured profile with `--mock-profile`.

## Network Modes

The deploy path supports three explicit network policies:

- `online`: permissive connected build and fetch behavior.
- `restricted`: Spack itself may still come from GitHub or a local seed, but
  Stage 2 must receive a prepared bootstrap bundle and Stage 4 must use a
  local source mirror plus an authoritative lockfile.
- `airgapped`: no outbound network assumptions. Stage 2 installs Spack from a
  local seed bundle and bootstrap bundle, and Stage 4 installs from a local
  source mirror and authoritative lockfile.

The artifact classes are:

- Spack seed bundle: required for `airgapped`, optional for `restricted`.
- Python wheelhouse: required for `restricted` and `airgapped`.
- Bootstrap bundle: required for `restricted` and `airgapped`.
- Source mirror: required for `restricted` and `airgapped`.
- Optional buildcache: usable in all modes.

## User Model

Users load one front-door module, then load the package they need:

```bash
module load cse-init/openmpi
module load cse/netcdf-fortran/4.6.1-mpi
```

`cse-init/<mpi>` exposes the CSE compiler baseline and the selected module
tree. Spack-generated package modules own dependency loading through curated
public module loads: HDF5 MPI modules load the MPI provider, NetCDF modules load
the matching public HDF5 or NetCDF-C module, and MPI provider modules do not
load their low-level implementation dependency graph. Package modules are
generated relative to the `cse_modules` Spack view so modulefiles expose clean
view paths instead of raw hashed install-store prefixes.

`cse-init` sets `CSE_GCC_ROOT`, `CSE_CC`, `CSE_CXX`, and `CSE_FC`, and prepends
the CSE GCC `bin` directory to `PATH` through the clean compiler view path
`${SHARED_PATH}/cse/<release>/<variant>/views/compiler/gcc/<version>`. It does
not set global `CC`, `CXX`, or `FC`; MPI builds should use `mpicc`, `mpicxx`,
and `mpifort` from `cse/openmpi/<version>` or `cse/mpich/<version>`.

## Personal Test Install

A first build does not need a shared filesystem or a `cse` Unix group:

```bash
./scripts/deploy.sh \
  --variant v1-openmpi \
  --release test \
  --shared-path /tmp/cse-test
```

For personal installs, group ownership checks are advisory. For shared cluster
installs, create the shared root with the desired group and setgid bit, then
pass `--group <name>`.

The default Spack target is `x86_64` for portability across login, build, and
compute nodes. Use `--target x86_64_v3` only after confirming every target node
supports that ISA level.

If a site uses an older external OpenSSL, select the legacy-compatible package
set explicitly:

```bash
./scripts/deploy.sh \
  --variant v1-openmpi \
  --release test \
  --shared-path /tmp/cse-test \
  --package-set full-legacy-openssl
```

## Prepared Deploy Workflow

Use the wrapper scripts when the target system cannot perform the whole
connected build itself:

```bash
./scripts/network_prepare_request.sh \
  --request-dir /tmp/cse-request \
  --variant v2-mpich \
  --release 2026_04 \
  --shared-path /shared/cse \
  --network-mode airgapped

./scripts/network_fulfill_request.sh \
  --request-dir /tmp/cse-request \
  --output-dir /tmp/cse-artifacts \
  --shared-path /tmp/cse-helper \
  --with-buildcache

./scripts/network_deploy.sh \
  --manifest /tmp/cse-artifacts/manifest.json \
  --shared-path /shared/cse
```

`network_prepare_request.sh` captures the target profile and deployment intent.
`network_fulfill_request.sh` runs on a connected helper machine, produces the
authoritative lockfile, and packages the Python wheelhouse, source mirror,
bootstrap bundle, optional buildcache, and air-gap Spack seed.
`network_deploy.sh` validates the manifest, unpacks the local artifacts, and
calls the normal staged deploy flow with the prepared artifacts.

The fulfillment host should use a Python/platform compatible with the target
for the deploy wheelhouse, just as buildcache artifacts must be compatible with
their consumers.

## Buildcache Target Policy

Keep the default buildcache generic until the site layout is proven:

- Generic cache: `target=x86_64`, broadest reuse across mixed nodes and nearby
  systems.
- Optimized cache: `target=x86_64_v3`, `x86_64_v4`, `zen3`, or similar only
  when every consumer node is compatible.
- Do not mix generic and optimized binaries under the same cache/release name;
  use a distinct release, target suffix, or cache namespace.

The generic cache is the baseline for first production builds. Optimized caches
are a later site-specific layer.

## Dry Runs

Dry-runs render the intended YAML/module content and execute no build:

```bash
./scripts/deploy.sh \
  --variant v1-openmpi \
  --release test \
  --shared-path /tmp/cse-test \
  --dry-run

./scripts/deploy.sh \
  --variant v2-mpich \
  --release test \
  --shared-path /tmp/cse-test \
  --mock-profile profiles/mock-cray.yaml \
  --dry-run
```

## Stages

`deploy.sh` runs five idempotent stages:

| Stage | Script | Purpose |
|---|---|---|
| 1 | `stage1_profile.sh` | Capture a Cluster Inspector system profile |
| 2 | `stage2_spack.sh` | Clone Spack to `${SHARED_PATH}/cse/spack-site` and bootstrap GCC |
| 3 | `stage3_externals.sh` | Render `packages.yaml` |
| 4 | `stage4_build.sh` | Render remaining Spack config, concretize, and install |
| 5 | `stage5_modules.sh` | Refresh Spack modules and render/install `cse-init` |

Stage 2 writes `${SHARED_PATH}/cse/<release>/<variant>/gcc-bootstrap.yaml`.
Stage 4 includes that file as the only compiler registration for the
bootstrapped GCC.

For prepared restricted or air-gapped deploys, `deploy.sh` also accepts:

- `--network-mode online|restricted|airgapped`
- `--spack-seed <tar-or-dir>`
- `--python-wheelhouse <wheel-dir>`
- `--bootstrap-bundle <tar-or-dir>`
- `--lockfile <spack.lock>`
- `--mirror-path <local-mirror-dir>`
- `--buildcache-uri file:///...`

If `--lockfile` is supplied, Stage 4 reuses that concretization and does not
silently re-concretize on the target.

## Module Policy

The module configuration keeps Spack in charge while avoiding raw store paths
and Tcl-only module features:

- `use_view: cse_modules` projects generated path edits through the clean Spack
  view.
- Prefix inspections provide `PATH`, `LD_LIBRARY_PATH`, `CPATH`,
  `PKG_CONFIG_PATH`, `CMAKE_PREFIX_PATH`, and `MANPATH`.
- Generic `{name}_ROOT`, `{name}_DIR`, and `{name}_HOME` variables are not set
  because Spack does not project those manual entries through `use_view`.
- Broad dependency autoload is disabled; only curated public module loads are
  emitted.
- `cse-init` activates the namespace only; it does not hard-code HDF5, NetCDF,
  or MPI dependency loads.

## Future Ansible Use

The bash scripts are the canonical implementation for now. They are kept
parameter-driven and idempotent so Ansible can later call the same stages
instead of reimplementing the deployment logic.
