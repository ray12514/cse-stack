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
from package_sets import detect_system_openssl, load_package_set  # noqa: E402


_SYSTEM_PREFIXES = ("/usr", "/usr/local")


def _query_cmd(*cmd) -> str:
    try:
        return subprocess.check_output(
            list(cmd), stderr=subprocess.DEVNULL, text=True
        ).strip()
    except (FileNotFoundError, subprocess.CalledProcessError, OSError):
        return ""


def _detect_curl() -> tuple:
    for prefix in _SYSTEM_PREFIXES:
        binary = Path(prefix, "bin", "curl")
        if binary.exists():
            out = _query_cmd(str(binary), "--version")
            first = out.splitlines()[0] if out else ""
            parts = first.split()
            if len(parts) >= 2 and parts[0].lower() == "curl":
                return parts[1], prefix
    for prefix in _SYSTEM_PREFIXES:
        pkgcfg = Path(prefix, "bin", "pkg-config")
        if pkgcfg.exists():
            ver = _query_cmd(str(pkgcfg), "--modversion", "libcurl")
            if ver:
                pfx = _query_cmd(str(pkgcfg), "--variable=prefix", "libcurl") or prefix
                return ver, pfx
    return "", ""


def _detect_perl() -> tuple:
    for prefix in _SYSTEM_PREFIXES:
        binary = Path(prefix, "bin", "perl")
        if binary.exists():
            ver = _query_cmd(str(binary), "-e", r'printf "%vd\n", $^V')
            if ver:
                return ver, prefix
    return "", ""


def _detect_python() -> tuple:
    for name in ("python3", "python"):
        for prefix in _SYSTEM_PREFIXES:
            binary = Path(prefix, "bin", name)
            if binary.exists():
                out = _query_cmd(str(binary), "--version")
                parts = out.split()
                if len(parts) >= 2 and parts[0].lower() == "python":
                    return parts[1], prefix
    return "", ""


def _detect_gcc_bootstrap(variant_dir: str) -> tuple[str, str]:
    override = os.environ.get("CSE_GCC_PREFIX", "").strip()
    if override:
        return override, os.environ.get("GCC_VERSION", "").strip()

    bootstrap_yaml = Path(variant_dir, "gcc-bootstrap.yaml")
    if not bootstrap_yaml.exists():
        return "", ""

    try:
        text = bootstrap_yaml.read_text()
    except OSError:
        return "", ""

    prefix_match = re.search(r"^\s*prefix:\s*(\S+)\s*$", text, flags=re.MULTILINE)
    spec_match = re.search(r"^\s*-\s*spec:\s*gcc@([^\s]+)", text, flags=re.MULTILINE)
    prefix = prefix_match.group(1) if prefix_match else ""
    version = spec_match.group(1) if spec_match else ""
    return prefix, version


def _spec_version(specs: list[str], name: str) -> str:
    root_pattern = re.compile(rf"^\s*{re.escape(name)}@([^\s+~^]+)")
    any_pattern = re.compile(rf"(?:^|[\s^]){re.escape(name)}@([^\s+~^]+)")

    for spec in specs:
        match = root_pattern.search(spec)
        if match:
            return match.group(1)
    for spec in specs:
        match = any_pattern.search(spec)
        if match:
            return match.group(1)
    return ""


def _root_specs(specs: list[str], name: str) -> list[str]:
    pattern = re.compile(rf"^\s*{re.escape(name)}(?:@|[\s+~]|$)")
    return [spec for spec in specs if pattern.search(spec)]


def _root_spec_name(spec: str) -> str:
    match = re.match(r"^\s*([A-Za-z0-9_.+-]+)", spec)
    return match.group(1) if match else ""


def _root_spec_version(spec: str) -> str:
    match = re.match(r"^\s*[A-Za-z0-9_.+-]+@([^\s+~^]+)", spec)
    return match.group(1) if match else ""


def _root_spec_has_token(spec: str, token: str) -> bool:
    token_pattern = re.compile(rf"(?<!\S){re.escape(token)}(?!\S)")
    return bool(token_pattern.search(spec))


def _root_spec_has_dep_variant(spec: str, dep_name: str, variant: str) -> bool:
    dep_pattern = re.compile(
        rf"\^{re.escape(dep_name)}(?:@[^\s^+~]+)?[^\s^]*{re.escape(variant)}"
    )
    spaced_dep_pattern = re.compile(
        rf"\^{re.escape(dep_name)}(?:@[^\s^+~]+)?(?:\s+[^\^]*)?{re.escape(variant)}"
    )
    return bool(dep_pattern.search(spec) or spaced_dep_pattern.search(spec))


def _root_spec_suffix(spec: str) -> str:
    name = _root_spec_name(spec)
    if name in ("hdf5", "netcdf-c"):
        if _root_spec_has_token(spec, "+mpi") or re.search(
            rf"{re.escape(name)}@[^\s^]*\+mpi", spec
        ):
            return "-mpi"
        if _root_spec_has_token(spec, "~mpi") or re.search(
            rf"{re.escape(name)}@[^\s^]*~mpi", spec
        ):
            return "-serial"
    if name in ("netcdf-fortran", "netcdf-cxx4"):
        if _root_spec_has_dep_variant(spec, "netcdf-c", "+mpi"):
            return "-mpi"
        if _root_spec_has_dep_variant(spec, "netcdf-c", "~mpi"):
            return "-serial"
    return ""


def _root_public_modules(specs: list[str]) -> list[dict[str, str]]:
    modules = []
    for spec in specs:
        name = _root_spec_name(spec)
        if not name:
            continue
        modules.append(
            {
                "name": name,
                "version": _root_spec_version(spec),
                "suffix": _root_spec_suffix(spec),
                "module": _module_use_name(
                    name, _root_spec_version(spec), _root_spec_suffix(spec)
                ),
            }
        )
    return modules


def _root_spec_has_variant(specs: list[str], name: str, variant: str) -> bool:
    token_pattern = re.compile(rf"(?<!\S){re.escape(variant)}(?!\S)")
    compact_pattern = re.compile(rf"{re.escape(name)}@[^\s^]*{re.escape(variant)}")
    for spec in _root_specs(specs, name):
        if token_pattern.search(spec) or compact_pattern.search(spec):
            return True
    return False


def _root_spec_dep_has_variant(
    specs: list[str], name: str, dep_name: str, variant: str
) -> bool:
    dep_pattern = re.compile(
        rf"\^{re.escape(dep_name)}(?:@[^\s^+~]+)?[^\s^]*{re.escape(variant)}"
    )
    spaced_dep_pattern = re.compile(
        rf"\^{re.escape(dep_name)}(?:@[^\s^+~]+)?(?:\s+[^\^]*)?{re.escape(variant)}"
    )
    for spec in _root_specs(specs, name):
        if dep_pattern.search(spec) or spaced_dep_pattern.search(spec):
            return True
    return False


def _module_use_name(package: str, version: str, suffix: str = "") -> str:
    if version:
        return f"cse/{package}/{version}{suffix}"
    return f"cse/{package}"


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
    _ssl_ver, _ssl_prefix = detect_system_openssl()
    _curl_ver, _curl_prefix = _detect_curl()
    _perl_ver, _perl_prefix = _detect_perl()
    _python_ver, _python_prefix = _detect_python()
    ctx: dict = {
        "variant": variant,
        "SHARED_PATH": shared_path,
        "CSE_RELEASE": release,
        "is_openmpi": variant == "v1-openmpi",
        "is_mpich":   variant == "v2-mpich",
        "openssl_version": _ssl_ver,   "openssl_prefix": _ssl_prefix,
        "curl_version":    _curl_ver,  "curl_prefix":    _curl_prefix,
        "perl_version":    _perl_ver,  "perl_prefix":    _perl_prefix,
        "python_version":  _python_ver, "python_prefix": _python_prefix,
        # OS
        "glibc_version": profile.glibc_version(),
        # Default to generic x86_64 so the same build runs on any node.
        # Override with SPACK_TARGET env var if a specific microarch is needed.
        "cpu_arch": os.environ.get("SPACK_TARGET", "x86_64"),
        # Module system
        "module_system": os.environ.get("MODULE_SYSTEM", profile.module_system()),
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
    ctx["variant_dir"] = variant_dir
    ctx["gcc_bootstrap_yaml_exists"] = os.path.exists(
        os.path.join(variant_dir, "gcc-bootstrap.yaml")
    )
    ctx["gcc_compilers_yaml_exists"] = os.path.exists(
        os.path.join(variant_dir, "gcc-compilers.yaml")
    )
    package_set = os.environ.get("CSE_PACKAGE_SET", "full")
    ctx["package_set"] = package_set
    package_set_data = load_package_set(Path(__file__).parent.parent.parent, package_set, variant, ctx)
    ctx["package_set_data"] = package_set_data
    ctx["mpi_provider"] = package_set_data.get(
        "mpi_provider", "openmpi" if variant == "v1-openmpi" else "mpich"
    )
    ctx["spack_specs"] = package_set_data.get("specs", [])
    ctx["view_mpi_select"] = package_set_data.get("views", {}).get("mpi", [])
    ctx["view_serial_select"] = package_set_data.get("views", {}).get("serial", [])
    mpi_version = _spec_version(ctx["spack_specs"], ctx["mpi_provider"])
    hdf5_version = _spec_version(ctx["spack_specs"], "hdf5")
    netcdf_c_version = _spec_version(ctx["spack_specs"], "netcdf-c")
    netcdf_fortran_version = _spec_version(ctx["spack_specs"], "netcdf-fortran")
    netcdf_cxx4_version = _spec_version(ctx["spack_specs"], "netcdf-cxx4")
    ctx["mpi_module"] = _module_use_name(ctx["mpi_provider"], mpi_version)
    ctx["hdf5_mpi_module"] = _module_use_name("hdf5", hdf5_version, "-mpi")
    ctx["hdf5_serial_module"] = _module_use_name("hdf5", hdf5_version, "-serial")
    ctx["netcdf_c_mpi_module"] = _module_use_name("netcdf-c", netcdf_c_version, "-mpi")
    ctx["netcdf_c_serial_module"] = _module_use_name(
        "netcdf-c", netcdf_c_version, "-serial"
    )
    ctx["netcdf_fortran_mpi_module"] = _module_use_name(
        "netcdf-fortran", netcdf_fortran_version, "-mpi"
    )
    ctx["netcdf_fortran_serial_module"] = _module_use_name(
        "netcdf-fortran", netcdf_fortran_version, "-serial"
    )
    ctx["netcdf_cxx4_mpi_module"] = _module_use_name(
        "netcdf-cxx4", netcdf_cxx4_version, "-mpi"
    )
    ctx["netcdf_cxx4_serial_module"] = _module_use_name(
        "netcdf-cxx4", netcdf_cxx4_version, "-serial"
    )
    public_modules = _root_public_modules(ctx["spack_specs"])
    ctx["public_module_include_specs"] = list(
        dict.fromkeys(item["name"] for item in public_modules)
    )
    ctx["public_module_names"] = list(
        dict.fromkeys(item["module"] for item in public_modules)
    )
    public_module_set = set(ctx["public_module_names"])
    ctx["load_hdf5_mpi"] = (
        ctx["mpi_module"] in public_module_set
        and ctx["hdf5_mpi_module"] in public_module_set
    )
    ctx["load_netcdf_c_mpi"] = (
        ctx["hdf5_mpi_module"] in public_module_set
        and ctx["netcdf_c_mpi_module"] in public_module_set
    )
    ctx["load_netcdf_c_serial"] = (
        ctx["hdf5_serial_module"] in public_module_set
        and ctx["netcdf_c_serial_module"] in public_module_set
    )
    ctx["load_netcdf_fortran_mpi"] = (
        ctx["netcdf_c_mpi_module"] in public_module_set
        and ctx["netcdf_fortran_mpi_module"] in public_module_set
    )
    ctx["load_netcdf_fortran_serial"] = (
        ctx["netcdf_c_serial_module"] in public_module_set
        and ctx["netcdf_fortran_serial_module"] in public_module_set
    )
    ctx["load_netcdf_cxx4_mpi"] = (
        ctx["netcdf_c_mpi_module"] in public_module_set
        and ctx["netcdf_cxx4_mpi_module"] in public_module_set
    )
    ctx["load_netcdf_cxx4_serial"] = (
        ctx["netcdf_c_serial_module"] in public_module_set
        and ctx["netcdf_cxx4_serial_module"] in public_module_set
    )
    curated_load_modules = []
    if (
        hdf5_version
        and _root_spec_has_variant(ctx["spack_specs"], "hdf5", "+mpi")
        and mpi_version
        and ctx["load_hdf5_mpi"]
    ):
        curated_load_modules.append(ctx["mpi_module"])
    if (
        netcdf_c_version
        and _root_spec_has_variant(ctx["spack_specs"], "netcdf-c", "+mpi")
        and ctx["load_netcdf_c_mpi"]
    ):
        curated_load_modules.append(ctx["hdf5_mpi_module"])
    if (
        netcdf_c_version
        and _root_spec_has_variant(ctx["spack_specs"], "netcdf-c", "~mpi")
        and ctx["load_netcdf_c_serial"]
    ):
        curated_load_modules.append(ctx["hdf5_serial_module"])
    if (
        netcdf_fortran_version
        and _root_spec_dep_has_variant(ctx["spack_specs"], "netcdf-fortran", "netcdf-c", "+mpi")
        and ctx["load_netcdf_fortran_mpi"]
    ):
        curated_load_modules.append(ctx["netcdf_c_mpi_module"])
    if (
        netcdf_fortran_version
        and _root_spec_dep_has_variant(ctx["spack_specs"], "netcdf-fortran", "netcdf-c", "~mpi")
        and ctx["load_netcdf_fortran_serial"]
    ):
        curated_load_modules.append(ctx["netcdf_c_serial_module"])
    if (
        netcdf_cxx4_version
        and _root_spec_dep_has_variant(ctx["spack_specs"], "netcdf-cxx4", "netcdf-c", "+mpi")
        and ctx["load_netcdf_cxx4_mpi"]
    ):
        curated_load_modules.append(ctx["netcdf_c_mpi_module"])
    if (
        netcdf_cxx4_version
        and _root_spec_dep_has_variant(ctx["spack_specs"], "netcdf-cxx4", "netcdf-c", "~mpi")
        and ctx["load_netcdf_cxx4_serial"]
    ):
        curated_load_modules.append(ctx["netcdf_c_serial_module"])
    ctx["curated_load_modules"] = list(dict.fromkeys(curated_load_modules))
    ctx["init_module_root"] = (
        os.environ.get("CSE_INIT_MODULE_ROOT", "").strip()
        or (
            f"{ctx['module_root']}/Core"
            if ctx["module_system"] == "lmod"
            else ctx["module_root"]
        )
    )
    cse_gcc_store_root, cse_gcc_version = _detect_gcc_bootstrap(variant_dir)
    ctx["cse_gcc_store_root"] = cse_gcc_store_root
    ctx["cse_gcc_version"] = cse_gcc_version or gcc_version
    ctx["cse_gcc_root"] = (
        f"{ctx['views_root']}/compiler/gcc/{ctx['cse_gcc_version']}"
    )
    ctx["cse_cc"] = f"{ctx['cse_gcc_root']}/bin/gcc"
    ctx["cse_cxx"] = f"{ctx['cse_gcc_root']}/bin/g++"
    ctx["cse_fc"] = f"{ctx['cse_gcc_root']}/bin/gfortran"
    return ctx


def _load_profile(profile_path: Optional[str], variant: str) -> SystemProfile:
    if profile_path and Path(profile_path).exists():
        return SystemProfile.from_file(profile_path)

    # Build a minimal stub so templates render without a real profile.
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
        # Inject Cray signals so the template gets plausible values.
        stub["system"]["platform_class"] = "cray"
        stub["vendor_substrate"]["source"] = "cray"
    return SystemProfile(stub)


def _context_from_args(profile_path: Optional[str], variant: str,
                       shared_path: str, release: str) -> dict:
    profile = _load_profile(profile_path, variant)
    return _build_context(profile, variant, shared_path, release,
                          gcc_version_override=os.environ.get("GCC_VERSION", ""),
                          cse_group=os.environ.get("CSE_GROUP", "cse"))


def render_template(template_path: str, profile_path: Optional[str],
                    variant: str, shared_path: str, release: str,
                    dry_run: bool = False, output_path: Optional[str] = None) -> int:
    repo_root = Path(__file__).parent.parent.parent
    templates_dir = repo_root / "templates"

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

    try:
        ctx = _context_from_args(profile_path, variant, shared_path, release)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
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


def emit_context_list(list_name: str, profile_path: Optional[str],
                      variant: str, shared_path: str, release: str) -> int:
    keys = {
        "public-modules": "public_module_names",
        "curated-loads": "curated_load_modules",
        "public-include-specs": "public_module_include_specs",
    }
    key = keys.get(list_name)
    if not key:
        print(f"ERROR: unknown list: {list_name}", file=sys.stderr)
        return 1

    try:
        ctx = _context_from_args(profile_path, variant, shared_path, release)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    for item in ctx[key]:
        print(item)
    return 0


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Render a CSE Jinja2 template")
    p.add_argument("--template", default="", help="Path to .j2 template file")
    p.add_argument("--output", default="", help="Output file path (omit to print to stdout)")
    p.add_argument("--profile", default="", help="Path to Cluster Inspector YAML profile")
    p.add_argument("--variant", required=True,
                   choices=["v1-openmpi", "v2-mpich"])
    p.add_argument("--shared-path", required=True, dest="shared_path")
    p.add_argument("--release", required=True)
    p.add_argument("--dry-run", action="store_true", dest="dry_run")
    p.add_argument(
        "--list",
        choices=["public-modules", "curated-loads", "public-include-specs"],
        default="",
        help="Print a derived render-context list instead of rendering a template",
    )
    return p.parse_args()


if __name__ == "__main__":
    args = _parse_args()
    if args.list:
        sys.exit(emit_context_list(
            list_name=args.list,
            profile_path=args.profile or None,
            variant=args.variant,
            shared_path=args.shared_path,
            release=args.release,
        ))
    if not args.template:
        print("ERROR: --template is required unless --list is used", file=sys.stderr)
        sys.exit(1)
    sys.exit(render_template(
        template_path=args.template,
        profile_path=args.profile or None,
        variant=args.variant,
        shared_path=args.shared_path,
        release=args.release,
        dry_run=args.dry_run,
        output_path=args.output or None,
    ))
