"""格式、分卷、文件夹命名。规则与 macOS 版 Sources/Engine/Formats.swift 对齐。"""

from __future__ import annotations

import os
import re

EXTENSIONS = {
    "zip", "zipx", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz",
    "zst", "tzst", "lz4", "lzma", "tlz", "z", "taz", "cab", "iso", "lzh", "lha",
    "cpio", "xar", "cbz", "cbr", "cb7", "deb", "rpm", "ar", "warc",
}
STRIPPABLE = EXTENSIONS | {"001"}

FORMATS = [
    ("zip", "ZIP", "兼容性最好，Windows / 手机都能直接打开", True, True),
    ("7z", "7Z", "压缩率高，对方需要 7-Zip / 解压软件", True, True),
    ("tar", "TAR", "只打包不压缩，速度最快", False, False),
    ("tar.gz", "TAR.GZ", "Linux / 服务器常用，兼容性好", True, False),
    ("tar.bz2", "TAR.BZ2", "比 gzip 小一点，也慢一点", True, False),
    ("tar.xz", "TAR.XZ", "压缩率很高，适合大文件归档", True, False),
]

LEVELS = [(0, "仅存储"), (1, "快速"), (5, "标准"), (9, "最高")]

VOLUME_CHOICES = [
    (0, "不分卷"),
    (25, "25 MB（邮件附件）"),
    (100, "100 MB"),
    (500, "500 MB"),
    (1000, "1 GB"),
    (2000, "2 GB"),
    (4000, "4 GB（FAT32 U 盘）"),
]


def is_archive(path: str) -> bool:
    if os.path.isdir(path):
        return False
    name = os.path.basename(path).lower()
    if re.search(r"\.(\d{3}|r\d{2})$", name):
        return True
    return os.path.splitext(name)[1].lstrip(".") in EXTENSIONS


def base_name(path: str) -> str:
    name = os.path.basename(path)
    for pattern in (r"\.\d{3}$", r"\.part\d+\.rar$"):
        name = re.sub(pattern, "", name, flags=re.IGNORECASE)
    while True:
        stem, ext = os.path.splitext(name)
        if not ext or ext.lower().lstrip(".") not in STRIPPABLE or not stem:
            break
        name = stem
    return name or "解压结果"


def _collect(directory: str, make, start: int) -> list[str]:
    found = []
    i = start
    while True:
        candidate = os.path.join(directory, make(i))
        if not os.path.isfile(candidate):
            break
        found.append(candidate)
        i += 1
    return found


def volumes_for(path: str) -> list[str]:
    """找齐分卷：x.7z.001、x.part1.rar、x.rar + x.r00。"""
    directory = os.path.dirname(path) or "."
    name = os.path.basename(path)

    m = re.match(r"^(.*)\.(\d{3})$", name)
    if m:
        base = m.group(1)
        found = _collect(directory, lambda i: f"{base}.{i:03d}", 1)
        return found or [path]

    m = re.match(r"^(.*)\.part(\d+)\.rar$", name, re.IGNORECASE)
    if m:
        base, width = m.group(1), len(m.group(2))
        ext = os.path.splitext(name)[1]
        found = _collect(directory, lambda i, w=width, e=ext: f"{base}.part{i:0{w}d}{e}", 1)
        return found or [path]

    lower = name.lower()
    if re.search(r"\.r\d{2}$", lower):
        rar = os.path.splitext(path)[0] + ".rar"
        if os.path.isfile(rar):
            return volumes_for(rar)
    if lower.endswith(".rar"):
        stem = os.path.splitext(name)[0]
        old = _collect(directory, lambda i: f"{stem}.r{i:02d}", 0)
        return [path] + old
    return [path]


def total_size(paths: list[str]) -> int:
    total = 0
    for path in paths:
        try:
            total += os.path.getsize(path)
        except OSError:
            pass
    return total


def format_title(fmt: str) -> str:
    for key, title, *_ in FORMATS:
        if key == fmt:
            return title
    return fmt.upper()


def supports_level(fmt: str) -> bool:
    return fmt != "tar"


def supports_password(fmt: str) -> bool:
    return fmt in ("zip", "7z")


def supports_store(fmt: str) -> bool:
    return fmt in ("zip", "7z")


def level_title(level: int) -> str:
    for value, title in LEVELS:
        if value == level:
            return title
    return "标准"
