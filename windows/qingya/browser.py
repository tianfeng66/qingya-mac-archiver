"""浏览压缩包：先看内容，再决定解压哪些。"""

from __future__ import annotations

import os

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QComboBox, QDialog, QHBoxLayout, QLabel, QMessageBox, QPushButton,
    QTreeWidget, QTreeWidgetItem, QVBoxLayout,
)

from .charset import CHOICES
from .errors import ArchiveError
from .extract import list_archive
from .formats import base_name
from .paths import format_bytes


class Browser(QDialog):
    def __init__(self, path: str, host):
        super().__init__(host)
        self.path = path
        self.host = host
        self.password = None
        self.listing = None
        self.setWindowTitle("浏览 · " + os.path.basename(path))
        self.resize(760, 520)

        root = QVBoxLayout(self)
        head = QHBoxLayout()
        self.summary = QLabel(base_name(path))
        self.summary.setStyleSheet("font-size: 15px; font-weight: 600;")
        head.addWidget(self.summary, 1)
        head.addWidget(QLabel("文件名编码"))
        self.encoding = QComboBox()
        for key, title in CHOICES:
            self.encoding.addItem(title, key)
        self.encoding.currentIndexChanged.connect(lambda _i: self.reload())
        head.addWidget(self.encoding)
        root.addLayout(head)

        self.tree = QTreeWidget()
        self.tree.setHeaderLabels(["名称", "大小", "加密"])
        self.tree.setColumnWidth(0, 460)
        self.tree.setSelectionMode(QTreeWidget.ExtendedSelection)
        self.tree.itemDoubleClicked.connect(self.preview)
        root.addWidget(self.tree, 1)

        buttons = QHBoxLayout()
        for text, slot in (
            ("全部解压", self.extract_all),
            ("解压所选", self.extract_selected),
            ("测试是否损坏", self.test),
        ):
            button = QPushButton(text)
            button.clicked.connect(slot)
            buttons.addWidget(button)
        buttons.addStretch(1)
        close = QPushButton("关闭")
        close.clicked.connect(self.close)
        buttons.addWidget(close)
        root.addLayout(buttons)
        self.reload()

    def reload(self) -> None:
        encoding = self.encoding.currentData() or "auto"
        try:
            self.listing = list_archive(
                self.path,
                encoding=encoding,
                password=self.password,
                candidates=self.host.saved_passwords(),
            )
        except ArchiveError as exc:
            if exc.code in ("password", "wrong_password"):
                entered = self.host.ask_password(
                    os.path.basename(self.path), wrong=exc.code == "wrong_password"
                )
                if not entered:
                    self.summary.setText("需要密码才能查看这个压缩包")
                    return
                self.password = entered[0]
                if entered[1]:
                    self.host.remember_password(entered[0])
                self.reload()
                return
            QMessageBox.warning(self, "打不开", str(exc))
            return
        self._fill()

    def _fill(self) -> None:
        listing = self.listing
        if listing is None:
            return
        enc = f" · 文件名按 {listing.legacy_encoding}" if listing.legacy_encoding else ""
        self.summary.setText(
            f"{listing.format_name} · {listing.file_count} 个文件 · {format_bytes(listing.total_size)}{enc}"
        )
        self.tree.clear()
        nodes = {"": self.tree.invisibleRootItem()}
        for item in listing.items:
            parts = item.path.split("/")
            parent = ""
            built = ""
            for index, part in enumerate(parts):
                built = part if not built else built + "/" + part
                if built not in nodes:
                    last = index == len(parts) - 1
                    size = format_bytes(item.size) if last and not item.is_directory else ""
                    locked = "是" if last and item.encrypted else ""
                    node = QTreeWidgetItem([part, size, locked])
                    node.setData(0, Qt.UserRole, built)
                    node.setData(0, Qt.UserRole + 1, bool(item.is_directory) if last else True)
                    nodes[parent].addChild(node)
                    nodes[built] = node
                parent = built
        self.tree.expandToDepth(1)

    def _selected_paths(self) -> set[str]:
        paths = set()
        for item in self.tree.selectedItems():
            path = item.data(0, Qt.UserRole)
            if path:
                paths.add(path)
        return paths

    def extract_all(self) -> None:
        self.host.extract_archives(
            [self.path],
            encoding=self.encoding.currentData() or "auto",
            password=self.password,
        )

    def extract_selected(self) -> None:
        paths = self._selected_paths()
        if not paths:
            QMessageBox.information(self, "解压所选", "先在列表里选中要解压的文件或文件夹。")
            return
        self.host.extract_archives(
            [self.path],
            encoding=self.encoding.currentData() or "auto",
            password=self.password,
            selection=paths,
        )

    def test(self) -> None:
        self.host.enqueue_test(self.path, self.password)

    def preview(self, item, _column) -> None:
        path = item.data(0, Qt.UserRole)
        if not path or item.data(0, Qt.UserRole + 1):
            item.setExpanded(not item.isExpanded())
            return
        self.host.extract_archives(
            [self.path],
            encoding=self.encoding.currentData() or "auto",
            password=self.password,
            selection={path},
            folder_mode="never",
            open_file=True,
        )
