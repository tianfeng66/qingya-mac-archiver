"""调用旁边的 7z.exe。RAR、ISO、CAB 以及 Python 引擎解不开的加密包走这里。"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys

from .errors import ArchiveError, failed, password_required, unsupported, wrong_password
from .paths import clean


def find_7z() -> str | None:
    env = os.environ.get("QINGYA_7Z")
    candidates = [env] if env else []
    if getattr(sys, "frozen", False):
        folder = os.path.dirname(sys.executable)
        candidates.append(os.path.join(folder, "7z.exe"))
        candidates.append(os.path.join(folder, "7zz"))
    if os.name == "nt":
        candidates.append(r"C:\Program Files\7-Zip\7z.exe")
        candidates.append(r"C:\Program Files (x86)\7-Zip\7z.exe")
    for candidate in candidates:
        if candidate and os.path.isfile(candidate):
            return candidate
    return shutil.which("7zz") or shutil.which("7z") or shutil.which("7z.exe")


def sevenzip_status() -> str:
    path = find_7z()
    if path:
        return path
    return ""


def _password_arg(password: str | None) -> str:
    # 空密码也显式传 -p，避免 7z 在没控制台时停下来等输入。
    return "-p" + (password or "")


def _run(args: list[str], cancel=None) -> subprocess.CompletedProcess:
    exe = find_7z()
    if not exe:
        raise unsupported(
            "这个格式要靠 7-Zip。安装包里已经带了 7z.exe；"
            "如果是从源码运行，请安装 7-Zip，或把 7z 放到 PATH。"
        )
    if cancel is not None:
        cancel.check()
    try:
        proc = subprocess.run(
            [exe, *args],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as exc:
        raise failed(f"无法启动 7-Zip：{exc}") from exc
    if cancel is not None:
        cancel.check()
    return proc


def _decode(data: bytes) -> str:
    for codec in ("utf-8", "gb18030"):
        try:
            return data.decode(codec)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", errors="replace")


def _raise_for_status(proc: subprocess.CompletedProcess, user_supplied: bool) -> None:
    text = _decode(proc.stderr) + "\n" + _decode(proc.stdout)
    lower = text.lower()
    if proc.returncode == 0:
        return
    if "wrong password" in lower or "can not open encrypted" in lower or "data error : wrong password" in lower:
        raise wrong_password() if user_supplied else password_required()
    if "encrypted" in lower and "password" in lower:
        raise wrong_password() if user_supplied else password_required()
    if "can not open the file as archive" in lower or "is not supported archive" in lower:
        raise unsupported("7-Zip 认不出这个压缩包，文件可能损坏或格式不受支持。")
    message = text.strip().splitlines()
    detail = message[-1] if message else f"退出码 {proc.returncode}"
    raise failed(f"7-Zip 失败：{detail}")


def list_with_7z(path: str, password: str | None, user_supplied: bool) -> list[dict]:
    proc = _run(["l", "-slt", "-y", "-bso1", "-bsp0", _password_arg(password), path])
    _raise_for_status(proc, user_supplied)
    items = []
    block: dict[str, str] = {}
    for line in _decode(proc.stdout).splitlines():
        if not line.strip():
            if "Path" in block:
                items.append(block)
            block = {}
            continue
        if " = " in line:
            key, value = line.split(" = ", 1)
            block[key] = value
    if "Path" in block:
        items.append(block)
    # 第一段是压缩包自己，Path 等于文件名且没有 Folder 字段时丢掉。
    archive_name = os.path.basename(path)
    cleaned = []
    for block in items:
        raw = block.get("Path", "")
        if raw == archive_name and "Folder" not in block and "Size" not in block:
            continue
        if raw in (archive_name, path):
            continue
        cleaned.append(block)
    return cleaned


def entries_from_7z(path: str, password: str | None, user_supplied: bool) -> tuple[list[dict], bool]:
    blocks = list_with_7z(path, password, user_supplied)
    entries = []
    encrypted = False
    for block in blocks:
        raw = block.get("Path", "")
        safe = clean(raw, windows_separators=True)
        if safe is None:
            raise failed(f"压缩包里有不安全的路径，已拒绝：{raw}")
        folder = block.get("Folder", "-") == "+"
        attrs = block.get("Attributes", "")
        is_dir = folder or attrs.startswith("D")
        try:
            size = int(block.get("Size", "0") or 0)
        except ValueError:
            size = 0
        enc = block.get("Encrypted", "-") == "+"
        encrypted = encrypted or enc
        entries.append({"path": safe, "is_directory": is_dir, "size": size, "encrypted": enc})
    return entries, encrypted


def extract_with_7z(path: str, dest: str, password: str | None, user_supplied: bool, cancel=None) -> None:
    os.makedirs(dest, exist_ok=True)
    # -o 和路径之间不能有空格。路径作为同一个参数。
    proc = _run(["x", "-y", "-bso0", "-bsp0", _password_arg(password), "-o" + dest, path], cancel)
    _raise_for_status(proc, user_supplied)


def test_with_7z(path: str, password: str | None, user_supplied: bool, cancel=None) -> None:
    proc = _run(["t", "-y", "-bso0", "-bsp0", _password_arg(password), path], cancel)
    _raise_for_status(proc, user_supplied)


def looks_like_password(exc: ArchiveError) -> bool:
    return exc.code in ("password", "wrong_password")


def ignored_switch_noise(text: str) -> bool:
    return bool(re.search(r"password", text, re.I))
