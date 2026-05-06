"""
Package-set loading and OpenSSL compatibility helpers for cse-stack.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required. Install it with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


_SYSTEM_PREFIXES = ("/usr", "/usr/local")


def _query_cmd(*cmd: str) -> str:
    try:
        return subprocess.check_output(list(cmd), stderr=subprocess.DEVNULL, text=True).strip()
    except (FileNotFoundError, subprocess.CalledProcessError, OSError):
        return ""


def detect_system_openssl() -> tuple[str, str]:
    override_version = os.environ.get("CSE_OPENSSL_VERSION_OVERRIDE", "").strip()
    if override_version:
        override_prefix = os.environ.get("CSE_OPENSSL_PREFIX_OVERRIDE", "/usr").strip() or "/usr"
        return override_version, override_prefix

    for prefix in _SYSTEM_PREFIXES:
        binary = Path(prefix, "bin", "openssl")
        if binary.exists():
            out = _query_cmd(str(binary), "version")
            parts = out.split()
            if parts and parts[0].lower() == "openssl" and len(parts) >= 2:
                return parts[1], prefix
    for prefix in _SYSTEM_PREFIXES:
        pkgcfg = Path(prefix, "bin", "pkg-config")
        if pkgcfg.exists():
            ver = _query_cmd(str(pkgcfg), "--modversion", "openssl")
            if ver:
                pfx = _query_cmd(str(pkgcfg), "--variable=prefix", "openssl") or prefix
                return ver, pfx
    return "", ""


def _openssl_version_key(version: str) -> tuple[int, int, int, int]:
    match = re.search(r"(\d+)\.(\d+)\.(\d+)([a-z]?)", version.lower())
    if not match:
        numbers = [int(part) for part in re.findall(r"\d+", version)]
        while len(numbers) < 3:
            numbers.append(0)
        return (numbers[0], numbers[1], numbers[2], 0)
    suffix = ord(match.group(4)) - ord("a") + 1 if match.group(4) else 0
    return (int(match.group(1)), int(match.group(2)), int(match.group(3)), suffix)


def openssl_version_gte(actual: str, minimum: str) -> bool:
    return _openssl_version_key(actual) >= _openssl_version_key(minimum)


def _format_value(value: Any, ctx: dict[str, Any]) -> Any:
    if isinstance(value, str):
        return value.format(**ctx)
    if isinstance(value, list):
        return [_format_value(item, ctx) for item in value]
    if isinstance(value, dict):
        return {key: _format_value(item, ctx) for key, item in value.items()}
    return value


def load_package_set(repo_root: Path, package_set: str, variant: str, ctx: dict[str, Any]) -> dict[str, Any]:
    package_set_path = repo_root / "package-sets" / f"{package_set}.yaml"
    if not package_set_path.exists():
        raise ValueError(f"package set {package_set!r} not found at {package_set_path}")
    try:
        data = yaml.safe_load(package_set_path.read_text()) or {}
    except (OSError, yaml.YAMLError) as exc:
        raise ValueError(f"failed to read package set {package_set_path}: {exc}") from exc

    variants = data.get("variants", {})
    if variant not in variants:
        raise ValueError(f"package set {package_set!r} does not define variant {variant!r}")

    selected = _format_value(variants[variant], ctx)
    selected["name"] = package_set
    selected["description"] = data.get("description", "")
    selected["openssl_policy"] = _format_value(data.get("openssl", {}), ctx)
    return selected


def validate_openssl_policy(
    repo_root: Path,
    package_set: str,
    variant: str,
    mpich_version: str = "",
) -> tuple[bool, str]:
    ctx = {
        "mpich_version": mpich_version or os.environ.get("MPICH_VERSION", "4.2.2"),
    }
    selected = load_package_set(repo_root, package_set, variant, ctx)
    openssl_version, openssl_prefix = detect_system_openssl()
    if not openssl_version:
        return (
            False,
            "ERROR: site OpenSSL was not detected under /usr or /usr/local. "
            "openssl is enforced as a site external and is never buildable from source.",
        )

    policy = selected.get("openssl_policy", {})
    minimum = str(policy.get("min_version", "")).strip()
    if minimum and not openssl_version_gte(openssl_version, minimum):
        recommendation = str(policy.get("recommended_package_set", "")).strip()
        reason = str(policy.get("reason", "")).strip()
        root_spec = ""
        specs = selected.get("specs", [])
        if specs:
            root_spec = str(specs[0])
        message = (
            f"ERROR: detected site OpenSSL {openssl_version} at {openssl_prefix}, "
            f"but package set {package_set} for {variant} requires external OpenSSL >= {minimum}."
        )
        if reason:
            message += f" {reason}"
        if root_spec:
            message += f" Selected MPI root spec: {root_spec}."
        if recommendation:
            message += f" Retry with --package-set {recommendation}."
        return (False, message)

    return (True, f"OpenSSL preflight OK: {openssl_version} at {openssl_prefix}")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate cse-stack package-set compatibility")
    parser.add_argument("--repo-root", required=True, dest="repo_root")
    parser.add_argument("--package-set", required=True, dest="package_set")
    parser.add_argument("--variant", required=True, choices=["v1-openmpi", "v2-mpich"])
    parser.add_argument("--mpich-version", default="")
    return parser.parse_args()


if __name__ == "__main__":
    args = _parse_args()
    try:
        ok, message = validate_openssl_policy(
            repo_root=Path(args.repo_root),
            package_set=args.package_set,
            variant=args.variant,
            mpich_version=args.mpich_version,
        )
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
    if ok:
        print(message)
        raise SystemExit(0)
    print(message, file=sys.stderr)
    raise SystemExit(1)
