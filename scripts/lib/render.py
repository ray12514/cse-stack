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
import sys
from pathlib import Path

try:
    from jinja2 import Environment, FileSystemLoader, StrictUndefined, TemplateNotFound
except ImportError:
    print("ERROR: Jinja2 is required. Install it with: pip install jinja2", file=sys.stderr)
    sys.exit(1)

# Allow importing profile.py from the same lib/ directory
sys.path.insert(0, str(Path(__file__).parent))
from profile import SystemProfile  # noqa: E402


def _build_context(profile: SystemProfile, variant: str,
                   shared_path: str, release: str,
                   gcc_version_override: str = "",
                   cse_group: str = "") -> dict:
    """Build the Jinja2 template context from a system profile + deploy args."""
    ctx: dict = {
        "variant": variant,
        "SHARED_PATH": shared_path,
        "CSE_RELEASE": release,
        "is_variant_a": variant == "v1-minimal-externals",
        "is_variant_b": variant == "v2-cray-integrated",
        # OS
        "glibc_version": profile.glibc_version(),
        "cpu_arch": (profile.cray_cpu_arch() if profile.is_cray()
                     else profile.cpu_arch()),
        # Module system
        "module_system": profile.module_system(),
        # Scheduler
        "scheduler_type": profile.scheduler_type(),
        # Variant A — GCC version: runtime override > env var > profile default
        "gcc_version": (gcc_version_override
                        or os.environ.get("GCC_VERSION", "")
                        or profile.variant_a_gcc_version()),
        # Variant B
        "is_cray": profile.is_cray(),
        "prgenv_gcc_version": profile.prgenv_gcc_version(),
        "prgenv_gcc_prefix": profile.prgenv_gcc_prefix(),
        "cray_mpich_version": profile.cray_mpich_version(),
        "cray_mpich_prefix": profile.cray_mpich_prefix(),
        "cray_libsci_version": profile.cray_libsci_version(),
        "cray_libsci_prefix": profile.cray_libsci_prefix(),
        "has_cray_pals": profile.has_cray_pals(),
        "cray_pals_version": profile.cray_pals_version(),
        "cray_pals_prefix": profile.cray_pals_prefix(),
    }
    # Derived paths used heavily in templates
    variant_slug = "v1-minimal" if variant == "v1-minimal-externals" else "v2-cray-integrated"
    ctx["variant_slug"] = variant_slug
    ctx["store_root"] = f"{shared_path}/cse/{release}/{variant_slug}/store"
    ctx["module_root"] = f"{shared_path}/cse/{release}/{variant_slug}/modules"
    ctx["views_root"] = f"{shared_path}/cse/{release}/{variant_slug}/views"
    ctx["bootstrap_prefix"] = (
        f"{shared_path}/cse/{release}/{variant_slug}/bootstrap"
        f"/gcc-{ctx['gcc_version']}"
    )
    ctx["cse_group"] = cse_group or os.environ.get("CSE_GROUP", "cse")
    return ctx


def render_template(template_path: str, profile_path: Optional[str],
                    variant: str, shared_path: str, release: str,
                    dry_run: bool = False, output_path: Optional[str] = None) -> int:
    from typing import Optional as Opt  # local import to avoid top-level clash

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
        if variant == "v2-cray-integrated":
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
                   choices=["v1-minimal-externals", "v2-cray-integrated"])
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
