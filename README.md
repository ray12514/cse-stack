# cse-stack

`cse-stack` is a Spack-driven scaffold for building the Computational Software
Environment (CSE): a small, reproducible HPC software stack exposed through a
stable `cse/*` module namespace.

Variants follow a `<compiler>-<mpi>` slug that encodes the stack identity and
maps to user-facing modules like `CSE/GCC/mpi-openmpi`:

| Variant | Compiler | MPI | Target |
|---|---|---|---|
| `gcc-openmpi` | Spack GCC 13.3.0 | Spack-built OpenMPI | Generic Linux, non-Cray clusters |
| `gcc-mpich` | Spack GCC 13.3.0 | Spack-built MPICH with OFI | Generic Linux + Cray/Slingshot |
| `gcc-craympich` | Spack GCC 13.3.0 | External cray-mpich | Cray PE (PrgEnv-gnu) |
| `gcc-serial` | Spack GCC 13.3.0 | none | Serial-only lane |
| `cce-craympich` | External CCE | External cray-mpich | Cray PE (PrgEnv-cray) |
| `aocc-openmpi` | External AOCC | Spack-built OpenMPI | AMD CPU clusters |
| `aocc-sitempi` | External AOCC | Site MPI | AMD CPU + site MPI |
| `nvhpc-openmpi` | External NVHPC | Spack-built OpenMPI | NVIDIA GPU nodes |
| `nvhpc-craympich` | External NVHPC | External cray-mpich | Cray PE + NVIDIA GPU |
| `rocmcc-craympich` | External ROCmCC | External cray-mpich | Cray PE + AMD GPU |
| `intel-impi` | External Intel oneAPI | External Intel MPI | Intel oneAPI clusters |

Legacy aliases (`v1-openmpi` → `gcc-openmpi`, `v2-mpich` → `gcc-mpich`) are
accepted with a deprecation warning and will be removed in a future release.

Non-GCC compilers (`cce`, `aocc`, `nvhpc`, `rocmcc`, `intel`) are always
treated as external. The correct `PrgEnv-*` or compiler module **must be loaded
before Stage 1** so Cluster Inspector can detect the version and prefix from the
environment variables the module sets.

## OpenSSL Policy

By default OpenSSL is treated as a site external — Spack will not build it from
source. This keeps the deploy aligned with the site-managed trust and patch
policy. If the site OpenSSL is too old for the selected package set, deploy
fails before concretization with a recommended alternate package set.

When the site OpenSSL forces an undesirable dependency version (e.g. an older
OpenMPI), use a package set with `openssl.mode: spack` to let Spack resolve
OpenSSL from source instead:

```bash
./scripts/deploy.sh --variant gcc-openmpi --release test \
  --shared-path /tmp/cse-test \
  --package-set hdf5-mpi-smoke-spack-openssl
```

Current supported package-set names include:

- `full`: preferred default stack, expects external OpenSSL 3.x
- `science-full`: expanded two-version science stack, with latest-only Miniforge
- `science-full-legacy-openssl`: expanded two-version science stack for older site OpenSSL
- `full-legacy-openssl`: legacy-compatible full stack for older site OpenSSL
- `hdf5-mpi-smoke`: reduced MPI smoke stack, expects external OpenSSL 3.x
- `hdf5-mpi-smoke-legacy-openssl`: reduced MPI smoke stack for older site OpenSSL
- `hdf5-mpi-smoke-spack-openssl`: reduced MPI smoke stack, Spack-built OpenSSL (proof-of-concept)
- `hdf5-serial-smoke`: reduced serial HDF5 smoke stack for Docker and pipeline tests
- `public-buildcache-smoke`: minimal single-package smoke set

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
- Bootstrap bundle: required for `restricted` and `airgapped`.
- Source mirror: required for `restricted` and `airgapped`.
- Optional buildcache: usable in all modes.

## User Model

Users load one front-door module, then load the package they need. The stable
front door points at the current promoted release:

```bash
module load cse-init/GCC/mpi-openmpi
module load cse/netcdf-fortran/4.6.1-mpi
```

Users can also pin themselves to a completed release:

```bash
module load cse-init/20260508/GCC/mpi-openmpi
module load cse/netcdf-fortran/4.6.1-mpi
```

`cse-init/<COMPILER>/<mpi-label>` exposes the CSE compiler baseline and selected
module tree for the current promoted release. `cse-init/<release>/<COMPILER>/<mpi-label>`
exposes the same interface for that exact release. The `mpi-label` is `mpi-openmpi`,
`mpi-mpich`, `mpi-craympich`, etc., or `serial` for the serial-only lane. Spack-generated package modules own
dependency loading through curated public module loads: HDF5 MPI modules load
the MPI provider, NetCDF modules load the matching public HDF5 or NetCDF-C
module, and MPI provider modules do not load their low-level implementation
dependency graph. Package modules are generated relative to the `cse_modules`
Spack view so modulefiles expose clean view paths instead of raw hashed
install-store prefixes. Build implementation dependencies such as bzip2, zlib,
and compiler runtime libraries remain installed, but they are not published as
user-facing modules unless they are explicit root entries in the selected
package set.

`cse-init` sets `CSE_GCC_ROOT`, `CSE_CC`, `CSE_CXX`, and `CSE_FC`, and prepends
the CSE GCC `bin` directory to `PATH` through the clean compiler view path
`${SHARED_PATH}/cse/<release>/<variant>/views/compiler/gcc/<version>`. It does
not set global `CC`, `CXX`, or `FC`; MPI builds should use `mpicc`, `mpicxx`,
and `mpifort` from `cse/openmpi/<version>` or `cse/mpich/<version>`.

## Personal Test Install

A first build does not need a shared filesystem or a `cse` Unix group:

```bash
./scripts/deploy.sh \
  --variant gcc-openmpi \
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
  --variant gcc-openmpi \
  --release test \
  --shared-path /tmp/cse-test \
  --package-set full-legacy-openssl
```

## Post-Install Verification

Normal deploys run Stage 6 after modules are generated. Stage 6 checks the
Spack install tree with `spack verify manifest` for non-external installs and
`spack verify libraries` for public CSE packages, then verifies the CSE user
workflow in a clean module environment. It purges or
resets inherited modules, loads exact site external modules recorded in the
rendered `packages.yaml`, loads the versioned `cse-init` module, and compiles
representative C, C++, Fortran, MPI, HDF5, NetCDF, Python/Numpy, and
Miniforge smoke checks when those packages are present in the selected package
set.

Runtime execution, including MPI launch, is opt-in because allocations and
scheduler launchers vary by system:

```bash
./scripts/deploy.sh \
  --variant gcc-openmpi \
  --release test \
  --shared-path /tmp/cse-test \
  --verify-runtime
```

Use `--skip-verify` for build-only debugging. Stage 6 writes its summary under
the release directory at `verify/summary.txt`.

For Docker smoke tests and disposable local builds, `--use-system-gcc` skips
the Stage 2 `gcc@13.3.0` bootstrap and registers the GCC already on `PATH` as
the CSE compiler baseline. Do not use this for production releases; production
releases should keep the Spack-built compiler baseline for reproducibility.
The serial Docker HDF5 check is available as:

```bash
./scripts/docker_hdf5_serial_smoke_test.sh
```

That script installs `environment-modules`, verifies that the `module` command
is available after sourcing `/etc/profile.d/modules.sh`, builds serial HDF5
with the Docker image GCC, and runs Stage 6 verification.

## Prepared Deploy Workflow

Use the wrapper scripts when the target system cannot perform the whole
connected build itself:

```bash
./scripts/network_prepare_request.sh \
  --request-dir /tmp/cse-request \
  --variant gcc-mpich \
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
authoritative lockfile, and packages the source mirror, bootstrap bundle,
optional buildcache, and air-gap Spack seed. `network_deploy.sh` validates the
manifest, unpacks the local mirror/buildcache payloads, and calls the normal
staged deploy flow with the prepared artifacts.

Operational lessons from real builds are tracked in
`docs/build_process_notes.md`.

## Shared Directory Layout

The cse-stack repository can live anywhere. Build outputs live under the
selected shared root:

```text
${SHARED_PATH}/cse/
  spack-site/                         # shared Spack checkout or seeded copy
  cache/
    source/                           # Spack source cache
    misc/
    spack/                            # Spack user cache isolated from ~/.spack
  modulefiles/
    cse-init/<COMPILER>/<lane>        # current promoted front-door modules
    cse-init/<release>/<COMPILER>/<lane>
  <release>/<variant>/
    profile.yaml                     # captured Cluster Inspector profile for handoff/replay
    render-metadata.json             # render host, package set, compiler mode, target, command
    env/
      packages.yaml                   # rendered externals
      toolchains.yaml                 # rendered compiler/MPI policy
      config.yaml
      modules.yaml
      spack.yaml
      setup-build-env.sh              # sourceable manual-build handoff script
      spack.lock                      # authoritative concretization after fetch/build
    gcc-bootstrap.yaml                # compiler registration for gcc-* variants
    gcc-compilers.yaml                # env-scoped compiler include
    store/                            # release-local Spack install tree
    views/
      compiler/gcc/<version>          # clean compiler path exposed by cse-init
      modules/                        # cse_modules view used by generated modules
      mpi/
      serial/
    modules/                          # Spack-generated package module tree
    verify/summary.txt                # Stage 6 report
```

`--render-only` writes only the `env/*.yaml` files. It does not build packages,
prepare Spack, generate Spack package modules, or write `cse-init`; those
happen after concretize/install and Stage 5. `--render-handoff` also writes
`profile.yaml`, `render-metadata.json`, and `env/setup-build-env.sh`.

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

Install-prefix padding is disabled by default. It can help when relocating
binaries to a longer destination prefix, but the long placeholder paths can
break generated build-time scripts in packages such as `gobject-introspection`.
Use `SPACK_PADDED_LENGTH=<n>` only for a dedicated relocation test build.

## Post-Build Mirror And Buildcache

After a successful build, the environment lockfile at
`${SHARED_PATH}/cse/<release>/<variant>/env/spack.lock` can be used to create
transferable source and binary artifacts.

Create a source mirror for the concretized package closure:

```bash
./scripts/mirror_fetch.sh \
  --mirror-path /tmp/cse-source-mirror \
  --variant gcc-openmpi \
  --release test \
  --shared-path /tmp/cse-test
```

Create a binary buildcache from the installed packages:

```bash
./scripts/buildcache_push.sh \
  --cache-uri file:///tmp/cse-buildcache \
  --variant gcc-openmpi \
  --release test \
  --shared-path /tmp/cse-test
```

Use the matching `--variant`, `--release`, and `--shared-path` from the stack
that was already built. `mirror_fetch.sh` downloads source tarballs and needs
network access. `buildcache_push.sh` publishes installed binaries from the
existing Spack environment and requires Stage 4 to have completed.

If Stage 4 failed after some packages installed, push the partial environment
before cleaning it up:

```bash
./scripts/buildcache_push.sh \
  --cache-uri file:///tmp/cse-buildcache \
  --variant gcc-openmpi \
  --release test \
  --shared-path /tmp/cse-test \
  --allow-partial
```

`--allow-partial` first attempts the normal environment push. If the full
environment cannot be pushed because not every root spec installed, it falls
back to the installed specs Spack can see in the active environment.

To rerun the same release name from a clean release-local store, use
`--restart-release`. When a `--buildcache-uri` is supplied and the previous
environment lockfile exists, deploy exports the installed packages to that cache
before deleting the old release-local `env`, `store`, `views`, and `modules`:

```bash
./scripts/deploy.sh \
  --variant gcc-openmpi \
  --release test \
  --shared-path /tmp/cse-test \
  --package-set science-full \
  --buildcache-uri file:///tmp/cse-buildcache \
  --restart-release \
  --jobs 4 \
  --make-jobs 16
```

This is the preferred recovery path when a deploy setting changes in a way that
affects installed prefixes, such as toggling `SPACK_PADDED_LENGTH`. Do not reuse
the old release-local store in place after that kind of change; export what is
usable to a buildcache, clear the release state, and reinstall into a fresh
store.

To test a cache-only install from a local buildcache:

```bash
SPACK_NO_CHECK_SIGNATURE=1 ./scripts/deploy.sh \
  --variant gcc-openmpi \
  --release test-cache \
  --shared-path /tmp/cse-cache-test \
  --package-set public-buildcache-smoke \
  --buildcache-uri file:///tmp/cse-buildcache \
  --cache-only
```

Use `SPACK_NO_CHECK_SIGNATURE=1` for unsigned local test caches, including
normal rebuilds that use `--buildcache-uri` without `--cache-only`. Production
caches should use a signing and trust policy before deploys rely on them.

Buildcache hits require an exact concrete Spack spec match, not just the same
package name. The hash includes the compiler, target, operating system, variants,
package version, and dependency DAG. A package like `pkgconf` can be reused
between releases only when those concrete details are identical.

To compare what the current environment wants with what the cache contains,
activate the generated environment and query both sides:

```bash
. "${SHARED_PATH}/cse/spack-site/share/spack/setup-env.sh"
spack env activate -d "${SHARED_PATH}/cse/<release>/<variant>/env"
spack find -L -c pkgconf
spack buildcache list -L pkgconf
```

If the dependency hash shown by `spack find -L -c` is not present in
`spack buildcache list -L`, Spack correctly treats the cache entry as a miss.

By default deploy runs up to four package builds at a time and gives each package
build up to the detected make-job count, clamped to 4-16 threads. Override those
separately when needed:

```bash
./scripts/deploy.sh \
  --variant gcc-openmpi \
  --release test-cache \
  --shared-path /tmp/cse-cache-test \
  --package-set science-full \
  --buildcache-uri file:///tmp/cse-buildcache \
  --jobs 4 \
  --make-jobs 16
```

## Dry Runs

Dry-runs render the intended YAML/module content and execute no build:

```bash
./scripts/deploy.sh \
  --variant gcc-openmpi \
  --release test \
  --shared-path /tmp/cse-test \
  --dry-run

./scripts/deploy.sh \
  --variant gcc-mpich \
  --release test \
  --shared-path /tmp/cse-test \
  --mock-profile profiles/mock-cray.yaml \
  --dry-run
```

## Render-Only, Prepared Handoff, and Manual Mode

`--render-only` runs stages 1 and 3, renders all remaining YAML files
(config, modules, spack), and exits before calling any Spack command. It does
not prepare Spack or lock the compiler baseline. Use it for YAML inspection or
template debugging:

```bash
./scripts/deploy.sh --variant gcc-openmpi --release test \
  --shared-path /tmp/cse-test --render-only
```

`--render-handoff` is the buildable handoff path. It runs stages 1-3, prepares
the shared Spack tree, locks the compiler choice in `gcc-bootstrap.yaml` and
`gcc-compilers.yaml`, renders the full environment, copies the captured profile,
writes `render-metadata.json`, and generates a sourceable setup script:

```bash
./scripts/deploy.sh --variant gcc-openmpi --release test \
  --shared-path /shared --render-handoff
```

The manual builder should source the generated script and then run the printed
commands. Cluster Inspector is not rerun by default; the builder uses the
captured `profile.yaml` and render metadata from the handoff. If site modules,
compiler paths, or system facts changed, rerun `--render-handoff` instead of
manually editing the build environment.

```bash
source /shared/cse/test/gcc-openmpi/env/setup-build-env.sh
spack concretize --fresh
spack install --concurrent-packages 4 --jobs 16 --fail-fast
```

After a manual install, return to the staged flow for module generation and
verification:

```bash
./scripts/deploy.sh --variant gcc-openmpi --release test \
  --shared-path /shared --skip-render --from-stage 5
```

`--skip-render` jumps directly to existing rendered YAML. Combine with
`--fetch` / `--build` for a login+compute split workflow.

For environments pre-rendered by an operator, `scripts/spack_build.sh` is a
standalone installer that needs only `--env-dir` and `--spack-root`:

```bash
./scripts/spack_build.sh \
  --env-dir /shared/cse/2026_05/gcc-openmpi/env \
  --spack-root /shared/cse/spack-site
```

That standalone path performs concretize/install only. The normal cse-stack
repo is still needed later to run Stage 5/6 and publish modules.

## Per-System GitLab Repository Workflow

The recommended operating model is one GitLab project per target system or
closely related system family. Keep cse-stack itself as the implementation
repo; the per-system repo records site policy, rendered intent, and release
evidence.

Suggested contents:

- `profiles/`: captured Cluster Inspector profiles used for releases.
- `releases/<release>/<variant>/`: rendered `env/*.yaml`, final `spack.lock`,
  copied handoff `profile.yaml`, `render-metadata.json`, Stage 6 `summary.txt`,
  release notes, and concise build notes.
- `package-sets/`: only site-local overrides that are not suitable for the
  shared cse-stack package sets.
- `artifacts/manifest.json`: pointers to source mirrors, bootstrap bundles,
  and buildcaches stored in GitLab Package Registry, object storage, or the
  site filesystem. Avoid committing large tarballs directly to Git.
- `README.md`: system-specific module roots, scheduler notes, expected external
  modules, build allocation instructions, and promotion policy.

The details still need to be finalized before we call this a locked workflow:
release tag naming, who is allowed to promote `cse-init/<COMPILER>/<lane>`,
where large artifacts live, and whether custom package sets are referenced by
file path or copied into the implementation repo before release.

## Login-Node Fetch / Compute-Node Build

On clusters where internet access is login-only and large builds need a
compute allocation, split stage 4 into two steps:

```bash
# Login node — concretize + fetch all sources:
./scripts/deploy.sh --variant gcc-openmpi --release 2026_05 \
  --shared-path /shared --from-stage 4 --fetch

# Compute node (inside salloc / qsub) — build only:
./scripts/deploy.sh --variant gcc-openmpi --release 2026_05 \
  --shared-path /shared --skip-render --build
```

The `--fetch` step writes `spack.lock` and populates the source cache.
The `--build` step reads the same lockfile and does not re-concretize.

## Stages

`deploy.sh` runs six idempotent stages:

| Stage | Script | Purpose |
|---|---|---|
| 1 | `stage1_profile.sh` | Capture a Cluster Inspector system profile |
| 2 | `stage2_spack.sh` | Clone Spack to `${SHARED_PATH}/cse/spack-site` and bootstrap GCC, or register system GCC for smoke tests |
| 3 | `stage3_externals.sh` | Render `packages.yaml` and `toolchains.yaml` |
| 4 | `stage4_build.sh` | Render remaining Spack config, concretize, and install |
| 5 | `stage5_modules.sh` | Refresh Spack modules and render/install current and pinned `cse-init` gates |
| 6 | `stage6_verify.sh` | Run Spack integrity checks and clean-shell user workflow smoke tests |

Stage 2 writes `${SHARED_PATH}/cse/<release>/<variant>/gcc-bootstrap.yaml`.
Stage 4 includes that file as the only compiler registration for the
bootstrapped GCC.

For prepared restricted or air-gapped deploys, `deploy.sh` also accepts:

- `--network-mode online|restricted|airgapped`
- `--spack-seed <tar-or-dir>`
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
- Spack's default prefix inspections provide build-discovery paths such as
  `PATH`, `PKG_CONFIG_PATH`, `CMAKE_PREFIX_PATH`, and `MANPATH`; the CSE
  template does not restate those defaults.
- Generated package modules filter broad low-level path variables such as
  `LD_LIBRARY_PATH`, `LIBRARY_PATH`, `CPATH`, `C_INCLUDE_PATH`, and
  `CPLUS_INCLUDE_PATH`. Runtime linking is expected to come from Spack RPATHs;
  package-specific build discovery should use compiler/MPI wrappers, CMake,
  pkg-config, or package config tools.
- The module catalog is derived from explicit root entries in package-set
  `specs:`; transitive dependencies are excluded from modulefile generation.
- Generic `{name}_ROOT`, `{name}_DIR`, and `{name}_HOME` variables are not set
  because Spack does not project those manual entries through `use_view`.
- Broad dependency autoload is disabled; only curated public module loads are
  emitted.
- `cse-init` activates the namespace only; it does not hard-code HDF5, NetCDF,
  or MPI dependency loads.
- Stage 5 writes both `cse-init/<mpi>` and `cse-init/<release>/<mpi>`.
  `cse-init/<mpi>` is the current promoted release, while the release-pinned
  path preserves access to a completed release.

## Future Ansible Use

The bash scripts are the canonical implementation for now. They are kept
parameter-driven and idempotent so Ansible can later call the same stages
instead of reimplementing the deployment logic.
