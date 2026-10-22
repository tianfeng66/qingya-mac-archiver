"""列目录、解压、测试。先写到隐藏临时目录，成功后再搬出来，失败就整段删掉。"""

from __future__ import annotations

import gzip
import io
import lzma
import os
import shutil
import tarfile
import time
import uuid
import zipfile
import bz2

import py7zr
import pyzipper

from .charset import decode_name, detect
from .errors import ArchiveError, Cancelled, failed, not_writable, password_required, unsupported, wrong_password
from .formats import base_name, total_size, volumes_for
from .paths import clean, format_bytes, is_junk_relative, unique_path
from .sevenzip import entries_from_7z, extract_with_7z, find_7z, test_with_7z
from .volume import MultiVolume

CHUNK = 1024 * 1024


class CancelToken:
    def __init__(self):
        self._cancelled = False

    def cancel(self) -> None:
        self._cancelled = True

    @property
    def cancelled(self) -> bool:
        return self._cancelled

    def check(self) -> None:
        if self._cancelled:
            raise Cancelled()


class Item:
    def __init__(self, path: str, is_directory: bool, size: int, modified: float | None, encrypted: bool):
        self.path = path
        self.is_directory = is_directory
        self.size = size
        self.modified = modified
        self.encrypted = encrypted

    @property
    def name(self) -> str:
        return self.path.rsplit("/", 1)[-1]


class Listing:
    def __init__(self, items: list[Item], format_name: str, has_encrypted: bool, legacy_encoding: str | None):
        self.items = items
        self.format_name = format_name
        self.has_encrypted = has_encrypted
        self.legacy_encoding = legacy_encoding

    @property
    def total_size(self) -> int:
        return sum(item.size for item in self.items)

    @property
    def file_count(self) -> int:
        return sum(1 for item in self.items if not item.is_directory)


class ExtractOptions:
    def __init__(self, destination: str):
        self.destination = destination
        self.folder_mode = "smart"
        self.skip_junk = True
        self.encoding = "auto"
        self.password: str | None = None
        self.candidate_passwords: list[str] = []
        self.selection: set[str] | None = None
        self.strip_prefix: str | None = None
        self.propagate_mark = True


def sniff(path: str) -> str:
    with open(path, "rb") as handle:
        head = handle.read(300)
        if len(head) >= 262 and head[257:262] == b"ustar":
            return "tar"
    if head.startswith(b"PK\x03\x04") or head.startswith(b"PK\x05\x06") or head.startswith(b"PK\x07\x08"):
        return "zip"
    if head.startswith(b"7z\xbc\xaf'\x1c"):
        return "7z"
    if head.startswith(b"Rar!\x1a\x07"):
        return "rar"
    if head.startswith(b"\x1f\x8b"):
        return "gz"
    if head.startswith(b"BZh"):
        return "bz2"
    if head.startswith(b"\xfd7zXZ\x00"):
        return "xz"
    if head.startswith(b"MSCF"):
        return "cab"
    if head.startswith(b"\x28\xb5\x2f\xfd"):
        return "zstd"
    if head.startswith(b"\x04\x22\x4d\x18"):
        return "lz4"
    ext = os.path.splitext(path)[1].lower().lstrip(".")
    if ext in ("tar", "tgz", "tbz", "tbz2", "txz"):
        return "tar"
    if ext == "zip" or ext == "zipx" or ext == "cbz":
        return "zip"
    if ext in ("7z", "cb7"):
        return "7z"
    if ext in ("rar", "cbr"):
        return "rar"
    return ext or "unknown"


def _ordered_passwords(options: ExtractOptions) -> list[str]:
    seen = set()
    out = []
    for password in [options.password, *options.candidate_passwords]:
        if password and password not in seen:
            seen.add(password)
            out.append(password)
    return out[:60]


def _open_source(volumes: list[str]):
    if len(volumes) == 1:
        return open(volumes[0], "rb")
    return MultiVolume(volumes)


def _zip_raw_name(info: zipfile.ZipInfo):
    name = info.filename
    if info.flag_bits & 0x800:
        return name
    try:
        raw = name.encode("cp437")
    except UnicodeEncodeError:
        return name
    if all(byte < 128 for byte in raw):
        return raw.decode("ascii")
    return raw


def _encoding_for(samples: list[bytes], requested: str) -> str | None:
    if not samples:
        return None
    if requested and requested != "auto":
        return requested
    return detect(samples)


def _is_selected(path: str, selection: set[str] | None) -> bool:
    if selection is None:
        return True
    if path in selection:
        return True
    parent = path
    while "/" in parent:
        parent = parent.rsplit("/", 1)[0]
        if parent in selection:
            return True
    return False


def _stripped(path: str, prefix: str | None) -> str | None:
    if not prefix:
        return path
    if path == prefix:
        return None
    head = prefix.rstrip("/") + "/"
    if path.startswith(head):
        return path[len(head):]
    return None


def list_archive(path: str, encoding: str = "auto", password: str | None = None,
                 candidates: list[str] | None = None) -> Listing:
    options = ExtractOptions(os.path.dirname(path) or ".")
    options.encoding = encoding
    options.password = password
    options.candidate_passwords = list(candidates or [])
    volumes = volumes_for(path)
    kind = sniff(volumes[0])
    if kind == "zip":
        return _list_zip(volumes, options)
    if kind == "7z":
        return _list_7z(volumes, options)
    if kind in ("tar", "gz", "bz2", "xz"):
        return _list_tar(volumes, options, kind)
    if kind in ("rar", "cab", "iso", "zstd", "lz4"):
        return _list_external(volumes[0], options, kind)
    raise unsupported(f"暂不支持这个格式（{kind}）。可以先用 7-Zip 解开，或换 zip / 7z / rar / tar.gz。")


def _list_zip(volumes: list[str], options: ExtractOptions) -> Listing:
    source = _open_source(volumes)
    try:
        with pyzipper.AESZipFile(source) as archive:
            infos = archive.infolist()
            samples = []
            raws = []
            for info in infos:
                raw = _zip_raw_name(info)
                raws.append(raw)
                if isinstance(raw, bytes):
                    samples.append(raw)
            chosen = _encoding_for(samples, options.encoding)
            items = []
            for info, raw in zip(infos, raws):
                text = decode_name(raw, chosen)
                safe = clean(text, windows_separators=True)
                if safe is None:
                    continue
                modified = None
                try:
                    modified = time.mktime(info.date_time + (0, 0, -1))
                except (OverflowError, ValueError):
                    modified = None
                items.append(Item(
                    safe,
                    info.is_dir() or safe.endswith("/"),
                    info.file_size,
                    modified,
                    bool(info.flag_bits & 0x1),
                ))
            return Listing(items, "ZIP", any(item.encrypted for item in items), chosen if samples else None)
    except (zipfile.BadZipFile, pyzipper.zipfile.BadZipFile) as exc:
        raise failed(f"文件不完整或已损坏（{exc}）") from exc
    finally:
        source.close()


def _passwords_to_try(options: ExtractOptions, encrypted: bool) -> list[str | None]:
    if not encrypted:
        return [None]
    found = _ordered_passwords(options)
    if not found:
        raise password_required() if not options.password else wrong_password()
    return found


def _list_7z(volumes: list[str], options: ExtractOptions) -> Listing:
    source = _open_source(volumes)
    last_error: Exception | None = None
    passwords = [None, *_ordered_passwords(options)]
    # 没加密的包用 None 就能打开；加密文件名时要试密码。
    seen = set()
    ordered: list[str | None] = []
    for password in passwords:
        if password not in seen:
            seen.add(password)
            ordered.append(password)
    try:
        for password in ordered:
            source.seek(0)
            try:
                with py7zr.SevenZipFile(source, mode="r", password=password) as archive:
                    items = []
                    for info in archive.list():
                        safe = clean(info.filename, windows_separators=True)
                        if safe is None:
                            continue
                        modified = info.creationtime.timestamp() if getattr(info, "creationtime", None) else None
                        items.append(Item(safe, bool(info.is_directory), int(info.uncompressed or 0), modified, False))
                    return Listing(items, "7Z", password is not None and bool(options.password or options.candidate_passwords) and False, None)
            except py7zr.exceptions.PasswordRequired as exc:
                last_error = exc
                continue
            except Exception as exc:
                text = str(exc).lower()
                if "password" in text or "corrupt" in text and password:
                    last_error = exc
                    continue
                if password is None and ("password" in text or type(exc).__name__ in ("PasswordRequired", "CrcError")):
                    last_error = exc
                    continue
                raise
        if last_error is not None:
            raise password_required() if not options.password else wrong_password()
        raise failed("无法读取这个 7z")
    finally:
        source.close()


def _tar_member_name(member: tarfile.TarInfo) -> str:
    name = member.name
    try:
        raw = name.encode("utf-8")
        name.encode("utf-8")
        return name
    except UnicodeError:
        return name


def _list_tar(volumes: list[str], options: ExtractOptions, kind: str) -> Listing:
    source = _open_source(volumes)
    try:
        try:
            archive = tarfile.open(fileobj=source, mode="r:*")
        except tarfile.ReadError:
            source.seek(0)
            return _list_single_stream(volumes[0], kind)
        with archive:
            items = []
            for member in archive.getmembers():
                safe = clean(member.name, windows_separators=False)
                if safe is None:
                    continue
                items.append(Item(
                    safe,
                    member.isdir(),
                    member.size if member.isfile() else 0,
                    member.mtime,
                    False,
                ))
            label = {"gz": "TAR.GZ", "bz2": "TAR.BZ2", "xz": "TAR.XZ", "tar": "TAR"}.get(kind, "TAR")
            if kind == "gz" and not volumes[0].lower().endswith((".tar.gz", ".tgz")):
                # tarfile 能开，说明确实是 tar.gz
                label = "TAR.GZ"
            return Listing(items, label, False, None)
    finally:
        source.close()


def _list_single_stream(path: str, kind: str) -> Listing:
    name = base_name(path)
    safe = clean(name, windows_separators=True) or "解压结果"
    size = 0
    opener = {"gz": gzip.open, "bz2": bz2.open, "xz": lzma.open}.get(kind)
    if opener is None:
        raise unsupported("这个文件不是压缩包。")
    try:
        with opener(path, "rb") as handle:
            while True:
                chunk = handle.read(CHUNK)
                if not chunk:
                    break
                size += len(chunk)
    except OSError as exc:
        raise failed(f"文件不完整或已损坏（{exc}）") from exc
    label = {"gz": "GZIP", "bz2": "BZIP2", "xz": "XZ"}.get(kind, kind.upper())
    return Listing([Item(safe, False, size, None, False)], label, False, None)


def _list_external(path: str, options: ExtractOptions, kind: str) -> Listing:
    passwords = _ordered_passwords(options)
    last = None
    tries: list[tuple[str | None, bool]] = [(None, False)]
    for password in passwords:
        tries.append((password, password == options.password))
    for password, supplied in tries:
        try:
            entries, encrypted = entries_from_7z(path, password, supplied or bool(options.password))
            items = [Item(entry["path"], entry["is_directory"], entry["size"], None, entry["encrypted"]) for entry in entries]
            label = {"rar": "RAR", "cab": "CAB", "iso": "ISO", "zstd": "ZSTD", "lz4": "LZ4"}.get(kind, kind.upper())
            return Listing(items, label + "（7-Zip）", encrypted, None)
        except ArchiveError as exc:
            last = exc
            if exc.code in ("password", "wrong_password"):
                continue
            raise
    if last is not None:
        raise last
    raise password_required()


def extract(path: str, options: ExtractOptions, cancel: CancelToken, progress) -> dict:
    destination = options.destination
    try:
        os.makedirs(destination, exist_ok=True)
        probe = os.path.join(destination, ".qingya-write-test")
        with open(probe, "wb") as handle:
            handle.write(b"")
        os.remove(probe)
    except OSError as exc:
        raise not_writable(destination) from exc

    staging = os.path.join(destination, ".qingya-" + uuid.uuid4().hex[:8])
    try:
        os.makedirs(staging)
    except OSError as exc:
        raise not_writable(destination) from exc

    volumes = volumes_for(path)
    kind = sniff(volumes[0])
    result = {"outputs": [], "file_count": 0, "skipped": 0, "used_password": None, "used_7z": False}
    try:
        progress(-1, "正在读取压缩包…")
        if kind in ("rar", "cab", "iso", "zstd", "lz4"):
            _extract_external(volumes[0], staging, options, cancel, progress, result)
            result["used_7z"] = True
        else:
            try:
                _extract_native(volumes, kind, staging, options, cancel, progress, result)
            except ArchiveError as exc:
                if exc.code in ("unsupported", "password", "wrong_password") and kind == "7z" and find_7z():
                    if exc.code in ("password", "wrong_password") and not _ordered_passwords(options) and not options.password:
                        raise
                    # 原生引擎搞不定时，交给附带的 7-Zip 再试一次。
                    if exc.code == "unsupported" or (exc.code in ("password", "wrong_password") and find_7z()):
                        shutil.rmtree(staging, ignore_errors=True)
                        os.makedirs(staging)
                        result = {"outputs": [], "file_count": 0, "skipped": 0, "used_password": options.password, "used_7z": True}
                        _extract_external(volumes[0], staging, options, cancel, progress, result)
                    else:
                        raise
                else:
                    raise
        cancel.check()
        mark = _read_mark(volumes[0]) if options.propagate_mark else None
        if mark:
            _apply_mark_tree(staging, mark)
        result["outputs"] = finalize(staging, destination, base_name(path), options.folder_mode)
        progress(1, "完成")
        return result
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    finally:
        if os.path.isdir(staging):
            # 成功时这个目录已经被搬走；失败时这里再清一次。
            shutil.rmtree(staging, ignore_errors=True)


def _extract_native(volumes, kind, staging, options, cancel, progress, result) -> None:
    if kind == "zip":
        _extract_zip(volumes, staging, options, cancel, progress, result)
    elif kind == "7z":
        _extract_7z(volumes, staging, options, cancel, progress, result)
    elif kind in ("tar", "gz", "bz2", "xz"):
        _extract_tar(volumes, kind, staging, options, cancel, progress, result)
    else:
        raise unsupported(f"暂不支持这个格式（{kind}）。")


def _copy_stream(src, dest_path: str, cancel: CancelToken, progress, done_box: list[int], total: int | None, label: str) -> int:
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    written = 0
    with open(dest_path, "wb") as out:
        while True:
            cancel.check()
            chunk = src.read(CHUNK)
            if not chunk:
                break
            out.write(chunk)
            written += len(chunk)
            done_box[0] += len(chunk)
            if total:
                progress(min(1, done_box[0] / total), label)
            else:
                progress(-1, label)
    return written


def _should_take(rel: str, options: ExtractOptions, is_dir: bool) -> str | None:
    if options.skip_junk and is_junk_relative(rel):
        return None
    if not _is_selected(rel, options.selection):
        return None
    return _stripped(rel, options.strip_prefix)


def _extract_zip(volumes, staging, options, cancel, progress, result) -> None:
    listing = _list_zip(volumes, options)
    chosen = [item for item in listing.items if not item.is_directory and _should_take(item.path, options, False)]
    total = sum(item.size for item in chosen) or None
    done = [0]
    passwords = [None]
    if listing.has_encrypted:
        passwords = _ordered_passwords(options)
        if not passwords:
            raise password_required() if not options.password else wrong_password()
    source = _open_source(volumes)
    try:
        last = None
        for password in passwords:
            source.seek(0)
            try:
                with pyzipper.AESZipFile(source) as archive:
                    if password is not None:
                        archive.setpassword(password.encode("utf-8"))
                    if listing.has_encrypted and not _probe_zip(archive):
                        last = wrong_password() if password == options.password or options.password else password_required()
                        # 这个密码不行，换下一个。临时文件清掉。
                        _empty_dir(staging)
                        continue
                    infos = archive.infolist()
                    samples = [raw for raw in (_zip_raw_name(i) for i in infos) if isinstance(raw, bytes)]
                    encoding = _encoding_for(samples, options.encoding)
                    for info in infos:
                        cancel.check()
                        raw = _zip_raw_name(info)
                        safe = clean(decode_name(raw, encoding), windows_separators=True)
                        if safe is None:
                            result["skipped"] += 1
                            continue
                        out_rel = _should_take(safe, options, info.is_dir())
                        if out_rel is None:
                            continue
                        target = os.path.join(staging, *out_rel.split("/"))
                        if info.is_dir():
                            os.makedirs(target, exist_ok=True)
                            continue
                        os.makedirs(os.path.dirname(target), exist_ok=True)
                        try:
                            with archive.open(info, "r") as src:
                                _copy_stream(src, target, cancel, progress, done, total, out_rel)
                        except RuntimeError as exc:
                            text = str(exc).lower()
                            if "password" in text or "bad crc" in text or "compress" in text:
                                raise wrong_password() if options.password else password_required()
                            raise failed(f"「{out_rel}」出错：{exc}") from exc
                        _set_mtime(target, info.date_time)
                        result["file_count"] += 1
                    result["used_password"] = password
                    return
            except RuntimeError as exc:
                last = exc
                _empty_dir(staging)
                continue
        if listing.has_encrypted:
            raise wrong_password() if options.password else password_required()
        if last:
            raise failed(str(last))
    except zipfile.BadZipFile as exc:
        raise failed(f"文件不完整或已损坏（{exc}）") from exc
    finally:
        source.close()


def _probe_zip(archive) -> bool:
    for info in archive.infolist():
        if info.is_dir() or not (info.flag_bits & 0x1) or info.file_size <= 0:
            continue
        try:
            with archive.open(info, "r") as src:
                while src.read(CHUNK):
                    pass
            return True
        except RuntimeError:
            return False
    return True


def _empty_dir(path: str) -> None:
    for name in os.listdir(path):
        target = os.path.join(path, name)
        if os.path.isdir(target) and not os.path.islink(target):
            shutil.rmtree(target, ignore_errors=True)
        else:
            try:
                os.remove(target)
            except OSError:
                pass


def _set_mtime(path: str, date_time) -> None:
    try:
        stamp = time.mktime(tuple(date_time) + (0, 0, -1))
        os.utime(path, (stamp, stamp))
    except (OverflowError, ValueError, OSError):
        pass


def _extract_7z(volumes, staging, options, cancel, progress, result) -> None:
    listing = None
    try:
        listing = _list_7z(volumes, options)
    except ArchiveError:
        raise
    chosen = [item for item in listing.items if not item.is_directory]
    total = sum(item.size for item in chosen) or None
    passwords: list[str | None] = [None]
    # 列表阶段如果没抛密码错误，说明 None 或某个已保存密码能打开。
    # 加密文件名时 _list_7z 已经试过密码；这里再按同样顺序解。
    saved = _ordered_passwords(options)
    if saved:
        passwords = saved
        if options.password is None:
            passwords = [None, *saved]
    source = _open_source(volumes)
    try:
        last: ArchiveError | None = None
        seen = set()
        for password in passwords:
            if password in seen:
                continue
            seen.add(password)
            source.seek(0)
            try:
                _extract_open_7z(source, staging, password, options, cancel, progress, result, total)
                result["used_password"] = password
                return
            except ArchiveError as exc:
                last = exc
                _empty_dir(staging)
                if exc.code in ("password", "wrong_password"):
                    continue
                raise
        if last:
            raise last
        raise failed("无法解压这个 7z")
    finally:
        source.close()


def _extract_open_7z(source, staging, password, options, cancel, progress, result, total) -> None:
    try:
        archive = py7zr.SevenZipFile(source, mode="r", password=password)
    except py7zr.exceptions.PasswordRequired as exc:
        raise (wrong_password() if options.password else password_required()) from exc
    except Exception as exc:
        text = str(exc).lower()
        if "password" in text:
            raise wrong_password() if options.password else password_required()
        raise failed(f"无法读取 7z：{exc}") from exc
    with archive:
        targets = None
        if options.selection is not None or options.skip_junk or options.strip_prefix:
            targets = []
            for info in archive.list():
                safe = clean(info.filename, windows_separators=True)
                if safe is None:
                    result["skipped"] += 1
                    continue
                if _should_take(safe, options, bool(info.is_directory)) is None and not info.is_directory:
                    continue
                if _should_take(safe, options, bool(info.is_directory)) is None:
                    continue
                targets.append(info.filename)
        progress(-1, "正在解压 7z…")
        try:
            archive.extract(path=staging, targets=targets)
        except py7zr.exceptions.PasswordRequired as exc:
            raise (wrong_password() if options.password else password_required()) from exc
        except Cancelled:
            raise
        except Exception as exc:
            text = str(exc).lower()
            if "password" in text or "corrupt" in text:
                raise wrong_password() if options.password else password_required()
            raise failed(f"解压 7z 失败：{exc}") from exc
        # 按净化后的相对路径统计。py7zr 会自己建目录。
        for root, dirs, files in os.walk(staging):
            result["file_count"] += len(files)
        # 上面会重复累加——调用方只应走一次。这里先清零再数。
        result["file_count"] = 0
        for root, dirs, files in os.walk(staging):
            result["file_count"] += len(files)


def _safe_symlink(staging: str, rel: str, target: str) -> bool:
    if os.path.isabs(target) or target.startswith("\\\\"):
        return False
    joined = os.path.normpath(os.path.join(os.path.dirname(rel), target.replace("\\", "/")))
    if joined.startswith(".."):
        return False
    dest = os.path.join(staging, *rel.split("/"))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    try:
        os.symlink(target, dest)
        return True
    except OSError:
        return False


def _extract_tar(volumes, kind, staging, options, cancel, progress, result) -> None:
    source = _open_source(volumes)
    archive_size = max(total_size(volumes), 1)
    try:
        try:
            archive = tarfile.open(fileobj=source, mode="r:*")
        except tarfile.ReadError:
            source.seek(0)
            _extract_single_stream(volumes[0], kind, staging, options, cancel, progress, result)
            return
        with archive:
            done = [0]
            for member in archive.getmembers():
                cancel.check()
                safe = clean(member.name, windows_separators=False)
                if safe is None:
                    result["skipped"] += 1
                    continue
                out_rel = _should_take(safe, options, member.isdir())
                if out_rel is None:
                    continue
                target = os.path.join(staging, *out_rel.split("/"))
                if member.isdir():
                    os.makedirs(target, exist_ok=True)
                    continue
                if member.issym() or member.islnk():
                    link = member.linkname or ""
                    if _safe_symlink(staging, out_rel, link):
                        result["file_count"] += 1
                    else:
                        result["skipped"] += 1
                    continue
                if not member.isfile():
                    result["skipped"] += 1
                    continue
                extracted = archive.extractfile(member)
                if extracted is None:
                    result["skipped"] += 1
                    continue
                with extracted:
                    _copy_stream(extracted, target, cancel, progress, done, None, out_rel)
                progress(min(1, source.tell() / archive_size), out_rel)
                try:
                    os.utime(target, (member.mtime, member.mtime))
                except OSError:
                    pass
                result["file_count"] += 1
    finally:
        source.close()


def _extract_single_stream(path, kind, staging, options, cancel, progress, result) -> None:
    name = clean(base_name(path), True) or "解压结果"
    out_rel = _should_take(name, options, False)
    if out_rel is None:
        return
    opener = {"gz": gzip.open, "bz2": bz2.open, "xz": lzma.open}.get(kind)
    if opener is None:
        raise unsupported("这个文件不是压缩包。")
    total = max(os.path.getsize(path), 1)
    done = [0]
    try:
        with opener(path, "rb") as src:
            _copy_stream(src, os.path.join(staging, *out_rel.split("/")), cancel, progress, done, total, out_rel)
    except OSError as exc:
        raise failed(f"文件不完整或已损坏（{exc}）") from exc
    result["file_count"] += 1


def _extract_external(path, staging, options, cancel, progress, result) -> None:
    passwords: list[str | None]
    saved = _ordered_passwords(options)
    passwords = saved or [None]
    if options.password is None and saved:
        passwords = [None, *saved]
    if not saved:
        passwords = [None]
    last = None
    for password in passwords:
        try:
            # 先列出，拒绝 Zip Slip，再解。
            entries, _encrypted = entries_from_7z(path, password, bool(options.password) and password == options.password)
            if options.selection is None and not options.strip_prefix:
                extract_with_7z(path, staging, password, bool(options.password) and password == options.password, cancel)
            else:
                extract_with_7z(path, staging, password, bool(options.password) and password == options.password, cancel)
                _prune_to_selection(staging, options)
            result["used_password"] = password
            result["file_count"] = _count_files(staging)
            progress(1, "完成")
            return
        except ArchiveError as exc:
            last = exc
            _empty_dir(staging)
            if exc.code in ("password", "wrong_password"):
                continue
            raise
        except Cancelled:
            raise
    if last:
        raise last
    raise password_required()


def _prune_to_selection(staging: str, options: ExtractOptions) -> None:
    if options.selection is None and not options.strip_prefix and not options.skip_junk:
        return
    keep_root = staging
    for root, dirs, files in os.walk(staging, topdown=False):
        for name in files:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, keep_root).replace("\\", "/")
            if _should_take(rel, options, False) is None:
                try:
                    os.remove(full)
                except OSError:
                    pass
        for name in dirs:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, keep_root).replace("\\", "/")
            if _should_take(rel, options, True) is None and not os.listdir(full):
                try:
                    os.rmdir(full)
                except OSError:
                    pass


def _count_files(root: str) -> int:
    count = 0
    for _dir, _dirs, files in os.walk(root):
        count += len(files)
    return count


def finalize(tmp: str, destination: str, name: str, mode: str) -> list[str]:
    items = [os.path.join(tmp, entry) for entry in os.listdir(tmp)]
    if not items:
        shutil.rmtree(tmp, ignore_errors=True)
        return []

    def move_out(item: str) -> str:
        directory = os.path.isdir(item) and not os.path.islink(item)
        target = unique_path(destination, os.path.basename(item), is_directory=directory)
        shutil.move(item, target)
        return target

    def wrap() -> str:
        target = unique_path(destination, name, is_directory=True)
        shutil.move(tmp, target)
        return target

    only = items[0]
    only_is_dir = os.path.isdir(only) and not os.path.islink(only)
    if mode == "smart" and len(items) == 1:
        output = move_out(only)
        shutil.rmtree(tmp, ignore_errors=True)
        return [output]
    if mode == "always" and len(items) == 1 and os.path.basename(only) == name and only_is_dir:
        output = move_out(only)
        shutil.rmtree(tmp, ignore_errors=True)
        return [output]
    if mode == "never":
        outputs = [move_out(item) for item in items]
        shutil.rmtree(tmp, ignore_errors=True)
        return outputs
    return [wrap()]


def test_archive(path: str, password: str | None, candidates: list[str], cancel: CancelToken, progress) -> dict:
    options = ExtractOptions(os.path.dirname(path) or ".")
    options.password = password
    options.candidate_passwords = list(candidates or [])
    options.skip_junk = False
    volumes = volumes_for(path)
    kind = sniff(volumes[0])
    progress(-1, "正在测试…")
    if kind in ("rar", "cab", "iso", "zstd", "lz4"):
        _extract_external_test(path, options, cancel)
        return {"ok": True, "used_password": options.password}
    if kind == "zip":
        listing = _list_zip(volumes, options)
        count = _test_zip(volumes, options, listing, cancel, progress)
        return {"ok": True, "file_count": count, "used_password": options.password if listing.has_encrypted else None}
    if kind == "7z":
        _test_7z(volumes, options, cancel, progress)
        return {"ok": True}
    if kind in ("tar", "gz", "bz2", "xz"):
        count = _test_tar(volumes, kind, cancel, progress)
        return {"ok": True, "file_count": count}
    raise unsupported(f"暂不支持测试这个格式（{kind}）。")


def _extract_external_test(path, options, cancel) -> None:
    saved = _ordered_passwords(options)
    passwords: list[str | None] = saved or [None]
    last = None
    for password in passwords:
        try:
            test_with_7z(path, password, bool(options.password), cancel)
            return
        except ArchiveError as exc:
            last = exc
            if exc.code in ("password", "wrong_password"):
                continue
            raise
    if last:
        raise last


def _test_zip(volumes, options, listing, cancel, progress) -> int:
    source = _open_source(volumes)
    passwords: list[str | None] = [None]
    if listing.has_encrypted:
        passwords = _ordered_passwords(options) or []
        if not passwords:
            source.close()
            raise password_required() if not options.password else wrong_password()
    try:
        for password in passwords:
            source.seek(0)
            try:
                with pyzipper.AESZipFile(source) as archive:
                    if password:
                        archive.setpassword(password.encode("utf-8"))
                    infos = [info for info in archive.infolist() if not info.is_dir()]
                    total = sum(info.file_size for info in infos) or 1
                    done = 0
                    for info in infos:
                        cancel.check()
                        with archive.open(info, "r") as src:
                            while True:
                                chunk = src.read(CHUNK)
                                if not chunk:
                                    break
                                done += len(chunk)
                                progress(min(1, done / total), info.filename)
                    return len(infos)
            except RuntimeError:
                continue
        raise wrong_password() if options.password else password_required()
    except (zipfile.BadZipFile, pyzipper.zipfile.BadZipFile) as exc:
        raise failed(f"文件不完整或已损坏（{exc}）") from exc
    finally:
        source.close()


def _test_7z(volumes, options, cancel, progress) -> None:
    source = _open_source(volumes)
    passwords: list[str | None] = [None, *_ordered_passwords(options)]
    try:
        last = None
        for password in passwords:
            source.seek(0)
            try:
                with py7zr.SevenZipFile(source, mode="r", password=password) as archive:
                    cancel.check()
                    ok = archive.test()
                    if ok is False:
                        raise failed("数据校验失败，文件可能已损坏")
                    progress(1, "完成")
                    return
            except py7zr.exceptions.PasswordRequired as exc:
                last = exc
                continue
            except Exception as exc:
                text = str(exc).lower()
                if "password" in text or "corrupt" in text:
                    last = exc
                    continue
                raise failed(f"数据校验失败，文件可能已损坏（{exc}）") from exc
        raise wrong_password() if options.password else password_required()
    finally:
        source.close()


def _test_tar(volumes, kind, cancel, progress) -> int:
    source = _open_source(volumes)
    try:
        try:
            archive = tarfile.open(fileobj=source, mode="r:*")
        except tarfile.ReadError:
            _list_single_stream(volumes[0], kind)
            return 1
        with archive:
            count = 0
            members = archive.getmembers()
            for index, member in enumerate(members, start=1):
                cancel.check()
                if member.isfile():
                    extracted = archive.extractfile(member)
                    if extracted is not None:
                        with extracted:
                            while extracted.read(CHUNK):
                                pass
                    count += 1
                progress(index / max(len(members), 1), member.name)
            return count
    finally:
        source.close()


def _read_mark(path: str):
    if os.name != "nt":
        return None
    try:
        with open(path + ":Zone.Identifier", "rb") as handle:
            return handle.read()
    except OSError:
        return None


def _apply_mark_tree(root: str, mark: bytes) -> None:
    if os.name != "nt" or not mark:
        return
    for current, dirs, files in os.walk(root):
        for name in dirs + files:
            try:
                with open(os.path.join(current, name) + ":Zone.Identifier", "wb") as handle:
                    handle.write(mark)
            except OSError:
                pass
