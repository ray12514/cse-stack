# Build Process Notes

This is the running log for practical lessons learned while building and
recovering CSE Spack stacks. Keep the README focused on supported operator
flows; put observed failures, root causes, diagnostics, and recovery notes here.

## Current Baseline

- Default release target is portable `target=x86_64`.
- Default parallelism is four concurrent package builds with up to sixteen
  build threads per package:

  ```bash
  ./scripts/deploy.sh ... --jobs 4 --make-jobs 16
  ```

- Install-prefix padding is disabled by default. Use
  `SPACK_PADDED_LENGTH=<n>` only for a dedicated relocation test build.
- Local test buildcaches are pushed unsigned. Use
  `SPACK_NO_CHECK_SIGNATURE=1` when consuming those caches.
- Environment-local mirror configuration must be visible through rendered
  `spack.yaml`. Stage 4 includes `./mirrors.yaml` whenever `--mirror-path` or
  `--buildcache-uri` is set.

## Buildcache Recovery Flow

When a build fails after some packages were installed, export what exists before
cleaning the release-local store:

```bash
./scripts/buildcache_push.sh \
  --cache-uri file:///p/work1/ravonmv/cse/cache/buildcache \
  --variant v1-openmpi \
  --release 20260508 \
  --shared-path /p/work1/ravonmv \
  --allow-partial
```

To retry the same release name from a clean release-local store:

```bash
SPACK_NO_CHECK_SIGNATURE=1 ./scripts/deploy.sh \
  --variant v1-openmpi \
  --release 20260508 \
  --shared-path /p/work1/ravonmv \
  --package-set science-full \
  --buildcache-uri file:///p/work1/ravonmv/cse/cache/buildcache \
  --restart-release \
  --jobs 4 \
  --make-jobs 16
```

`--restart-release` removes only release-local generated state:

- `${SHARED_PATH}/cse/<release>/<variant>/env`
- `${SHARED_PATH}/cse/<release>/<variant>/store`
- `${SHARED_PATH}/cse/<release>/<variant>/views`
- `${SHARED_PATH}/cse/<release>/<variant>/modules`
- `${SHARED_PATH}/cse/<release>/<variant>/.cse-install-meta`

It does not remove the shared Spack clone or shared caches under
`${SHARED_PATH}/cse/cache`.

## Buildcache Diagnostics

Stage 4 prints the active mirror list when a mirror or buildcache is configured.
Confirm that the output includes the expected buildcache:

```text
Stage 4: active Spack mirrors:
cse-buildcache  file:///p/work1/ravonmv/cse/cache/buildcache
```

If Spack sees the mirror but still builds from source, compare concrete hashes:

```bash
. /p/work1/ravonmv/cse/spack-site/share/spack/setup-env.sh
spack env activate -d /p/work1/ravonmv/cse/20260508/v1-openmpi/env
spack find -L -c pkgconf
spack buildcache list -L pkgconf
```

The hash from `spack find -L -c` must appear in `spack buildcache list -L`.
Matching names are not enough. The hash includes OS, compiler, target, variants,
package versions, and dependency DAG.

## Known Failure Modes

### Padded Prefix Breaks GIR Generation

Symptom:

- `gobject-introspection` fails while generating `gir/GLib-2.0.gir`.
- The log contains `/usr/bin/env: ... __spack_path_placeholder__ ... No such
  file or directory`.

Cause:

- `padded_length: 256` creates very long placeholder prefixes.
- Some generated build-time scripts can preserve or truncate those placeholder
  paths in a way that makes the interpreter path invalid.

Resolution:

- Prefix padding is now disabled by default.
- Retry with `--restart-release` so the release-local store is rebuilt without
  padded paths.
- Use `SPACK_PADDED_LENGTH=<n>` only in a separate relocation test.

### Unsigned Buildcache Ignored During Normal Installs

Symptom:

- A local buildcache is passed with `--buildcache-uri`.
- Packages still install from source.
- Cache-only may behave differently from a normal install.

Cause:

- Local caches are pushed with `spack buildcache push --unsigned`.
- Spack needs `--no-check-signature` to consume unsigned binaries.

Resolution:

- Run deploy with `SPACK_NO_CHECK_SIGNATURE=1` for unsigned local test caches.
- Stage 2 and Stage 4 now pass `--no-check-signature` for normal installs when a
  buildcache URI is set and `SPACK_NO_CHECK_SIGNATURE=1`.

### Environment Mirror File Not Included

Symptom:

- Stage 4 writes `mirrors.yaml`, but the build still behaves as if no binary
  cache was configured.

Cause:

- The rendered environment `spack.yaml` did not include `./mirrors.yaml`.

Resolution:

- `templates/spack.yaml.j2` now includes `./mirrors.yaml` whenever
  `--mirror-path` or `--buildcache-uri` is set.
- Stage 4 prints `spack mirror list` after activating the environment.

### Stale Views Block Restart

Symptom:

- A stopped or failed Stage 4 run later fails during view regeneration.
- Errors mention an existing or non-empty view path, including hidden staging
  paths such as `views/._modules/...`.

Cause:

- Spack can leave view directories or hidden temporary view directories behind
  after interrupted installs.

Resolution:

- Stage 4 and Stage 5 remove stale `modules`, `mpi`, `serial`, `._modules`,
  `._mpi`, and `._serial` view paths before concretize/install/regenerate.

### Boost Serial View Collision

Symptom:

- Serial environment view fails because multiple Boost versions project to the
  same prefix.

Cause:

- Multiple `boost~mpi` versions projected to the same view path.

Resolution:

- Boost view projections use readable variant subdirectories:
  `boost/<version>/serial` and `boost/<version>/mpi`.
- Boost module names use Spack's module suffix form:
  `cse/boost/<version>-serial` and `cse/boost/<version>-mpi`.
- Boost modules conflict with `cse/boost` so users do not load incompatible
  Boost variants together.

### Transitive View Collisions

Symptom:

- The build completes, but view regeneration fails because multiple concrete
  hidden dependency specs project to the same view path.
- Observed examples include `pango` and `harfbuzz`.

Cause:

- Packages such as `pango` and `harfbuzz` are not top-level CSE package-set
  specs. They are pulled in by graphics dependencies, most visibly through the
  `gnuplot` stack.
- Multiple top-level specs can require different concrete dependency DAGs. The
  hidden packages may share the same package version while differing by
  dependency hash, which makes a default `{name}/{version}` view projection
  collide.

Resolution:

- Public/root package-set specs keep clean view projections.
- Hidden/transitive fallback projections use `{name}/{version}/{hash:7}` so
  multiple concrete instances can coexist without changing clean public module
  names.
- Stage 4 reports duplicate concrete `name@version` specs after concretization
  so this class of collision is visible before install/view regeneration.
- Stage 5 enforces that expected public and curated-load module targets exist.
  Extra generated dependency modules are reported as warnings instead of
  failing the release, because the public contract is the curated catalog.

### HDF5 Threadsafe Variant Pressure

Symptom:

- HDF5 builds become harder to satisfy or fail around feature combinations.

Cause:

- `+threadsafe` is not required for the current science stack and can conflict
  with other HDF5 features depending on package version and dependency choices.

Resolution:

- `science-full` no longer requests `+threadsafe` by default.

### Current and Pinned Release Gates

Policy:

- `cse-init/<mpi>` is the stable front-door module for the current promoted
  release.
- `cse-init/<release>/<mpi>` is the pinned front-door module for one completed
  release.
- Stage 5 is the promotion step. Running Stage 5 for a release refreshes the
  Spack module tree, writes that release's pinned gate, and repoints the stable
  `cse-init/<mpi>` gate at the same release.

Implications:

- Users who want the current site default load `cse-init/openmpi` or
  `cse-init/mpich`.
- Users who need repeatability load a pinned module such as
  `cse-init/20260508/openmpi`.
- Operators can switch current back to an already-built release by rerunning
  Stage 5 with that release name.

### Compiler Selection: Why No packages:all:compiler

`packages:all:compiler: [gcc@X]` was added to `packages.yaml.j2` to express a
compiler preference, then removed because Spack v1.0.x deprecated it and emits a
warning that it will be dropped. The replacement, `packages:all:require:`, is a
hard constraint and causes concretization failures for noarch/binary packages
(the immediate symptom was `miniforge3` failing with "cannot depend on gcc").

The correct mechanism for a self-contained CSE Spack environment is isolation:

- `SPACK_DISABLE_LOCAL_CONFIG=1` — no user `~/.spack/compilers.yaml` leaks in.
- `SPACK_SYSTEM_CONFIG_PATH=/dev/null` — no site-level compiler config leaks in.
- `gcc-bootstrap.yaml` (written by stage 2, included by stage 4's `spack.yaml`)
  is the **only** registered compiler.

With exactly one compiler available, the CLINGO concretizer picks it for every
buildable package. Externals and noarch packages are unaffected because Spack
does not assign a compiler to them in the first place.

### Package-Set Matrix Entries: Only fftw Is 2D

The `science-full` package sets used `matrix:` syntax for several packages that
had only a single axis (e.g., `matrix: [["openblas@0.3.30", "openblas@0.3.29"]]`).
A single-axis matrix is identical to two plain spec strings and adds parsing
overhead with no combinatorial benefit. Those entries were flattened to plain
strings.

`fftw` retains the matrix because it is genuinely two-dimensional: two versions
× two MPI options = four specs. That is the intended use case for matrix syntax.
When adding new dual-version packages to a science package set, write them as
plain specs unless a second axis (variants, MPI providers, etc.) also needs to
be crossed.

## Open Items

- Decide when to introduce signed production buildcaches and key trust
  management.
- Add a first-class cache inspection command that summarizes mirror visibility,
  root spec hashes, and cache hit/miss status before the long install starts.
- Keep evaluating whether generic `x86_64` remains the right default for the
  first production cache, or whether a site-specific optimized cache namespace
  should be added later.
