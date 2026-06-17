# Canonical schemas

This directory holds the **canonical JSON Schema** files for the data
contracts described in the v6 design notes. The design docs are
authoritative for the prose and rationale; the schemas in this directory
are the machine-readable form a tool can `load` and `validate` against.

If the docs and a schema disagree, that is a bug — open an issue. The
intended workflow is: change the doc first, then regenerate or hand-edit
the matching schema; never the other way around.

## Files

| Schema | Source design section | Status |
|---|---|---|
| `profile-v1.json` | `docs/spack_stack_generation_design_v6.md` § `profile.yaml` (line 448) | **landed** |
| `stack-v1.json` | `docs/spack_stack_generation_design_v6.md` § `stack.yaml` (line 672) | TBD — follow-up plan |
| `stack-defaults-v1.json` | `docs/spack_stack_generation_design_v6.md` § Stack Defaults Merge Rules (line 1255+) | TBD |
| `template-contract-v1.json` | `docs/spack_stack_generation_design_v6.md` § Template Contract Files (line 1045) | TBD |
| `package-set-v1.json` | `docs/spack_stack_generation_design_v6.md` § Package Sets (line 1490) | TBD |
| `release-manifest-v1.json` | `docs/spack_stack_generation_design_v6.md` § Release Manifest Schema (line 5088) | TBD |

`profile-v1.json` landed as the prototype to validate the conversion
approach. The other five follow the same conventions and ship in a
follow-up plan.

## Conventions

| Aspect | Decision |
|---|---|
| JSON Schema draft | **2020-12**. `$schema: "https://json-schema.org/draft/2020-12/schema"`. |
| `$id` | Placeholder URL: `https://spack-composer.example/schemas/<name>.json`. Not served; serves as a stable identifier and rewrites cleanly when the project picks a real domain. |
| Strictness | **Strict**. Every object that lists explicit properties sets `additionalProperties: false`. The schema is a contract: unknown keys are bugs, not extensions. |
| Required | Every key the design doc marks `# R` appears in the parent's `required` array. |
| Optional with default | Keys marked `# O - default <x>` carry `default: <x>` and stay absent from `required`. |
| Enums | Where the design lists a closed vocabulary inline (e.g., `slingshot \| infiniband \| roce \| omnipath \| ethernet` with no `...`), the schema uses `enum`. Where the design ends the vocabulary with `...`, the schema uses `string` with a description noting the open vocabulary. |
| Patterns | Used sparingly for shape-checked strings (glibc version, absolute paths). Conservative — over-constraint blocks valid inputs. |
| `$defs` | Used for repeated sub-objects within one schema (e.g., `compiler_external`, `node_type`). Not currently used cross-schema; revisit only when a real reuse case appears. |
| `$ref` cross-document | Not used in v1. Each schema is a standalone document so tools can load one file at a time. |
| Formatting | Pretty-printed JSON, 2-space indent, trailing newline. Key order optimised for review: `$schema`, `$id`, `title`, `description`, `type`, `properties`, `required`, `additionalProperties`, `$defs`. |
| Versioning | Schema bumps live as new files (`profile-v2.json`) alongside the old. Never edited in place once published. The actual bump policy will be written when the first real bump happens. |

## How tools consume them

A tool that needs to validate a profile loads `profile-v1.json` and runs
a 2020-12 validator (e.g., Python `jsonschema.Draft202012Validator`,
Go `santhosh-tekuri/jsonschema`). Tools must **not** embed copies of
the schema — they load from this directory (during development) or
from the equivalent path their package ships (after install). Embedded
copies are how schema drift starts.

For Python tools, `pydantic` models can be derived from these schemas
mechanically. The recommended pattern is `datamodel-code-generator
--input <schema>.json --output <module>.py --output-model-type
pydantic_v2.BaseModel`, then check the generated file in and edit
afterwards if needed. The schema remains canonical.

## Validation harness

`schemas/.validation/` (note: leading dot, intentionally hidden from
casual `ls`) holds the round-trip validator used to develop and
sanity-check the schemas. It is **not** a runtime contract — it is
developer-only infrastructure.

- `example-cray.yaml`, `example-linux.yaml` — canonical positive
  examples mirroring the design-doc walkthroughs.
- `validate.py` — runs Draft 2020-12 self-validity, validates both
  positive examples, and runs a series of deliberately broken
  mutations expected to fail with specific error locations.

Run from the repo root with the development venv:

```bash
.schema-venv/bin/python schemas/.validation/validate.py
```

The expected output ends with `ALL CHECKS PASSED`. Treat any other
result as a regression — either the schema drifted from the docs or
the harness needs updating to match a deliberate change.

The `.schema-venv/` directory is a local Python virtualenv created with
`python3 -m venv .schema-venv && .schema-venv/bin/pip install jsonschema
pyyaml`. It is not committed and not required at runtime — only for
running the validator harness during development.
