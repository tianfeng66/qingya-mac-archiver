"""Windows 右键菜单和「打开方式」。只改当前用户的注册表，不需要管理员。"""

from __future__ import annotations

import os
import sys

PROG_ID = "QingYa.Archive"
EXTENSIONS = [
    ".zip", ".zipx", ".7z", ".rar", ".tar", ".gz", ".tgz", ".bz2", ".tbz", ".tbz2",
    ".xz", ".txz", ".cab", ".iso", ".cbz", ".cbr", ".cb7",
]


def exe_path() -> str:
    if getattr(sys, "frozen", False):
        return sys.executable
    return os.path.abspath(sys.argv[0])


def _command(flag: str) -> str:
    return f'"{exe_path()}" {flag} "%1"'


def register() -> str:
    if os.name != "nt":
        return "右键菜单只能在 Windows 上添加。"
    import winreg

    exe = exe_path()
    classes = winreg.CreateKey(winreg.HKEY_CURRENT_USER, r"Software\Classes")
    with winreg.CreateKey(classes, PROG_ID) as prog:
        winreg.SetValueEx(prog, "", 0, winreg.REG_SZ, "轻压压缩包")
        with winreg.CreateKey(prog, r"DefaultIcon") as icon:
            winreg.SetValueEx(icon, "", 0, winreg.REG_SZ, exe)
        with winreg.CreateKey(prog, r"shell\open\command") as cmd:
            winreg.SetValueEx(cmd, "", 0, winreg.REG_SZ, _command("--extract"))

    for ext in EXTENSIONS:
        with winreg.CreateKey(classes, ext + r"\OpenWithProgids") as key:
            winreg.SetValueEx(key, PROG_ID, 0, winreg.REG_SZ, "")
        with winreg.CreateKey(classes, ext + r"\shell\用轻压解压\command") as cmd:
            winreg.SetValueEx(cmd, "", 0, winreg.REG_SZ, _command("--extract"))

    for root in (r"*\shell\用轻压压缩", r"Directory\shell\用轻压压缩"):
        with winreg.CreateKey(classes, root) as key:
            winreg.SetValueEx(key, "", 0, winreg.REG_SZ, "用轻压压缩")
            winreg.SetValueEx(key, "Icon", 0, winreg.REG_SZ, exe)
        with winreg.CreateKey(classes, root + r"\command") as cmd:
            winreg.SetValueEx(cmd, "", 0, winreg.REG_SZ, _command("--compress"))
    return "已加到右键菜单。在文件上右键就能看到「用轻压压缩 / 用轻压解压」。"


def unregister() -> str:
    if os.name != "nt":
        return "当前不是 Windows。"
    import winreg

    classes = winreg.CreateKey(winreg.HKEY_CURRENT_USER, r"Software\Classes")

    def delete(path: str) -> None:
        try:
            winreg.DeleteKey(classes, path)
        except OSError:
            pass

    for ext in EXTENSIONS:
        try:
            with winreg.OpenKey(classes, ext + r"\OpenWithProgids", 0, winreg.KEY_SET_VALUE) as key:
                winreg.DeleteValue(key, PROG_ID)
        except OSError:
            pass
        delete(ext + r"\shell\用轻压解压\command")
        delete(ext + r"\shell\用轻压解压")
    for root in (r"*\shell\用轻压压缩", r"Directory\shell\用轻压压缩"):
        delete(root + r"\command")
        delete(root)
    delete(PROG_ID + r"\shell\open\command")
    delete(PROG_ID + r"\shell\open")
    delete(PROG_ID + r"\shell")
    delete(PROG_ID + r"\DefaultIcon")
    delete(PROG_ID)
    return "已从右键菜单移除。"


def open_default_apps() -> None:
    if os.name == "nt":
        os.startfile("ms-settings:defaultapps")
