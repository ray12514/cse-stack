# Spack-Composer Design v1

## Purpose

`spack-composer` is the central stack-side tool described in the v6 design
notes (`docs/spack_stack_generation_design_v6.md`). It is the *replacement* for
the ad-hoc tooling layer that grew up inside `cse-stack`. The stack content
(profiles, stacks, templates, package sets, package repos) remains
human-authored YAML and Jinja; `spack-composer` operates on that content
and produces Spack-consumable workspaces, validation reports, scaffolded
template stubs, and finalized release manifests.

It is the **non-helper** of the v6 model: unlike `cluster-inspector` or
Ansible, the typical end-to-end flow goes through `spack-composer`. The
"manual workflow" remains executable (a human can write `spack.yaml` and run
`spack install` by hand), but the supported path is `spack-composer
render` → Spack → `spack-composer publish-manifest`.

## Document Set

| Document | Purpose |
|---|---|
| `spack_stack_generation_design_v6.md` § Render Step — Specification | The render seam contract: inputs, outputs, invariants, and the render pseudo-code. Authoritative for what a rendered workspace must look like. |
| `spack_composer_design_v1.md` (this document) | Product boundary, language and repo decisions, command catalog with per-command algorithm sketches, repository shape, packaging plan, and implementation phases. |

When the two disagree, the v6 render seam wins for the *render* command's
contract (`render` is a seam that every implementer reads). This document
wins for everything else: the other six commands, the repo shape, the
language, the packaging plan, the phases.

## Product Boundary

`spack-composer` is a content-to-Spack-workspace pipeline plus a set of
maintainer-facing analysis commands. Its CLI is the supported entry point
for stack operations.

| Boundary | Decision |
|---|---|
| Primary artifact | A rendered Spack workspace at `<output-root>/<system>/<stack>/<release>/`. |
| Primary consumer | Spack itself, on a build host; downstream Ansible playbooks for distribution. |
| Primary command | `spack-composer render`. |
| Durable inputs | `systems/<system>/profile.yaml`, `stacks/<stack>/stack.yaml`, `templates/<set>/...`, optional `package-sets/<name>.yaml`, optional `package-repos/<name>/`. |
| Durable outputs | Rendered workspace tree + `release-manifest.yaml`. The manifest is rewritten in place by `publish-manifest` to add build-context fields. |
| Diagnostics | Coverage reports, validate reports, explain menus, scaffold proposals. Written only when commanded; never co-mingled with the rendered workspace. |
| Source of truth | The stack repository. `spack-composer` does not invent stack content. |

## Relationship To `cse-stack`

`cse-stack` is being replaced by the generic, content-driven model where
`spack-composer` provides the tooling and `cse-stack` becomes one
*content corpus* among others. The relationship is:

- `cse-stack` is a downstream consumer / test fixture.
- Patterns proven in `cse-stack` are evaluated for promotion into the
  generic model (`templates/`, contract resolver rules, manifest fields).
- Patterns that do not promote stay in `cse-stack` until they either prove
  themselves or are discarded.
- `spack-composer` must not encode `cse-stack`-specific assumptions.
  Whatever it learns about packaging, lane composition, or manifest
  shape must be expressible through the generic stack inputs.

This means `cse-stack` is also the most useful early test surface for
`spack-composer`. The phase plan below (§Implementation Plan) treats
`cse-stack` fixtures as Phase 4 acceptance evidence, not Phase 1.

## Non-Goals

These are *not* `spack-composer`'s job:

- **No host probing.** `spack-composer` does not call `module avail`,
  read `/etc/os-release`, or otherwise inspect the host. System facts come
  from `profile.yaml`. The producer of that file is `cluster-inspector` or
  a human; see the inspector design docs.
- **No Spack calls in `render`.** The render step does not run `spack
  concretize`, `spack spec`, or `spack install`. Spack may be installed on
  the same host, but the renderer does not depend on it.
  (`validate-template-set` is the one command that *may* invoke Spack as
  an optional Phase 2 acceptance check; the render contract itself
  remains Spack-free.)
- **No deploy.** `spack-composer` does not `rsync`, `scp`, or otherwise
  distribute a rendered workspace to a build host. Distribution is
  Ansible's job (or a human's `rsync`).
- **No promotion.** `spack-composer` does not swap a `current` symlink,
  push to a release tree, or sign off on a release. The `publish-manifest`
  command rewrites the manifest in place; promotion gating lives in
  Ansible or human review.
- **No build orchestration.** `spack-composer` does not loop over lanes,
  submit `srun` jobs, or push to buildcaches. Those operations live in
  Ansible (or a human running `spack install`).
- **No template policy.** `scaffold-templates` proposes; the maintainer
  decides what becomes a committed template set. `spack-composer` will
  never overwrite an existing template scope or contract without the
  operator explicitly redirecting `--output` at that path.
- **No package decisions.** Which packages get built is `stack.yaml` intent.
  `spack-composer` resolves intent against the contract and profile; it
  does not pick package roots.

## Runtime Distribution

`spack-composer` ships as a pip-installable Python package. The packaging
constraints differ from `cluster-inspector`:

| Concern | spack-composer | cluster-inspector |
|---|---|---|
| Target host | Maintainer laptop, CI runner, optionally a build host with Python. | Restricted HPC login or compute node, no source checkout. |
| Distribution | `pip install spack-composer` from an internal index, or `pip install` from a wheel artifact. | Single Go binary copied onto the target. |
| Self-contained | Python package + dependencies pinned at release time. Resource files (template contract schema, manifest schema, jinja base templates) shipped in the package and loaded via `importlib.resources`. | Resource files embedded in the Go binary via `embed`. |
| Network | None required at runtime. Internal package index used at install time. | None required at runtime. |
| Spack required | No (`render` and `validate` never call Spack). Optional for `validate-template-set` Phase 2. | No. |

The package must not read schema or template-base files from the source
checkout. After install, the only inputs are command-line arguments, the
stack repository the operator points at, and resource files embedded in
the package.

## Implementation Language Decision

The implementation language is **Python**.

Rationale:

- The Spack ecosystem itself is Python. Stack maintainers reading
  templates, contract resolver rules, and packages.yaml fragments already
  read Python.
- Jinja2 is the canonical templating engine in Python and is the natural
  fit for the `templates/<set>/configs/...` and `environments/...` tree.
  Go's `text/template` is less ergonomic for the macro-heavy templates a
  real template set uses.
- Schema validation libraries (`pydantic`, `jsonschema`) are mature and
  ergonomic for the layered YAML the renderer consumes.
- `spack-composer` runs on laptops and CI runners. It does not need to be
  copied onto a restricted HPC host the way `cluster-inspector` does. The
  single-binary distribution argument that decided Go for the inspector
  does not apply here.
- A Python tool is easier to extend from a maintainer who already maintains
  a `package.py` recipe than a Go tool would be.

Stack maintainers do not need to know Go to maintain templates, but they
will routinely read and occasionally extend `spack-composer`. Choosing
Python keeps that path open.

## Relationship To The Stack Design

The stack design separates concerns sharply:

| File | Owner | Contents |
|---|---|---|
| `profile.yaml` | System owner / `cluster-inspector` | Observed platform facts. |
| `stack.yaml` | Stack owner (package manager) | Desired stack behavior and root specs. |
| `templates/<set>/contract.yaml` | Framework/template owner | Vocabulary and resolver semantics. |
| `templates/<set>/stack-defaults.yaml` | Framework/template owner | Defaults for modules, externals, buildcache, release policy. |
| `templates/<set>/configs/...`, `templates/<set>/environments/...` | Framework/template owner | Jinja template tree the renderer expands. |
| `package-sets/<name>.yaml` | Stack owner | Optional reusable root spec lists. |
| `package-repos/<name>/` | Stack owner | Internal Spack package recipes. |

`spack-composer` works *only* on these files plus release variables passed
on the command line. It does not infer stack intent from system facts (that
would re-introduce the inspector/composer coupling v6 is designed to
prevent), and it does not write into any of the above paths during normal
operation. `scaffold-templates` is the one command that writes Jinja and
contract content, and it writes to a separate proposed-output path under
operator control.

## Command Set

Seven first-class commands, grouped by audience:

| Command | Audience | Writes to | Calls Spack? |
|---|---|---|---|
| `spack-composer assess-profiles` | maintainer | `--output` report file | No |
| `spack-composer scaffold-templates` | maintainer | `--output` proposed-template directory | No |
| `spack-composer validate-template-set` | maintainer / CI | `--output` report directory | Optional |
| `spack-composer explain` | package manager | stdout | No |
| `spack-composer render` | package manager / CI | `--output-root/<sys>/<stack>/<release>/` | No |
| `spack-composer validate` | package manager / CI | stdout (or `--report`) | No |
| `spack-composer publish-manifest` | CI / package manager | rewrites `release-manifest.yaml` in place | No |

The render seam is the only command whose contract lives in v6. Every
other command's contract lives in this document (the per-command
specifications below).

## Per-Command Specifications

Each subsection covers: purpose, audience, inputs, outputs, algorithm
sketch, invariants, and an example invocation.

### `spack-composer assess-profiles`

**Purpose.** Read a corpus of profiles and report which template sets cover
which systems. Identify coverage gaps before changing templates.

**Audience.** Maintainer.

**Inputs.**

- `--profiles <glob>` — one or more `profile.yaml` paths. Required.
- `--templates <dir>` — root of one or more template sets. Required.
- `--output <path>` — report YAML; defaults to stdout when omitted.

**Outputs.** A coverage report (YAML) plus a human summary on stderr. No
writes to stack source.

**Algorithm sketch.**

```text
function assess_profiles(profiles_glob, templates_dir, output_path):
    profiles = [load_profile(p) for p in expand(profiles_glob)]
    template_sets = enumerate_template_sets(templates_dir)
    matrix = {}
    for ts in template_sets:
        contract = load_contract(ts)
        defaults = load_defaults(ts)
        for profile in profiles:
            row = matrix.setdefault(ts.name, {})
            try:
                resolved = dry_resolve(profile, contract, defaults)
                row[profile.system.name] = {
                    "covered": True,
                    "lane_count": len(resolved.lanes),
                    "lane_kinds": resolved.lane_kinds,
                }
            except ResolutionFailure as e:
                row[profile.system.name] = {
                    "covered": False,
                    "missing_facts": e.missing_facts,
                    "blocked_toolchains": e.blocked_toolchains,
                }
    write_report(output_path, matrix, gaps=derive_gaps(matrix))
```

`dry_resolve` is a thin wrapper around the parts of the renderer that
resolve `build_class`, `toolchain`, and `nodes` against the contract and
profile, *without* expanding any Jinja templates or writing a workspace.

**Invariants.**

- Read-only on the stack source. The report is the only output.
- Deterministic for a fixed profile corpus and template tree.
- Never fails the run because one profile failed to resolve; failures are
  data in the report, not crashes.

**Example.**

```bash
spack-composer assess-profiles \
  --profiles 'systems/*/profile.yaml' \
  --templates templates \
  --output reports/coverage-2026.06.yaml
```

### `spack-composer scaffold-templates`

**Purpose.** Propose template/contract stubs that would extend coverage to
a profile not yet supported by any existing template set.

**Audience.** Maintainer.

**Inputs.**

- `--profile <path>` — one `profile.yaml`. Required.
- `--seed <template-set-dir>` — optional starter template set to use as
  the structural baseline. Defaults to a bundled starter shipped in the
  package's resource files.
- `--output <dir>` — directory the proposed templates will be written to.
  Required, must not exist or must be empty.
- `--stack-kind <library|application>` — picks which starter shape is used
  when `--seed` is not supplied. Defaults to `library`.

**Outputs.** A proposed-template directory containing draft `contract.yaml`,
draft `stack-defaults.yaml`, draft `configs/<scope>/...` files, and draft
`environments/<lane-kind>/spack.yaml.j2` files. Every file carries TODO
comments at the points where a human must make a real decision.

**Algorithm sketch.**

```text
function scaffold_templates(profile_path, seed_dir, output_dir, stack_kind):
    profile = load_profile(profile_path)
    seed = seed_dir or builtin_starter(stack_kind)
    require(output_dir.is_empty(),
            "scaffold output dir must not contain existing templates")

    facts = summarize_profile_facts(profile)
    # facts.compilers, facts.mpi_providers, facts.gpu_arches, facts.fabric,
    # facts.os, facts.cpu_targets, facts.vendor_cray (bool)

    scopes_to_emit = []
    scopes_to_emit += os_scopes(facts.os)
    scopes_to_emit += target_scopes(facts.cpu_targets)
    if facts.vendor_cray:
        scopes_to_emit += vendor_cray_scopes(facts)
    else:
        scopes_to_emit += vendor_generic_scopes(facts)
    scopes_to_emit += mpi_scopes(facts.mpi_providers)
    scopes_to_emit += gpu_scopes(facts.gpu_arches)

    for scope in scopes_to_emit:
        emit_scope_stub(output_dir / "configs" / scope.path,
                        seed_scope_template(seed, scope), facts)

    emit_contract_stub(output_dir / "contract.yaml",
                       facts, scopes_to_emit, seed_contract(seed))
    emit_defaults_stub(output_dir / "stack-defaults.yaml",
                       facts, scopes_to_emit, seed_defaults(seed))

    for lane_kind in lane_kinds_for_profile(profile):
        emit_env_stub(output_dir / "environments" / lane_kind / "spack.yaml.j2",
                      seed_env(seed, lane_kind), facts)

    write_review_checklist(output_dir / "REVIEW.md", facts, scopes_to_emit)
```

**Invariants.**

- Never writes outside `--output`. Never modifies an existing template set.
- Every file has at least one `# TODO` marker. The maintainer is expected
  to walk the tree and make decisions before promoting.
- `REVIEW.md` is the operator's checklist: which scope decisions are
  load-bearing, what defaults were guessed, what was left blank.
- Re-running with the same inputs produces byte-identical output.

**Example.**

```bash
spack-composer scaffold-templates \
  --profile systems/new-site/profile.yaml \
  --seed templates/v6 \
  --output proposed-templates/new-site \
  --stack-kind library
```

### `spack-composer validate-template-set`

**Purpose.** Render smoke stacks across a profile corpus to prove a
template set covers known systems. Catches breakage in CI before a
template change reaches a release.

**Audience.** Maintainer, CI.

**Inputs.**

- `--templates <dir>` — single template set under test. Required.
- `--profiles <glob>` — profiles to test against. Required.
- `--smoke-stack <path>` — a small `stack.yaml` that exercises the template
  set's core lane kinds. Required.
- `--concretize` — optional flag. When set, attempt `spack -e <env>
  concretize` on each rendered lane. Requires Spack on `PATH`.
- `--output <dir>` — directory of per-profile reports.

**Outputs.** Per-profile reports under `--output/<profile>/`:
`render.log`, optional `concretize.log`, and a summary `result.yaml`.
A roll-up `summary.yaml` at the output root.

**Algorithm sketch.**

```text
function validate_template_set(templates_dir, profiles_glob, smoke_stack,
                                concretize, output_dir):
    summary = []
    for profile_path in expand(profiles_glob):
        report_dir = output_dir / slug(profile_path)
        mkdir(report_dir)
        try:
            workspace = render(profile_path, smoke_stack,
                               templates_dir=templates_dir,
                               output_dir=report_dir / "workspace",
                               release_vars=smoke_release_vars())
            result = {"render": "ok", "workspace": str(workspace)}
            if concretize:
                conc = try_concretize_all_lanes(workspace)
                result["concretize"] = conc.status
                result["lane_results"] = conc.lane_results
        except RenderFailure as e:
            result = {"render": "fail", "reason_code": e.code,
                      "reason": str(e)}
        write_yaml(report_dir / "result.yaml", result)
        summary.append({"profile": profile_path, **result})
    write_yaml(output_dir / "summary.yaml", summary)
```

**Invariants.**

- Renders for *every* profile, even after one fails. Aggregates results.
- Failures are reported, not raised. Exit code reflects whether any
  profile failed.
- When `--concretize` is set, Spack version is recorded in the summary
  for reproducibility.
- Writes only under `--output`.

**Example.**

```bash
spack-composer validate-template-set \
  --templates templates/v6 \
  --profiles 'systems/*/profile.yaml' \
  --smoke-stack stacks/_smoke/stack.yaml \
  --concretize \
  --output reports/template-validation/v6
```

### `spack-composer explain`

**Purpose.** Print valid `class`, `toolchain`, `nodes`, GPU arch, and
`per_system` narrowing values for one (stack, template-set, profile)
triple. Helps the package manager author a `stack.yaml` without reading
the contract source.

**Audience.** Package manager.

**Inputs.**

- `--profile <path>` — required.
- `--stack <path>` — required when explaining a specific stack; if omitted,
  explains the contract's full vocabulary against the profile.
- `--template-set <dir>` — required when `--stack` does not pin
  `templates.set`; otherwise resolved from the stack.
- `--format <human|yaml>` — defaults to human.

**Outputs.** stdout.

**Algorithm sketch.**

```text
function explain(profile_path, stack_path, template_set_dir, format):
    profile = load_profile(profile_path)
    stack = load_stack(stack_path) if stack_path else None
    contract = load_contract(template_set_dir or stack.templates.set)
    facts = summarize_profile_facts(profile)

    valid = {
        "build_classes":   contract.build_classes.keys(),
        "toolchains":      filter_resolvable(contract.toolchains, facts),
        "node_selectors":  filter_resolvable(contract.node_selectors,
                                              facts.node_types),
        "gpu_arches":      facts.gpu_arches,
        "compilers":       facts.compiler_names,
        "mpi_providers":   facts.mpi_provider_names,
    }
    if stack:
        valid["per_system_narrowing"] = compute_narrowing_menu(stack, contract, facts)

    render_output(format, valid)
```

**Invariants.**

- Read-only.
- Deterministic.
- Filters every menu by what the profile can actually resolve; a compiler
  the contract knows about but the profile lacks does not appear.

**Example.**

```bash
spack-composer explain \
  --profile systems/example-cray/profile.yaml \
  --stack stacks/cse/stack.yaml
```

### `spack-composer render`

**Purpose.** Produce a runnable Spack workspace from a profile, stack,
template set, optional package sets, and optional package repos.

**Audience.** Package manager, CI.

**Contract.** The render command's full spec — inputs, outputs, invariants,
pseudo-code — lives in v6 § Render Step — Specification. This is the seam
contract that every implementer reads. This document does not duplicate
it.

**Notes specific to the Python implementation.**

- The render function corresponds to the v6 `render()` pseudo-code
  literally. Each top-level section in the pseudo-code (`Inputs`,
  `Context`, `Workspace skeleton`, `Config scopes`, `Lane environments`,
  `Release manifest`, `Commit`) maps to a function in the
  implementation.
- The Jinja environment is constructed once per render and is sandboxed:
  no `os.system`, no filesystem reads outside `templates/<set>/`, no
  network. The template context is the frozen `ctx` dict from the
  pseudo-code; templates may read its keys but cannot extend it.
- Schema validation uses `pydantic` models generated from the JSON
  schemas under `spack_composer/schemas/`. Profile, stack, package set,
  contract, defaults, and manifest each have a model.
- Determinism: YAML output uses a stable dumper (sorted keys at the
  per-block level chosen for review, not insertion order); template
  rendering never calls `time.time()` or `random`. Release timestamps are
  release-variable inputs, never wall-clock reads.

### `spack-composer validate`

**Purpose.** Run the render-step's pre-render checks without writing a
workspace. Used in CI on every stack-source PR and by package managers
before committing a `stack.yaml` change.

**Audience.** Package manager, CI.

**Inputs.**

- `--profile <path>` — required.
- `--stack <path>` — required.
- `--templates <dir>` — required.
- `--package-sets <dir>` — optional; defaults to `package-sets/` relative to stack.
- `--package-repos <dir>` — optional; defaults to `package-repos/` relative to stack.
- `--report <path>` — optional YAML report; defaults to stdout summary.

**Outputs.** A pass/fail summary on stdout (or stderr) plus optional
YAML report. Exit code 0 on pass, non-zero on any fail.

**Algorithm sketch.**

```text
function validate(profile_path, stack_path, templates_dir,
                  package_sets_dir, package_repos_dir, report_path):
    issues = []

    profile = load_yaml(profile_path)
    issues += validate_schema(profile, "profile.v1")
    raw_stack = load_yaml(stack_path)
    issues += validate_schema(raw_stack, "stack.v1")

    template_set = templates_dir / raw_stack.templates.set
    defaults = load_yaml(template_set / "stack-defaults.yaml")
    issues += validate_schema(defaults, "stack_defaults.v1")
    contract = load_yaml(template_set / "contract.yaml")
    issues += validate_schema(contract, "template_contract.v1")

    stack = merge_defaults(defaults, raw_stack)
    issues += cross_check_profile_contract(profile, stack)
    issues += validate_builds_against_contract(stack, contract)
    issues += validate_package_sets(stack, package_sets_dir, contract)
    issues += validate_package_repositories(stack, defaults, package_repos_dir)
    issues += validate_per_system_narrowing(stack, profile, contract)

    write_report(report_path, issues)
    return 0 if not issues.has_errors() else 1
```

Every check is one the renderer would have run before writing the
workspace. `validate` is the renderer with the writes removed.

**Invariants.**

- Read-only. Never writes inside the stack source. The only file write is
  the optional `--report`.
- The validation checks are *the same* checks the renderer applies; a
  pass here guarantees the renderer's pre-render validation will pass.
- Includes the `per_system` validation: every name in the matching
  `per_system.<system>` block must resolve in the profile or contract.

**Example.**

```bash
spack-composer validate \
  --profile systems/example-cray/profile.yaml \
  --stack stacks/cse/stack.yaml \
  --templates templates \
  --report reports/validate-cse-cray.yaml
```

### `spack-composer publish-manifest`

**Purpose.** Rewrite a draft `release-manifest.yaml` to `phase: final`
after build, verification, and buildcache push. Captures build-context
fields the renderer could not know.

**Audience.** CI, package manager.

**Inputs.**

- `--workspace <dir>` — the rendered workspace whose manifest is being
  finalized. Required.
- `--build-host <hostname>` — required.
- `--lockfiles <dir>` — directory of `spack.lock` files per lane; required.
  The lockfile path layout matches `environments/<compiler>/<lane>/spack.lock`.
- `--platform-module-prereqs <file>` — YAML listing platform-module
  prerequisites per lane (the modules the package modules' `prereq` lines
  will name). Required for stacks that declare site-external lanes.
- `--buildcache-destinations <file>` — YAML listing mirrors the build was
  actually pushed to. Required when `stack.yaml.buildcache.policy` requires push.
- `--verify-results <file>` — YAML with smoke, ldd, manifest-verify
  results per lane. Required.
- `--force` — optional; rewrite a manifest already in `phase: final`.

**Outputs.** Rewrites `<workspace>/release-manifest.yaml` in place,
atomic-replace. Setting `phase: final`. Returns the workspace path.

**Algorithm sketch.**

```text
function publish_manifest(workspace, build_host, lockfiles_dir,
                          platform_module_prereqs_path,
                          buildcache_destinations_path,
                          verify_results_path, force):
    manifest_path = workspace / "release-manifest.yaml"
    manifest = load_yaml(manifest_path)
    if manifest.phase == "final" and not force:
        fail("manifest is already final; use --force to overwrite")
    require(manifest.phase == "draft" or force,
            "expected phase: draft, got " + manifest.phase)

    manifest.build_context = {
        "build_host":   build_host,
        "built_at":     now_from_release_var_or_caller(),
        "spack_version": detect_spack_version(),
        "renderer":     manifest.templates.render_tool,
    }

    for lane_entry in manifest.lanes:
        lock_path = lockfiles_dir / lane_entry.compiler / lane_entry.lane / "spack.lock"
        lockfile  = load_yaml(lock_path)
        lane_entry.lockfile = {
            "digest":   sha256_of_file(lock_path),
            "spec_count": len(lockfile.concretized_specs),
        }
        lane_entry.installs = summarize_installs(lockfile)
        lane_entry.provenance_summary = derive_provenance(lockfile,
                                                          manifest.profile,
                                                          manifest.contract)

    manifest.platform_module_prereqs = load_yaml(platform_module_prereqs_path)
    manifest.buildcache.actual_destinations = load_yaml(buildcache_destinations_path)
    manifest.verification = load_yaml(verify_results_path)

    manifest.phase = "final"
    atomic_write_yaml(manifest_path, manifest)
    return workspace
```

**Invariants.**

- Idempotent (modulo `--force`): a final manifest is not rewritten without
  the operator opting in.
- The renderer-derived fields (`source-derived`, `templates`,
  `applied_narrowing`, `skipped_builds`, `lanes[*].skeleton`) are *not*
  modified by this command. Only fields explicitly marked "build-context"
  in the manifest schema are added.
- The provenance summary per lane (`Stack-built / Platform-backed /
  Site-external / Spack-built` counts) is derived here from the lockfile
  plus contract; the renderer must not pre-label provenance.
- Atomic write: the manifest is fully written to a side path and renamed.
- The `built_at` timestamp comes from a release variable (the caller's
  intent) or the caller's clock; never from `spack-composer`'s own clock
  without the caller asking for it. Reruns of `publish-manifest` with
  the same inputs are not expected to be byte-identical (timestamps and
  build host are observed at finalize time), but the rest of the manifest
  is.

**Example.**

```bash
spack-composer publish-manifest \
  --workspace /shared/stack/work/example-cray/cse/2026.06 \
  --build-host cray01 \
  --lockfiles /shared/stack/work/example-cray/cse/2026.06/environments \
  --platform-module-prereqs reports/prereqs.yaml \
  --buildcache-destinations reports/buildcache-push.yaml \
  --verify-results reports/verify.yaml
```

## Companion Script: `spack-build`

`spack-build` is a standalone shell script shipped in the `spack-composer`
package and installed onto `$PATH` by the wheel. It is the supported way to
drive Spack from a rendered workspace for sites that do not run Ansible,
for laptop-side testing, and for CI smoke runs. Ansible may either call
`spack-build` per host or replicate its logic; either is fine.

### Why a shell script, not a Python subcommand

The build half is a sequence of `spack` invocations plus a few `ldd` and
`spack verify` calls. Re-implementing that in Python adds layers without
value, and sites *will* customize parallelism, partition selection, and
retries on flaky fabric. A short bash script is easier to fork than a Python
subcommand, and it keeps `spack-composer`'s Python tool focused on YAML
transforms (render, validate, publish-manifest). The split mirrors the
render/build separation: `spack-composer` knows nothing about Spack
invocation; `spack-build` knows nothing about template rendering.

### Inputs

| Argument | Purpose |
|---|---|
| `--workspace <dir>` | Required. The rendered workspace produced by `spack-composer render`. |
| `--spack-root <dir>` | Optional. Path to a Spack checkout to source. If omitted, `spack` must already be on `$PATH`. |
| `--lanes <glob>` | Optional. Lane filter, e.g. `gcc/*` or `gcc/mpi-craympich`. Defaults to all lanes in the workspace. |
| `--reports <dir>` | Optional. Where to write per-lane reports and the manifest-feed YAML files. Defaults to `<workspace>/reports/`. |
| `--jobs <n>` | Optional. `spack install -j <n>` parallelism. Defaults to half the host's CPU count. |
| `--skip-push` | Optional. Skip the buildcache push step (useful for laptop test runs). |
| `--fail-fast` | Optional. Exit on the first lane failure instead of continuing through all lanes. Default is continue-and-report. |

### Per-lane flow

For each lane the script does, in order:

1. `spack -e <env> concretize --force` → writes `spack.lock`.
2. `spack -e <env> install -j <n>` → installs every spec in the lock.
3. Smoke test: for each entry in `stack.yaml.smoke[*]` (when present in
   the rendered workspace's effective stack), `spack -e <env> load <spec>
   && <smoke_command>`.
4. `ldd` walk over installed binaries — drift detector, not a deploy gate.
5. `spack -e <env> verify --files` — cross-check installed files against
   the manifest.
6. `spack -e <env> buildcache push <mirror>` per buildcache mirror declared
   in the workspace's `configs/common/mirrors.yaml` (skipped under
   `--skip-push`).

Each step's stdout/stderr is captured to `<reports>/<lane>/<step>.log`. A
per-lane `result.yaml` records pass/fail and timings.

### Output artifacts

The script writes three roll-up files under `<reports>/` whose shapes
match what `spack-composer publish-manifest` consumes:

| File | Format | Used by |
|---|---|---|
| `verify-results.yaml` | per-lane pass/fail for concretize, install, smoke, ldd, manifest-verify | `publish-manifest --verify-results` |
| `buildcache-destinations.yaml` | per-lane list of mirrors actually pushed to | `publish-manifest --buildcache-destinations` |
| `platform-module-prereqs.yaml` | per-lane platform-module list, copied verbatim from each lane's `spack.yaml` `include::` resolution | `publish-manifest --platform-module-prereqs` |

The intent is that a caller can run `spack-build --workspace <ws>` and
then `spack-composer publish-manifest --workspace <ws> --build-host
$(hostname) --lockfiles <ws>/environments --verify-results
<ws>/reports/verify-results.yaml ...` without staging files by hand.

### Failure handling

- Default (no `--fail-fast`): run every lane, record per-lane failures,
  exit non-zero if any lane failed. The per-lane logs let the operator
  re-run individual lanes after fixing the cause.
- `--fail-fast`: exit on the first lane failure. Useful for CI on a
  small smoke stack where the first failure should kill the job.
- A lane failure does not stop later lanes from running unless
  `--fail-fast` is set; failed lanes are simply absent from the
  buildcache push step.

### Determinism

`spack-build` is **not** byte-deterministic on re-runs (timestamps, build
host, parallelism effects on log interleaving). Determinism is the
renderer's contract; the build half is observably non-deterministic by
nature. What it *is*: idempotent on success. Re-running on an already-built
workspace re-uses Spack's installed prefixes and skips work.

### Distribution

- Shipped in the `spack-composer` Python package under
  `src/spack_composer/scripts/spack-build`.
- Installed onto `$PATH` by declaring it under
  `[project.scripts]` *or* `data_files` in `pyproject.toml` (decision
  deferred to Phase 1; both work).
- The script's only runtime dependencies are `bash`, `spack`, and standard
  POSIX utilities (`awk`, `sed`, `find`, `ldd`). No Python is required at
  build time.
- The script is read-only on the rendered workspace except for
  `<workspace>/spack.lock` per lane (created by concretize),
  `<workspace>/.spack-env/` per lane (created by Spack), and the
  `<reports>/` tree it writes to.

### What `spack-build` does NOT do

- It does not render. The workspace is an input.
- It does not finalize the manifest. `spack-composer publish-manifest` is
  the next step.
- It does not promote the release (swap `current` symlink, copy to a
  release tree). That is Ansible's job, or a human's `rsync` + `ln -sfn`.
- It does not orchestrate across hosts. One invocation runs on one
  build host. Ansible (or a human) loops across hosts.

## Repository Shape

Recommended layout for the new `spack-composer/` repo:

```text
spack-composer/
  pyproject.toml
  README.md
  src/
    spack_composer/
      __init__.py
      __main__.py
      cli.py                          # argument parser, dispatch
      commands/
        assess_profiles.py
        scaffold_templates.py
        validate_template_set.py
        explain.py
        render.py
        validate.py
        publish_manifest.py
      model/
        profile.py                    # pydantic models for profile.v1
        stack.py                      # stack.v1, stack_defaults.v1
        contract.py                   # template_contract.v1
        package_set.py
        manifest.py                   # release-manifest schema
      render/
        engine.py                     # the render() function from v6
        context.py                    # build_render_context
        scopes.py                     # required_scopes, render_template_tree
        environments.py               # lane env rendering
        narrowing.py                  # per_system narrowing logic
      resolve/
        build_class.py                # resolve_build_request
        toolchain.py                  # toolchain_for_lane
        node_selector.py
        contract_resolver.py          # validate_builds_against_contract
      scaffold/
        facts.py                      # summarize_profile_facts
        scope_emitter.py
        contract_emitter.py
        env_emitter.py
        starters/                     # bundled seed template sets
          library/
          application/
      validate/
        checks.py                     # cross_check_profile_contract, etc.
        report.py
      manifest/
        draft.py                      # renderer side
        finalize.py                   # publish_manifest side
        provenance.py
      schemas/
        profile-v1.json
        stack-v1.json
        stack-defaults-v1.json
        template-contract-v1.json
        package-set-v1.json
        release-manifest-v1.json
      resources/
        # bundled non-schema resources loaded via importlib.resources
        renderer_identity.toml        # name + version emitted into manifest
      scripts/
        spack-build                   # companion shell script; installed onto $PATH
  tests/
    fixtures/
      profiles/
        example-cray/
        example-linux/
      template-sets/
        v6/
        app-direct-v1/
      stacks/
        cse/
        fun3d/
  docs/
    cli.md
    development.md
```

The Python package is `spack_composer`, the CLI entry point is
`spack-composer`. Resource files (schemas, starters) are loaded with
`importlib.resources`, so the installed package does not need to locate
files relative to a source checkout.

## Packaging Plan

- `pip install spack-composer` from an internal package index, or
  `pip install spack_composer-*.whl` from a release artifact.
- Python ≥ 3.10. Pinned dependency set in `pyproject.toml`.
- Console-script entry point declared in `pyproject.toml`:
  ```toml
  [project.scripts]
  spack-composer = "spack_composer.cli:main"
  ```
- The `spack-build` shell script is shipped as part of the same wheel and
  installed onto `$PATH` (decision deferred between `[project.scripts]`
  shim and `data_files` placement until Phase 1; both work).
- Release artifacts:
  - Source distribution (`.tar.gz`).
  - Built wheel (`.whl`).
  - Both signed if the deployment environment requires provenance.
- Dependencies (minimum viable):
  - `pydantic >= 2`
  - `jinja2`
  - `ruamel.yaml` (preserves key ordering and round-trips comments where
    we want them — used for manifest in-place rewrite)
  - `jsonschema` (for the JSON Schema files alongside pydantic models)
  - `click` *or* `argparse` (CLI; choose one in Phase 1)
- No Spack dependency: `spack-composer` neither imports Spack nor depends
  on a Spack install. The optional `validate-template-set --concretize`
  shells out to `spack` if found on `PATH`; otherwise it skips the
  concretization step.
- No network access at runtime.

## Implementation Plan

### Phase 1 — Skeleton + Render Seam

- Create the `spack-composer/` repo with the layout above.
- Implement `cli.py` with all seven subcommand stubs returning "not yet
  implemented" except `render`.
- Implement the schema models (profile, stack, stack-defaults, contract,
  package-set, manifest) as pydantic v2 classes generated from / aligned
  with the JSON schemas under `schemas/`.
- Implement `render` against the v6 pseudo-code, using the deterministic
  YAML dumper and Jinja2 environment described above.
- Implement `validate` as a re-use of the render pre-checks without
  the writes.

Acceptance:

- `spack-composer render` produces a byte-identical workspace for a fixed
  fixture set on two successive runs.
- `spack-composer validate` produces a report for the same inputs and
  catches every render-time validation failure listed in v6's render
  invariant table.
- The installed wheel runs without the source checkout.

### Phase 2 — Maintainer Commands

- Implement `assess-profiles`: dry-resolve every (profile, template-set)
  pair, emit coverage report.
- Implement `explain`: filter contract vocabulary by profile-resolvable
  candidates.
- Implement `validate-template-set` (render-only mode). Add the
  `--concretize` flag last; treat Spack as optional.

Acceptance:

- `assess-profiles` correctly reports coverage for the fixture corpus
  including at least one profile with a deliberate gap (missing GPU
  toolkit, missing site MPI).
- `explain` agrees with what `render` would actually accept; there is a
  test that fuzzes `stack.yaml` against `explain`'s output and asserts
  render success/failure matches.
- `validate-template-set` exits non-zero when one profile fails to render
  against the template set and the failure is recorded in the summary.

### Phase 3 — Scaffold And Publish

- Implement `scaffold-templates` with the `library` and `application`
  starters bundled in `scaffold/starters/`.
- Implement `publish-manifest` against the v6 manifest schema, including
  provenance derivation from lockfiles.
- Implement the `spack-build` companion script and wire its output
  artifact shapes to `publish-manifest`'s input flags.

Acceptance:

- `scaffold-templates` produces a draft template set that, after the
  TODO comments are filled in, passes `validate-template-set` against
  the originating profile.
- `publish-manifest` rewrites a draft manifest to final and the result
  validates against `release-manifest-v1.json`.
- Re-running `publish-manifest` without `--force` on a final manifest
  exits non-zero with a clear message.
- `spack-build --workspace <rendered>` builds every lane of the
  smoke-stack fixture, emits `verify-results.yaml`,
  `buildcache-destinations.yaml`, and `platform-module-prereqs.yaml`,
  and those three files satisfy `publish-manifest`'s schema without
  hand editing.

### Phase 4 — `cse-stack` Acceptance

- Point `spack-composer` at the real `cse-stack` content. Render every
  documented stack against every documented profile.
- Use the resulting fixtures to drive `validate-template-set` in CI.
- Identify patterns in `cse-stack` that did not fit cleanly into the
  generic model and decide per-pattern: promote to templates, keep in
  `cse-stack`, or discard.

Acceptance:

- `cse-stack`'s end-to-end Cray flow (v6 § Example Cray Flow) reproduces
  through `spack-composer` without out-of-tree patches.
- `cse-stack`'s end-to-end Generic Linux HPC flow (v6 § Example Generic
  Linux HPC Flow) reproduces through `spack-composer` without
  out-of-tree patches.
- At least one `cse-stack` pattern is identified for promotion and at
  least one is identified for discard, with the decisions captured in
  follow-on commits to `templates/v6/` or to this design doc's Open
  Questions.

## Acceptance Criteria For v1

- All seven `spack-composer` commands implemented end-to-end, plus the
  `spack-build` companion script.
- `render` byte-deterministic for fixed inputs.
- `validate` agrees with `render`'s pre-flight check set: anything
  `render` would reject before writing, `validate` reports.
- `publish-manifest` rewrites the draft manifest to final and the
  result validates against the manifest schema.
- `assess-profiles` and `explain` filter strictly by profile-resolvable
  candidates; no candidate the renderer would reject ever appears in a
  positive menu.
- `scaffold-templates` proposes a template set that passes
  `validate-template-set` after the operator fills the TODOs.
- `validate-template-set` runs in CI on the fixture corpus on every PR.
- `spack-composer` runs from the installed wheel without the source
  checkout.
- `cse-stack`'s Cray and Generic Linux HPC end-to-end flows reproduce
  through `spack-composer`.

## Open Questions

- **Stable schema versions.** Each schema (profile, stack, contract,
  manifest, package-set) carries a `schema_version`. The bump policy is
  not specified yet — does a Phase 2 schema change require a tool major
  bump? Probably yes for breaking changes; defer to the first real bump.
- **CLI library.** `click` vs `argparse`. `click` is more ergonomic for
  multi-command tools; `argparse` is zero-dependency. Pick in Phase 1
  and capture the choice in `pyproject.toml`.
- **Provenance derivation details.** `publish-manifest` derives the
  four-class provenance per spec from lockfile + profile + contract. The
  rules for "is this spec a Platform-backed external or a Site-external
  external?" are stated structurally in v6 but not as code-ready
  predicates. Resolve in Phase 3 when implementing the manifest
  finalize step.
- **Optional concretization in `validate-template-set`.** Should the
  concretize step take a Spack version pin so CI is reproducible across
  Spack upgrades? Likely yes; add `--spack-version` (advisory: refuses
  to run if `spack --version` does not match) in a Phase 2 follow-up.
- **Starter template sets.** The bundled `library` and `application`
  starters need to be designed. Phase 3 should resolve whether they are
  copies of `cse-stack`'s `templates/v6` and `templates/app-direct-v1`
  or simpler skeletons.
- **CI integration shape.** What does the recommended CI configuration
  look like for a stack repo that uses `spack-composer`? Out of scope
  for v1; document in a follow-on after the maintainer commands are
  real.
