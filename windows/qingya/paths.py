"""路径净化、去重命名、字节显示。"""

from __future__ import annotations

import os
import re
import stat

JUNK_NAMES = {
    ".ds_store", "__macosx", ".spotlight-v100", ".trashes", ".fseventsd",
    ".temporaryitems", "icon\r", ".localized", "thumbs.db", "ehthumbs.db",
    "desktop.ini",
}
RESERVED = {"CON", "PRN", "AUX", "NUL"} | {f"COM{i}" for i in range(1, 10)} | {f"LPT{i}" for i in range(1, 10)}
_ILLEGAL = re.compile(r'[<>:"|?*\x00-\x1f]')


def clean(path: str, windows_separators: bool = True) -> str | None:
    """变成安全的相对路径。含 .. 的整条拒绝（Zip Slip）。"""
    text = path.replace("\\", "/") if windows_separators else path
    parts: list[str] = []
    for comp in text.split("/"):
        if comp in ("", "."):
            continue
        if comp == "..":
            return None
        comp = _ILLEGAL.sub("_", comp).rstrip(" .")
        if not comp:
            comp = "_"
        stem = comp.split(".", 1)[0].upper()
        if stem in RESERVED:
            comp = "_" + comp
        parts.append(comp)
    if not parts:
        return None
    return "/".join(parts)


def is_junk_name(name: str) -> bool:
    base = name.replace("\r", "")
    lower = base.lower()
    return lower in JUNK_NAMES or base.startswith("._") or lower.startswith("._")


def is_junk_relative(relative: str) -> bool:
    parts = [p for p in relative.split("/") if p]
    if parts and parts[0].lower() == "__macosx":
        return True
    return bool(parts) and is_junk_name(parts[-1])


def split_extension(name: str) -> tuple[str, str]:
    match = re.match(r"^(.+?)((?:\.tar)?\.[A-Za-z0-9]{1,5}\.\d{3}|\.tar\.[A-Za-z0-9]{1,4})$", name)
    if match:
        return match.group(1), match.group(2)
    stem, ext = os.path.splitext(name)
    if ext and len(ext) < len(name):
        return stem, ext
    return name, ""


def exists(path: str) -> bool:
    try:
        os.lstat(path)
        return True
    except OSError:
        return False


def unique_path(directory: str, name: str, is_directory: bool = False, also_avoid: list[str] | None = None) -> str:
    """重名变成「资料 2」「报告 2.txt」，永不覆盖。"""
    stem, ext = (name, "") if is_directory else split_extension(name)
    extra = also_avoid or []
    n = 1
    while True:
        candidate = stem + ext if n == 1 else f"{stem} {n}{ext}"
        path = os.path.join(directory, candidate)
        taken = exists(path) or any(exists(path + suffix) for suffix in extra)
        if not taken:
            return path
        n += 1


def is_within(root: str, path: str) -> bool:
    root_real = os.path.abspath(root)
    parent = os.path.abspath(path if os.path.isdir(path) else os.path.dirname(path))
    try:
        return os.path.commonpath([root_real, parent]) == root_real
    except ValueError:
        return False


def format_bytes(n: int) -> str:
    value = float(max(0, n))
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            if unit == "B":
                return f"{int(value)} B"
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{int(n)} B"


def file_size(path: str) -> int:
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def is_dir(path: str) -> bool:
    try:
        return stat.S_ISDIR(os.lstat(path).st_mode)
    except OSError:
        return False


def is_link(path: str) -> bool:
    try:
        return stat.S_ISLNK(os.lstat(path).st_mode)
    except OSError:
        return False
