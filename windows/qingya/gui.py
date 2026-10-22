"""轻压主窗口。拖进来就能解压或压缩，重名不覆盖。"""

from __future__ import annotations

import os
import subprocess
import sys
import time
import traceback

from PySide6.QtCore import Qt, QThread, Signal
from PySide6.QtGui import QFont, QIcon
from PySide6.QtWidgets import (
    QCheckBox, QComboBox, QDialog, QFileDialog, QFrame, QHBoxLayout, QLabel,
    QLineEdit, QMainWindow, QMessageBox, QPushButton, QScrollArea, QVBoxLayout,
    QWidget,
)

from . import __version__
from .browser import Browser
from .compress import CompressOptions, compress
from .errors import ArchiveError, failed
from .extract import CancelToken, ExtractOptions, extract, test_archive
from .formats import FORMATS, LEVELS, VOLUME_CHOICES, is_archive, supports_level, supports_password, supports_store
from .integrate import open_default_apps, register, unregister
from .passwords import KeyringStore
from .paths import unique_path

STYLESHEET = """
QMainWindow, QWidget#root { background: #f3f4f6; color: #1f2328; }
QFrame#bar, QFrame#task {
    background: white;
    border: 1px solid #e5e7eb;
    border-radius: 12px;
}
QFrame#extract, QFrame#compress {
    background: #f8fafc;
    border: 1.5px dashed #c5d0e0;
    border-radius: 16px;
}
QFrame#extract { background: #f4f8ff; border-color: #b9d0fb; }
QFrame#compress { background: #f6f5ff; border-color: #cfcaf8; }
QFrame#extract[hot="true"] { background: #e7f0ff; border: 2px solid #2f6fed; }
QFrame#compress[hot="true"] { background: #eeedff; border: 2px solid #4f46e5; }
QPushButton {
    background: #ffffff;
    border: 1px solid #d0d7de;
    border-radius: 8px;
    padding: 6px 12px;
}
QPushButton:hover { background: #f6f8fa; }
QPushButton#primary { background: #2f6fed; color: white; border: none; }
QLineEdit, QComboBox {
    background: white;
    border: 1px solid #d0d7de;
    border-radius: 8px;
    padding: 4px 8px;
    min-height: 24px;
}
QProgressBar {
    border: none;
    background: #e5e7eb;
    border-radius: 3px;
    max-height: 6px;
}
QProgressBar::chunk { background: #2f6fed; border-radius: 3px; }
"""


def asset_path(name: str) -> str:
    if getattr(sys, "frozen", False):
        base = getattr(sys, "_MEIPASS", os.path.dirname(sys.executable))
    else:
        base = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(base, "assets", name)


def log_path() -> str:
    if os.name == "nt":
        base = os.environ.get("APPDATA", os.path.expanduser("~"))
    elif sys.platform == "darwin":
        base = os.path.expanduser("~/Library/Application Support")
    else:
        base = os.path.expanduser("~/.local/share")
    folder = os.path.join(base, "QingYa")
    os.makedirs(folder, exist_ok=True)
    return os.path.join(folder, "qingya.log")


def write_log(text: str) -> None:
    try:
        with open(log_path(), "a", encoding="utf-8") as handle:
            handle.write(text.rstrip() + "\n")
    except OSError:
        pass


def reveal_path(path: str) -> None:
    path = os.path.abspath(path)
    if os.name == "nt":
        subprocess.run(["explorer", "/select,", path], check=False)
    elif sys.platform == "darwin":
        subprocess.run(["open", "-R", path], check=False)
    else:
        folder = path if os.path.isdir(path) else os.path.dirname(path)
        subprocess.run(["xdg-open", folder], check=False)


def open_path(path: str) -> None:
    if os.name == "nt":
        os.startfile(path)  # type: ignore[attr-defined]
    elif sys.platform == "darwin":
        subprocess.run(["open", path], check=False)
    else:
        subprocess.run(["xdg-open", path], check=False)


def archive_name(items: list[str]) -> str:
    if len(items) == 1:
        path = items[0]
        if os.path.isdir(path) and not os.path.islink(path):
            return os.path.basename(path.rstrip(os.sep)) or "归档"
        stem, _ext = os.path.splitext(os.path.basename(path))
        return stem or os.path.basename(path)
    parent = os.path.basename(os.path.dirname(os.path.abspath(items[0])))
    return parent or "归档"


def _elapsed(started: float) -> str:
    seconds = max(0, time.monotonic() - started)
    if seconds < 1:
        return "不到 1 秒"
    if seconds < 60:
        return f"{int(seconds)} 秒"
    return f"{int(seconds) // 60} 分 {int(seconds) % 60} 秒"


class Task:
    def __init__(self, kind: str, title: str):
        self.id = 0
        self.kind = kind
        self.title = title
        self.state = "waiting"
        self.progress = -1.0
        self.detail = "等待中"
        self.summary = ""
        self.outputs: list[str] = []
        self.cancel = CancelToken()
        self.started = 0.0
        self.src = ""
        self.dest = ""
        self.items: list[str] = []
        self.output = ""
        self.password = None
        self.save_password = False
        self.encoding = "auto"
        self.selection = None
        self.folder_mode = "smart"
        self.open_file = False
        self.level = 5
        self.volume_mb = 0
        self.exclude_junk = True
        self.fmt = "zip"
        self.skip_junk = True


class Runner(QThread):
    progressed = Signal(int, float, str)
    done = Signal(int, object)

    def __init__(self, task_id: int, fn):
        super().__init__()
        self.task_id = task_id
        self.fn = fn
        self._last = 0.0

    def report(self, fraction, message) -> None:
        now = time.monotonic()
        if fraction < 1 and now - self._last < 0.08:
            return
        self._last = now
        self.progressed.emit(self.task_id, float(fraction), str(message or ""))

    def run(self) -> None:
        try:
            self.done.emit(self.task_id, self.fn(self.report))
        except Exception as exc:
            if not isinstance(exc, ArchiveError):
                write_log(traceback.format_exc())
                exc = failed(f"出错了：{exc}")
            self.done.emit(self.task_id, exc)


class DropCard(QFrame):
    def __init__(self, object_name: str, title: str, subtitle: str, hint: str, color: str):
        super().__init__()
        self.setObjectName(object_name)
        self.setAcceptDrops(True)
        self.setCursor(Qt.PointingHandCursor)
        self.setMinimumHeight(156)
        self._subtitle = subtitle
        self._action = title
        layout = QVBoxLayout(self)
        layout.setAlignment(Qt.AlignCenter)
        self.title = QLabel(title)
        self.title.setAlignment(Qt.AlignCenter)
        self.title.setStyleSheet(f"font-size: 22px; font-weight: 650; color: {color}; background: transparent;")
        self.subtitle = QLabel(subtitle)
        self.subtitle.setAlignment(Qt.AlignCenter)
        self.subtitle.setStyleSheet("color: #4b5563; background: transparent;")
        self.hint = QLabel(hint)
        self.hint.setAlignment(Qt.AlignCenter)
        self.hint.setStyleSheet("color: #9ca3af; font-size: 12px; background: transparent;")
        for label in (self.title, self.subtitle, self.hint):
            label.setAttribute(Qt.WA_TransparentForMouseEvents, True)
            layout.addWidget(label)
        self.clicked = None
        self.dropped = None

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.LeftButton and self.clicked:
            self.clicked()
        super().mouseReleaseEvent(event)

    def dragEnterEvent(self, event):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()
            self.subtitle.setText("松开开始" + self._action)
            self.setProperty("hot", True)
            self._polish()

    def dragLeaveEvent(self, event):
        self.subtitle.setText(self._subtitle)
        self.setProperty("hot", False)
        self._polish()
        super().dragLeaveEvent(event)

    def dropEvent(self, event):
        self.subtitle.setText(self._subtitle)
        self.setProperty("hot", False)
        self._polish()
        paths = [url.toLocalFile() for url in event.mimeData().urls() if url.isLocalFile()]
        if paths and self.dropped:
            self.dropped(paths)
        event.acceptProposedAction()

    def _polish(self) -> None:
        self.style().unpolish(self)
        self.style().polish(self)


class PasswordDialog(QDialog):
    def __init__(self, parent, name: str, wrong: bool):
        super().__init__(parent)
        self.setWindowTitle("输入密码")
        self.setModal(True)
        self.resize(420, 180)
        layout = QVBoxLayout(self)
        text = f"「{name}」的密码不对，请再试一次。" if wrong else f"「{name}」有密码。"
        layout.addWidget(QLabel(text))
        row = QHBoxLayout()
        self.edit = QLineEdit()
        self.edit.setEchoMode(QLineEdit.Password)
        self.edit.setPlaceholderText("解压密码")
        self.edit.returnPressed.connect(self.accept)
        row.addWidget(self.edit, 1)
        toggle = QPushButton("显示")
        toggle.setCheckable(True)
        toggle.toggled.connect(lambda on: self.edit.setEchoMode(QLineEdit.Normal if on else QLineEdit.Password))
        toggle.toggled.connect(lambda on: toggle.setText("隐藏" if on else "显示"))
        row.addWidget(toggle)
        layout.addLayout(row)
        self.remember = QCheckBox("记住密码，下次自动尝试")
        self.remember.setChecked(True)
        layout.addWidget(self.remember)
        buttons = QHBoxLayout()
        buttons.addStretch(1)
        cancel = QPushButton("取消")
        cancel.clicked.connect(self.reject)
        ok = QPushButton("确定")
        ok.setObjectName("primary")
        ok.clicked.connect(self.accept)
        buttons.addWidget(cancel)
        buttons.addWidget(ok)
        layout.addLayout(buttons)
        self.edit.setFocus()


class SettingsDialog(QDialog):
    def __init__(self, host: "MainWindow"):
        super().__init__(host)
        self.host = host
        self.setWindowTitle("设置")
        self.resize(520, 460)
        layout = QVBoxLayout(self)

        layout.addWidget(QLabel("解压到"))
        self.dest = QComboBox()
        self.dest.addItem("和压缩包放在一起", "same")
        self.dest.addItem("每次询问", "ask")
        self.dest.addItem("固定文件夹", "fixed")
        layout.addWidget(self.dest)
        self.fixed = QLineEdit()
        self.fixed.setPlaceholderText("固定文件夹路径")
        pick = QPushButton("选择…")
        pick.clicked.connect(self._pick_fixed)
        row = QHBoxLayout()
        row.addWidget(self.fixed, 1)
        row.addWidget(pick)
        layout.addLayout(row)

        layout.addWidget(QLabel("放出来的方式"))
        self.folder = QComboBox()
        self.folder.addItem("智能：只有一个项目就直接放出，否则新建同名文件夹", "smart")
        self.folder.addItem("总是新建同名文件夹", "always")
        self.folder.addItem("直接解压到目标位置", "never")
        layout.addWidget(self.folder)

        self.reveal = QCheckBox("完成后在文件夹中显示")
        self.trash = QCheckBox("解压成功后把压缩包移到回收站（Windows）")
        self.junk = QCheckBox("跳过 .DS_Store、Thumbs.db 这类系统文件")
        layout.addWidget(self.reveal)
        layout.addWidget(self.trash)
        layout.addWidget(self.junk)

        layout.addWidget(QLabel("已记住的解压密码"))
        self.password_count = QLabel("")
        layout.addWidget(self.password_count)
        clear = QPushButton("清空密码本")
        clear.clicked.connect(self._clear_passwords)
        layout.addWidget(clear)

        menu = QHBoxLayout()
        add_menu = QPushButton("添加到右键菜单")
        add_menu.clicked.connect(lambda: QMessageBox.information(self, "右键菜单", register()))
        remove_menu = QPushButton("从右键菜单移除")
        remove_menu.clicked.connect(lambda: QMessageBox.information(self, "右键菜单", unregister()))
        defaults = QPushButton("打开系统默认应用设置")
        defaults.clicked.connect(open_default_apps)
        if os.name != "nt":
            add_menu.setEnabled(False)
            remove_menu.setEnabled(False)
            defaults.setEnabled(False)
        menu.addWidget(add_menu)
        menu.addWidget(remove_menu)
        menu.addWidget(defaults)
        layout.addLayout(menu)
        layout.addWidget(QLabel(f"轻压 {__version__}    完全在本机运行，不联网，不上传文件。"))

        buttons = QHBoxLayout()
        buttons.addStretch(1)
        close = QPushButton("完成")
        close.setObjectName("primary")
        close.clicked.connect(self.accept)
        buttons.addWidget(close)
        layout.addLayout(buttons)
        self._load()

    def _load(self) -> None:
        self.dest.setCurrentIndex(max(0, self.dest.findData(self.host.setting("extractDestination", "same"))))
        self.fixed.setText(str(self.host.setting("extractFixed", "")))
        self.folder.setCurrentIndex(max(0, self.folder.findData(self.host.setting("folderMode", "smart"))))
        self.reveal.setChecked(self.host.setting_bool("revealExtract", True))
        self.trash.setChecked(self.host.setting_bool("trashExtract", False))
        self.junk.setChecked(self.host.setting_bool("skipJunk", True))
        count = len(self.host.saved_passwords())
        self.password_count.setText(f"当前记住了 {count} 个密码。密码保存在系统凭据里，这里不显示原文。")

    def _pick_fixed(self) -> None:
        folder = QFileDialog.getExistingDirectory(self, "选择解压位置")
        if folder:
            self.fixed.setText(folder)

    def _clear_passwords(self) -> None:
        self.host.passwords.clear()
        self.password_count.setText("密码本已清空。")

    def accept(self) -> None:
        self.host.settings.setValue("extractDestination", self.dest.currentData())
        self.host.settings.setValue("extractFixed", self.fixed.text().strip())
        self.host.settings.setValue("folderMode", self.folder.currentData())
        self.host.settings.setValue("revealExtract", self.reveal.isChecked())
        self.host.settings.setValue("trashExtract", self.trash.isChecked())
        self.host.settings.setValue("skipJunk", self.junk.isChecked())
        super().accept()


class TaskRow(QFrame):
    def __init__(self, task: Task, host: "MainWindow"):
        super().__init__()
        self.task = task
        self.host = host
        self.setObjectName("task")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(12, 10, 12, 10)
        self.title = QLabel(task.title)
        self.title.setStyleSheet("font-weight: 600;")
        self.detail = QLabel(task.detail)
        self.detail.setStyleSheet("color: #4b5563;")
        self.detail.setWordWrap(True)
        self.bar = QWidget()
        from PySide6.QtWidgets import QProgressBar
        self.bar = QProgressBar()
        self.bar.setTextVisible(False)
        buttons = QHBoxLayout()
        self.cancel_btn = QPushButton("取消")
        self.show_btn = QPushButton("在文件夹中显示")
        self.retry_btn = QPushButton("重试")
        self.elsewhere_btn = QPushButton("换个位置")
        self.clear_btn = QPushButton("清除")
        self.cancel_btn.clicked.connect(lambda: host.cancel_task(task.id))
        self.show_btn.clicked.connect(lambda: host.reveal_task(task.id))
        self.retry_btn.clicked.connect(lambda: host.retry_task(task.id))
        self.elsewhere_btn.clicked.connect(lambda: host.retry_elsewhere(task.id))
        self.clear_btn.clicked.connect(lambda: host.remove_task(task.id))
        for button in (self.cancel_btn, self.show_btn, self.retry_btn, self.elsewhere_btn, self.clear_btn):
            buttons.addWidget(button)
        buttons.addStretch(1)
        layout.addWidget(self.title)
        layout.addWidget(self.detail)
        layout.addWidget(self.bar)
        layout.addLayout(buttons)
        self.sync()

    def sync(self) -> None:
        task = self.task
        self.title.setText(task.title)
        self.detail.setText(task.summary or task.detail or "")
        running = task.state == "running"
        if running and task.progress < 0:
            self.bar.setRange(0, 0)
        else:
            self.bar.setRange(0, 1000)
            self.bar.setValue(int(max(0, min(1, task.progress)) * 1000))
        self.bar.setVisible(running)
        self.cancel_btn.setVisible(task.state in ("running", "waiting"))
        self.show_btn.setVisible(task.state == "done" and bool(task.outputs))
        failed_state = task.state == "failed"
        self.retry_btn.setVisible(failed_state)
        self.elsewhere_btn.setVisible(failed_state)
        self.clear_btn.setVisible(task.state in ("done", "failed", "cancelled"))


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        from PySide6.QtCore import QSettings
        self.settings = QSettings()
        self.passwords = KeyringStore()
        self.tasks: dict[int, Task] = {}
        self.rows: dict[int, TaskRow] = {}
        self.threads: list[Runner] = []
        self.next_id = 1
        self.asking = False
        self.setWindowTitle("轻压")
        self.resize(880, 660)
        self.setMinimumSize(720, 560)
        self.setAcceptDrops(True)
        icon = asset_path("icon.png")
        if os.path.isfile(icon):
            self.setWindowIcon(QIcon(icon))

        root = QWidget()
        root.setObjectName("root")
        self.setCentralWidget(root)
        layout = QVBoxLayout(root)
        layout.setContentsMargins(16, 16, 16, 12)
        layout.setSpacing(12)

        cards = QHBoxLayout()
        self.extract_card = DropCard("extract", "解压", "拖入压缩包", "zip · rar · 7z · tar · gz · xz", "#2f6fed")
        self.compress_card = DropCard("compress", "压缩", "拖入文件或文件夹", "按下面的设置生成压缩包", "#4f46e5")
        self.extract_card.clicked = self.choose_extract
        self.extract_card.dropped = self.extract_archives
        self.compress_card.clicked = self.choose_compress
        self.compress_card.dropped = self.compress_items
        cards.addWidget(self.extract_card)
        cards.addWidget(self.compress_card)
        layout.addLayout(cards)

        bar = QFrame()
        bar.setObjectName("bar")
        bar_layout = QVBoxLayout(bar)
        row = QHBoxLayout()
        self.format_box = QComboBox()
        for key, title, _hint, _level, _password in FORMATS:
            self.format_box.addItem(title, key)
        self.level_box = QComboBox()
        for value, title in LEVELS:
            self.level_box.addItem(title, value)
        self.password = QLineEdit()
        self.password.setEchoMode(QLineEdit.Password)
        self.password.setPlaceholderText("密码（可选）")
        self.password.setClearButtonEnabled(True)
        self.show_password = QPushButton("显示")
        self.show_password.setToolTip("显示或隐藏密码")
        self.show_password.setCheckable(True)
        self.show_password.toggled.connect(self._toggle_password)
        self.volume_box = QComboBox()
        for mb, label in VOLUME_CHOICES:
            self.volume_box.addItem(label, mb)
        row.addWidget(QLabel("格式"))
        row.addWidget(self.format_box)
        row.addWidget(QLabel("压缩率"))
        row.addWidget(self.level_box)
        row.addWidget(self.password, 1)
        row.addWidget(self.show_password)
        row.addWidget(QLabel("分卷"))
        row.addWidget(self.volume_box)
        bar_layout.addLayout(row)
        checks = QHBoxLayout()
        self.separate = QCheckBox("多个项目分别压缩")
        self.exclude_junk = QCheckBox("排除 .DS_Store 等系统文件")
        self.exclude_junk.setChecked(True)
        checks.addWidget(self.separate)
        checks.addWidget(self.exclude_junk)
        checks.addStretch(1)
        browse = QPushButton("浏览压缩包")
        browse.clicked.connect(self.choose_browse)
        settings = QPushButton("设置")
        settings.clicked.connect(self.open_settings)
        clear = QPushButton("清除已完成")
        clear.clicked.connect(self.clear_finished)
        checks.addWidget(browse)
        checks.addWidget(settings)
        checks.addWidget(clear)
        bar_layout.addLayout(checks)
        layout.addWidget(bar)

        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QFrame.NoFrame)
        self.task_host = QWidget()
        self.task_layout = QVBoxLayout(self.task_host)
        self.task_layout.setContentsMargins(0, 0, 0, 0)
        self.task_layout.setSpacing(8)
        self.empty = QLabel("把文件拖进来，或点上面的区域选择。\n压缩包会解压，其他文件会按上面的格式压缩。重名自动加序号，不会覆盖。")
        self.empty.setAlignment(Qt.AlignCenter)
        self.empty.setStyleSheet("color: #6b7280; padding: 24px;")
        self.task_layout.addWidget(self.empty)
        self.task_layout.addStretch(1)
        self.scroll.setWidget(self.task_host)
        layout.addWidget(self.scroll, 1)

        self.status = QLabel("不联网  ·  原文件不会被覆盖")
        self.status.setStyleSheet("color: #6b7280;")
        layout.addWidget(self.status)

        self.format_box.currentIndexChanged.connect(self._sync_format)
        self._load_compress_prefs()
        self._sync_format()
        self.format_box.currentIndexChanged.connect(self._save_compress_prefs)
        self.level_box.currentIndexChanged.connect(self._save_compress_prefs)
        self.volume_box.currentIndexChanged.connect(self._save_compress_prefs)
        self.separate.toggled.connect(self._save_compress_prefs)
        self.exclude_junk.toggled.connect(self._save_compress_prefs)

    def setting(self, key: str, default):
        value = self.settings.value(key, default)
        return default if value is None else value

    def setting_bool(self, key: str, default: bool) -> bool:
        value = self.settings.value(key, default)
        if isinstance(value, str):
            return value.lower() in ("1", "true", "yes")
        return bool(value)

    def _load_compress_prefs(self) -> None:
        fmt = str(self.setting("format", "zip"))
        index = self.format_box.findData(fmt)
        if index >= 0:
            self.format_box.setCurrentIndex(index)
        try:
            level = int(self.setting("level", 5))
        except (TypeError, ValueError):
            level = 5
        index = self.level_box.findData(level)
        if index >= 0:
            self.level_box.setCurrentIndex(index)
        try:
            volume = int(self.setting("volumeMB", 0))
        except (TypeError, ValueError):
            volume = 0
        index = self.volume_box.findData(volume)
        if index >= 0:
            self.volume_box.setCurrentIndex(index)
        self.separate.setChecked(self.setting_bool("separate", False))
        self.exclude_junk.setChecked(self.setting_bool("excludeJunk", True))

    def _save_compress_prefs(self, *_args) -> None:
        self.settings.setValue("format", self.format_box.currentData())
        self.settings.setValue("level", self.level_box.currentData())
        self.settings.setValue("volumeMB", self.volume_box.currentData())
        self.settings.setValue("separate", self.separate.isChecked())
        self.settings.setValue("excludeJunk", self.exclude_junk.isChecked())

    def _sync_format(self, *_args) -> None:
        fmt = self.format_box.currentData()
        self.level_box.setEnabled(supports_level(fmt))
        self.password.setEnabled(supports_password(fmt))
        self.show_password.setEnabled(supports_password(fmt))
        if not supports_store(fmt) and self.level_box.currentData() == 0:
            index = self.level_box.findData(5)
            if index >= 0:
                self.level_box.setCurrentIndex(index)

    def _toggle_password(self, on: bool) -> None:
        self.password.setEchoMode(QLineEdit.Normal if on else QLineEdit.Password)
        self.show_password.setText("隐藏" if on else "显示")

    def dragEnterEvent(self, event):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()

    def dropEvent(self, event):
        paths = [url.toLocalFile() for url in event.mimeData().urls() if url.isLocalFile()]
        self.open_paths(paths)
        event.acceptProposedAction()

    def open_paths(self, paths: list[str]) -> None:
        archives, others = [], []
        for path in paths:
            if not path or not os.path.exists(path):
                continue
            if os.path.isdir(path) or not is_archive(path):
                others.append(path)
            else:
                archives.append(path)
        if archives:
            self.extract_archives(archives)
        if others:
            self.compress_items(others)
        if not archives and not others:
            self.status.setText("没有找到能处理的文件")

    def choose_extract(self) -> None:
        paths, _ = QFileDialog.getOpenFileNames(self, "选择要解压的压缩包")
        if paths:
            self.extract_archives(paths)

    def choose_compress(self) -> None:
        box = QMessageBox(self)
        box.setWindowTitle("压缩")
        box.setText("要压缩文件，还是整个文件夹？")
        files = box.addButton("选择文件", QMessageBox.AcceptRole)
        folder = box.addButton("选择文件夹", QMessageBox.AcceptRole)
        box.addButton("取消", QMessageBox.RejectRole)
        box.exec()
        clicked = box.clickedButton()
        if clicked == files:
            paths, _ = QFileDialog.getOpenFileNames(self, "选择要压缩的文件")
            if paths:
                self.compress_items(paths)
        elif clicked == folder:
            path = QFileDialog.getExistingDirectory(self, "选择要压缩的文件夹")
            if path:
                self.compress_items([path])

    def choose_browse(self) -> None:
        path, _ = QFileDialog.getOpenFileName(self, "选择要浏览的压缩包")
        if path:
            self.open_browser(path)

    def open_browser(self, path: str) -> None:
        if not is_archive(path):
            QMessageBox.information(self, "浏览", "这不是支持的压缩包。")
            return
        Browser(path, self).exec()

    def open_settings(self) -> None:
        SettingsDialog(self).exec()

    def saved_passwords(self) -> list[str]:
        if not self.setting_bool("rememberPasswords", True):
            return []
        try:
            return self.passwords.candidates()
        except Exception:
            return []

    def remember_password(self, password: str) -> None:
        if password and self.setting_bool("rememberPasswords", True):
            try:
                self.passwords.add(password)
            except Exception as exc:
                write_log("保存密码失败：" + str(exc))

    def ask_password(self, name: str, wrong: bool = False):
        dialog = PasswordDialog(self, name, wrong)
        if dialog.exec() != QDialog.Accepted:
            return None
        password = dialog.edit.text()
        if not password:
            return None
        return password, dialog.remember.isChecked()

    def extract_archives(self, paths, encoding=None, password=None, selection=None,
                         folder_mode=None, open_file=False) -> None:
        archives = [path for path in paths if os.path.isfile(path) and is_archive(path)]
        if not archives:
            self.status.setText("没有识别到压缩包。文件夹和普通文件请拖到右边压缩。")
            return
        asked = None
        for path in archives:
            dest = self._extract_dest(path, asked)
            if not dest:
                return
            if str(self.setting("extractDestination", "same")) == "ask":
                asked = dest
            task = Task("extract", "解压 " + os.path.basename(path))
            task.src = path
            task.dest = dest
            task.encoding = encoding or "auto"
            task.password = password
            task.selection = selection
            task.folder_mode = folder_mode or str(self.setting("folderMode", "smart"))
            task.open_file = open_file
            task.skip_junk = self.setting_bool("skipJunk", True)
            self.enqueue(task)

    def compress_items(self, paths) -> None:
        items = [path for path in paths if os.path.exists(path)]
        if not items:
            self.status.setText("没有找到要压缩的文件")
            return
        groups = [[item] for item in items] if self.separate.isChecked() and len(items) > 1 else [items]
        asked = None
        fmt = self.format_box.currentData()
        for group in groups:
            dest = self._compress_dest(group[0], asked)
            if not dest:
                return
            if str(self.setting("compressDestination", "same")) == "ask":
                asked = dest
            output = unique_path(dest, archive_name(group) + "." + fmt, also_avoid=[".001"])
            task = Task("compress", "压缩 " + os.path.basename(output))
            task.items = group
            task.output = output
            task.fmt = fmt
            task.level = int(self.level_box.currentData() or 5)
            task.volume_mb = int(self.volume_box.currentData() or 0)
            task.exclude_junk = self.exclude_junk.isChecked()
            if supports_password(fmt):
                task.password = self.password.text() or None
            self.enqueue(task)

    def enqueue_test(self, path: str, password=None) -> None:
        task = Task("test", "测试 " + os.path.basename(path))
        task.src = path
        task.password = password
        self.enqueue(task)

    def _extract_dest(self, path: str, asked: str | None) -> str | None:
        mode = str(self.setting("extractDestination", "same"))
        sibling = os.path.dirname(os.path.abspath(path))
        if mode == "ask":
            if asked:
                return asked
            return QFileDialog.getExistingDirectory(self, "解压到…", sibling) or None
        if mode == "fixed":
            folder = str(self.setting("extractFixed", "") or "")
            if folder and os.path.isdir(folder) and os.access(folder, os.W_OK):
                return folder
            picked = QFileDialog.getExistingDirectory(self, "设置里的文件夹不可用，请另外选一个", sibling)
            return picked or None
        if os.path.isdir(sibling) and os.access(sibling, os.W_OK):
            return sibling
        return QFileDialog.getExistingDirectory(self, "原位置不能写入，请选择解压到哪里", sibling) or None

    def _compress_dest(self, path: str, asked: str | None) -> str | None:
        mode = str(self.setting("compressDestination", "same"))
        sibling = os.path.dirname(os.path.abspath(path))
        if mode == "ask":
            if asked:
                return asked
            return QFileDialog.getExistingDirectory(self, "压缩包保存到…", sibling) or None
        if mode == "fixed":
            folder = str(self.setting("compressFixed", "") or "")
            if folder and os.path.isdir(folder) and os.access(folder, os.W_OK):
                return folder
            return QFileDialog.getExistingDirectory(self, "请选择压缩包保存到哪里", sibling) or None
        if os.path.isdir(sibling) and os.access(sibling, os.W_OK):
            return sibling
        return QFileDialog.getExistingDirectory(self, "原位置不能写入，请选择保存到哪里", sibling) or None

    def enqueue(self, task: Task) -> None:
        task.id = self.next_id
        self.next_id += 1
        self.tasks[task.id] = task
        row = TaskRow(task, self)
        self.rows[task.id] = row
        self.task_layout.insertWidget(0, row)
        self.empty.hide()
        self.pump()

    def pump(self) -> None:
        running = sum(1 for task in self.tasks.values() if task.state == "running")
        if running >= 2:
            return
        for task in list(self.tasks.values()):
            if task.state != "waiting":
                continue
            if sum(1 for item in self.tasks.values() if item.state == "running") >= 2:
                break
            self._start(task)

    def _start(self, task: Task) -> None:
        task.state = "running"
        task.progress = -1
        task.detail = "正在准备…"
        task.started = time.monotonic()
        task.cancel = CancelToken()
        self._refresh(task)
        task_id = task.id

        def work(report):
            if task.kind == "extract":
                options = ExtractOptions(task.dest)
                options.folder_mode = task.folder_mode
                options.encoding = task.encoding
                options.password = task.password
                options.candidate_passwords = self.saved_passwords()
                options.selection = task.selection
                options.skip_junk = task.skip_junk
                options.propagate_mark = True
                return extract(task.src, options, task.cancel, report)
            if task.kind == "compress":
                options = CompressOptions()
                options.format = task.fmt
                options.level = task.level
                options.password = task.password
                options.exclude_junk = task.exclude_junk
                options.volume_size = task.volume_mb * 1024 * 1024 if task.volume_mb else None
                outputs = compress(task.items, task.output, options, task.cancel, report)
                return {"outputs": outputs, "file_count": len(outputs)}
            report(-1, "正在测试…")
            report_result = test_archive(task.src, task.password, self.saved_passwords(), task.cancel, report)
            report_result["outputs"] = []
            return report_result

        runner = Runner(task_id, work)
        runner.progressed.connect(self._on_progress)
        runner.done.connect(self._on_done)
        runner.finished.connect(lambda r=runner: self._drop_thread(r))
        self.threads.append(runner)
        runner.start()

    def _drop_thread(self, runner: Runner) -> None:
        if runner in self.threads:
            self.threads.remove(runner)

    def _on_progress(self, task_id: int, fraction: float, message: str) -> None:
        task = self.tasks.get(task_id)
        if not task or task.state != "running":
            return
        task.progress = fraction
        if message:
            task.detail = message
        self._refresh(task)

    def _on_done(self, task_id: int, payload) -> None:
        task = self.tasks.get(task_id)
        if not task:
            return
        if isinstance(payload, ArchiveError) and payload.code == "cancelled":
            task.state = "cancelled"
            task.summary = "已取消"
            task.progress = 0
        elif isinstance(payload, ArchiveError) and payload.code in ("password", "wrong_password"):
            task.state = "needs_password"
            task.detail = "需要密码" if payload.code == "password" else "密码不对"
            self._refresh(task)
            self._prompt_next()
            return
        elif isinstance(payload, Exception):
            task.state = "failed"
            task.summary = str(payload)
            task.progress = 0
        else:
            task.state = "done"
            task.progress = 1
            outputs = list(payload.get("outputs") or [])
            task.outputs = outputs
            count = payload.get("file_count", len(outputs))
            if task.kind == "test":
                task.summary = f"没有发现问题，用时 {_elapsed(task.started)}"
            elif task.kind == "compress":
                task.summary = f"已生成 {len(outputs)} 个文件，用时 {_elapsed(task.started)}"
            else:
                task.summary = f"完成，{count} 个文件，用时 {_elapsed(task.started)}"
            used = payload.get("used_password")
            if task.save_password and used:
                self.remember_password(used)
            elif task.password and task.save_password:
                self.remember_password(task.password)
            if self.setting_bool("revealExtract", True) and task.kind == "extract" and outputs and not task.open_file:
                reveal_path(outputs[0])
            if self.setting_bool("revealCompress", True) and task.kind == "compress" and outputs:
                reveal_path(outputs[0])
            if task.open_file and outputs:
                open_path(self._preview_target(outputs, task.selection))
            if task.kind == "extract" and self.setting_bool("trashExtract", False):
                self._trash_archive(task.src)
        self._refresh(task)
        self.pump()

    def _preview_target(self, outputs: list[str], selection) -> str:
        if not selection:
            return outputs[0]
        name = next(iter(selection)).rsplit("/", 1)[-1]
        for output in outputs:
            if os.path.isfile(output) and os.path.basename(output) == name:
                return output
            if os.path.isdir(output):
                for folder, _dirs, files in os.walk(output):
                    if name in files:
                        return os.path.join(folder, name)
        return outputs[0]

    def _trash_archive(self, path: str) -> None:
        if os.name != "nt":
            self.status.setText("移到回收站只在 Windows 上可用，压缩包还留在原地。")
            return
        try:
            import ctypes
            from ctypes import wintypes

            class SHFILEOPSTRUCTW(ctypes.Structure):
                _fields_ = [
                    ("hwnd", wintypes.HWND),
                    ("wFunc", ctypes.c_uint),
                    ("pFrom", wintypes.LPCWSTR),
                    ("pTo", wintypes.LPCWSTR),
                    ("fFlags", ctypes.c_ushort),
                    ("fAnyOperationsAborted", wintypes.BOOL),
                    ("hNameMappings", ctypes.c_void_p),
                    ("lpszProgressTitle", wintypes.LPCWSTR),
                ]

            op = SHFILEOPSTRUCTW()
            op.wFunc = 3
            op.pFrom = os.path.abspath(path) + "\0\0"
            op.fFlags = 0x40 | 0x10 | 0x4
            ctypes.windll.shell32.SHFileOperationW(ctypes.byref(op))
        except Exception as exc:
            write_log("移到回收站失败：" + str(exc))

    def _prompt_next(self) -> None:
        if self.asking:
            return
        for task in self.tasks.values():
            if task.state != "needs_password":
                continue
            self.asking = True
            entered = self.ask_password(os.path.basename(task.src or task.title), wrong=task.detail == "密码不对")
            self.asking = False
            if not entered:
                task.state = "failed"
                task.summary = "未输入密码"
                self._refresh(task)
            else:
                task.password = entered[0]
                task.save_password = entered[1]
                task.state = "waiting"
                task.summary = ""
                self._refresh(task)
            self._prompt_next()
            self.pump()
            return

    def _refresh(self, task: Task) -> None:
        row = self.rows.get(task.id)
        if row:
            row.sync()

    def cancel_task(self, task_id: int) -> None:
        task = self.tasks.get(task_id)
        if not task:
            return
        if task.state == "running":
            task.cancel.cancel()
        elif task.state in ("waiting", "needs_password"):
            task.state = "cancelled"
            task.summary = "已取消"
            self._refresh(task)

    def retry_task(self, task_id: int) -> None:
        task = self.tasks.get(task_id)
        if not task:
            return
        task.state = "waiting"
        task.progress = -1
        task.summary = ""
        task.detail = "等待中"
        self._refresh(task)
        self.pump()

    def retry_elsewhere(self, task_id: int) -> None:
        task = self.tasks.get(task_id)
        if not task:
            return
        folder = QFileDialog.getExistingDirectory(self, "选择保存位置")
        if not folder:
            return
        if task.kind == "extract":
            task.dest = folder
        elif task.kind == "compress":
            task.output = unique_path(folder, os.path.basename(task.output), also_avoid=[".001"])
            task.title = "压缩 " + os.path.basename(task.output)
        self.retry_task(task_id)

    def reveal_task(self, task_id: int) -> None:
        task = self.tasks.get(task_id)
        if task and task.outputs:
            reveal_path(task.outputs[0])

    def remove_task(self, task_id: int) -> None:
        task = self.tasks.get(task_id)
        if task and task.state == "running":
            task.cancel.cancel()
        row = self.rows.pop(task_id, None)
        self.tasks.pop(task_id, None)
        if row:
            row.setParent(None)
            row.deleteLater()
        if not self.rows:
            self.empty.show()

    def clear_finished(self) -> None:
        for task_id, task in list(self.tasks.items()):
            if task.state in ("done", "failed", "cancelled"):
                self.remove_task(task_id)


def install_excepthook() -> None:
    def hook(exc_type, exc, tb):
        write_log("".join(traceback.format_exception(exc_type, exc, tb)))
        sys.__excepthook__(exc_type, exc, tb)
    sys.excepthook = hook


def apply_font(app) -> None:
    font = QFont()
    if os.name == "nt":
        font.setFamilies(["Segoe UI", "Microsoft YaHei", "sans-serif"])
    else:
        font.setFamilies(["PingFang SC", "Microsoft YaHei"])
    font.setPointSize(13)
    app.setFont(font)
