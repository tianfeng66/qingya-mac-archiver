"""压缩。先写到隐藏临时目录，成功后再改名搬出来；取消或失败不留半截文件。"""

from __future__ import annotations

import os
import shutil
import stat
import tarfile
import uuid
import zipfile

import py7zr
import pyzipper

from .errors import failed, not_writable
from .paths import is_junk_name, unique_path

CHUNK = 1024 * 1024


class CompressOptions:
    def __init__(self):
        self.format = "zip"
        self.level = 5
        self.password: str | None = None
        self.volume_size: int | None = None
        self.exclude_junk = True


class Record:
    def __init__(self, path: str, arcname: str, kind: str, size: int):
        self.path = path
        self.arcname = arcname
        self.kind = kind
        self.size = size


def _inside(path: str, root: str | None) -> bool:
    if not root:
        return False
    try:
        return os.path.commonpath([os.path.abspath(path), os.path.abspath(root)]) == os.path.abspath(root)
    except ValueError:
        return False


def _arcname(root_item: str, path: str) -> str:
    parent = os.path.dirname(os.path.abspath(root_item))
    rel = os.path.relpath(os.path.abspath(path), parent)
    return rel.replace("\\", "/")


def collect(items: list[str], exclude_junk: bool, excluding: str | None, cancel) -> list[Record]:
    records: list[Record] = []
    for item in items:
        cancel.check()
        if not os.path.exists(item) and not os.path.islink(item):
            raise failed(f"找不到「{os.path.basename(item)}」")
        if _inside(item, excluding):
            continue
        top = os.path.basename(item.rstrip(os.sep)) or item
        st = os.lstat(item)
        if stat.S_ISLNK(st.st_mode):
            records.append(Record(item, top, "symlink", 0))
            continue
        if stat.S_ISDIR(st.st_mode):
            records.append(Record(item, top, "dir", 0))
            for dirpath, dirnames, filenames in os.walk(item, followlinks=False):
                cancel.check()
                kept_dirs = []
                for name in dirnames:
                    full = os.path.join(dirpath, name)
                    if _inside(full, excluding):
                        continue
                    if exclude_junk and is_junk_name(name):
                        continue
                    kept_dirs.append(name)
                    records.append(Record(full, _arcname(item, full), "dir", 0))
                dirnames[:] = kept_dirs
                for name in filenames:
                    full = os.path.join(dirpath, name)
                    if exclude_junk and is_junk_name(name):
                        continue
                    if _inside(full, excluding):
                        continue
                    if os.path.islink(full):
                        records.append(Record(full, _arcname(item, full), "symlink", 0))
                    elif os.path.isfile(full):
                        try:
                            size = os.path.getsize(full)
                        except OSError:
                            size = 0
                        records.append(Record(full, _arcname(item, full), "file", size))
            continue
        if os.path.isfile(item):
            try:
                size = os.path.getsize(item)
            except OSError:
                size = 0
            records.append(Record(item, top, "file", size))
        else:
            raise failed(f"无法读取「{top}」")
    return records


def _zip_level(level: int) -> int:
    if level <= 1:
        return 1
    if level >= 9:
        return 9
    return 6


def _write_zip(records: list[Record], dest: str, level: int, password: str | None, cancel, progress, total: int) -> None:
    compression = zipfile.ZIP_STORED if level == 0 else zipfile.ZIP_DEFLATED
    kwargs = {}
    if level != 0:
        kwargs["compresslevel"] = _zip_level(level)
    if password:
        archive = pyzipper.AESZipFile(
            dest, "w", compression=compression, encryption=pyzipper.WZ_AES, **kwargs
        )
        archive.setpassword(password.encode("utf-8"))
    else:
        archive = zipfile.ZipFile(dest, "w", compression=compression, **kwargs)
    done = 0
    with archive:
        for record in records:
            cancel.check()
            if record.kind == "dir":
                info = zipfile.ZipInfo(record.arcname.rstrip("/") + "/")
                info.external_attr = (0o40755 << 16) | 0x10
                archive.writestr(info, b"")
                continue
            if record.kind == "symlink":
                # zip 没有通用的符号链接。指向包内文件时存一份副本，指向外面的直接跳过。
                root = os.path.dirname(record.path)
                if not _link_is_inside_file(record.path, root):
                    continue
                archive.write(record.path, record.arcname)
                continue
            archive.write(record.path, record.arcname)
            done += record.size
            progress(min(1, done / total), record.arcname)


def _link_is_inside_file(path: str, root: str) -> bool:
    try:
        real = os.path.realpath(path)
        root_real = os.path.realpath(root)
        if not os.path.isfile(real):
            return False
        return os.path.commonpath([real, root_real]) == root_real
    except (OSError, ValueError):
        return False


def _7z_filters(level: int):
    if level == 0:
        return [{"id": py7zr.FILTER_COPY}]
    preset = 1 if level <= 1 else 9 if level >= 9 else 5
    return [{"id": py7zr.FILTER_LZMA2, "preset": preset}]


def _write_7z(records: list[Record], dest: str, level: int, password: str | None, cancel, progress, total: int) -> None:
    done = 0
    with py7zr.SevenZipFile(
        dest,
        "w",
        password=password or None,
        header_encryption=bool(password),
        filters=_7z_filters(level),
    ) as archive:
        for record in records:
            cancel.check()
            if record.kind != "file":
                continue
            archive.write(record.path, record.arcname)
            done += record.size
            progress(min(1, done / total), record.arcname)


def _write_tar(records: list[Record], dest: str, fmt: str, level: int, cancel, progress, total: int) -> None:
    mapped = {0: 1, 1: 1, 5: 6, 9: 9}.get(level, 6)
    if fmt == "tar":
        mode, kwargs = "w", {}
    elif fmt == "tar.gz":
        mode, kwargs = "w:gz", {"compresslevel": mapped}
    elif fmt == "tar.bz2":
        mode, kwargs = "w:bz2", {"compresslevel": mapped}
    elif fmt == "tar.xz":
        mode, kwargs = "w:xz", {"preset": min(9, mapped)}
    else:
        raise failed(f"不支持的压缩格式：{fmt}")
    done = 0
    with tarfile.open(dest, mode, **kwargs) as archive:
        for record in records:
            cancel.check()
            archive.add(record.path, arcname=record.arcname, recursive=False)
            done += record.size
            progress(min(1, done / total), record.arcname)


def _split(path: str, volume_size: int | None, directory: str, name: str) -> list[str]:
    if not volume_size or volume_size <= 0:
        return [path]
    size = os.path.getsize(path)
    if size <= volume_size:
        return [path]
    parts = []
    with open(path, "rb") as src:
        index = 1
        while True:
            remaining = volume_size
            part = os.path.join(directory, f"{name}.{index:03d}")
            wrote = 0
            with open(part, "wb") as out:
                while remaining > 0:
                    chunk = src.read(min(CHUNK, remaining))
                    if not chunk:
                        break
                    out.write(chunk)
                    wrote += len(chunk)
                    remaining -= len(chunk)
            if wrote == 0:
                os.remove(part)
                break
            parts.append(part)
            index += 1
    os.remove(path)
    return parts


def compress(items: list[str], output: str, options: CompressOptions, cancel, progress) -> list[str]:
    destination = os.path.dirname(os.path.abspath(output)) or "."
    try:
        os.makedirs(destination, exist_ok=True)
    except OSError as exc:
        raise not_writable(destination) from exc
    staging = os.path.join(destination, ".qingya-" + uuid.uuid4().hex[:8])
    try:
        os.makedirs(staging)
    except OSError as exc:
        raise not_writable(destination) from exc
    try:
        progress(-1, "正在统计文件…")
        records = collect(items, options.exclude_junk, staging, cancel)
        total = max(sum(record.size for record in records), 1)
        name = os.path.basename(output)
        staged = os.path.join(staging, name)
        password = options.password or None
        if options.format == "zip":
            _write_zip(records, staged, options.level, password, cancel, progress, total)
        elif options.format == "7z":
            _write_7z(records, staged, options.level, password, cancel, progress, total)
        elif options.format in ("tar", "tar.gz", "tar.bz2", "tar.xz"):
            if password:
                raise failed("TAR 不能设密码，请改用 ZIP 或 7Z。")
            _write_tar(records, staged, options.format, options.level, cancel, progress, total)
        else:
            raise failed(f"不支持的压缩格式：{options.format}")
        cancel.check()
        parts = _split(staged, options.volume_size, staging, name)
        moved = []
        if len(parts) == 1:
            target = unique_path(destination, name, also_avoid=[".001"])
            shutil.move(parts[0], target)
            moved.append(target)
        else:
            for part in parts:
                target = unique_path(destination, os.path.basename(part))
                shutil.move(part, target)
                moved.append(target)
        progress(1, "完成")
        return moved
    finally:
        shutil.rmtree(staging, ignore_errors=True)
