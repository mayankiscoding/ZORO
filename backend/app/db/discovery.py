"""ORM model discovery by package name.

Every package keeps its models in `app/<pkg>/models.py` on the shared `Base`. Importing those
modules is all it takes for `Base.metadata` to know the tables, so nobody edits a shared file.
"""

from __future__ import annotations

import importlib
import importlib.util
import logging
from collections.abc import Iterable, Sequence

log = logging.getLogger(__name__)

#: Kernel packages that own tables.
KERNEL_MODEL_PACKAGES: tuple[str, ...] = ("app.security", "app.tools")


def module_exists(name: str) -> bool:
    """True when `name` can be imported. A missing parent package counts as "does not exist";
    an error raised while importing an existing parent propagates."""
    try:
        return importlib.util.find_spec(name) is not None
    except ModuleNotFoundError as exc:
        missing = exc.name or ""
        if missing and (name == missing or name.startswith(missing + ".")):
            return False
        raise


def model_packages(plugin_modules: Iterable[str] | None = None) -> tuple[str, ...]:
    """Kernel packages plus the package of every plugin module ("app.finance.plugin" -> "app.finance")."""
    if plugin_modules is None:
        from app.plugins import PLUGIN_MODULES

        plugin_modules = PLUGIN_MODULES
    packages = list(KERNEL_MODEL_PACKAGES)
    for module in plugin_modules:
        package = module.rsplit(".", 1)[0]
        if package not in packages:
            packages.append(package)
    return tuple(packages)


def import_models(packages: Sequence[str] | None = None) -> list[str]:
    """Import `<package>.models` for each package that has one. Returns the modules imported."""
    imported: list[str] = []
    for package in packages if packages is not None else model_packages():
        name = f"{package}.models"
        if not module_exists(name):
            continue
        importlib.import_module(name)
        imported.append(name)
    log.debug("orm models discovered", extra={"modules": imported})
    return imported
