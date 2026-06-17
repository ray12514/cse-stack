"""Round-trip validation harness for profile-v1.json.

Runs four checks:
  1. Schema is self-valid (Draft 2020-12).
  2. example-cray.yaml validates with zero errors.
  3. example-linux.yaml validates with zero errors.
  4. A set of deliberately broken snippets each fail with a clear, specific error.

Usage (from repo root):
    .schema-venv/bin/python schemas/.validation/validate.py
"""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path
from typing import Any, Iterable

import yaml
from jsonschema import Draft202012Validator

HERE = Path(__file__).resolve().parent
SCHEMA_PATH = HERE.parent / "profile-v1.json"


def load_yaml(path: Path) -> Any:
    with path.open() as f:
        return yaml.safe_load(f)


def load_schema() -> dict[str, Any]:
    with SCHEMA_PATH.open() as f:
        return json.load(f)


def check_schema(schema: dict[str, Any]) -> None:
    Draft202012Validator.check_schema(schema)
    print("PASS  schema is self-valid (Draft 2020-12)")


def check_positive(schema: dict[str, Any], path: Path) -> None:
    instance = load_yaml(path)
    validator = Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(instance), key=lambda e: e.path)
    if errors:
        print(f"FAIL  {path.name} produced {len(errors)} error(s):")
        for e in errors:
            loc = "/".join(str(p) for p in e.absolute_path) or "<root>"
            print(f"        {loc}: {e.message}")
        sys.exit(1)
    print(f"PASS  {path.name} validates")


def with_mutation(base: dict[str, Any], path: Iterable[str], value: Any) -> dict[str, Any]:
    """Return a deep copy of base with the dotted path set to value.

    If value is the sentinel object _MISSING, delete the key instead.
    """
    copy_ = copy.deepcopy(base)
    cursor: Any = copy_
    keys = list(path)
    for key in keys[:-1]:
        cursor = cursor[key]
    if value is _MISSING:
        del cursor[keys[-1]]
    else:
        cursor[keys[-1]] = value
    return copy_


class _Missing:  # singleton
    def __repr__(self) -> str:  # pragma: no cover
        return "_MISSING"


_MISSING = _Missing()


def check_negative(schema: dict[str, Any], base: dict[str, Any]) -> None:
    """Each case should fail validation; print a one-liner per case."""
    cases: list[tuple[str, dict[str, Any], str]] = [
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
    fail = False
    validator = Draft202012Validator(schema)
    for label, instance, expected_locus in cases:
        errors = list(validator.iter_errors(instance))
        if not errors:
            print(f"FAIL  expected error for case: {label}")
            fail = True
            continue
        first = errors[0]
        loc = "/".join(str(p) for p in first.absolute_path) or "<root>"
        if expected_locus not in loc and expected_locus != "<root>":
            print(
                f"WARN  {label} → error at {loc} (expected to mention {expected_locus}): {first.message}"
            )
        else:
            print(f"PASS  rejected: {label}  →  {loc}: {first.message.splitlines()[0]}")
    if fail:
        sys.exit(1)


def main() -> int:
    schema = load_schema()
    check_schema(schema)
    check_positive(schema, HERE / "example-cray.yaml")
    check_positive(schema, HERE / "example-linux.yaml")
    print()
    print("Negative cases (each should be rejected with a clear error):")
    cray = load_yaml(HERE / "example-cray.yaml")
    check_negative(schema, cray)
    print()
    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
