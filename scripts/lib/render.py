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
from itertools import product
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
import yaml  # noqa: E402


_SYSTEM_PREFIXES = ("/usr", "/usr/local")

_KNOWN_COMPILERS = frozenset({"gcc", "cce", "aocc", "nvhpc", "rocmcc", "intel"})
_KNOWN_MPI_LANES = frozenset({"openmpi", "mpich", "craympich", "impi", "sitempi", "serial"})
_LEGACY_ALIASES: dict[str, str] = {
    "v1-openmpi": "gcc-openmpi",
    "v2-mpich":   "gcc-mpich",
}
_MPI_PROVIDER_DEFAULTS: dict[str, str] = {
    "openmpi":   "openmpi",
    "mpich":     "mpich",
    "craympich": "cray-mpich",
    "impi":      "intel-mpi",
    "sitempi":   "openmpi",
    "serial":    "",
}


def _parse_variant(variant: str) -> tuple[str, str]:
    """Split a variant slug into (compiler_family, mpi_lane).

    "gcc-openmpi"   → ("gcc",  "openmpi")
    "cce-craympich" → ("cce",  "craympich")
    "gcc-serial"    → ("gcc",  "serial")
    """
    parts = variant.split("-", 1)
    return parts[0].lower(), (parts[1].lower() if len(parts) > 1 else "serial")


def _resolve_variant(variant: str) -> str:
    """Map legacy variant names to their canonical equivalents."""
    if variant in _LEGACY_ALIASES:
        new_name = _LEGACY_ALIASES[variant]
        print(
            f"WARNING: --variant {variant!r} is deprecated; use {new_name!r}.",
            file=sys.stderr,
        )
        return new_name
    return variant


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


def _format_spack_spec_entry(spec: object) -> str:
    if isinstance(spec, str):
        return f"    - {spec}"
    rendered = yaml.safe_dump([spec], default_flow_style=False, sort_keys=False).rstrip()
    return "\n".join(f"    {line}" for line in rendered.splitlines())



def _expand_matrix_entry(entry: dict) -> list[str]:
    axes = entry.get("matrix", [])
    if not isinstance(axes, list) or not axes:
        return []

    expanded = []
    for combination in product(*axes):
        parts = []
        for item in combination:
            if isinstance(item, list):
                parts.extend(str(part) for part in item if str(part).strip())
            elif str(item).strip():
                parts.append(str(item))
        spec = " ".join(parts).strip()
        if spec:
            expanded.append(spec)
    return expanded


def _expand_spack_specs(specs: list[object]) -> list[str]:
    expanded = []
    for spec in specs:
        if isinstance(spec, str):
            expanded.append(spec)
        elif isinstance(spec, dict) and "matrix" in spec:
            expanded.extend(_expand_matrix_entry(spec))
    return expanded


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


def _root_spec_dep_version(spec: str, dep_name: str) -> str:
    match = re.search(rf"\^{re.escape(dep_name)}@([^\s+~^]+)", spec)
    return match.group(1) if match else ""


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
    if name in ("hdf5", "netcdf-c", "fftw"):
        if _root_spec_has_token(spec, "+mpi") or re.search(
            rf"{re.escape(name)}@[^\s^]*\+mpi", spec
        ):
            return "-mpi"
        if _root_spec_has_token(spec, "~mpi") or re.search(
            rf"{re.escape(name)}@[^\s^]*~mpi", spec
        ):
            return "-serial"
    if name == "boost":
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


def _root_module_example(specs: list[str], name: str, suffix: str = "") -> str:
    for spec in _root_specs(specs, name):
        version = _root_spec_version(spec)
        if version:
            return _module_use_name(name, version, suffix)
    return _module_use_name(name, "", suffix)


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


def _module_load_rule(
    selector: str,
    module: str,
    public_module_set: set[str],
) -> Optional[dict[str, object]]:
    if module not in public_module_set:
        return None
    return {"selector": selector, "loads": [module]}


def _build_module_load_rules(
    specs: list[str],
    mpi_module: str,
    public_module_set: set[str],
) -> list[dict[str, object]]:
    rules = []
    for spec in specs:
        name = _root_spec_name(spec)
        version = _root_spec_version(spec)
        if not name or not version:
            continue

        rule = None
        if name in ("hdf5", "fftw") and _root_spec_has_token(spec, "+mpi"):
            rule = _module_load_rule(f"{name}@{version} +mpi", mpi_module, public_module_set)
        elif name == "netcdf-c":
            hdf5_version = _root_spec_dep_version(spec, "hdf5")
            if _root_spec_has_token(spec, "+mpi"):
                rule = _module_load_rule(
                    f"netcdf-c@{version} +mpi",
                    _module_use_name("hdf5", hdf5_version, "-mpi"),
                    public_module_set,
                )
            elif _root_spec_has_token(spec, "~mpi"):
                rule = _module_load_rule(
                    f"netcdf-c@{version} ~mpi",
                    _module_use_name("hdf5", hdf5_version, "-serial"),
                    public_module_set,
                )
        elif name in ("netcdf-fortran", "netcdf-cxx4"):
            netcdf_c_version = _root_spec_dep_version(spec, "netcdf-c")
            if _root_spec_has_dep_variant(spec, "netcdf-c", "+mpi"):
                rule = _module_load_rule(
                    f"{name}@{version} ^netcdf-c@{netcdf_c_version} +mpi",
                    _module_use_name("netcdf-c", netcdf_c_version, "-mpi"),
                    public_module_set,
                )
            elif _root_spec_has_dep_variant(spec, "netcdf-c", "~mpi"):
                rule = _module_load_rule(
                    f"{name}@{version} ^netcdf-c@{netcdf_c_version} ~mpi",
                    _module_use_name("netcdf-c", netcdf_c_version, "-serial"),
                    public_module_set,
                )
        elif name == "py-numpy":
            python_version = _root_spec_dep_version(spec, "python")
            if python_version:
                rule = _module_load_rule(
                    f"py-numpy@{version} ^python@{python_version}",
                    _module_use_name("python", python_version),
                    public_module_set,
                )

        if rule and rule not in rules:
            rules.append(rule)
    return rules


def _validate_v2_mpich_slurm_externals(ctx: dict) -> None:
    """Fail before concretization when Slurm MPICH needs site externals."""
    if ctx.get("mpi_lane") != "mpich" or ctx.get("scheduler_type") != "slurm":
        return
    if not _root_specs(ctx.get("expanded_spack_specs", []), "mpich"):
        return

    failures = []
    if not (ctx.get("has_libfabric") and ctx.get("libfabric_prefix")):
        failures.append(
            "libfabric external not detected; load a libfabric/<version> module "
            "or set CSE_LIBFABRIC_PREFIX_OVERRIDE and CSE_LIBFABRIC_VERSION_OVERRIDE"
        )
    if not (ctx.get("has_slurm") and ctx.get("slurm_prefix")):
        failures.append(
            "Slurm external not detected; run from a Slurm login node with srun/scontrol "
            "available or set CSE_SLURM_PREFIX_OVERRIDE and CSE_SLURM_VERSION_OVERRIDE"
        )
    if not (ctx.get("has_pmix") and ctx.get("pmix_prefix")):
        failures.append(
            "PMIx external not detected; load a pmix/<version> module, make pkg-config "
            "find pmix, or set CSE_PMIX_PREFIX_OVERRIDE and CSE_PMIX_VERSION_OVERRIDE"
        )

    if failures:
        details = "\n  - ".join(failures)
        raise ValueError(
            "v2-mpich on Slurm requires site-managed libfabric, Slurm, and PMIx "
            f"externals for srun + PMIx launch.\n  - {details}"
        )


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
    try:
        padded_length = int(os.environ.get("SPACK_PADDED_LENGTH", "") or "0")
    except ValueError:
        padded_length = 0
    _ssl_ver, _ssl_prefix = detect_system_openssl()
    _curl_ver, _curl_prefix = _detect_curl()
    _perl_ver, _perl_prefix = _detect_perl()
    _python_ver, _python_prefix = _detect_python()
    compiler_family, mpi_lane = _parse_variant(variant)
    ctx: dict = {
        "variant": variant,
        "SHARED_PATH": shared_path,
        "CSE_RELEASE": release,
        # Compiler and MPI identity — primary way to branch in templates
        "compiler_family": compiler_family,
        "mpi_lane":        mpi_lane,
        "compiler_upper":  compiler_family.upper(),
        "mpi_label":       mpi_lane if mpi_lane == "serial" else f"mpi-{mpi_lane}",
        # Derived booleans — kept for template backward compatibility
        "is_openmpi":  mpi_lane == "openmpi",
        "is_mpich":    mpi_lane in ("mpich", "craympich"),
        "is_craympich": mpi_lane == "craympich",
        "is_serial":   mpi_lane == "serial",
        "is_gcc":      compiler_family == "gcc",
        "is_cce":      compiler_family == "cce",
        "is_aocc":     compiler_family == "aocc",
        "is_nvhpc":    compiler_family == "nvhpc",
        "is_rocmcc":   compiler_family == "rocmcc",
        "is_intel":    compiler_family == "intel",
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
        "has_slurm": profile.has_slurm(),
        "slurm_version": profile.slurm_version(),
        "slurm_prefix": profile.slurm_prefix(),
        "slurm_module": profile.slurm_module(),
        # GCC — both variants bootstrap from Spack
        "gcc_version": gcc_version,
        # MPICH version (auto-detected from cray-mpich series for ABI compat)
        "mpich_version": mpich_version,
        # Threads per package build → templates/config.yaml.j2 build_jobs
        "make_jobs": make_jobs,
        # Disabled by default. Long padded prefixes can break generated
        # shebangs during builds such as gobject-introspection.
        "padded_length": padded_length if padded_length > 0 else 0,
        # Cray detection — libfabric and pals for v2-mpich
        "is_cray":           profile.is_cray(),
        "has_libfabric":     profile.has_libfabric(),
        "libfabric_version": profile.libfabric_version(),
        "libfabric_prefix":  profile.libfabric_prefix(),
        "libfabric_module":  profile.libfabric_module(),
        "has_cray_pals":     profile.has_cray_pals(),
        "cray_pals_version": profile.cray_pals_version(),
        "cray_pals_prefix":  profile.cray_pals_prefix(),
        "has_pmix":          profile.has_pmix(),
        "pmix_version":      profile.pmix_version(),
        "pmix_prefix":       profile.pmix_prefix(),
        "pmix_module":       profile.pmix_module(),
        # Non-GCC compiler externals — populated when PrgEnv module is loaded at Stage 1
        "cce_version":    profile.cce_version(),
        "cce_prefix":     profile.cce_prefix(),
        "aocc_version":   profile.aocc_version(),
        "aocc_prefix":    profile.aocc_prefix(),
        "nvhpc_version":  profile.nvhpc_version(),
        "nvhpc_prefix":   profile.nvhpc_prefix(),
        "rocmcc_version": profile.rocmcc_version(),
        "rocmcc_prefix":  profile.rocmcc_prefix(),
        "intel_version":  profile.intel_version(),
        "intel_prefix":   profile.intel_prefix(),
        # cray-mpich external (also used by gcc-craympich, nvhpc-craympich, etc.)
        "cray_mpich_version": profile.cray_mpich_version(),
        "cray_mpich_prefix":  profile.cray_mpich_prefix(),
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
    ctx["toolchains_yaml_exists"] = os.path.exists(
        os.path.join(variant_dir, "env", "toolchains.yaml")
    )
    ctx["mirrors_yaml_enabled"] = bool(
        os.environ.get("MIRROR_PATH")
        or os.environ.get("BUILDCACHE_URI")
        or os.path.exists(os.path.join(variant_dir, "env", "mirrors.yaml"))
    )
    package_set = os.environ.get("CSE_PACKAGE_SET", "full")
    ctx["package_set"] = package_set
    package_set_data = load_package_set(Path(__file__).parent.parent.parent, package_set, variant, ctx)
    ctx["package_set_data"] = package_set_data
    ctx["mpi_provider"] = package_set_data.get(
        "mpi_provider", _MPI_PROVIDER_DEFAULTS.get(mpi_lane, "openmpi")
    )
    ctx["openssl_mode"] = package_set_data.get("openssl_mode", "external")
    ctx["spack_specs"] = package_set_data.get("specs", [])
    ctx["spack_spec_entries"] = [
        _format_spack_spec_entry(spec)
        for spec in ctx["spack_specs"]
    ]
    ctx["expanded_spack_specs"] = _expand_spack_specs(ctx["spack_specs"])
    _validate_v2_mpich_slurm_externals(ctx)
    ctx["view_mpi_select"] = package_set_data.get("views", {}).get("mpi", [])
    ctx["view_serial_select"] = package_set_data.get("views", {}).get("serial", [])
    mpi_version = _spec_version(ctx["expanded_spack_specs"], ctx["mpi_provider"])
    ctx["mpi_module"] = _module_use_name(ctx["mpi_provider"], mpi_version)
    ctx["hdf5_mpi_module"] = _root_module_example(ctx["expanded_spack_specs"], "hdf5", "-mpi")
    ctx["netcdf_fortran_mpi_module"] = _root_module_example(
        ctx["expanded_spack_specs"], "netcdf-fortran", "-mpi"
    )
    public_modules = _root_public_modules(ctx["expanded_spack_specs"])
    ctx["public_module_include_specs"] = list(
        dict.fromkeys(item["name"] for item in public_modules)
    )
    variant_projected_names = {
        "boost",
        "fftw",
        "hdf5",
        "netcdf-c",
        "netcdf-cxx4",
        "netcdf-fortran",
    }
    ctx["clean_view_projection_names"] = [
        name
        for name in ctx["public_module_include_specs"]
        if name not in variant_projected_names
    ]
    ctx["public_module_names"] = list(
        dict.fromkeys(item["module"] for item in public_modules)
    )
    public_module_set = set(ctx["public_module_names"])
    ctx["module_load_rules"] = _build_module_load_rules(
        ctx["expanded_spack_specs"],
        ctx["mpi_module"],
        public_module_set,
    )
    ctx["curated_load_modules"] = list(
        dict.fromkeys(
            module
            for rule in ctx["module_load_rules"]
            for module in rule["loads"]
        )
    )
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
    if _parse_variant(variant)[1] == "craympich":
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
                   help="Variant slug: <compiler>-<mpi> or <compiler>-serial "
                        "(e.g. gcc-openmpi, gcc-mpich, cce-craympich, aocc-openmpi). "
                        "Legacy aliases: v1-openmpi=gcc-openmpi, v2-mpich=gcc-mpich.")
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
    args.variant = _resolve_variant(args.variant)
    _cf, _ml = _parse_variant(args.variant)
    if _cf not in _KNOWN_COMPILERS:
        print(
            f"ERROR: unknown compiler in --variant {args.variant!r}: {_cf!r}. "
            f"Known: {', '.join(sorted(_KNOWN_COMPILERS))}",
            file=sys.stderr,
        )
        sys.exit(1)
    if _ml not in _KNOWN_MPI_LANES:
        print(
            f"ERROR: unknown MPI lane in --variant {args.variant!r}: {_ml!r}. "
            f"Known: {', '.join(sorted(_KNOWN_MPI_LANES))}",
            file=sys.stderr,
        )
        sys.exit(1)
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
