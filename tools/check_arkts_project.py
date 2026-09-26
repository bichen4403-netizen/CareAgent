#!/usr/bin/env python3
"""无 SDK 依赖的 ArkTS 工程完整性检查。

这个检查不替代 DevEco Studio 的真实 HAP 构建；它专门拦截最常见、也最容易
被后端 CI 漏掉的问题：ArkTS 相对导入、main_pages 页面注册，以及媒体资源引用
指向了未提交的文件。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ETS_ROOT = ROOT / "entry" / "src" / "main" / "ets"
RESOURCE_ROOT = ROOT / "entry" / "src" / "main" / "resources"
MODULE_JSON = ROOT / "entry" / "src" / "main" / "module.json5"
MAIN_PAGES = RESOURCE_ROOT / "base" / "profile" / "main_pages.json"

RELATIVE_IMPORT = re.compile(
    r"^\s*import(?:\s+type)?[\s\S]*?\sfrom\s*['\"](\.{1,2}/[^'\"]+)['\"]",
    re.MULTILINE,
)
MEDIA_REFERENCE = re.compile(r"\$media:([A-Za-z0-9_]+)")
APP_MEDIA_REFERENCE = re.compile(r"\$r\(\s*['\"]app\.media\.([A-Za-z0-9_]+)['\"]\s*\)")
PAGE_REFERENCE = re.compile(r'"src"\s*:\s*"([^"]+)"')


def existing_ets(path: Path) -> bool:
    """ArkTS imports normally omit .ets; accept an explicit extension too."""
    candidates = [path]
    if path.suffix == "":
        candidates.append(path.with_suffix(".ets"))
        candidates.append(path / "index.ets")
    return any(candidate.is_file() for candidate in candidates)


def collect_media_names() -> set[str]:
    names: set[str] = set()
    if not RESOURCE_ROOT.is_dir():
        return names
    for item in RESOURCE_ROOT.rglob("*"):
        if item.is_file() and item.parent.name == "media":
            names.add(item.stem)
    return names


def main() -> int:
    errors: list[str] = []
    if not ETS_ROOT.is_dir():
        errors.append(f"missing ArkTS source root: {ETS_ROOT}")
    else:
        for source in sorted(ETS_ROOT.rglob("*.ets")):
            text = source.read_text(encoding="utf-8")
            for module in RELATIVE_IMPORT.findall(text):
                target = (source.parent / module).resolve()
                if not existing_ets(target):
                    errors.append(
                        f"missing relative import: {source.relative_to(ROOT)} -> {module}"
                    )

    if not MAIN_PAGES.is_file():
        errors.append(f"missing page profile: {MAIN_PAGES.relative_to(ROOT)}")
    else:
        for page in PAGE_REFERENCE.findall(MAIN_PAGES.read_text(encoding="utf-8")):
            target = ETS_ROOT / f"{page}.ets"
            if not target.is_file():
                errors.append(f"missing registered page: {page} ({target.relative_to(ROOT)})")

    media_names = collect_media_names()
    references: list[tuple[Path, str]] = []
    if MODULE_JSON.is_file():
        module_text = MODULE_JSON.read_text(encoding="utf-8")
        references.extend((MODULE_JSON, name) for name in MEDIA_REFERENCE.findall(module_text))
    for source in sorted(ETS_ROOT.rglob("*.ets")) if ETS_ROOT.is_dir() else []:
        source_text = source.read_text(encoding="utf-8")
        references.extend((source, name) for name in APP_MEDIA_REFERENCE.findall(source_text))
    for source, name in references:
        if name not in media_names:
            errors.append(
                f"missing media resource: {source.relative_to(ROOT)} -> app.media.{name}"
            )

    if errors:
        print("ArkTS static integrity check failed:")
        for error in errors:
            print(f"- {error}")
        return 1

    print("ArkTS static integrity check passed: imports, registered pages, and media references are present.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
