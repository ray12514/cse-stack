"""
Jinja2 template renderer for CSE deploy pipeline.

Usage (from stage scripts):
  python3 scripts/lib/render.py \
      --template templates/packages.yaml.j2 \
      --output /path/to/env/packages.yaml \
      --profile profiles/myhostname-20260401.yaml \
      --variant v1-minimal-externals \
      --shared-path /shared \
      --release 2026_04 \
      [--dry-run]

With --dry-run the rendered content is printed to stdout and no file is written.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Optional

try:
    from jinja2 import Environment, FileSystemLoader, StrictUndefined, TemplateNotFound
except ImportError:
    print("ERROR: Jinja2 is required. Install it with: pip install jinja2", file=sys.stderr)
    sys.exit(1)

# Allow importing profile.py from the same lib/ directory
sys.path.insert(0, str(Path(__file__).parent))
from profile import SystemProfile  # noqa: E402


def _query_cmd(*cmd) -> str:
    """Run cmd, return stdout stripped, or '' on any error."""
    try:
        return subprocess.check_output(
            list(cmd), stderr=subprocess.DEVNULL, text=True
        ).strip()
    except (FileNotFoundError, subprocess.CalledProcessError, OSError):
        return ""


def _detect_openssl() -> tuple:
    """Return (version, prefix) or ('', '/usr') if not found / is LibreSSL."""
    out = _query_cmd("openssl", "version")
    parts = out.split()
    if parts and parts[0].lower() == "openssl" and len(parts) >= 2:
        return parts[1], "/usr"
    # pkg-config fallback — works when the openssl binary is absent from PATH
    ver = _query_cmd("pkg-config", "--modversion", "openssl")
    if ver:
        prefix = _query_cmd("pkg-config", "--variable=prefix", "openssl") or "/usr"
        return ver, prefix
    return "", "/usr"


def _detect_curl() -> tuple:
    """Return (version, prefix) or ('', '/usr') if not found."""
    out = _query_cmd("curl", "--version")
    # First line: "curl X.Y.Z (platform) ..."
    first = out.splitlines()[0] if out else ""
    parts = first.split()
    if len(parts) >= 2 and parts[0].lower() == "curl":
        return parts[1], "/usr"
    ver = _query_cmd("pkg-config", "--modversion", "libcurl")
    if ver:
        prefix = _query_cmd("pkg-config", "--variable=prefix", "libcurl") or "/usr"
        return ver, prefix
    return "", "/usr"


def _detect_perl() -> tuple:
    """Return (version, prefix) or ('', '/usr') if not found."""
    ver = _query_cmd("perl", "-e", r'printf "%vd\n", $^V')
    if ver:
        return ver, "/usr"
    return "", "/usr"


def _detect_python() -> tuple:
    """Return (version, prefix) or ('', '/usr') if not found."""
    for cmd in (["python3", "--version"], ["python", "--version"]):
        out = _query_cmd(*cmd)
        parts = out.split()
        if len(parts) >= 2 and parts[0].lower() == "python":
            return parts[1], "/usr"
    return "", "/usr"


def _build_context(profile: SystemProfile, variant: str,
                   shared_path: str, release: str,
                   gcc_version_override: str = "",
                   cse_group: str = "") -> dict:
    """Build the Jinja2 template context from a system profile + deploy args."""
    gcc_version = (gcc_version_override
                   or os.environ.get("GCC_VERSION", "")
                   or profile.variant_a_gcc_version())
    # MPICH version: explicit env var > auto-detect from cray-mpich series
    mpich_version = (os.environ.get("MPICH_VERSION", "")
                     or profile.mpich_version_for_spack())
    # make_jobs: threads per package build, written to config:build_jobs.
    # Sourced from SPACK_MAKE_JOBS (set by deploy.sh --make-jobs) and falls
    # back to 16 when render.py is invoked outside the deploy pipeline.
    try:
        make_jobs = int(os.environ.get("SPACK_MAKE_JOBS", "") or "16")
    except ValueError:
        make_jobs = 16
    _ssl_ver,    _ssl_prefix    = _detect_openssl()
    _curl_ver,   _curl_prefix   = _detect_curl()
    _perl_ver,   _perl_prefix   = _detect_perl()
    _python_ver, _python_prefix = _detect_python()
    ctx: dict = {
        "variant": variant,
        "SHARED_PATH": shared_path,
        "CSE_RELEASE": release,
        "is_openmpi": variant == "v1-openmpi",
        "is_mpich":   variant == "v2-mpich",
        # OS-level externals: versions detected at render time from the actual
        # system so Spack never gets a wrong version hint.  Empty string means
        # the package was not found; templates leave out the externals: block
        # and set buildable: true so Spack can build its own.
        "openssl_version": _ssl_ver,   "openssl_prefix": _ssl_prefix,
        "curl_version":    _curl_ver,  "curl_prefix":    _curl_prefix,
        "perl_version":    _perl_ver,  "perl_prefix":    _perl_prefix,
        "python_version":  _python_ver,"python_prefix":  _python_prefix,
        # OS
        "glibc_version": profile.glibc_version(),
        "cpu_arch": (profile.cray_cpu_arch() if profile.is_cray()
                     else profile.cpu_arch()),
        # Module system
        "module_system": profile.module_system(),
        # Scheduler
        "scheduler_type": profile.scheduler_type(),
        # GCC — both variants bootstrap from Spack
        "gcc_version": gcc_version,
        # MPICH version (auto-detected from cray-mpich series for ABI compat)
        "mpich_version": mpich_version,
        # Threads per package build → templates/config.yaml.j2 build_jobs
        "make_jobs": make_jobs,
        # Cray detection — libfabric and pals for v2-mpich
        "is_cray":           profile.is_cray(),
        "has_libfabric":     profile.has_libfabric(),
        "libfabric_version": profile.libfabric_version(),
        "libfabric_prefix":  profile.libfabric_prefix(),
        "has_cray_pals":     profile.has_cray_pals(),
        "cray_pals_version": profile.cray_pals_version(),
        "cray_pals_prefix":  profile.cray_pals_prefix(),
    }
    # variant_slug == variant name — no shortening needed
    ctx["variant_slug"] = variant
    ctx["store_root"] = f"{shared_path}/cse/{release}/{variant}/store"
    ctx["module_root"] = f"{shared_path}/cse/{release}/{variant}/modules"
    ctx["views_root"] = f"{shared_path}/cse/{release}/{variant}/views"
    ctx["bootstrap_prefix"] = (
        f"{shared_path}/cse/{release}/{variant}/bootstrap"
        f"/gcc-{gcc_version}"
    )
    ctx["cse_group"] = cse_group or os.environ.get("CSE_GROUP", "cse")
    # gcc-bootstrap.yaml is written by stage2 next to the env dir. The
    # environment's spack.yaml conditionally includes it — render-time check
    # so we don't emit an `include:` entry that Spack will fail to find.
    variant_dir = f"{shared_path}/cse/{release}/{variant}"
    ctx["gcc_bootstrap_yaml_exists"] = os.path.exists(
        os.path.join(variant_dir, "gcc-bootstrap.yaml")
    )
    return ctx


def render_template(template_path: str, profile_path: Optional[str],
                    variant: str, shared_path: str, release: str,
                    dry_run: bool = False, output_path: Optional[str] = None) -> int:
    repo_root = Path(__file__).parent.parent.parent
    templates_dir = repo_root / "templates"

    # Load profile (use empty/mock if not supplied, e.g. in dry-run without Stage 1)
    if profile_path and Path(profile_path).exists():
        profile = SystemProfile.from_file(profile_path)
    else:
        # Build a minimal stub so templates render without a real profile
        stub: dict = {
            "system": {"name": "stub", "platform_class": "unknown",
                       "environment_model": "unknown"},
            "os": {"glibc_version": "2.34"},
            "modules": {"system": "lmod", "loaded": []},
            "scheduler": {"type": "unknown"},
            "hardware": {"cpu": {}},
            "vendor_substrate": {"prgenv_module": "", "mpi_module": "",
                                  "source": "unknown"},
        }
        if variant == "v2-mpich":
            # Inject Cray signals so the template gets plausible values
            stub["system"]["platform_class"] = "cray"
            stub["vendor_substrate"]["source"] = "cray"
        profile = SystemProfile(stub)

    env = Environment(
        loader=FileSystemLoader(str(templates_dir)),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
    )

    tpl_name = Path(template_path).name
    try:
        template = env.get_template(tpl_name)
    except TemplateNotFound:
        print(f"ERROR: template not found: {templates_dir / tpl_name}", file=sys.stderr)
        return 1

    ctx = _build_context(profile, variant, shared_path, release,
                         gcc_version_override=os.environ.get("GCC_VERSION", ""),
                         cse_group=os.environ.get("CSE_GROUP", "cse"))
    rendered = template.render(**ctx)

    if dry_run:
        print(f"\n--- {tpl_name} (rendered, dry-run) ---")
        print(rendered)
        return 0

    if output_path:
        Path(output_path).parent.mkdir(parents=True, exist_ok=True)
        Path(output_path).write_text(rendered)
        print(f"  wrote {output_path}")
    else:
        print(rendered)

    return 0


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Render a CSE Jinja2 template")
    p.add_argument("--template", required=True, help="Path to .j2 template file")
    p.add_argument("--output", default="", help="Output file path (omit to print to stdout)")
    p.add_argument("--profile", default="", help="Path to Cluster Inspector YAML profile")
    p.add_argument("--variant", required=True,
                   choices=["v1-openmpi", "v2-mpich"])
    p.add_argument("--shared-path", required=True, dest="shared_path")
    p.add_argument("--release", required=True)
    p.add_argument("--dry-run", action="store_true", dest="dry_run")
    return p.parse_args()


if __name__ == "__main__":
    args = _parse_args()
    sys.exit(render_template(
        template_path=args.template,
        profile_path=args.profile or None,
        variant=args.variant,
        shared_path=args.shared_path,
        release=args.release,
        dry_run=args.dry_run,
        output_path=args.output or None,
    ))
