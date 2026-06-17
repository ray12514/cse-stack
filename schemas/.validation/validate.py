"""Round-trip validation harness for every schema under schemas/.

For each schema, runs:
  1. Self-validity check (Draft 2020-12).
  2. One or more positive YAML examples that should validate with zero errors.
  3. A list of deliberately broken mutations that should each fail with a
     specific, locatable error.

Usage (from repo root):
    .schema-venv/bin/python schemas/.validation/validate.py
"""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path
from typing import Any, Callable, Iterable

import yaml
from jsonschema import Draft202012Validator

HERE = Path(__file__).resolve().parent
SCHEMAS_DIR = HERE.parent


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def load_yaml(path: Path) -> Any:
    with path.open() as f:
        return yaml.safe_load(f)


def load_json(path: Path) -> Any:
    with path.open() as f:
        return json.load(f)


class _Missing:  # singleton
    def __repr__(self) -> str:  # pragma: no cover
        return "_MISSING"


_MISSING = _Missing()


def with_mutation(base: Any, path: Iterable[Any], value: Any) -> Any:
    """Return a deep copy of *base* with the nested *path* set to *value*.

    Path elements may be dict keys (strings) or list indexes (ints). If
    *value* is the _MISSING sentinel, delete the leaf key (for dicts) or
    omit it from the list (for lists).
    """
    copy_ = copy.deepcopy(base)
    cursor: Any = copy_
    keys = list(path)
    for key in keys[:-1]:
        cursor = cursor[key]
    leaf = keys[-1]
    if value is _MISSING:
        if isinstance(cursor, list):
            del cursor[leaf]
        else:
            del cursor[leaf]
    else:
        cursor[leaf] = value
    return copy_


# ─────────────────────────────────────────────────────────────────────────────
# Per-schema negative cases (each is a callable that returns case tuples)
# ─────────────────────────────────────────────────────────────────────────────

def profile_negatives(base: dict) -> list[tuple[str, dict, str]]:
    return [
        (
            "missing required schema_version",
            with_mutation(base, ["schema_version"], _MISSING),
            "<root>",
        ),
        (
            "wrong schema_version value",
            with_mutation(base, ["schema_version"], 2),
            "schema_version",
        ),
        (
            "wrong os.name type (integer)",
            with_mutation(base, ["os", "name"], 42),
            "os/name",
        ),
        (
            "wrong glibc shape (not a version string)",
            with_mutation(base, ["os", "glibc"], "two-point-twenty-eight"),
            "os/glibc",
        ),
        (
            "wrong fabric.type enum",
            with_mutation(base, ["fabric", "type"], "smoke-signals"),
            "fabric/type",
        ),
        (
            "wrong modules_system.tool enum",
            with_mutation(base, ["modules_system", "tool"], "envmod"),
            "modules_system/tool",
        ),
        (
            "node_type role missing",
            with_mutation(base, ["node_types", "login", "role"], _MISSING),
            "node_types/login",
        ),
        (
            "gpu block missing required arch_target",
            with_mutation(
                base,
                ["node_types", "gpu_compute_mi250x", "gpu"],
                {
                    "vendor": "amd",
                    "driver_version": "6.0",
                    "toolkit_ceiling": "6.0.0",
                },
            ),
            "node_types/gpu_compute_mi250x/gpu",
        ),
        (
            "extra top-level key",
            with_mutation(base, ["unexpected_field"], "uh oh"),
            "<root>",
        ),
    ]


def package_set_negatives(base: dict) -> list[tuple[str, dict, str]]:
    return [
        (
            "missing required name",
            with_mutation(base, ["name"], _MISSING),
            "<root>",
        ),
        (
            "wrong tier enum",
            with_mutation(base, ["tier"], "preview"),
            "tier",
        ),
        (
            "missing required description",
            with_mutation(base, ["description"], _MISSING),
            "<root>",
        ),
        (
            "empty kinds list",
            with_mutation(base, ["kinds"], []),
            "kinds",
        ),
        (
            "spec value not a string",
            with_mutation(base, ["specs", "any"], [42]),
            "specs/any/0",
        ),
        (
            "extra top-level key",
            with_mutation(base, ["unexpected_field"], "uh oh"),
            "<root>",
        ),
        (
            "provenance_hints value outside enum",
            with_mutation(base, ["provenance_hints", "cray-mpich"], "Mystery-tier"),
            "provenance_hints/cray-mpich",
        ),
    ]


def stack_defaults_negatives(base: dict) -> list[tuple[str, dict, str]]:
    return [
        (
            "missing required schema_version",
            with_mutation(base, ["schema_version"], _MISSING),
            "<root>",
        ),
        (
            "missing required spack block",
            with_mutation(base, ["spack"], _MISSING),
            "<root>",
        ),
        (
            "missing required spack.floor",
            with_mutation(base, ["spack"], {}),
            "spack",
        ),
        (
            "forbidden name key present",
            with_mutation(base, ["name"], "should-not-be-here"),
            "<root>",
        ),
        (
            "forbidden templates.set inside templates block",
            with_mutation(base, ["templates"], {"set": "v6"}),
            "templates",
        ),
        (
            "externals.compilers outside enum",
            with_mutation(base, ["externals", "compilers"], "yolo"),
            "externals/compilers",
        ),
        (
            "extra top-level key",
            with_mutation(base, ["unexpected_field"], "uh oh"),
            "<root>",
        ),
    ]


def stack_negatives(base: dict) -> list[tuple[str, dict, str]]:
    return [
        (
            "missing required templates block",
            with_mutation(base, ["templates"], _MISSING),
            "<root>",
        ),
        (
            "missing templates.set",
            with_mutation(base, ["templates"], {}),
            "templates",
        ),
        (
            "build with both specs and package_set",
            with_mutation(
                base,
                ["builds", 0, "specs"],
                ["hdf5@1.14.5"],
            ),
            "builds/0",
        ),
        (
            "build with neither specs nor package_set",
            with_mutation(
                base,
                ["builds", 0],
                {
                    "name": "broken",
                    "class": "core",
                    "toolchain": "cse-core",
                    "nodes": "cpu",
                    "expand": "one",
                },
            ),
            "builds/0",
        ),
        (
            "unknown release.promotion enum",
            with_mutation(base, ["release", "promotion"], "yolo"),
            "release/promotion",
        ),
        (
            "spack.version is not a string",
            with_mutation(base, ["spack", "version"], 12345),
            "spack/version",
        ),
        (
            "per_system narrowing array is empty",
            with_mutation(
                base,
                ["per_system", "example-cray", "builds", "mpi", "compilers"],
                [],
            ),
            "per_system/example-cray/builds/mpi/compilers",
        ),
        (
            "extra top-level key",
            with_mutation(base, ["unexpected_field"], "uh oh"),
            "<root>",
        ),
    ]


def template_contract_negatives(base: dict) -> list[tuple[str, dict, str]]:
    return [
        (
            "missing build_classes",
            with_mutation(base, ["build_classes"], _MISSING),
            "<root>",
        ),
        (
            "empty build_classes object",
            with_mutation(base, ["build_classes"], {}),
            "build_classes",
        ),
        (
            "toolchain missing compiler",
            with_mutation(
                base,
                ["toolchains", "cse-core"],
                {"mpi": "none", "gpu_toolkit": "none"},
            ),
            "toolchains/cse-core",
        ),
        (
            "gpu_selector with wrong vendor enum",
            with_mutation(base, ["gpu_selectors", "mi250x", "vendor"], "intel"),
            "gpu_selectors/mi250x/vendor",
        ),
        (
            "node_selector missing match",
            with_mutation(base, ["node_selectors", "cpu"], {}),
            "node_selectors/cpu",
        ),
        (
            "target_policy resolve is not a string",
            with_mutation(base, ["target_policies", "foundation", "resolve"], None),
            "target_policies/foundation/resolve",
        ),
        (
            "extra top-level key",
            with_mutation(base, ["unexpected_field"], "uh oh"),
            "<root>",
        ),
    ]


def release_manifest_negatives(base_final: dict) -> list[tuple[str, dict, str]]:
    return [
        (
            "phase outside enum",
            with_mutation(base_final, ["phase"], "tentative"),
            "phase",
        ),
        (
            "final manifest missing spack block",
            with_mutation(base_final, ["spack"], None),
            "<root>",
        ),
        (
            "skipped_builds reason_code outside enum",
            with_mutation(
                base_final,
                ["skipped_builds"],
                [
                    {
                        "build": "gpu",
                        "reason_code": "vibes_were_off",
                        "reason": "unspecified",
                    }
                ],
            ),
            "skipped_builds/0/reason_code",
        ),
        (
            "digest with wrong prefix",
            with_mutation(
                base_final,
                ["profile", "digest"],
                "md5:b13c2e0000000000000000000000000000",
            ),
            "profile/digest",
        ),
        (
            "applied_narrowing block missing system",
            with_mutation(
                base_final,
                ["templates", "applied_narrowing"],
                {
                    "builds": {
                        "gpu": {
                            "dropped_lanes": ["x"],
                            "narrowed_by": {
                                "gpu_arch": {"kept": ["a"], "dropped": ["b"]}
                            },
                        }
                    }
                },
            ),
            "templates/applied_narrowing",
        ),
        (
            "negative integer in provenance_summary",
            with_mutation(
                base_final,
                ["lanes", 0, "provenance_summary", "stack_built"],
                -1,
            ),
            "lanes/0/provenance_summary",
        ),
        (
            "final manifest lane missing publish-required lockfile_digest",
            with_mutation(base_final, ["lanes", 0, "lockfile_digest"], None),
            "lanes/0",
        ),
    ]


# ─────────────────────────────────────────────────────────────────────────────
# Schema-to-data registry
# ─────────────────────────────────────────────────────────────────────────────

NegFactory = Callable[[Any], list[tuple[str, Any, str]]]


SCHEMAS: list[tuple[str, list[str], str, NegFactory]] = [
    # (schema filename, [positive example filenames], filename whose loaded YAML feeds the negatives, factory)
    ("profile-v1.json",          ["example-cray.yaml", "example-linux.yaml"],          "example-cray.yaml",                     profile_negatives),
    ("package-set-v1.json",      ["example-package-set.yaml"],                          "example-package-set.yaml",              package_set_negatives),
    ("stack-defaults-v1.json",   ["example-stack-defaults.yaml"],                       "example-stack-defaults.yaml",           stack_defaults_negatives),
    ("stack-v1.json",            ["example-stack-cse.yaml"],                            "example-stack-cse.yaml",                stack_negatives),
    ("template-contract-v1.json",["example-template-contract-v6.yaml"],                 "example-template-contract-v6.yaml",     template_contract_negatives),
    ("release-manifest-v1.json", ["example-release-manifest-draft.yaml", "example-release-manifest-final.yaml"],
                                                                                        "example-release-manifest-final.yaml",   release_manifest_negatives),
]


# ─────────────────────────────────────────────────────────────────────────────
# Drivers
# ─────────────────────────────────────────────────────────────────────────────

def check_schema_self_valid(schema: dict) -> bool:
    try:
        Draft202012Validator.check_schema(schema)
        return True
    except Exception as e:
        print(f"FAIL  schema self-validity check: {e}")
        return False


def check_positive(schema: dict, path: Path) -> bool:
    instance = load_yaml(path)
    validator = Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(instance), key=lambda e: tuple(e.absolute_path))
    if errors:
        print(f"FAIL  {path.name} produced {len(errors)} error(s):")
        for e in errors:
            loc = "/".join(str(p) for p in e.absolute_path) or "<root>"
            print(f"        {loc}: {e.message}")
        return False
    print(f"PASS  {path.name} validates")
    return True


def check_negative_cases(schema: dict, cases: list[tuple[str, Any, str]]) -> bool:
    validator = Draft202012Validator(schema)
    all_ok = True
    for label, instance, expected_locus in cases:
        errors = list(validator.iter_errors(instance))
        if not errors:
            print(f"FAIL  expected error for case: {label}")
            all_ok = False
            continue
        first = errors[0]
        loc = "/".join(str(p) for p in first.absolute_path) or "<root>"
        if expected_locus != "<root>" and expected_locus not in loc:
            print(f"WARN  {label} → error at {loc} (expected to mention {expected_locus}): {first.message.splitlines()[0]}")
        else:
            print(f"PASS  rejected: {label}  →  {loc}: {first.message.splitlines()[0]}")
    return all_ok


def main() -> int:
    overall_ok = True

    for schema_name, positives, neg_source, neg_factory in SCHEMAS:
        print()
        print(f"── {schema_name} ──")

        schema_path = SCHEMAS_DIR / schema_name
        schema = load_json(schema_path)

        if not check_schema_self_valid(schema):
            overall_ok = False
            continue
        print("PASS  schema is self-valid (Draft 2020-12)")

        for pos in positives:
            if not check_positive(schema, HERE / pos):
                overall_ok = False

        print(f"Negative cases for {schema_name}:")
        base = load_yaml(HERE / neg_source)
        cases = neg_factory(base)
        if not check_negative_cases(schema, cases):
            overall_ok = False

    print()
    if overall_ok:
        print("ALL CHECKS PASSED")
        return 0
    print("SOME CHECKS FAILED")
    return 1


if __name__ == "__main__":
    sys.exit(main())
