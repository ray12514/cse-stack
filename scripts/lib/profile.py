"""
Typed accessors for a Cluster Inspector system profile (YAML format).

Cluster Inspector emits profiles via:
  clusterinspector profile --local --format yaml --include-modules

This module loads that YAML and exposes the fields that the CSE pipeline
templates and stage scripts care about.  All accessors fail gracefully with
a sensible default rather than raising KeyError so that templates render
even when a field is absent (e.g. on a non-Cray host missing vendor_substrate).
"""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required. Install it with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


class SystemProfile:
    def __init__(self, data: Dict[str, Any]) -> None:
        self._data = data

    # ------------------------------------------------------------------
    # Loaders
    # ------------------------------------------------------------------

    @classmethod
    def from_file(cls, path: str) -> "SystemProfile":
        with open(path) as fh:
            data = yaml.safe_load(fh)
        if not isinstance(data, dict):
            raise ValueError(f"Profile at {path!r} did not parse as a YAML mapping")
        return cls(data)

    @classmethod
    def from_string(cls, text: str) -> "SystemProfile":
        data = yaml.safe_load(text)
        if not isinstance(data, dict):
            raise ValueError("Profile YAML did not parse as a mapping")
        return cls(data)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _get(self, *keys: str, default: Any = None) -> Any:
        node: Any = self._data
        for k in keys:
            if not isinstance(node, dict):
                return default
            node = node.get(k, default)
            if node is default:
                return default
        return node

    @staticmethod
    def _version_from_module_string(module_str: str) -> str:
        """Extract version from a module string like 'cray-mpich/8.1.30'."""
        if "/" in module_str:
            return module_str.split("/", 1)[1].strip()
        return module_str.strip()

    @staticmethod
    def _query_cmd(*cmd: str) -> str:
        try:
            return subprocess.check_output(
                list(cmd), stderr=subprocess.DEVNULL, text=True
            ).strip()
        except (FileNotFoundError, subprocess.CalledProcessError, OSError):
            return ""

    @staticmethod
    def _env_first(*names: str) -> str:
        for name in names:
            value = os.environ.get(name, "").strip()
            if value:
                return value
        return ""

    def _loaded_module_version(self, name_prefix: str) -> str:
        """Search modules.loaded list for a module name matching name_prefix.

        name_prefix may include a trailing '/' (e.g. 'cray-pals/') which is
        stripped before comparing against the name field of dict entries.
        """
        bare_prefix = name_prefix.rstrip("/").lower()
        for mod in self._loaded_modules():
            if isinstance(mod, dict):
                mod_name = mod.get("name", "").lower()
                # Match "cray-pals" against prefix "cray-pals" or "cray-pals/"
                if mod_name == bare_prefix or mod_name.startswith(bare_prefix + "/"):
                    version = str(mod.get("version", ""))
                    if version:
                        return version
                    name = str(mod.get("name", ""))
                    return self._version_from_module_string(name) if "/" in name else ""
            else:
                mod_str = str(mod).lower()
                if (
                    mod_str == bare_prefix
                    or mod_str.startswith(bare_prefix + "/")
                    or (bare_prefix.endswith("@") and mod_str.startswith(bare_prefix))
                ):
                    return self._version_from_module_string(str(mod))
        return ""

    def _loaded_module_prefix(self, name_prefix: str) -> str:
        """Return the prefix path for a loaded module."""
        bare_prefix = name_prefix.rstrip("/").lower()
        for mod in self._loaded_modules():
            if not isinstance(mod, dict):
                continue
            mod_name = mod.get("name", "").lower()
            if mod_name == bare_prefix or mod_name.startswith(bare_prefix + "/"):
                return mod.get("prefix", "")
        return ""

    def _loaded_module_name(self, name_prefix: str) -> str:
        """Return the loaded module name for a package, if one is present."""
        bare_prefix = name_prefix.rstrip("/").lower()
        for mod in self._loaded_modules():
            if isinstance(mod, dict):
                mod_name = str(mod.get("name", ""))
                mod_name_lower = mod_name.lower()
                if (
                    mod_name_lower == bare_prefix
                    or mod_name_lower.startswith(bare_prefix + "/")
                ):
                    if "/" in mod_name:
                        return mod_name
                    version = str(mod.get("version", ""))
                    return f"{mod_name}/{version}" if version else mod_name
            else:
                mod_str = str(mod)
                mod_str_lower = mod_str.lower()
                if (
                    mod_str_lower == bare_prefix
                    or mod_str_lower.startswith(bare_prefix + "/")
                ):
                    return mod_str
        return ""

    def _loaded_modules(self) -> List[Any]:
        loaded = self._get("modules", "loaded", default=[])
        return loaded if isinstance(loaded, list) else []

    # ------------------------------------------------------------------
    # Platform / system
    # ------------------------------------------------------------------

    def is_cray(self) -> bool:
        platform_class = self._get("system", "platform_class", default="").lower()
        env_model = self._get("system", "environment_model", default="").lower()
        vendor_source = self._get("vendor_substrate", "source", default="").lower()
        return any("cray" in v for v in (platform_class, env_model, vendor_source))

    def hostname(self) -> str:
        return self._get("system", "name", default="unknown")

    def cpu_arch(self) -> str:
        """Return the Spack target microarchitecture string."""
        # TODO: confirm the actual CPU field path against the target system
        for path in (
            ("hardware", "cpu", "microarch"),
            ("hardware", "cpu", "architecture"),
            ("hardware", "cpu", "model"),
        ):
            val = self._get(*path, default="")
            if val:
                # Normalize to a Spack target name (e.g. "zen3", "x86_64_v3")
                val = val.lower().replace(" ", "_").replace("-", "_")
                return val
        return "x86_64_v3"  # TODO: confirm against target system

    # ------------------------------------------------------------------
    # OS
    # ------------------------------------------------------------------

    def glibc_version(self) -> str:
        for path in (("os", "glibc_version"), ("os", "glibc")):
            v = self._get(*path, default="")
            if v:
                return str(v)
        return "2.34"  # TODO: confirm against target system

    def os_distro(self) -> str:
        return self._get("os", "name", default="unknown")

    # ------------------------------------------------------------------
    # Module system
    # ------------------------------------------------------------------

    def module_system(self) -> str:
        """Return 'lmod', 'tcl', or 'both'."""
        val = self._get("modules", "system", default="").lower()
        if "lmod" in val:
            return "lmod"
        if "tcl" in val or "environment" in val:
            return "tcl"
        # Fall back to checking if lmod binary is detectable from profile signals
        loaded = self._loaded_modules()
        if loaded and isinstance(loaded[0], dict) and "version" in loaded[0]:
            return "lmod"
        return "lmod"  # assume Lmod unless profile says otherwise

    # ------------------------------------------------------------------
    # Scheduler
    # ------------------------------------------------------------------

    def scheduler_type(self) -> str:
        """Return 'slurm', 'pbs', or 'unknown'."""
        return self._get("scheduler", "type", default="unknown").lower()

    def has_slurm(self) -> bool:
        if self.scheduler_type() == "slurm":
            return True
        if self._env_first("CSE_SLURM_PREFIX_OVERRIDE", "CSE_SLURM_PREFIX"):
            return True
        if self._loaded_module_version("slurm/") or self._loaded_module_prefix("slurm/"):
            return True
        return bool(shutil.which("scontrol") or shutil.which("srun"))

    def slurm_version(self) -> str:
        override = self._env_first("CSE_SLURM_VERSION_OVERRIDE", "CSE_SLURM_VERSION")
        if override:
            return override
        ver = self._loaded_module_version("slurm/")
        if ver:
            return ver
        for binary_name in ("scontrol", "srun"):
            binary = shutil.which(binary_name)
            if not binary:
                continue
            out = self._query_cmd(binary, "--version")
            match = re.search(r"slurm\s+([0-9][0-9A-Za-z_.-]*)", out, flags=re.IGNORECASE)
            if match:
                return match.group(1)
        return ""

    def slurm_prefix(self) -> str:
        override = self._env_first("CSE_SLURM_PREFIX_OVERRIDE", "CSE_SLURM_PREFIX")
        if override:
            return override
        prefix = self._loaded_module_prefix("slurm/")
        if prefix:
            return prefix
        for binary_name in ("scontrol", "srun"):
            binary = shutil.which(binary_name)
            if binary:
                return str(Path(binary).resolve().parent.parent)
        return "/usr" if self.has_slurm() else ""

    def slurm_module(self) -> str:
        return self._loaded_module_name("slurm/")

    # ------------------------------------------------------------------
    # Variant A: GCC bootstrap
    # ------------------------------------------------------------------

    def variant_a_gcc_version(self) -> str:
        # Default; override at deploy time with --gcc-version flag on deploy.sh.
        return "13.3.0"

    # ------------------------------------------------------------------
    # Variant B: Cray substrate
    # ------------------------------------------------------------------

    def prgenv_gcc_version(self) -> str:
        """GCC version inside PrgEnv-gnu on this Cray system."""
        # TODO: confirm GCC version against the target Cray system
        # Try vendor_substrate first
        prgenv = self._get("vendor_substrate", "prgenv_module", default="")
        if prgenv:
            # Some profiles emit "PrgEnv-gnu/8.3.3" or just "PrgEnv-gnu"
            ver = self._version_from_module_string(prgenv)
            if re.match(r"\d+\.\d+", ver):
                return ver

        # Try searching loaded modules for gcc/<version>
        gcc_ver = self._loaded_module_version("gcc/")
        if not gcc_ver:
            gcc_ver = self._loaded_module_version("gcc@")
        if gcc_ver:
            return gcc_ver

        return "12.3.0"  # TODO: placeholder; confirm from actual system

    def prgenv_gcc_prefix(self) -> str:
        ver = self.prgenv_gcc_version()
        prefix = self._loaded_module_prefix("gcc/")
        if prefix:
            return prefix
        return f"/opt/cray/pe/gcc/{ver}/snos"  # TODO: confirm path

    def cray_mpich_version(self) -> str:
        # TODO: confirm version from actual Cray system (filled in by Stage 1)
        mpi_mod = self._get("vendor_substrate", "mpi_module", default="")
        if mpi_mod:
            return self._version_from_module_string(mpi_mod)
        ver = self._loaded_module_version("cray-mpich/")
        return ver or "8.1.30"  # TODO: placeholder

    def cray_mpich_prefix(self) -> str:
        ver = self.cray_mpich_version()
        prefix = self._loaded_module_prefix("cray-mpich/")
        if prefix:
            return prefix
        gcc_ver = self.prgenv_gcc_version()
        gcc_major = gcc_ver.split(".")[0]
        return f"/opt/cray/pe/mpich/{ver}/ofi/gnu/{gcc_major}.{gcc_ver.split('.')[1]}"  # TODO: confirm

    def cray_libsci_version(self) -> str:
        # TODO: confirm version from actual Cray system
        ver = self._loaded_module_version("cray-libsci/")
        return ver or "23.12.5"  # TODO: placeholder

    def cray_libsci_prefix(self) -> str:
        ver = self.cray_libsci_version()
        prefix = self._loaded_module_prefix("cray-libsci/")
        if prefix:
            return prefix
        gcc_ver = self.prgenv_gcc_version()
        return f"/opt/cray/pe/libsci/{ver}/gnu/{gcc_ver.split('.')[0]}.{gcc_ver.split('.')[1]}"  # TODO: confirm

    def has_cray_pals(self) -> bool:
        """True if cray-pals is present (PBS Cray systems; absent on Slurm Cray)."""
        ver = self._loaded_module_version("cray-pals/")
        return bool(ver)

    def cray_pals_version(self) -> str:
        # TODO: confirm version from actual Cray system
        return self._loaded_module_version("cray-pals/") or "1.4.0"  # TODO: placeholder

    def cray_pals_prefix(self) -> str:
        ver = self.cray_pals_version()
        prefix = self._loaded_module_prefix("cray-pals/")
        return prefix or f"/opt/cray/pe/pals/{ver}"  # TODO: confirm

    # ------------------------------------------------------------------
    # Libfabric (OFI) — present on Cray/Slingshot systems
    # ------------------------------------------------------------------

    def has_libfabric(self) -> bool:
        return bool(
            self._env_first("CSE_LIBFABRIC_VERSION_OVERRIDE", "CSE_LIBFABRIC_VERSION")
            or self._env_first("CSE_LIBFABRIC_PREFIX_OVERRIDE", "CSE_LIBFABRIC_PREFIX")
            or self._loaded_module_version("libfabric/")
            or self._loaded_module_prefix("libfabric/")
        )

    def libfabric_version(self) -> str:
        return (
            self._env_first("CSE_LIBFABRIC_VERSION_OVERRIDE", "CSE_LIBFABRIC_VERSION")
            or self._loaded_module_version("libfabric/")
            or ""
        )

    def libfabric_prefix(self) -> str:
        ver = self.libfabric_version()
        prefix = (
            self._env_first("CSE_LIBFABRIC_PREFIX_OVERRIDE", "CSE_LIBFABRIC_PREFIX")
            or self._loaded_module_prefix("libfabric/")
        )
        if prefix:
            return prefix
        return f"/opt/cray/pe/libfabric/{ver}" if ver else ""

    def libfabric_module(self) -> str:
        return self._loaded_module_name("libfabric/")

    # ------------------------------------------------------------------
    # PMIx — required for Slurm-launched MPICH pmi=pmix builds
    # ------------------------------------------------------------------

    def _pkg_config_value(self, package: str, *args: str) -> str:
        pkg_config = shutil.which("pkg-config")
        if not pkg_config:
            return ""
        return self._query_cmd(pkg_config, *args, package)

    def has_pmix(self) -> bool:
        return bool(
            self._env_first("CSE_PMIX_VERSION_OVERRIDE", "CSE_PMIX_VERSION")
            or self._env_first("CSE_PMIX_PREFIX_OVERRIDE", "CSE_PMIX_PREFIX")
            or self._loaded_module_version("pmix/")
            or self._loaded_module_prefix("pmix/")
            or self._pkg_config_value("pmix", "--modversion")
        )

    def pmix_version(self) -> str:
        return (
            self._env_first("CSE_PMIX_VERSION_OVERRIDE", "CSE_PMIX_VERSION")
            or self._loaded_module_version("pmix/")
            or self._pkg_config_value("pmix", "--modversion")
            or ""
        )

    def pmix_prefix(self) -> str:
        override = self._env_first("CSE_PMIX_PREFIX_OVERRIDE", "CSE_PMIX_PREFIX")
        if override:
            return override
        prefix = self._loaded_module_prefix("pmix/")
        if prefix:
            return prefix
        ver = self._loaded_module_version("pmix/")
        if ver:
            return f"/opt/cray/pe/pmix/{ver}"
        prefix = self._pkg_config_value("pmix", "--variable=prefix")
        if prefix:
            return prefix
        ver = self.pmix_version()
        return f"/opt/cray/pe/pmix/{ver}" if ver else ""

    def pmix_module(self) -> str:
        return self._loaded_module_name("pmix/")

    def mpich_version_for_spack(self) -> str:
        """Map detected cray-mpich series to an ABI-compatible upstream MPICH version.

        cray-mpich 8.x is based on MPICH 3.4.x; cray-mpich 9.x on MPICH 4.x.
        Matching versions preserves ABI compatibility for a future Phase 2 splice.
        """
        cray_ver = self.cray_mpich_version()
        if cray_ver.startswith("9."):
            return "4.2.2"
        if cray_ver.startswith("8."):
            return "3.4.3"
        return "4.2.2"  # non-Cray or undetected: use latest stable

    def cray_cpu_arch(self) -> str:
        """Spack target for Cray compute nodes (e.g. zen3, cascadelake)."""
        arch = self.cpu_arch()
        # If the generic profiler didn't find a Cray-specific arch, default to zen3
        if arch in ("x86_64", "x86_64_v3", "unknown"):
            return "zen3"  # TODO: confirm against actual Cray node CPU
        return arch
